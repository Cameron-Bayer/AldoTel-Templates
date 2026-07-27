#!/usr/bin/env bash
# =============================================================================
# install-collector.sh — deploy the ClickHouse + collector self-metrics scraper
# =============================================================================
# Deploys a small opentelemetry-collector (contrib) that scrapes ClickHouse's
# :9363 Prometheus endpoint and the ClickStack central collector's :8888 self-
# telemetry, then forwards both via OTLP/gRPC mTLS to the ClickStack central
# collector — the same ingest path the appliance's kube-telemetry collectors use.
# This lights up the ADVANCED ClickHouse and Collector-Health dashboards.
#
# Run AFTER the appliance is deployed, then run the HyperDX preflight/importer and
# the Grafana advanced install. Re-running is safe (helm upgrade --install).
#
# Requires: kubectl + helm on PATH, configured against the target cluster.
# =============================================================================
set -euo pipefail

NAMESPACE='aldotel'
RELEASE='clickstack-metrics-collector'
COLLECTOR_SERVICE='clickstack-otel-collector'
CH_SERVICE='clickstack-clickhouse-clickhouse-headless'
CH_METRICS_PORT='9363'
CH_SCHEME='http'
EMITTER_SECRET='clickstack-emitter-app-secret'
CREATE_DEDICATED_CERT=0
SKIP_COLLECTOR_METRICS=0
UNINSTALL=0

DEDICATED_CERT_NAME='clickstack-emitter-dashboards-scraper'
DEDICATED_SECRET='clickstack-emitter-dashboards-scraper-secret'
HELM_REPO_NAME='open-telemetry'
HELM_REPO_URL='https://open-telemetry.github.io/opentelemetry-helm-charts'
COLLECTOR_CHART="${HELM_REPO_NAME}/opentelemetry-collector"

usage() {
  cat <<'EOF'
Usage: install-collector.sh [options]
  --namespace <ns>              Namespace where ClickStack/appliance is installed (default: aldotel)
  --release <name>              Helm release name (default: clickstack-metrics-collector)
  --collector-service <name>    Central OTel Collector Service (default: clickstack-otel-collector)
  --ch-service <name>           ClickHouse headless Service (default: clickstack-clickhouse-clickhouse-headless)
  --ch-metrics-port <port>      ClickHouse Prometheus port (default: 9363)
  --ch-scheme <http|https>      Scheme for the ClickHouse metrics endpoint (default: http)
  --emitter-secret <name>       Existing enrolled internal-emitter TLS secret (default: clickstack-emitter-app-secret)
  --create-dedicated-cert       Mint a dedicated cert-manager emitter identity instead of reusing a secret
  --skip-collector-metrics      Only scrape ClickHouse :9363 (skip collector :8888)
  --uninstall                   Remove the release (and dedicated cert if present)
  -h, --help                    Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2;;
    --release) RELEASE="$2"; shift 2;;
    --collector-service) COLLECTOR_SERVICE="$2"; shift 2;;
    --ch-service) CH_SERVICE="$2"; shift 2;;
    --ch-metrics-port) CH_METRICS_PORT="$2"; shift 2;;
    --ch-scheme) CH_SCHEME="$2"; shift 2;;
    --emitter-secret) EMITTER_SECRET="$2"; shift 2;;
    --create-dedicated-cert) CREATE_DEDICATED_CERT=1; shift;;
    --skip-collector-metrics) SKIP_COLLECTOR_METRICS=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_TEMPLATE="$SCRIPT_DIR/otel-metrics-collector-values.yaml"
CERT_TEMPLATE="$SCRIPT_DIR/emitter-cert.yaml"

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }

# --- Uninstall ---------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
  step "Uninstalling release '$RELEASE' from namespace '$NAMESPACE'"
  helm uninstall "$RELEASE" -n "$NAMESPACE" || true
  step "Removing dedicated emitter cert (if present)"
  kubectl delete certificate "$DEDICATED_CERT_NAME" -n "$NAMESPACE" --ignore-not-found || true
  kubectl delete secret "$DEDICATED_SECRET" -n "$NAMESPACE" --ignore-not-found || true
  echo "Done."
  exit 0
fi

