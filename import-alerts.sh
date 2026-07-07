#!/usr/bin/env bash
# Imports / upserts the ClickStack ALERT templates into a self-hosted (OSS) HyperDX instance.
#
# Ships alongside the dashboard templates. Each file in alerts/ binds one high-level alert to a
# dashboard tile (by dashboard tmpl-slug + tile name). Dashboard and tile IDs are per-install, so this
# script resolves them at import time from the HyperDX v2 API, wires the alert to a notification
# webhook, and UPSERTS it (matched by dashboard+tile+source; updated in place).
#
# Run ./import.sh FIRST so the dashboards exist, then run this.
#
# Notification channel: HyperDX has no native "Teams" service, so a Microsoft Teams channel is a
# `generic` webhook whose URL is a Teams *Incoming Webhook*. Resolution order:
#   1. --webhook-id <id>                       use verbatim
#   2. an existing webhook named --webhook-name (default "AldoTel Alerts (Teams)")
#   3. if --webhook-url is given, CREATE one    (needs HDX_EMAIL/HDX_PASS; webhook create is only on
#                                                the cookie-authed POST /webhooks route)
#
# Usage:
#   export HDX_API_URL="http://localhost:8000"
#   export HDX_API_KEY="<Personal API Access Key>"
#   ./import-alerts.sh                          # upsert all (webhook must already exist)
#   ./import-alerts.sh --dry-run
#   ./import-alerts.sh --only error-rate.json,replication-lag.json
#   # First-time channel setup (creates the Teams webhook, then imports):
#   export HDX_EMAIL="you@corp.com"; export HDX_PASS="***"; export HDX_APP_URL="http://localhost:3000"
#   ./import-alerts.sh --webhook-url "https://<tenant>.webhook.office.com/webhookb2/xxxx"
#   ./import-alerts.sh --delete                 # remove template-managed alerts (by name)
#
# Requires: curl, jq

set -euo pipefail

DRY_RUN=0; DELETE=0; ONLY=""
WEBHOOK_ID=""; WEBHOOK_NAME="AldoTel Alerts (Teams)"; WEBHOOK_URL=""; WEBHOOK_SERVICE="generic"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)          DRY_RUN=1 ;;
    --delete)           DELETE=1 ;;
    --only)             ONLY="$2"; shift ;;
    --only=*)           ONLY="${1#*=}" ;;
    --webhook-id)       WEBHOOK_ID="$2"; shift ;;
    --webhook-id=*)     WEBHOOK_ID="${1#*=}" ;;
    --webhook-name)     WEBHOOK_NAME="$2"; shift ;;
    --webhook-name=*)   WEBHOOK_NAME="${1#*=}" ;;
    --webhook-url)      WEBHOOK_URL="$2"; shift ;;
    --webhook-url=*)    WEBHOOK_URL="${1#*=}" ;;
    --webhook-service)  WEBHOOK_SERVICE="$2"; shift ;;
    --webhook-service=*) WEBHOOK_SERVICE="${1#*=}" ;;
    -h|--help)          sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

: "${HDX_API_URL:?Set HDX_API_URL (e.g. http://localhost:8000)}"
: "${HDX_API_KEY:?Set HDX_API_KEY (Team Settings -> API Keys -> Personal API Access Key)}"

BASE_URL="${HDX_API_URL%/}"
AUTH="Authorization: Bearer ${HDX_API_KEY}"
DIR="$(cd "$(dirname "$0")" && pwd)"
ALERT_DIR="$DIR/alerts"
[ -d "$ALERT_DIR" ] || { echo "No alerts/ directory found next to this script." >&2; exit 1; }

api() { curl -fsS -H "$AUTH" "$@"; }

# --- resolve the notification webhook id ---
resolve_webhook_id() {
  if [ -n "$WEBHOOK_ID" ]; then echo "$WEBHOOK_ID"; return; fi

  local hooks id
  hooks="$(api "$BASE_URL/api/v2/webhooks" | jq -c '.data // .')"
  id="$(echo "$hooks" | jq -r --arg n "$WEBHOOK_NAME" '[.[] | select(.name==$n)][0] | (._id // .id) // empty')"
  if [ -n "$id" ]; then echo "Using existing webhook '$WEBHOOK_NAME' -> $id" >&2; echo "$id"; return; fi

  if [ -z "$WEBHOOK_URL" ]; then
    cat >&2 <<EOF
No webhook named '$WEBHOOK_NAME' exists. Either:
  - create one in HyperDX (Team Settings -> Webhooks -> service 'generic', paste your Microsoft Teams
    Incoming Webhook URL) named '$WEBHOOK_NAME', then re-run; or
  - pass --webhook-url "<your Teams Incoming Webhook URL>" to have this script create it
    (that path also needs HDX_EMAIL / HDX_PASS, and HDX_APP_URL if the UI origin differs from the API).
EOF
    exit 1
  fi

  : "${HDX_EMAIL:?Creating a webhook needs HDX_EMAIL (a HyperDX login)}"
  : "${HDX_PASS:?Creating a webhook needs HDX_PASS}"
  local app_url="${HDX_APP_URL:-$BASE_URL}"; app_url="${app_url%/}"

  if [ "$DRY_RUN" = 1 ]; then echo "[DRY RUN] would create webhook '$WEBHOOK_NAME' ($WEBHOOK_SERVICE) -> $WEBHOOK_URL" >&2; echo "{{DRYRUN_WEBHOOK_ID}}"; return; fi

  local jar; jar="$(mktemp)"
  # Log in for a session cookie (webhook create is only on the cookie-authed root route).
  curl -fsS -c "$jar" -H "X-Forwarded-Proto: https" \
       --data-urlencode "email=${HDX_EMAIL}" --data-urlencode "password=${HDX_PASS}" \
       -o /dev/null "$app_url/api/login/password" || true
  if ! grep -q "connect.sid" "$jar"; then rm -f "$jar"; echo "Login to $app_url failed (no session cookie)." >&2; exit 1; fi

  local body created id
  body="$(jq -n --arg n "$WEBHOOK_NAME" --arg s "$WEBHOOK_SERVICE" --arg u "$WEBHOOK_URL" \
            '{name:$n, service:$s, url:$u, description:"Managed by clickstack-dashboards alerts pack"}')"
  created="$(curl -fsS -b "$jar" -H "X-Forwarded-Proto: https" -H "Content-Type: application/json" \
              -X POST --data "$body" "$BASE_URL/webhooks")"
  rm -f "$jar"
  id="$(echo "$created" | jq -r '.data._id // .data.id // ._id // .id')"
  echo "Created webhook '$WEBHOOK_NAME' -> $id" >&2
  echo "$id"
}

