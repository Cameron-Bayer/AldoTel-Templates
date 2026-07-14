#!/usr/bin/env bash
# Discover the metric names that actually exist in your ClickStack install and compare them to
# what the dashboard templates expect.
#
# preflight tells you whether a dashboard's *exact* expected metric name has data. When it reports
# MISS, the metric may be genuinely absent OR just named differently by your collector
# (e.g. k8s.node.cpu.usage vs k8s.node.cpu.utilization, or a missing *_total suffix).
#
# This script:
#   1. Resolves your metric schema (database + gauge/sum/histogram tables) from the HyperDX API.
#   2. Enumerates the DISTINCT metric names present in ClickHouse over the lookback window.
#   3. Compares them to requirements.json and, for every MISSING one, fuzzy-matches against the
#      names you *do* have and prints the closest candidates.
#
# Connection via environment variables:
#   HyperDX API (to resolve the metric schema):
#     export HDX_API_URL="https://api.aldotel.local"   # or http://localhost:8000 for a port-forward
#     export HDX_API_KEY="<Personal API Access Key>"
#   ClickHouse HTTP (the metrics live here, not behind the HDX API):
#     export CH_URL="http://localhost:8123"
#     export CH_USER="app"                             # default: app
#     export CH_PASSWORD="<clickhouse password>"        # omit if no password
#     export CH_DATABASE="default"                     # optional; else taken from the HDX source
#
# Reaching ClickHouse:
#   * Helm/Kubernetes (ingress at aldotel.local):
#       kubectl -n <ns> port-forward svc/<clickhouse-headless-svc> 8123:8123
#   * docker-compose/all-in-one: ClickHouse HTTP is usually already on http://localhost:8123.
#
# Usage:
#   ./list-metrics.sh                       # 24h lookback, all tables
#   ./list-metrics.sh --hours 0             # scan all history
#   ./list-metrics.sh --table gauge --top 5
#   ./list-metrics.sh --dump-to actual-metrics.txt --show-all
#
# Requires: curl, jq, awk

set -euo pipefail

LOOKBACK_HOURS=24
TABLE=""
TOP=3
DUMP_TO=""
SHOW_ALL=0
SKIP_SIGNALS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) LOOKBACK_HOURS="$2"; shift ;;
    --hours=*) LOOKBACK_HOURS="${1#*=}" ;;
    --table) TABLE="$2"; shift ;;
    --table=*) TABLE="${1#*=}" ;;
    --top) TOP="$2"; shift ;;
    --top=*) TOP="${1#*=}" ;;
    --dump-to) DUMP_TO="$2"; shift ;;
    --dump-to=*) DUMP_TO="${1#*=}" ;;
    --show-all) SHOW_ALL=1 ;;
    --skip-signals) SKIP_SIGNALS=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

CH_URL="${CH_URL:-http://localhost:8123}"; CH_URL="${CH_URL%/}"
CH_USER="${CH_USER:-app}"
CH_PASSWORD="${CH_PASSWORD:-}"
DIR="$(cd "$(dirname "$0")" && pwd)"
REQ="$DIR/requirements.json"

ch_headers=(-H "X-ClickHouse-User: ${CH_USER}")
[ -n "$CH_PASSWORD" ] && ch_headers+=(-H "X-ClickHouse-Key: ${CH_PASSWORD}")
ch_query() { curl -fsS "${ch_headers[@]}" "${CH_URL}/" --data-binary "$1"; }

