#!/usr/bin/env bash
# =============================================================================
# enable-host-metrics.sh — turn on host cpu/memory *utilization* metrics
# =============================================================================
# The AzureLocal-Observability-Appliance runs its hostmetrics receiver with the
# cpu/memory scrapers on, but their ratio metrics --
#     system.cpu.utilization / system.memory.utilization
# -- left at the OpenTelemetry default of DISABLED (they are opt-in). The
# "Infrastructure" board marks both [required], so preflight shows them MISS
# even though the DaemonSet is healthy (cpu.load_average / disk.io / network.io
# all report fine).
#
# This patches the running DaemonSet release IN PLACE:
#     helm upgrade <release> --reuse-values -f <two-metric override>
# --reuse-values keeps everything the appliance's installer set (crucially the
# injected mTLS OTLP endpoint env), and the installed chart version is
# auto-detected and pinned with --version so this only flips the two metrics and
# never drifts the appliance's collector chart.
#
# Idempotent. Re-run any time; pass --disable to turn them back off.
#
# NOTE: this patches an APPLIANCE release (default clickstack-kube-daemonset),
# NOT the metrics scraper from install-collector.sh. If the appliance re-runs its
# own install-kube-telemetry.ps1 the packaged values revert this -- re-run this,
# or bake the same metrics into configs/kube-otel-daemonset-values.yaml.
#
# Requires: kubectl + helm on PATH, configured against the target cluster.
# =============================================================================
set -euo pipefail

NAMESPACE='aldotel'
DAEMONSET_RELEASE='clickstack-kube-daemonset'
DISABLE=0

HELM_REPO_NAME='open-telemetry'
HELM_REPO_URL='https://open-telemetry.github.io/opentelemetry-helm-charts'
COLLECTOR_CHART="${HELM_REPO_NAME}/opentelemetry-collector"

usage() {
  cat <<'EOF'
Usage: enable-host-metrics.sh [options]
  --namespace <ns>            Namespace where the appliance/kube-telemetry is installed (default: aldotel)
  --daemonset-release <name>  Kube-telemetry DaemonSet helm release (default: clickstack-kube-daemonset)
  --disable                   Set the two utilization metrics back to disabled
  -h, --help                  Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2;;
    --daemonset-release) DAEMONSET_RELEASE="$2"; shift 2;;
    --disable) DISABLE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }

if [ "$DISABLE" -eq 1 ]; then ENABLED='false'; VERB='Disabling'; else ENABLED='true'; VERB='Enabling'; fi

# --- Locate the DaemonSet release and pin its current chart version -----------
# `helm get metadata` returns this ONE release's chart name + version as separate
# fields; anchor the regex to the adjacent "chart":"..","version":".." pair so the
# unrelated labels.version is never picked up.
step "Locating DaemonSet release '$DAEMONSET_RELEASE' in namespace '$NAMESPACE'"
META="$(helm get metadata "$DAEMONSET_RELEASE" -n "$NAMESPACE" -o json 2>/dev/null)" || {
  echo "DaemonSet release '$DAEMONSET_RELEASE' not found in namespace '$NAMESPACE'. Is the appliance's kube-telemetry installed?  (check: helm list -n $NAMESPACE)" >&2
  exit 1
}
PAIR="$(printf '%s' "$META" | grep -o '"chart":"[^"]*","version":"[^"]*"' | head -1 || true)"
CHART_NAME="$(printf '%s' "$PAIR" | sed 's/^"chart":"//; s/","version.*$//')"
CHART_VERSION="$(printf '%s' "$PAIR" | sed 's/^.*","version":"//; s/"$//')"
if [ "$CHART_NAME" != "opentelemetry-collector" ]; then
  echo "Release '$DAEMONSET_RELEASE' is chart '${CHART_NAME}-${CHART_VERSION}', not opentelemetry-collector. Refusing to patch an unexpected chart." >&2
  exit 1
fi
echo "    found (chart opentelemetry-collector-$CHART_VERSION) - pinning that version"

# --- Stage the two-metric override -------------------------------------------
step "Staging Helm values override"
STAGED="$(mktemp)"
cat > "$STAGED" <<EOF
# Enable the two opt-in hostmetrics ratio metrics the Infrastructure dashboard needs.
# Deep-merged onto the appliance's existing DaemonSet values via --reuse-values.
config:
  receivers:
    hostmetrics:
      scrapers:
        cpu:
          metrics:
            system.cpu.utilization:
              enabled: ${ENABLED}
        memory:
          metrics:
            system.memory.utilization:
              enabled: ${ENABLED}
EOF

# --- Apply --------------------------------------------------------------------
step "Adding/updating Helm repo '$HELM_REPO_NAME'"
helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true

step "$VERB system.cpu.utilization + system.memory.utilization on '$DAEMONSET_RELEASE'"
helm upgrade "$DAEMONSET_RELEASE" "$COLLECTOR_CHART" \
  --namespace "$NAMESPACE" \
  --version "$CHART_VERSION" \
  --reuse-values \
  -f "$STAGED" \
  --wait --timeout 5m
rm -f "$STAGED"

echo ""
step "Done. DaemonSet rolling restart underway (~1-2 min)."
cat <<EOF
Then verify:
  ./hyperdx/preflight.sh          # 'Infrastructure' -> OK

Revert:
  ./collector/enable-host-metrics.sh --namespace ${NAMESPACE} --disable
EOF
