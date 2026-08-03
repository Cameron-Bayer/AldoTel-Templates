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

NS='aldotel'
DEPLOYMENT='clickstack-grafana'
DATASOURCES_CM='clickstack-grafana-datasources'
DASHBOARDS_CM='clickstack-grafana-dashboards'
ALERTING_CM='clickstack-grafana-alerting'
# Data source UID that dashboards + provisioned alert rules bind to. Provisioned alert
# rules can't prompt for a data source, so they reference this UID directly. Defaults to
# the `clickstack-ch` data source this script provisions. On the Observability Appliance,
# whose Grafana already ships an identical ClickHouse data source (uid `clickhouse`), pass
# --reuse-datasource --datasource-uid clickhouse to bind to it instead of provisioning one.
DS_UID='clickstack-ch'
DS_UID_EXPLICIT=0
REUSE_DS=0
CH_SERVER='clickstack-clickhouse-clickhouse-headless'
CH_PORT='9440'
CA_CERT_PATH='/etc/grafana/certs/ca.crt'
INSECURE=0
ADVANCED=0
SKIP_ALERTS=0
ALERT_DEST=''
ALERT_URL=''
ALERT_EMAIL=''
PAGERDUTY_KEY=''
KEYVAULT_WORKLOAD=''
NON_INTERACTIVE=0
NO_RESTART=0

usage() {
  cat <<'EOF'
Usage: ./install-k8s.sh [options]
  --namespace <ns>            Namespace of the Grafana deployment/ConfigMaps (default: aldotel)
  --deployment <name>         Grafana Deployment name (default: clickstack-grafana)
  --datasources-cm <name>     Datasources provisioning ConfigMap (default: clickstack-grafana-datasources)
  --dashboards-cm <name>      Dashboards provisioning ConfigMap (default: clickstack-grafana-dashboards)
  --alerting-cm <name>        Alerting provisioning ConfigMap (default: clickstack-grafana-alerting)
  --ch-server <host>          ClickHouse endpoint host (default: clickstack-clickhouse-clickhouse-headless)
  --ch-port <port>            ClickHouse endpoint port (default: 9440, native-secure)
  --ca-cert-path <path>       CA cert file mounted in the Grafana pod for TLS verify (default: /etc/grafana/certs/ca.crt)
  --datasource-uid <uid>      Data source UID dashboards + alert rules bind to (default: clickstack-ch)
  --reuse-datasource          Force skipping datasource provisioning; bind to an existing --datasource-uid
                              (auto-enabled when the datasources ConfigMap is absent, e.g. the appliance)
  --insecure                  Plaintext (non-TLS) ClickStack: strip TLS, default port to 9000
  --advanced                  Also provision dashboards/advanced/ (need optional data sources)
  --skip-alerts               Install data source + dashboards only
  --alert-destination <kind>  teams|slack|email|pagerduty|webhook|keep (prompts when omitted)
  --alert-url <url>           Webhook/Workflows URL for teams|slack|webhook
  --alert-email <addrs>       Comma-separated address(es) for --alert-destination email
  --pagerduty-key <key>       PagerDuty Events v2 integration key
  --keyvault-workload <s>     Pod-name substring the Key Vault rule matches (default: moc-kms)
  --non-interactive           Never prompt; leave contact-points.yaml as shipped
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
    --datasource-uid) DS_UID="$2"; DS_UID_EXPLICIT=1; shift 2;;
    --reuse-datasource) REUSE_DS=1; shift;;
    --insecure) INSECURE=1; shift;;
    --advanced) ADVANCED=1; shift;;
    --skip-alerts) SKIP_ALERTS=1; shift;;
    --alert-destination) ALERT_DEST="$2"; shift 2;;
    --alert-url) ALERT_URL="$2"; shift 2;;
    --alert-email) ALERT_EMAIL="$2"; shift 2;;
    --pagerduty-key) PAGERDUTY_KEY="$2"; shift 2;;
    --keyvault-workload) KEYVAULT_WORKLOAD="$2"; shift 2;;
    --non-interactive) NON_INTERACTIVE=1; shift;;
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