DASHBOARDS="$(api "$BASE_URL/api/v2/dashboards" | jq -c '.data // .')"
EXISTING_ALERTS="$(api "$BASE_URL/api/v2/alerts" | jq -c '.data // .')"

# --- select files ---
mapfile -t FILES < <(ls "$ALERT_DIR"/*.json 2>/dev/null)
if [ -n "$ONLY" ]; then
  IFS=',' read -ra WANT <<< "$ONLY"
  SEL=(); for f in "${FILES[@]}"; do b="$(basename "$f")"; for w in "${WANT[@]}"; do [ "$b" = "$(echo "$w" | xargs)" ] && SEL+=("$f"); done; done
  FILES=("${SEL[@]}")
fi

WEBHOOK=""
[ "$DELETE" = 1 ] || WEBHOOK="$(resolve_webhook_id)"

for f in "${FILES[@]}"; do
  slug="$(jq -r '.dashboard' "$f")"
  tile_name="$(jq -r '.tile' "$f")"
  name="$(jq -r '.alert.name' "$f")"

  if [ "$DELETE" = 1 ]; then
    id="$(echo "$EXISTING_ALERTS" | jq -r --arg n "$name" '[.[] | select(.name==$n)][0].id // empty')"
    if [ -n "$id" ]; then
      if [ "$DRY_RUN" = 1 ]; then echo "[DRY RUN] would DELETE '$name' -> $id"
      else api -X DELETE "$BASE_URL/api/v2/alerts/$id" -o /dev/null; echo "Deleted '$name' -> $id"; fi
    else echo "No existing alert named '$name'"; fi
    continue
  fi

  dash="$(echo "$DASHBOARDS" | jq -c --arg t "tmpl:$slug" '[.[] | select(.tags | index($t))][0] // empty')"
  if [ -z "$dash" ] || [ "$dash" = "null" ]; then echo "WARN $(basename "$f"): dashboard 'tmpl:$slug' not found (run ./import.sh first?); skipping." >&2; continue; fi
  dash_id="$(echo "$dash" | jq -r '.id')"
  tile_id="$(echo "$dash" | jq -r --arg n "$tile_name" '[.tiles[] | select(.name==$n)][0].id // empty')"
  if [ -z "$tile_id" ]; then echo "WARN $(basename "$f"): tile '$tile_name' not found on '$slug'; skipping." >&2; continue; fi

  body="$(jq -c --arg did "$dash_id" --arg tid "$tile_id" --arg wid "$WEBHOOK" \
    '{source:"tile", dashboardId:$did, tileId:$tid,
      threshold:.alert.threshold, thresholdType:.alert.thresholdType, interval:.alert.interval,
      channel:{type:"webhook", webhookId:$wid}, name:.alert.name}
     + (if .alert.message then {message:.alert.message} else {} end)' "$f")"

  existing_id="$(echo "$EXISTING_ALERTS" | jq -r --arg d "$dash_id" --arg t "$tile_id" \
    '[.[] | select(.source=="tile" and (.dashboardId|tostring)==$d and (.tileId|tostring)==$t)][0].id // empty')"

  if [ "$DRY_RUN" = 1 ]; then
    act="CREATE"; [ -n "$existing_id" ] && act="UPDATE -> $existing_id"
    echo "[DRY RUN] would $act  $(basename "$f")  ($slug / '$tile_name')"; continue
  fi

  if [ -n "$existing_id" ]; then
    api -X PUT -H "Content-Type: application/json" --data "$body" "$BASE_URL/api/v2/alerts/$existing_id" -o /dev/null
    echo "Updated '$name' -> $existing_id"
  else
    new_id="$(api -X POST -H "Content-Type: application/json" --data "$body" "$BASE_URL/api/v2/alerts" | jq -r '.data.id // .id')"
    echo "Created '$name' -> $new_id"
  fi
done

echo "Done."
