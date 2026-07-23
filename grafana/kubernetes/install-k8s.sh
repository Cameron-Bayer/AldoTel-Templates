#!/usr/bin/env bash
# Durably install the ClickStack Grafana dashboards, ClickHouse data source, and alert
# rules into an existing ClickStack-on-Kubernetes Grafana (bash port of install-k8s.ps1).
#
# ClickStack's bundled Grafana stores everything in an *ephemeral* SQLite DB (no
# PersistentVolume on /var/lib/grafana), so anything created through the Grafana HTTP API
# is wiped on the next pod restart. The only durable path is file-based provisioning, which
# on this chart is fed by ConfigMaps. This script patches those ConfigMaps so the install
# survives restarts, then rolls Grafana. Re-running it is safe (idempotent).
#
# Requires: kubectl (configured against the target cluster) and jq.
# The data source password comes from the CH_PASSWORD env var already injected into the
# ClickStack Grafana pod — you do not pass a password here.
set -euo pipefail

NS='clickstack'
DEPLOYMENT='clickstack-grafana'
DATASOURCES_CM='clickstack-grafana-datasources'
DASHBOARDS_CM='clickstack-grafana-dashboards'
ALERTING_CM='clickstack-grafana-alerting'
# Fixed data source UID. The provisioned alert rules reference it directly (provisioned
# rules can't prompt for a data source), and datasource-clickstack-ch.yaml declares it —
# so it is intentionally NOT configurable.
DS_UID='clickstack-ch'
CH_SERVER='clickstack-clickhouse-clickhouse-headless'
CH_PORT='9440'
CA_CERT_PATH='/etc/grafana/certs/ca.crt'
INSECURE=0
ADVANCED=0
SKIP_ALERTS=0
NO_RESTART=0

usage() {
  cat <<'EOF'
Usage: ./install-k8s.sh [options]
  --namespace <ns>            Namespace of the Grafana deployment/ConfigMaps (default: clickstack)
  --deployment <name>         Grafana Deployment name (default: clickstack-grafana)
  --datasources-cm <name>     Datasources provisioning ConfigMap (default: clickstack-grafana-datasources)
  --dashboards-cm <name>      Dashboards provisioning ConfigMap (default: clickstack-grafana-dashboards)
  --alerting-cm <name>        Alerting provisioning ConfigMap (default: clickstack-grafana-alerting)
  --ch-server <host>          ClickHouse endpoint host (default: clickstack-clickhouse-clickhouse-headless)
  --ch-port <port>            ClickHouse endpoint port (default: 9440, native-secure)
  --ca-cert-path <path>       CA cert file mounted in the Grafana pod for TLS verify (default: /etc/grafana/certs/ca.crt)
  --insecure                  Plaintext (non-TLS) ClickStack: strip TLS, default port to 9000
  --advanced                  Also provision dashboards/advanced/ (need optional data sources)
  --skip-alerts               Install data source + dashboards only
  --no-restart                Patch the ConfigMaps but don't roll Grafana
  -h, --help                  Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NS="$2"; shift 2;;
    --deployment) DEPLOYMENT="$2"; shift 2;;
    --datasources-cm) DATASOURCES_CM="$2"; shift 2;;
    --dashboards-cm) DASHBOARDS_CM="$2"; shift 2;;
    --alerting-cm) ALERTING_CM="$2"; shift 2;;
    --ch-server) CH_SERVER="$2"; shift 2;;
    --ch-port) CH_PORT="$2"; shift 2;;
    --ca-cert-path) CA_CERT_PATH="$2"; shift 2;;
    --insecure) INSECURE=1; shift;;
    --advanced) ADVANCED=1; shift;;
    --skip-alerts) SKIP_ALERTS=1; shift;;
    --no-restart) NO_RESTART=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found on PATH" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAFANA_DIR="$(dirname "$SCRIPT_DIR")"
DASHBOARDS_DIR="$GRAFANA_DIR/dashboards"
ALERTING_DIR="$GRAFANA_DIR/alerting"
DS_FILE="$SCRIPT_DIR/datasource-clickstack-ch.yaml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }

step "Checking Grafana deployment '$DEPLOYMENT' in namespace '$NS'"
kubectl get deployment "$DEPLOYMENT" -n "$NS" -o name >/dev/null

# --- 1. Data source ----------------------------------------------------------
step "Provisioning data source '$DS_UID' into ConfigMap '$DATASOURCES_CM'"
if [ "$INSECURE" -eq 1 ]; then
  # Plaintext ClickStack: strip TLS and default the port to 9000 unless overridden.
  [ "$CH_PORT" = "9440" ] && CH_PORT='9000'
  DS_YAML="$(sed \
    -e "s|server: .*|server: $CH_SERVER|" \
    -e "s|port: [0-9]*|port: $CH_PORT|" \
    -e "s|secure: true|secure: false|" \
    -e "s|tlsAuthWithCACert: true|tlsAuthWithCACert: false|" \
    -e "/tlsCACert:/d" \
    "$DS_FILE")"