# ---------- Resolve metric schema ----------
DATABASE="${CH_DATABASE:-}"
G_TBL="otel_metrics_gauge"; S_TBL="otel_metrics_sum"; H_TBL="otel_metrics_histogram"
LOG_DB=""; LOG_TBL="otel_logs"; LOG_TS="Timestamp"
TRACE_DB=""; TRACE_TBL="otel_traces"; TRACE_TS="Timestamp"
if [ -n "${HDX_API_URL:-}" ] && [ -n "${HDX_API_KEY:-}" ]; then
  base="${HDX_API_URL%/}"
  if src="$(curl -fsS -H "Authorization: Bearer ${HDX_API_KEY}" "${base}/api/v2/sources" 2>/dev/null)"; then
    src="$(echo "$src" | jq 'if type=="object" and has("data") then .data else . end')"
    m="$(echo "$src" | jq 'map(select(.kind=="metric")) | .[0] // empty')"
    if [ -n "$m" ] && [ "$m" != "null" ]; then
      [ -z "$DATABASE" ] && DATABASE="$(echo "$m" | jq -r '.from.databaseName // empty')"
      G_TBL="$(echo "$m" | jq -r '.metricTables.gauge // "otel_metrics_gauge"')"
      S_TBL="$(echo "$m" | jq -r '.metricTables.sum // "otel_metrics_sum"')"
      H_TBL="$(echo "$m" | jq -r '.metricTables.histogram // "otel_metrics_histogram"')"
      echo "Resolved metric schema from HyperDX: db='${DATABASE}' tables=${G_TBL}, ${S_TBL}, ${H_TBL}"
    fi
    lg="$(echo "$src" | jq 'map(select(.kind=="log")) | .[0] // empty')"
    if [ -n "$lg" ] && [ "$lg" != "null" ]; then
      LOG_DB="$(echo "$lg" | jq -r '.from.databaseName // empty')"
      LOG_TBL="$(echo "$lg" | jq -r '.from.tableName // "otel_logs"')"
      LOG_TS="$(echo "$lg" | jq -r '.timestampValueExpression // "Timestamp"')"
    fi
    tr="$(echo "$src" | jq 'map(select(.kind=="trace")) | .[0] // empty')"
    if [ -n "$tr" ] && [ "$tr" != "null" ]; then
      TRACE_DB="$(echo "$tr" | jq -r '.from.databaseName // empty')"
      TRACE_TBL="$(echo "$tr" | jq -r '.from.tableName // "otel_traces"')"
      TRACE_TS="$(echo "$tr" | jq -r '.timestampValueExpression // "Timestamp"')"
    fi
  else
    echo "WARN: could not resolve schema from HyperDX API; using defaults." >&2
  fi
fi
[ -n "$DATABASE" ] || DATABASE="default"
[ -n "$LOG_DB" ] || LOG_DB="$DATABASE"
[ -n "$TRACE_DB" ] || TRACE_DB="$DATABASE"

declare -a SCAN
if [ -n "$TABLE" ]; then
  case "$TABLE" in
    gauge) SCAN=("gauge:$G_TBL") ;;
    sum) SCAN=("sum:$S_TBL") ;;
    histogram) SCAN=("histogram:$H_TBL") ;;
    *) echo "Unknown --table: $TABLE (gauge|sum|histogram)"; exit 2 ;;
  esac
else
  SCAN=("gauge:$G_TBL" "sum:$S_TBL" "histogram:$H_TBL")
fi

TIME_FILTER=""
[ "$LOOKBACK_HOURS" -gt 0 ] 2>/dev/null && TIME_FILTER="WHERE TimeUnix >= now() - INTERVAL ${LOOKBACK_HOURS} HOUR"

# ---------- Enumerate actual metric names ----------
# ACTUAL file: "name<TAB>kind" lines (kind may repeat across tables)
ACTUAL="$(mktemp)"; trap 'rm -f "$ACTUAL"' EXIT
echo "Enumerating metric names from ClickHouse at ${CH_URL} (db=${DATABASE}, lookback=${LOOKBACK_HOURS}h) ..."
for pair in "${SCAN[@]}"; do
  kind="${pair%%:*}"; tbl="${pair#*:}"
  sql="SELECT DISTINCT MetricName FROM \`${DATABASE}\`.\`${tbl}\` ${TIME_FILTER} FORMAT TabSeparated"
  if names="$(ch_query "$sql")"; then
    cnt="$(printf '%s\n' "$names" | grep -c . || true)"
    printf '   %-10s %-28s %s names\n' "$kind" "$tbl" "$cnt"
    printf '%s\n' "$names" | grep . | while IFS= read -r n; do printf '%s\t%s\n' "$n" "$kind"; done >> "$ACTUAL"
  else
    echo "   ERROR reading ${DATABASE}.${tbl}" >&2
  fi
done

# unique names
NAMES="$(cut -f1 "$ACTUAL" | sort -u)"
TOTAL="$(printf '%s\n' "$NAMES" | grep -c . || true)"
if [ "$TOTAL" -eq 0 ]; then
  echo "No metric names found. Check CH_URL/CH_USER/CH_PASSWORD and that metrics are flowing (try --hours 0)." >&2
  exit 1
fi
echo "Total distinct metric names: ${TOTAL}"
[ -n "$DUMP_TO" ] && { printf '%s\n' "$NAMES" > "$DUMP_TO"; echo "Wrote full list to $DUMP_TO"; }