# --- 0a. Alert destination ---------------------------------------------------
# Resolved up front, before anything in the cluster is mutated, so a bad URL or a
# cancelled prompt fails before the data source or dashboards are touched.

# Validate a URL for a given destination kind. Echoes an error, returns non-zero.
validate_alert_url() {
  local url="$1" kind="$2"
  [ -n "$url" ] || { echo "A URL is required."; return 1; }
  case "$url" in http://*|https://*) ;; *) echo "Must start with http:// or https://"; return 1;; esac
  case "$kind" in
    teams)
      case "$url" in *outlook.office.com*|*outlook.office365.com*)
        echo "That is a legacy Office 365 connector URL. Microsoft blocked new ones in 2024 and is retiring existing ones in 2026. Use a Power Automate Workflows URL instead: right-click the channel -> Workflows -> 'Post to a channel when a webhook request is received'."; return 1;; esac
      case "$url" in *logic.azure.com*|*powerplatform.com*|*azure-api.net*) ;; *)
        echo "That does not look like a Power Automate Workflows URL (expected a logic.azure.com host)."; return 1;; esac ;;
    slack)
      case "$url" in https://hooks.slack.com/*) ;; *)
        echo "Expected a Slack incoming webhook (https://hooks.slack.com/services/...)."; return 1;; esac ;;
  esac
  return 0
}

# YAML single-quoted scalar: double any embedded single quote.
yq_str() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

# Escape a string for use as sed's replacement text (delimiter is '|').
sed_rep() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

write_contact_points() {
  local kind="$1" out="$2"
  {
    echo "# ClickStack Grafana alerts — contact points"
    echo "# GENERATED by install-k8s.sh. Re-run the installer to change the destination."
    echo "apiVersion: 1"
    echo ""
    echo "contactPoints:"
    echo "  - orgId: 1"
    echo "    name: ClickStack Alerts"
    echo "    receivers:"
    echo "      - uid: clickstack-alerts"
    echo "        disableResolveMessage: false"
    case "$kind" in
      teams)
        echo "        type: teams"
        echo "        settings:"
        echo "          url: $(yq_str "$ALERT_URL")"
        echo "          title: '{{ template \"default.title\" . }}'"
        echo "          sectiontitle: ''"
        echo "          message: '{{ template \"default.message\" . }}'" ;;
      slack)
        echo "        type: slack"; echo "        settings:"; echo "          url: $(yq_str "$ALERT_URL")" ;;
      email)
        echo "        type: email"; echo "        settings:"
        echo "          addresses: $(yq_str "$(printf '%s' "$ALERT_EMAIL" | tr ',' ';' | tr -d ' ')")" ;;
      pagerduty)
        echo "        type: pagerduty"; echo "        settings:"; echo "          integrationKey: $(yq_str "$PAGERDUTY_KEY")" ;;
      webhook)
        echo "        type: webhook"; echo "        settings:"; echo "          url: $(yq_str "$ALERT_URL")" ;;
    esac
  } > "$out"
}

