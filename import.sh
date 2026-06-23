#!/usr/bin/env bash
# Imports / upserts the ClickStack dashboard templates into a self-hosted (OSS) HyperDX instance.
#
# Resolves install-specific source IDs / connection / table names from the HyperDX v2 API,
# substitutes the {{TOKENS}} in each template, then UPSERTS each dashboard: dashboards are matched
# by their stable "tmpl:<slug>" tag and updated in place (PUT) instead of duplicated. If no match
# exists, a new dashboard is created (POST).
#
# Usage:
#   export HDX_API_URL="http://localhost:8000"
#   export HDX_API_KEY="<Personal API Access Key from Team Settings -> API Keys>"
#   ./import.sh                      # upsert all
#   ./import.sh --dry-run            # preview, write nothing
#   ./import.sh --only services-red.json,logs-overview.json
#   ./import.sh --delete             # remove template-managed dashboards (by tmpl tag)
#   ./import.sh --duplicate          # force-create new copies (legacy behavior)
#
# Requires: curl, jq

set -euo pipefail

DRY_RUN=0; DELETE=0; DUPLICATE=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --delete)    DELETE=1 ;;
    --duplicate) DUPLICATE=1 ;;
    --only)      ONLY="$2"; shift ;;
    --only=*)    ONLY="${1#*=}" ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

: "${HDX_API_URL:?Set HDX_API_URL (e.g. http://localhost:8000)}"
: "${HDX_API_KEY:?Set HDX_API_KEY (Team Settings -> API Keys -> Personal API Access Key)}"

BASE_URL="${HDX_API_URL%/}"
AUTH="Authorization: Bearer ${HDX_API_KEY}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# Unwrap optional { "data": ... } envelope.
unwrap() { jq 'if type=="object" and has("data") then .data else . end'; }

echo "Fetching sources from ${BASE_URL} ..."
SOURCES="$(curl -fsS -H "$AUTH" "${BASE_URL}/api/v2/sources" | unwrap)"

pick() { echo "$SOURCES" | jq -r --arg k "$1" 'map(select(.kind==$k)) | .[0] // empty'; }
LOG="$(pick log)";       [ -n "$LOG" ]    || { echo "No 'log' source found";    exit 1; }
TRACE="$(pick trace)";   [ -n "$TRACE" ]  || { echo "No 'trace' source found";  exit 1; }
METRIC="$(pick metric)"; [ -n "$METRIC" ] || { echo "No 'metric' source found"; exit 1; }

LOGS_SOURCE_ID="$(echo "$LOG" | jq -r .id)"
TRACES_SOURCE_ID="$(echo "$TRACE" | jq -r .id)"
METRICS_SOURCE_ID="$(echo "$METRIC" | jq -r .id)"
CONNECTION_ID="$(echo "$METRIC" | jq -r .connection)"
METRICS_SCHEMA="$(echo "$METRIC" | jq -r '.from.databaseName // "default"')"
LOGS_SCHEMA="$(echo "$LOG" | jq -r .from.databaseName)"
LOGS_TABLE="$(echo "$LOG" | jq -r .from.tableName)"
TRACES_SCHEMA="$(echo "$TRACE" | jq -r .from.databaseName)"
TRACES_TABLE="$(echo "$TRACE" | jq -r .from.tableName)"

echo "Resolved sources: logs=${LOGS_SOURCE_ID} traces=${TRACES_SOURCE_ID} metrics=${METRICS_SOURCE_ID}"
[ "$DRY_RUN" = 1 ] && echo "[DRY RUN] no changes will be written."

# Existing dashboards (for tmpl-tag matching).
EXISTING="$(curl -fsS -H "$AUTH" "${BASE_URL}/api/v2/dashboards" | unwrap)"

# Find an existing dashboard id by its tmpl tag.
find_existing_id() {
  echo "$EXISTING" | jq -r --arg t "$1" '[.[] | select(.tags // [] | index($t))][0].id // empty'
}
# Existing filters (array) for an existing dashboard id.
existing_filters() {
  echo "$EXISTING" | jq -c --arg id "$1" '[.[] | select(.id==$id)][0].filters // []'
}