# --- Preconditions -----------------------------------------------------------
step "Checking namespace '$NAMESPACE' and central collector '$COLLECTOR_SERVICE'"
kubectl get namespace "$NAMESPACE" -o name >/dev/null
kubectl get service "$COLLECTOR_SERVICE" -n "$NAMESPACE" -o name >/dev/null

# --- Emitter identity --------------------------------------------------------
if [ "$CREATE_DEDICATED_CERT" -eq 1 ]; then
  step "Minting dedicated emitter cert '$DEDICATED_CERT_NAME'"
  sed "s/__NAMESPACE__/${NAMESPACE}/g" "$CERT_TEMPLATE" | kubectl apply -f -
  echo "    waiting for secret '$DEDICATED_SECRET' to be issued..."
  deadline=$(( $(date +%s) + 120 ))
  until kubectl get secret "$DEDICATED_SECRET" -n "$NAMESPACE" -o name >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "Timed out waiting for $DEDICATED_SECRET" >&2; exit 1; }
    sleep 3
  done
  EMITTER_SECRET="$DEDICATED_SECRET"
  echo "    issued. Allowing ~60s for trust-manager allow-list propagation..."
  sleep 60
else
  step "Verifying emitter secret '$EMITTER_SECRET' exists"
  kubectl get secret "$EMITTER_SECRET" -n "$NAMESPACE" -o name >/dev/null
fi

# --- Stage values ------------------------------------------------------------
step "Staging Helm values"
OTLP_ENDPOINT="https://${COLLECTOR_SERVICE}.${NAMESPACE}.svc.cluster.local:4317"
CH_TARGET="${CH_SERVICE}.${NAMESPACE}.svc.cluster.local"
COLLECTOR_METRICS_TARGET="${COLLECTOR_SERVICE}.${NAMESPACE}.svc.cluster.local:8888"

STAGED="$(mktemp)"
cp "$VALUES_TEMPLATE" "$STAGED"

if [ "$SKIP_COLLECTOR_METRICS" -eq 1 ]; then
  # Strip the otelcol scrape job (inclusive of the >>> / <<< marker lines).
  awk 'BEGIN{skip=0} /# >>> otelcol job/{skip=1} skip==0{print} /# <<< otelcol job/{skip=0}' "$STAGED" > "$STAGED.tmp" && mv "$STAGED.tmp" "$STAGED"
  echo "    collector :8888 scrape disabled (--skip-collector-metrics)"
fi

# Portable in-place sed (GNU + BSD).
sedi() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }
sedi "s|__EMITTER_SECRET__|${EMITTER_SECRET}|g" "$STAGED"
sedi "s|__CH_SCHEME__|${CH_SCHEME}|g" "$STAGED"
sedi "s|__CH_TARGET__|${CH_TARGET}|g" "$STAGED"
sedi "s|__CH_METRICS_PORT__|${CH_METRICS_PORT}|g" "$STAGED"
sedi "s|__COLLECTOR_METRICS_TARGET__|${COLLECTOR_METRICS_TARGET}|g" "$STAGED"
sedi "s|__OTLP_ENDPOINT__|${OTLP_ENDPOINT}|g" "$STAGED"

# --- Helm install ------------------------------------------------------------
step "Adding/updating Helm repo '$HELM_REPO_NAME'"
helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true

step "Deploying '$RELEASE' (helm upgrade --install)"
helm upgrade --install "$RELEASE" "$COLLECTOR_CHART" \
  --namespace "$NAMESPACE" \
  -f "$STAGED" \
  --wait --timeout 5m
rm -f "$STAGED"

echo ""
step "Done. Scraper deployed."
cat <<EOF
Metrics take ~1-2 minutes to appear in ClickHouse. Then verify + import:

  # 1. Confirm the advanced-tier metrics are now present (preflight checks every tier)
  ./hyperdx/preflight.sh

  # 2. Import the advanced dashboards
  ./hyperdx/import.sh --advanced
  ./grafana/kubernetes/install-k8s.sh --namespace ${NAMESPACE} --advanced

Troubleshoot the scraper:
  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/instance=${RELEASE} --tail=50

Remove it:
  ./collector/install-collector.sh --namespace ${NAMESPACE} --uninstall
EOF