alert_wizard() {
  echo ""
  echo "  Where should alerts be sent?"
  echo "    1) Microsoft Teams  (Power Automate Workflows URL)"
  echo "    2) Slack            (incoming webhook)"
  echo "    3) Email"
  echo "    4) PagerDuty        (Events v2 integration key)"
  echo "    5) Generic webhook  (any endpoint that accepts a POST)"
  echo "    6) Leave contact-points.yaml as-is"
  local choice err
  while :; do
    printf "  Choose 1-6: "; read -r choice
    case "$choice" in [1-6]) break;; *) echo "    ! Enter a number from 1 to 6.";; esac
  done
  case "$choice" in
    1) ALERT_DEST=teams
       echo "  Get the URL in Teams: right-click the channel -> Workflows ->"
       echo "  'Post to a channel when a webhook request is received' -> Add workflow."
       while :; do printf "  Teams Workflows URL: "; read -r ALERT_URL
         if err="$(validate_alert_url "$ALERT_URL" teams)"; then break; else echo "    ! $err"; fi; done ;;
    2) ALERT_DEST=slack
       while :; do printf "  Slack webhook URL: "; read -r ALERT_URL
         if err="$(validate_alert_url "$ALERT_URL" slack)"; then break; else echo "    ! $err"; fi; done ;;
    3) ALERT_DEST=email
       while :; do printf "  Email address(es), comma-separated: "; read -r ALERT_EMAIL
         if printf '%s' "$ALERT_EMAIL" | grep -Eq '^[^@,[:space:]]+@[^@,[:space:]]+\.[^@,[:space:]]+([[:space:]]*,[[:space:]]*[^@,[:space:]]+@[^@,[:space:]]+\.[^@,[:space:]]+)*$'; then break
         else echo "    ! Enter one or more valid email addresses."; fi; done ;;
    4) ALERT_DEST=pagerduty
       while :; do printf "  PagerDuty Events v2 integration key: "; read -r PAGERDUTY_KEY
         if printf '%s' "$PAGERDUTY_KEY" | grep -Eq '^[A-Za-z0-9]{20,}$'; then break
         else echo "    ! Expected a PagerDuty integration key (20+ alphanumeric characters)."; fi; done ;;
    5) ALERT_DEST=webhook
       while :; do printf "  Webhook URL: "; read -r ALERT_URL
         if err="$(validate_alert_url "$ALERT_URL" webhook)"; then break; else echo "    ! $err"; fi; done ;;
    6) ALERT_DEST=keep ;;
  esac
}

if [ "$SKIP_ALERTS" -eq 0 ]; then
  if [ -n "$ALERT_DEST" ]; then
    ALERT_DEST="$(printf '%s' "$ALERT_DEST" | tr '[:upper:]' '[:lower:]')"
    case "$ALERT_DEST" in
      email) [ -n "$ALERT_EMAIL" ] || { echo "--alert-destination email requires --alert-email" >&2; exit 1; };;
      pagerduty) [ -n "$PAGERDUTY_KEY" ] || { echo "--alert-destination pagerduty requires --pagerduty-key" >&2; exit 1; };;
      keep) ;;
      teams|slack|webhook)
        if ! err="$(validate_alert_url "$ALERT_URL" "$ALERT_DEST")"; then
          echo "--alert-url rejected: $err" >&2; exit 1
        fi ;;
      *) echo "Unknown --alert-destination '$ALERT_DEST' (expected teams, slack, email, pagerduty, webhook or keep)" >&2; exit 1;;
    esac
  elif [ "$NON_INTERACTIVE" -eq 0 ] && [ -t 0 ]; then
    step "Configuring the alert notification channel"
    alert_wizard
    if [ -z "$KEYVAULT_WORKLOAD" ]; then
      echo ""
      echo "  The Key Vault alert rule finds its workload by pod-name substring."
      echo "  The default matches the Azure Local appliance. Press Enter to keep it."
      printf "  Key Vault / KMS pod name contains [moc-kms]: "; read -r KEYVAULT_WORKLOAD
    fi
  else
    ALERT_DEST=keep
  fi
fi

# --- 0. Auto-detect layout ---------------------------------------------------
# Stock ClickStack ships a separate datasources ConfigMap that this script provisions
# `clickstack-ch` into. The Observability Appliance instead keeps datasources.yaml as a
# subPath key of the single grafana config ConfigMap (no separate datasources CM) and
# already ships an equivalent ClickHouse data source. When that CM is absent and the user
# didn't ask to provision, fall back to reusing Grafana's existing data source.
if [ "$REUSE_DS" -eq 0 ]; then
  if ! kubectl get configmap "$DATASOURCES_CM" -n "$NS" -o name >/dev/null 2>&1; then
    REUSE_DS=1
    step "No '$DATASOURCES_CM' ConfigMap found - appliance layout detected; reusing Grafana's existing data source"
  fi
fi
if [ "$REUSE_DS" -eq 1 ] && [ "$DS_UID_EXPLICIT" -eq 0 ]; then
  # Detect the existing data source UID from Grafana's config ConfigMap (falls back to
  # `clickhouse`, the appliance's built-in ClickHouse data source).
  detected="$(kubectl get configmap "$DEPLOYMENT" -n "$NS" -o 'jsonpath={.data.datasources\.yaml}' 2>/dev/null \
    | sed -nE 's/^[[:space:]]*uid:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n1 || true)"
  DS_UID="${detected:-clickhouse}"
  echo "    binding dashboards + alert rules to existing uid '$DS_UID'"
