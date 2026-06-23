#!/usr/bin/env bash
# Compatibility pre-flight for the ClickStack dashboard templates.
#
# For every metric/field each dashboard needs (see requirements.json), runs a lightweight query
# via the HyperDX v2 charts API and reports whether data is actually flowing. Tells you which
# dashboards are safe to import BEFORE you import them.
#
#   OK        all required + optional checks have data
#   DEGRADED  all required checks pass; some optional tiles will be empty
#   FAIL      one or more required checks have no data (do not import as-is)
#
# Usage:
#   export HDX_API_URL="http://localhost:8000"
#   export HDX_API_KEY="<Personal API Access Key>"
#   ./preflight.sh                 # 24h lookback
#   ./preflight.sh --hours 6
#
# Requires: curl, jq

set -euo pipefail

LOOKBACK_HOURS=24
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) LOOKBACK_HOURS="$2"; shift ;;
    --hours=*) LOOKBACK_HOURS="${1#*=}" ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

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

# check_has_data <kind> <metricName|""> <metricType|""> <where|"">  -> prints "rows=<sum>"; exit 0 if >0
check_has_data() {
  local kind="$1" mname="$2" mtype="$3" where="$4" sid series body resp sum
  case "$kind" in
    metric) sid="$METRIC_ID" ;;
    trace)  sid="$TRACE_ID" ;;
    log)    sid="$LOG_ID" ;;
  esac

  if [ "$kind" = "metric" ]; then
    # 'count' is not a valid aggregation for metric series (returns no datapoints), and a gauge
    # can legitimately read 0 while still flowing — use avg and test for *presence* of datapoints.
    series="$(jq -n --arg s "$sid" --arg m "$mname" --arg t "$mtype" \
      '{sourceId:$s, aggFn:"avg", where:"", groupBy:[], metricName:$m, metricDataType:$t}')"
  elif [ -n "$where" ]; then
    series="$(jq -n --arg s "$sid" --arg w "$where" \
      '{sourceId:$s, aggFn:"count", where:$w, whereLanguage:"lucene", groupBy:[]}')"
  else
    series="$(jq -n --arg s "$sid" '{sourceId:$s, aggFn:"count", where:"", groupBy:[]}')"
  fi

  local gran="1d"; [ "$kind" = "metric" ] && gran="1h"
  body="$(jq -n --argjson se "$series" --argjson st "$START_TIME" --argjson et "$END_TIME" --arg g "$gran" \
    '{series:[$se], startTime:$st, endTime:$et, granularity:$g, seriesReturnType:"column"}')"

  resp="$(curl -fsS -H "$AUTH" -H 'Content-Type: application/json' \
          -X POST "${BASE_URL}/api/v2/charts/series" -d "$body" 2>/dev/null || echo '')"
  if [ -z "$resp" ]; then echo "rows=0"; return 1; fi
  if [ "$kind" = "metric" ]; then
    local points
    points="$(echo "$resp" | jq '[ (.data // [])[] | select(.series_0 != null) ] | length')"
    echo "points=$points"
    awk "BEGIN{exit !($points>0)}"
    return
  fi
  sum="$(echo "$resp" | jq '[ (.data // [])[] | (.series_0 // 0) ] | add // 0')"
  echo "rows=$sum"
  awk "BEGIN{exit !($sum>0)}"
}

RECOMMEND=()
declare -a SUMMARY

ndash="$(jq '.dashboards | length' "$REQ")"
for ((i=0; i<ndash; i++)); do
  name="$(jq -r ".dashboards[$i].name" "$REQ")"
  file="$(jq -r ".dashboards[$i].file" "$REQ")"
  receivers="$(jq -r ".dashboards[$i].receivers | join(\"; \")" "$REQ")"
  echo ""
  echo "== $name ($file) =="
  echo "   receivers: $receivers"

  req_fail=0; opt_fail=0
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

    if detail="$(check_has_data "$kind" "$mname" "$mtype" "$where")"; then
      echo "   PASS $tag $label  ($detail)"
    else
      echo "   MISS $tag $label  ($detail)"
      if [ "$required" = "true" ]; then req_fail=$((req_fail+1)); else opt_fail=$((opt_fail+1)); fi
    fi
  done

  if [ "$req_fail" -gt 0 ]; then status="FAIL"
  elif [ "$opt_fail" -gt 0 ]; then status="DEGRADED"
  else status="OK"; fi
  [ "$status" != "FAIL" ] && RECOMMEND+=("$file")
  SUMMARY+=("$(printf '%-40s %-9s req_missing=%d opt_missing=%d' "$name" "$status" "$req_fail" "$opt_fail")")
done

echo ""
echo "===== SUMMARY ====="
for line in "${SUMMARY[@]}"; do echo "$line"; done

echo ""
if [ "${#RECOMMEND[@]}" -gt 0 ]; then
  echo "Safe to import:"
  for f in "${RECOMMEND[@]}"; do echo "   $f"; done
  echo ""
  echo "Then run: ./import.sh --only $(IFS=,; echo "${RECOMMEND[*]}")"
else
  echo "No dashboards passed their required checks. Verify your OTel collector is sending data."
fi