# Build the file list.
mapfile -t FILES < <(ls "$DIR"/dashboards/*.json)
if [ -n "$ONLY" ]; then
  IFS=',' read -ra WANTED <<< "$ONLY"
  SELECTED=()
  for f in "${FILES[@]}"; do
    base="$(basename "$f")"
    for w in "${WANTED[@]}"; do [ "$base" = "$(echo "$w" | xargs)" ] && SELECTED+=("$f"); done
  done
  FILES=("${SELECTED[@]}")
fi

for f in "${FILES[@]}"; do
  base="$(basename "$f")"
  raw="$(sed \
    -e "s|{{LOGS_SOURCE_ID}}|${LOGS_SOURCE_ID}|g" \
    -e "s|{{TRACES_SOURCE_ID}}|${TRACES_SOURCE_ID}|g" \
    -e "s|{{METRICS_SOURCE_ID}}|${METRICS_SOURCE_ID}|g" \
    -e "s|{{CONNECTION_ID}}|${CONNECTION_ID}|g" \
    -e "s|{{METRICS_SCHEMA}}|${METRICS_SCHEMA}|g" \
    -e "s|{{LOGS_SCHEMA}}|${LOGS_SCHEMA}|g" \
    -e "s|{{LOGS_TABLE}}|${LOGS_TABLE}|g" \
    -e "s|{{TRACES_SCHEMA}}|${TRACES_SCHEMA}|g" \
    -e "s|{{TRACES_TABLE}}|${TRACES_TABLE}|g" \
    "$f")"

  tmpl_tag="$(echo "$raw" | jq -r '(.tags // []) | map(select(startswith("tmpl:")))[0] // empty')"
  if [ -z "$tmpl_tag" ]; then echo "WARN: $base has no 'tmpl:' tag; skipping."; continue; fi
  match_id="$(find_existing_id "$tmpl_tag")"

  # --- delete mode ---
  if [ "$DELETE" = 1 ]; then
    if [ -n "$match_id" ]; then
      if [ "$DRY_RUN" = 1 ]; then echo "[DRY RUN] would DELETE $base -> $match_id"; else
        curl -fsS -H "$AUTH" -X DELETE "${BASE_URL}/api/v2/dashboards/${match_id}" >/dev/null
        echo "Deleted $base -> $match_id"
      fi
    else echo "No existing dashboard for $base ($tmpl_tag)"; fi
    continue
  fi

  if echo "$raw" | grep -q '{{[A-Z_]\+}}'; then
    echo "WARN: $base still has unresolved tokens; skipping."; continue
  fi

  use_update=0
  [ -n "$match_id" ] && [ "$DUPLICATE" = 0 ] && use_update=1

  if [ "$DRY_RUN" = 1 ]; then
    if [ "$use_update" = 1 ]; then echo "[DRY RUN] would UPDATE -> $match_id  $base";
    else echo "[DRY RUN] would CREATE  $base"; fi
    continue
  fi

  if [ "$use_update" = 1 ]; then
    # PUT requires each filter to carry an "id". Reuse the existing dashboard's filter ids
    # (matched by expression); mint a new 24-hex id for any filter it doesn't have.
    ex_filters="$(existing_filters "$match_id")"
    body="$(echo "$raw" | jq -c --argjson ex "$ex_filters" '
      .filters = ((.filters // []) | map(
        . as $f
        | ($ex | map(select(.expression==$f.expression))[0].id) as $eid
        | .id = ($eid // ($f.expression | @base64 | gsub("[^a-zA-Z0-9]";"") | .[0:24]))
      ))')"
    if curl -fsS -H "$AUTH" -H 'Content-Type: application/json' \
         -X PUT "${BASE_URL}/api/v2/dashboards/${match_id}" -d "$body" >/dev/null; then
      echo "Updated $base -> $match_id"
    else echo "WARN: update failed for $base"; fi
  else
    id="$(curl -fsS -H "$AUTH" -H 'Content-Type: application/json' \
          -X POST "${BASE_URL}/api/v2/dashboards" -d "$raw" \
          | jq -r 'if type=="object" and has("data") then .data.id else .id end')"
    echo "Created $base -> $id"
  fi
done

echo "Done."