fi

# --- 1. Data source ----------------------------------------------------------
if [ "$REUSE_DS" -eq 1 ]; then
  step "Reusing existing data source '$DS_UID' (skipping datasource provisioning)"
  echo "    dashboards + alert rules will bind to uid '$DS_UID'"
else
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
      -e "s|uid: clickstack-ch|uid: $DS_UID|" \
      "$DS_FILE")"
  else
    DS_YAML="$(sed \
      -e "s|server: .*|server: $CH_SERVER|" \
      -e "s|port: [0-9]*|port: $CH_PORT|" \
      -e "s|tlsCACert: \$__file{[^}]*}|tlsCACert: \$__file{$CA_CERT_PATH}|" \
      -e "s|uid: clickstack-ch|uid: $DS_UID|" \
      "$DS_FILE")"
  fi
  jq -n --arg k "$DS_UID.yaml" --arg v "$DS_YAML" '{data: {($k): $v}}' > "$TMP/ds-patch.json"
  kubectl patch configmap "$DATASOURCES_CM" -n "$NS" --type merge -p "$(cat "$TMP/ds-patch.json")" >/dev/null
  echo "    added key $DS_UID.yaml"
fi

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
  # Provisioned alert rules bind to the data source by UID. If a non-default UID is in
  # use (e.g. --datasource-uid clickhouse), rewrite the rules' UID onto substituted
  # copies. The `__expr__` expression UID is untouched (no 'clickstack-ch' substring).
  # The generated contact point and workload substitutions land on the same copies, so
  # the files in ../alerting/ are never modified.
  ALERT_SRC_DIR="$ALERTING_DIR"
  if [ "$DS_UID" != "clickstack-ch" ] || { [ -n "$ALERT_DEST" ] && [ "$ALERT_DEST" != "keep" ]; } \
     || [ -n "$KEYVAULT_WORKLOAD" ]; then
    ALERT_SRC_DIR="$TMP/alerting"
    mkdir -p "$ALERT_SRC_DIR"
    for y in "$ALERTING_DIR"/*.yaml; do
      base="$(basename "$y")"
      sed "s|clickstack-ch|$DS_UID|g" "$y" > "$ALERT_SRC_DIR/$base"
      if [ "$base" = "appliance-alert-rules.yaml" ] && [ -n "$KEYVAULT_WORKLOAD" ]; then
        kv="$(sed_rep "$KEYVAULT_WORKLOAD")"
        sed -i "s|\(\['k8s\.pod\.name'\], '\)moc-kms'|\1$kv'|g" "$ALERT_SRC_DIR/$base"
      fi
    done
    if [ -n "$ALERT_DEST" ] && [ "$ALERT_DEST" != "keep" ]; then
      write_contact_points "$ALERT_DEST" "$ALERT_SRC_DIR/contact-points.yaml"
      echo "    notification channel: $ALERT_DEST"
      if [ -n "$ALERT_URL" ] || [ -n "$PAGERDUTY_KEY" ]; then
        echo "    note: this credential is stored in ConfigMap '$ALERTING_CM' (not a Secret),"
        echo "          so anyone with read access to the namespace can see it."
      fi
    fi
    if [ -n "$KEYVAULT_WORKLOAD" ]; then
      echo "    Key Vault rule matches pods containing '$KEYVAULT_WORKLOAD'"
    fi
  fi
  cm_args=(create configmap "$ALERTING_CM" -n "$NS")
  count=0
  for y in "$ALERT_SRC_DIR"/*.yaml; do cm_args+=(--from-file="$y"); count=$((count+1)); done
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

Notification channel: re-run this script and pick a destination at the prompt, or pass
    ./install-k8s.sh --alert-destination teams --alert-url '<workflows-url>'
Unattended installs that pass neither keep ../alerting/contact-points.yaml as shipped.
EOF
