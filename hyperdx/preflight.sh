#!/usr/bin/env bash
# Compatibility pre-flight for the ClickStack dashboard templates.
#
# For every metric/field each dashboard needs (see requirements.json), runs a lightweight query
# via the HyperDX v2 charts API and reports whether the OTel telemetry each dashboard reads is
# actually flowing. NOTE: this checks OTel data presence only — it does NOT verify ClickHouse
# Raw SQL access (system.parts / system.part_log / system.query_log) that the SQL-based
# dashboards (clickhouse-storage-mergetree, clickhouse-queryperf) additionally require.
#
#   OK        all required + optional checks have data
#   DEGRADED  all required checks pass; some optional tiles will be empty
#   FAIL      one or more required checks have no data (do not import as-is)
#   UNKNOWN   one or more probes still failed after retries; run again before importing
#
# Usage:
#   export HDX_API_URL="http://localhost:8000"
#   export HDX_API_KEY="<Personal API Access Key>"
#   ./preflight.sh                 # 24h logs/traces; 60m metrics
#   ./preflight.sh --hours 6
#   ./preflight.sh --metric-minutes 15 --retries 3
#
# Requires: curl, jq

set -euo pipefail

LOOKBACK_HOURS=24
METRIC_PROBE_MINUTES=60
QUERY_RETRIES=2
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) [ $# -ge 2 ] || { echo "--hours requires a value." >&2; exit 2; }
             LOOKBACK_HOURS="$2"; shift ;;
    --hours=*) LOOKBACK_HOURS="${1#*=}" ;;
    --metric-minutes) [ $# -ge 2 ] || { echo "--metric-minutes requires a value." >&2; exit 2; }
                       METRIC_PROBE_MINUTES="$2"; shift ;;
    --metric-minutes=*) METRIC_PROBE_MINUTES="${1#*=}" ;;
    --retries) [ $# -ge 2 ] || { echo "--retries requires a value." >&2; exit 2; }
                QUERY_RETRIES="$2"; shift ;;
    --retries=*) QUERY_RETRIES="${1#*=}" ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$LOOKBACK_HOURS" in ''|*[!0-9]*) echo "--hours must be an integer from 1 to 720." >&2; exit 2;; esac
case "$METRIC_PROBE_MINUTES" in ''|*[!0-9]*) echo "--metric-minutes must be an integer from 1 to 1440." >&2; exit 2;; esac
case "$QUERY_RETRIES" in ''|*[!0-9]*) echo "--retries must be an integer from 0 to 10." >&2; exit 2;; esac
[ "$LOOKBACK_HOURS" -ge 1 ] && [ "$LOOKBACK_HOURS" -le 720 ] ||
  { echo "--hours must be from 1 to 720." >&2; exit 2; }
[ "$METRIC_PROBE_MINUTES" -ge 1 ] && [ "$METRIC_PROBE_MINUTES" -le 1440 ] ||
  { echo "--metric-minutes must be from 1 to 1440." >&2; exit 2; }
[ "$QUERY_RETRIES" -ge 0 ] && [ "$QUERY_RETRIES" -le 10 ] ||
  { echo "--retries must be from 0 to 10." >&2; exit 2; }

: "${HDX_API_URL:?Set HDX_API_URL (e.g. http://localhost:8000)}"
: "${HDX_API_KEY:?Set HDX_API_KEY (Team Settings -> API Keys)}"

BASE_URL="${HDX_API_URL%/}"
AUTH="Authorization: Bearer ${HDX_API_KEY}"
DIR="$(cd "$(dirname "$0")" && pwd)"
REQ="$DIR/requirements.json"

unwrap() { jq 'if type=="object" and has("data") then .data else . end'; }

echo "Resolving sources from ${BASE_URL} ..."
SOURCES="$(curl -fsS -H "$AUTH" "${BASE_URL}/api/v2/sources" | unwrap)"
src_id() { echo "$SOURCES" | jq -r --arg k "$1" 'map(select(.kind==$k)) | .[0].id // empty'; }
LOG_ID="$(src_id log)"; TRACE_ID="$(src_id trace)"; METRIC_ID="$(src_id metric)"
for pair in "log:$LOG_ID" "trace:$TRACE_ID" "metric:$METRIC_ID"; do
  [ -n "${pair#*:}" ] || { echo "No source of kind '${pair%%:*}' found in HyperDX."; exit 1; }