else
  DS_YAML="$(sed \
    -e "s|server: .*|server: $CH_SERVER|" \
    -e "s|port: [0-9]*|port: $CH_PORT|" \
    -e "s|tlsCACert: \$__file{[^}]*}|tlsCACert: \$__file{$CA_CERT_PATH}|" \
    "$DS_FILE")"
fi
jq -n --arg k "$DS_UID.yaml" --arg v "$DS_YAML" '{data: {($k): $v}}' > "$TMP/ds-patch.json"
kubectl patch configmap "$DATASOURCES_CM" -n "$NS" --type merge -p "$(cat "$TMP/ds-patch.json")" >/dev/null
echo "    added key $DS_UID.yaml"

# --- 2. Dashboards -----------------------------------------------------------
step "Provisioning dashboards into ConfigMap '$DASHBOARDS_CM'"
echo '{}' > "$TMP/dashdata.json"
# Default: only the always-populated top-level dashboards. --advanced also provisions
# dashboards/advanced/, which need optional data sources (OTLP histograms).
DASH_FILES=("$DASHBOARDS_DIR"/*.json)
if [ "$ADVANCED" = 1 ] && [ -d "$DASHBOARDS_DIR/advanced" ]; then
  DASH_FILES+=("$DASHBOARDS_DIR"/advanced/*.json)
fi
for f in "${DASH_FILES[@]}"; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  baked="$(jq -c --arg uid "$DS_UID" '
    (.templating.list[]? | select(.type=="datasource")) |=
      (.current = {selected:true, text:$uid, value:$uid}
       | .options = [{selected:true, text:$uid, value:$uid}])
    | del(.__inputs) | del(.id)
  ' "$f")"
  jq --arg k "$base" --arg v "$baked" '.[$k]=$v' "$TMP/dashdata.json" > "$TMP/dashdata.json.tmp"
  mv "$TMP/dashdata.json.tmp" "$TMP/dashdata.json"
  echo "    baked $base (ds -> $DS_UID)"
done
jq '{data: .}' "$TMP/dashdata.json" > "$TMP/dash-patch.json"
kubectl patch configmap "$DASHBOARDS_CM" -n "$NS" --type merge -p "$(cat "$TMP/dash-patch.json")" >/dev/null

# --- 3. Alerts ---------------------------------------------------------------
if [ "$SKIP_ALERTS" -eq 0 ]; then
  step "Loading alert rules into ConfigMap '$ALERTING_CM'"
  cm_args=(create configmap "$ALERTING_CM" -n "$NS")
  count=0
  for y in "$ALERTING_DIR"/*.yaml; do cm_args+=(--from-file="$y"); count=$((count+1)); done
  cm_args+=(--dry-run=client -o yaml)
  kubectl "${cm_args[@]}" | kubectl apply -f - >/dev/null
  echo "    loaded $count YAML file(s)"

  step "Ensuring Grafana mounts the alerting provisioning folder"
  container="$(kubectl get deployment "$DEPLOYMENT" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].name}')"
  mount_patch="$(jq -n --arg cm "$ALERTING_CM" --arg c "$container" '{
    spec: {template: {spec: {
      volumes: [{name: "alerting", configMap: {name: $cm}}],
      containers: [{name: $c, volumeMounts: [{name: "alerting", mountPath: "/etc/grafana/provisioning/alerting", readOnly: true}]}]
    }}}
  }')"
  kubectl patch deployment "$DEPLOYMENT" -n "$NS" --type strategic -p "$mount_patch" >/dev/null
  echo "    mounted $ALERTING_CM at /etc/grafana/provisioning/alerting"
else
  step "Skipping alerts (--skip-alerts)"
fi

# --- 4. Restart + verify -----------------------------------------------------
if [ "$NO_RESTART" -eq 1 ]; then
  step "Skipping restart (--no-restart). Roll Grafana yourself to apply provisioning:"
  echo "    kubectl rollout restart deployment $DEPLOYMENT -n $NS"
else
  step "Restarting Grafana to apply provisioning"
  kubectl rollout restart deployment "$DEPLOYMENT" -n "$NS" >/dev/null
  kubectl rollout status deployment "$DEPLOYMENT" -n "$NS" --timeout=180s
fi

echo ""
step "Done."
cat <<EOF
Verify (port-forward Grafana, then hit the API):
    kubectl port-forward -n $NS svc/$DEPLOYMENT 3010:3000
    # data sources — expect 'clickhouse' and '$DS_UID'
    curl -s -u admin:'<pass>' http://localhost:3010/api/datasources
    # dashboards
    curl -s -u admin:'<pass>' "http://localhost:3010/api/search?type=dash-db"
    # alert-rule health — expect health=ok for all rules
    curl -s -u admin:'<pass>' http://localhost:3010/api/prometheus/grafana/api/v1/rules

Notification channel: edit the webhook URL in ../alerting/contact-points.yaml, re-run
this script (or kubectl apply the alerting ConfigMap), and restart Grafana.
EOF