# ---------- Load expected metrics ----------
# EXPECTED: "metricName<TAB>required<TAB>type<TAB>dashboards"
# When restricted to one table, only audit expected metrics of that type — otherwise metrics that
# legitimately live in a different table would be reported as falsely absent.
EXPECTED="$(jq -r --arg tbl "$TABLE" '
  [ .dashboards[] as $d | $d.checks[] | select(.kind=="metric")
    | select($tbl=="" or .metricType==$tbl)
    | {name:.metricName, required:.required, type:.metricType, file:$d.file} ]
  | group_by(.name)
  | map({ name: .[0].name,
          required: (map(.required) | any),
          type: .[0].type,
          files: (map(.file) | unique | join(", ")) })
  | .[] | "\(.name)\t\(.required)\t\(.type)\t\(.files)"
' "$REQ")"

# ---------- Compare + fuzzy-suggest (awk) ----------
printf '%s\n' "$NAMES" | awk -v top="$TOP" -v showall="$SHOW_ALL" '
  # normalized string: lowercase alnum only
  function norm(s,  t){ t=tolower(s); gsub(/[^a-z0-9]/,"",t); return t }
  # tokenize into array toks[], returns count
  function toks(s, arr,  n,i,parts){ n=split(tolower(s), parts, /[^a-z0-9]+/); delete arr; i=0
    for(k=1;k<=n;k++){ if(parts[k]!=""){ i++; arr[i]=parts[k] } } return i }
  function sim(a,b,  ca,cb,ta,tb,i,j,inter,uni,seen,na,nb,subs,ml,mx,jac){
    ca=toks(a,ta); cb=toks(b,tb); inter=0; delete seen
    for(i=1;i<=ca;i++) seen[ta[i]]=1
    for(j=1;j<=cb;j++) if(seen[tb[j]]){ inter++ }
    # union = distinct tokens across both
    delete seen; uni=0
    for(i=1;i<=ca;i++){ if(!(ta[i] in seen)){seen[ta[i]]=1; uni++} }
    for(j=1;j<=cb;j++){ if(!(tb[j] in seen)){seen[tb[j]]=1; uni++} }
    jac=(uni>0)?inter/uni:0
    na=norm(a); nb=norm(b); subs=0
    if(na!="" && nb!=""){ if(index(na,nb)||index(nb,na)){
        ml=(length(na)<length(nb))?length(na):length(nb)
        mx=(length(na)>length(nb))?length(na):length(nb)
        subs=(mx>0)?(ml/mx)*0.9:0 } }
    return (jac>subs)?jac:subs
  }
  # pass 1: read actual names from stdin
  { actual[NR]=$0; nact=NR }
  END{
    # read expected from file via getline
    present=0; missing=0
    while((getline line < ENVEXP) > 0){
      nf=split(line, f, "\t"); ename=f[1]; ereq=f[2]; etype=f[3]; efiles=f[4]
      has=0
      for(i=1;i<=nact;i++) if(actual[i]==ename){ has=1; break }
      if(has){ present++ ; continue }
      missing++
      mnames[missing]=ename; mreq[missing]=ereq; mtype[missing]=etype; mfiles[missing]=efiles
    }
    printf "\n===== EXPECTED METRICS AUDIT =====\n"
    printf "Present: %d   Missing: %d\n", present, missing
    if(missing==0){
      print "Every expected metric name exists in your install. Any preflight MISS is a lookback/aggregation quirk, not a naming issue."
    } else {
      print "\n----- MISSING expected metrics (with closest actual names) -----"
      # required first
      for(pass=0; pass<2; pass++){
        for(m=1;m<=missing;m++){
          isreq=(mreq[m]=="true")
          if((pass==0)!=isreq) continue
          tag=(isreq)?"[required]":"[optional]"
          printf "\n%s %s   (type=%s; used by %s)\n", tag, mnames[m], mtype[m], mfiles[m]
          # score all actual
          delete sc
          for(i=1;i<=nact;i++){ sc[i]=sim(mnames[m], actual[i]) }
          shown=0
          for(t=0;t<top;t++){
            best=-1; bi=0
            for(i=1;i<=nact;i++){ if(sc[i]>best){ best=sc[i]; bi=i } }
            if(bi==0 || best<=0.34) break
            printf "     ~ %3d%%  %s\n", int(best*100+0.5), actual[bi]
            sc[bi]=-1; shown++
          }
          if(shown>0) print "       -> likely RENAMED. If one matches, update the tile + requirements.json metricName."
          else print "     (no similar name found) -> likely TRULY ABSENT: this collector/receiver isn'\''t sending it."
        }
      }
    }
    if(showall=="1"){
      printf "\n===== ALL ACTUAL METRIC NAMES =====\n"
      n=asort(actual, sorted)
      for(i=1;i<=n;i++) print "   " sorted[i]
    }
  }