done

END_TIME="$(( $(date -u +%s) * 1000 ))"
START_TIME="$(( END_TIME - LOOKBACK_HOURS * 3600 * 1000 ))"
METRIC_START_TIME="$(( END_TIME - METRIC_PROBE_MINUTES * 60 * 1000 ))"
[ "$METRIC_START_TIME" -lt "$START_TIME" ] && METRIC_START_TIME="$START_TIME"

CACHE_KEYS=()
CACHE_DETAILS=()
CACHE_OK=()

# check_has_data <kind> <metricName|""> <metricType|""> <where|"">  -> prints "rows=<sum>"; exit 0 if >0
check_has_data() {
  local kind="$1" mname="$2" mtype="$3" where="$4" sid series body resp sum query_start window attempt
  case "$kind" in
    metric) sid="$METRIC_ID" ;;
    trace)  sid="$TRACE_ID" ;;
    log)    sid="$LOG_ID" ;;
  esac

  if [ "$kind" = "metric" ]; then
    # 'count' is not a valid aggregation for metric series (returns no datapoints), and a gauge
    # can legitimately read 0 while still flowing — use avg and test for *presence* of datapoints.
    # Histogram metrics reject avg/sum, so verify them with count (supported for that data type).
    local magg="avg"; [ "$mtype" = "histogram" ] && magg="count"
    series="$(jq -n --arg s "$sid" --arg m "$mname" --arg t "$mtype" --arg a "$magg" \
      '{sourceId:$s, aggFn:$a, where:"", groupBy:[], metricName:$m, metricDataType:$t}')"
  elif [ -n "$where" ]; then
    series="$(jq -n --arg s "$sid" --arg w "$where" \
      '{sourceId:$s, aggFn:"count", where:$w, whereLanguage:"lucene", groupBy:[]}')"
  else
    series="$(jq -n --arg s "$sid" '{sourceId:$s, aggFn:"count", where:"", groupBy:[]}')"
  fi

  query_start="$START_TIME"; window="${LOOKBACK_HOURS}h"
  if [ "$kind" = "metric" ]; then query_start="$METRIC_START_TIME"; window="${METRIC_PROBE_MINUTES}m"; fi
  body="$(jq -n --argjson se "$series" --argjson st "$query_start" --argjson et "$END_TIME" \
    '{series:[$se], startTime:$st, endTime:$et, granularity:"1h", seriesReturnType:"column"}')"

  attempt=0
  resp=""
  while [ "$attempt" -le "$QUERY_RETRIES" ]; do
    if resp="$(curl -fsS -H "$AUTH" -H 'Content-Type: application/json' \
                -X POST "${BASE_URL}/api/v2/charts/series" -d "$body" 2>/dev/null)"; then
      break
    fi
    resp=""
    attempt=$((attempt+1))
    [ "$attempt" -le "$QUERY_RETRIES" ] && sleep 1
  done
  if [ -z "$resp" ]; then echo "query error after $((QUERY_RETRIES+1)) attempts"; return 1; fi
  if [ "$kind" = "metric" ]; then
    local points
    points="$(echo "$resp" | jq '[ (.data // [])[] | select(.series_0 != null) ] | length')"
    echo "points=$points, window=$window"
    awk "BEGIN{exit !($points>0)}"
    return
  fi
  sum="$(echo "$resp" | jq '[ (.data // [])[] | (.series_0 // 0) ] | add // 0')"
  echo "rows=$sum, window=$window"
  awk "BEGIN{exit !($sum>0)}"
}

RECOMMEND=()
declare -a SUMMARY