' ENVEXP=<(printf '%s\n' "$EXPECTED")

# ---------- Signal-value discovery (logs severity, trace kind/status) ----------
# Trace/log tiles filter on column *values* (SpanKind:Server, StatusCode:Error, error/fatal severity),
# not metric names. A preflight MISS there can mean the value is labelled differently. Enumerate the
# actual distinct values so a value-mismatch is obvious.
if [ "$SKIP_SIGNALS" != "1" ]; then
  LOG_WHERE=""; TRACE_WHERE=""
  if [ "$LOOKBACK_HOURS" -gt 0 ] 2>/dev/null; then
    LOG_WHERE="WHERE ${LOG_TS} >= now() - INTERVAL ${LOOKBACK_HOURS} HOUR"
    TRACE_WHERE="WHERE ${TRACE_TS} >= now() - INTERVAL ${LOOKBACK_HOURS} HOUR"
  fi
  echo ""
  echo "===== SIGNAL VALUE DISCOVERY (logs & traces) ====="

  # --- Logs: severity labelling ---
  log_sql="SELECT SeverityText, SeverityNumber, count() AS c FROM \`${LOG_DB}\`.\`${LOG_TBL}\` ${LOG_WHERE} GROUP BY SeverityText, SeverityNumber ORDER BY c DESC LIMIT 30 FORMAT TabSeparated"
  if log_rows="$(ch_query "$log_sql" 2>/dev/null)" && [ -n "$log_rows" ]; then
    echo ""
    echo "Logs — SeverityText / SeverityNumber distribution (${LOG_DB}.${LOG_TBL}):"
    printf '%s\n' "$log_rows" | awk -F'\t' '
      { txt=$1; num=$2+0; cnt=$3+0
        lc=tolower(txt); isErr=(num>=17 || lc=="error" || lc=="fatal" || lc=="err" || lc=="critical" || lc=="crit" || lc=="emerg" || lc=="alert")
        if(isErr) errTotal+=cnt
        printf "   %s  %-14s num=%-3s %12d\n", (isErr?"ERR":"   "), (txt==""?"(empty)":txt), num, cnt }
      END{ if(errTotal>0) printf "   => error/fatal logs ARE present (%d rows). The error tiles should populate; if preflight said MISS, widen the lookback.\n", errTotal
           else print "   => no error/fatal-level logs in window. \"error logs\" is TRULY ABSENT (not a naming issue)." }'
  else
    echo "Logs: no rows in window or table unreadable (${LOG_DB}.${LOG_TBL})."
  fi

  # --- Traces: span kind + status ---
  trace_sql="SELECT SpanKind, StatusCode, count() AS c FROM \`${TRACE_DB}\`.\`${TRACE_TBL}\` ${TRACE_WHERE} GROUP BY SpanKind, StatusCode ORDER BY c DESC LIMIT 30 FORMAT TabSeparated"
  if trace_rows="$(ch_query "$trace_sql" 2>/dev/null)" && [ -n "$trace_rows" ]; then
    echo ""
    echo "Traces — SpanKind / StatusCode distribution (${TRACE_DB}.${TRACE_TBL}):"
    printf '%s\n' "$trace_rows" | awk -F'\t' '
      { k=$1; st=$2; cnt=$3+0
        printf "   SpanKind=%-12s StatusCode=%-8s %12d\n", (k==""?"(empty)":k), (st==""?"(empty)":st), cnt
        if(tolower(k)=="server") hasServer=1; if(tolower(st)=="error") hasError=1
        kinds[k]=1; statuses[st]=1 }
      END{ if(!hasServer){ ks=""; for(x in kinds) ks=ks (ks==""?"":", ") x
             printf "   ! No SpanKind='"'"'Server'"'"' found (present: %s). Templates filter SpanKind:Server.\n", ks }
           if(!hasError){ ss=""; for(x in statuses) ss=ss (ss==""?"":", ") x
             printf "   ! No StatusCode='"'"'Error'"'"' found (present: %s). Error-span tiles filter StatusCode:Error.\n", ss } }'
  else
    echo ""
    echo "Traces: no rows in window => trace dashboards (services-red, slo-errorbudget) are TRULY EMPTY: no spans ingested."
  fi
fi

echo ""
echo "Done. Investigate the MISSING list above."