ndash="$(jq '.dashboards | length' "$REQ")"
for ((i=0; i<ndash; i++)); do
  name="$(jq -r ".dashboards[$i].name" "$REQ")"
  file="$(jq -r ".dashboards[$i].file" "$REQ")"
  tier="$(jq -r ".dashboards[$i].tier // \"default\"" "$REQ")"
  receivers="$(jq -r ".dashboards[$i].receivers | join(\"; \")" "$REQ")"
  echo ""
  tier_tag=""; [ "$tier" = "advanced" ] && tier_tag=" [advanced]"
  echo "== $name ($file)$tier_tag =="
  echo "   receivers: $receivers"

  req_fail=0; opt_fail=0; query_errors=0
  nchecks="$(jq ".dashboards[$i].checks | length" "$REQ")"
  for ((j=0; j<nchecks; j++)); do
    kind="$(jq -r ".dashboards[$i].checks[$j].kind" "$REQ")"
    required="$(jq -r ".dashboards[$i].checks[$j].required" "$REQ")"
    mname="$(jq -r ".dashboards[$i].checks[$j].metricName // \"\"" "$REQ")"
    mtype="$(jq -r ".dashboards[$i].checks[$j].metricType // \"\"" "$REQ")"
    where="$(jq -r ".dashboards[$i].checks[$j].where // \"\"" "$REQ")"
    label="$(jq -r ".dashboards[$i].checks[$j].label // \"\"" "$REQ")"
    [ -n "$mname" ] && label="$mname"
    tag="[optional]"; [ "$required" = "true" ] && tag="[required]"

    cache_key="${kind}|${mtype}|${mname}|${where}"
    cache_index=-1
    for ((k=0; k<${#CACHE_KEYS[@]}; k++)); do
      if [ "${CACHE_KEYS[$k]}" = "$cache_key" ]; then cache_index=$k; break; fi
    done

    if [ "$cache_index" -ge 0 ]; then
      detail="${CACHE_DETAILS[$cache_index]}, cached"
      ok="${CACHE_OK[$cache_index]}"
    elif detail="$(check_has_data "$kind" "$mname" "$mtype" "$where")"; then
      ok=1
      CACHE_KEYS+=("$cache_key"); CACHE_DETAILS+=("$detail"); CACHE_OK+=("$ok")
    else
      ok=0
      case "$detail" in
        "query error"*) ;;
        *) CACHE_KEYS+=("$cache_key"); CACHE_DETAILS+=("$detail"); CACHE_OK+=("$ok") ;;
      esac
    fi

    if [ "$ok" = 1 ]; then
      echo "   PASS $tag $label  ($detail)"
    elif [ "${detail#query error}" != "$detail" ]; then
      echo "   ERROR $tag $label  ($detail)"
      query_errors=$((query_errors+1))
    else
      echo "   MISS $tag $label  ($detail)"
      if [ "$required" = "true" ]; then req_fail=$((req_fail+1)); else opt_fail=$((opt_fail+1)); fi
    fi
  done

  if [ "$req_fail" -gt 0 ]; then status="FAIL"
  elif [ "$query_errors" -gt 0 ]; then status="UNKNOWN"
  elif [ "$opt_fail" -gt 0 ]; then status="DEGRADED"
  else status="OK"; fi
  if [ "$status" = "OK" ] || [ "$status" = "DEGRADED" ]; then RECOMMEND+=("$file"); fi
  SUMMARY+=("$(printf '%-40s %-9s %-9s req_missing=%d opt_missing=%d query_errors=%d' "$name" "$tier" "$status" "$req_fail" "$opt_fail" "$query_errors")")
done

echo ""
echo "===== SUMMARY ====="
for line in "${SUMMARY[@]}"; do echo "$line"; done

echo ""
if [ "${#RECOMMEND[@]}" -gt 0 ]; then
  echo "OTel data present (telemetry tiles will render):"
  for f in "${RECOMMEND[@]}"; do echo "   $f"; done
  echo ""
  echo "Note: Raw-SQL dashboards also need the HyperDX ClickHouse user to have SELECT on the"
  echo "      relevant system.* tables (not checked here) — see requirements.json 'receivers'."
  echo ""
  echo "Then run: ./import.sh --only $(IFS=,; echo "${RECOMMEND[*]}")"
else
  echo "No dashboards passed their required checks. Verify your OTel collector is sending data."
fi
