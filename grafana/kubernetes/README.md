# Install into a ClickStack-on-Kubernetes Grafana (durable)

ClickStack ships a bundled Grafana. On Kubernetes that Grafana stores everything in
an **ephemeral SQLite database** — there is no PersistentVolume on `/var/lib/grafana`.

> **The gotcha:** anything you create through the Grafana **HTTP API** — a data source,
> an imported dashboard — **disappears the next time the Grafana pod restarts** (and it
> restarts often: chart upgrades, node pressure, cold-start crash-loops). Only Grafana's
> **file-based provisioning** survives, and on this chart that provisioning is fed by
> **ConfigMaps**.

Two equivalent installers do the durable thing — `install-k8s.ps1` (PowerShell) and
`install-k8s.sh` (bash) — patching the Grafana provisioning ConfigMaps so the data source,
dashboards, and alerts all come back automatically on every restart.

## What it installs

| Component | ConfigMap patched | Notes |
|-----------|-------------------|-------|
| `clickstack-ch` ClickHouse data source | `clickstack-grafana-datasources` | From [`datasource-clickstack-ch.yaml`](datasource-clickstack-ch.yaml). Defaults to the **native-secure** port `9440` with CA verification (matches a TLS-hardened ClickStack); pass `-Insecure`/`--insecure` for a plaintext ClickStack. The alert rules reference this fixed UID. |
| 5 default dashboards (`../dashboards/*.json`) | `clickstack-grafana-dashboards` | Each dashboard's datasource variable (`clickhouseDatasource`) is pinned to `clickstack-ch` so panels resolve with no prompt. Pass `-Advanced`/`--advanced` to also install `../dashboards/advanced/` (needs an optional data source). |
| 15 alert rules + contact point + policy (`../alerting/*.yaml`) | `clickstack-grafana-alerting` | Also ensures the Grafana Deployment mounts it at `/etc/grafana/provisioning/alerting`. |

## Prerequisites

- `kubectl` pointed at the cluster running ClickStack.
- For `install-k8s.sh` (bash): `jq` on your PATH. (`install-k8s.ps1` needs no extra tools.)
- The ClickStack Grafana Deployment already injects a `CH_PASSWORD` env var (its built-in
  `clickhouse` data source uses it) — the provisioned `clickstack-ch` data source reuses it,
  so **you don't pass a password**.
- **TLS (default):** the data source connects over the native-secure port `9440` and verifies
  ClickHouse against a CA certificate read from `-CaCertPath` (default
  `/etc/grafana/certs/ca.crt`) — the same file the chart's built-in `clickhouse` data source
  already mounts into the Grafana pod. On a plaintext (non-TLS) ClickStack, pass
  `-Insecure`/`--insecure`, which strips TLS and defaults the port to `9000`.

## Wire up notifications

**The installer asks you.** On an interactive run it prompts for a destination before it
touches the cluster, validates what you enter, and writes the contact point for you — so
there is nothing to edit by hand:

```
  Where should alerts be sent?
    1) Microsoft Teams  (Power Automate Workflows URL)
    2) Slack            (incoming webhook)
    3) Email
    4) PagerDuty        (Events v2 integration key)
    5) Generic webhook  (any endpoint that accepts a POST)
    6) Leave contact-points.yaml as-is
```

It then offers to point the Key Vault appliance rule at your actual pod name. The default
(`moc-kms`) already matches an Azure Local appliance, so press Enter to keep it.

To script it instead, pass the answers as flags and no prompt appears:

```powershell
./install-k8s.ps1 -AlertDestination Teams -AlertUrl 'https://prod-NN.LOCATION.logic.azure.com:443/workflows/...'
./install-k8s.ps1 -AlertDestination Email -AlertEmail 'ops@contoso.com,oncall@contoso.com'
```
```bash
./install-k8s.sh --alert-destination slack --alert-url 'https://hooks.slack.com/services/...'
./install-k8s.sh --non-interactive          # never prompt; ship contact-points.yaml as-is
```

Notes:

- **Teams needs a Power Automate Workflows URL**, not a legacy Office 365 connector.
  Right-click the channel → **Workflows** → *"Post to a channel when a webhook request is
  received"*. Microsoft blocked new O365 connectors in 2024 and retires existing ones in
  2026; the installer rejects `outlook.office.com` URLs for that reason.
- Answers are written to **temporary copies** — the files in `../alerting/` are never
  modified, so the repo stays clean and re-runnable.
- ⚠️ The webhook URL / PagerDuty key is stored in the **ConfigMap, not a Secret**. Anyone
  with read access to the namespace can read it. Treat the URL as a shared secret.
- Prompts are skipped automatically when stdin isn't a TTY (CI), leaving the shipped
  placeholder in place. Rules still evaluate and fire — they just don't deliver anywhere.

(Not deploying alerts? Pass `-SkipAlerts` / `--skip-alerts`.)

## Usage

**PowerShell (Windows):**

```powershell
# From the repo, in grafana/kubernetes/
./install-k8s.ps1

# Different namespace, data source + dashboards only (no alerts):
./install-k8s.ps1 -Namespace obs -SkipAlerts

# Plaintext (non-TLS) ClickStack, and/or a non-default endpoint:
./install-k8s.ps1 -Insecure -ChServer my-clickhouse-headless -ChPort 9000

# Also install the advanced/ deep-dive dashboards:
./install-k8s.ps1 -Advanced
```

**bash (macOS / Linux, needs `jq`):**

```bash
# From the repo, in grafana/kubernetes/
chmod +x install-k8s.sh   # first time only
./install-k8s.sh

# Different namespace, data source + dashboards only (no alerts):
./install-k8s.sh --namespace obs --skip-alerts

# Plaintext (non-TLS) ClickStack, and/or a non-default endpoint:
./install-k8s.sh --insecure --ch-server my-clickhouse-headless --ch-port 9000

# Also install the advanced/ deep-dive dashboards:
./install-k8s.sh --advanced
```

Key parameters (all optional, defaults match the stock ClickStack chart). PowerShell
flags are shown; the bash equivalents are the lowercase `--kebab-case` forms
(`-Namespace` → `--namespace`, `-SkipAlerts` → `--skip-alerts`, etc.):

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-Namespace` | `aldotel` | Namespace of the Grafana deployment/ConfigMaps. |
| `-Deployment` | `clickstack-grafana` | Grafana Deployment name. |
| `-DatasourcesConfigMap` / `-DashboardsConfigMap` / `-AlertingConfigMap` | `clickstack-grafana-*` | Override if your release prefix differs. |
| `-ChServer` / `-ChPort` | `clickstack-clickhouse-clickhouse-headless` / `9440` | ClickHouse endpoint baked into the data source (`9440` = native-secure; `-Insecure` defaults it to `9000`). |
| `-CaCertPath` | `/etc/grafana/certs/ca.crt` | CA cert file (already mounted in the Grafana pod) used to verify ClickHouse TLS. |
| `-Insecure` | off | Plaintext (non-TLS) ClickStack: strip TLS from the data source, default the port to `9000`. |
| `-DatasourceUid` | `clickstack-ch` (auto-detected in reuse mode) | UID that dashboards + alert rules bind to. Set to an existing datasource's UID (e.g. `clickhouse`) to reuse it. |
| `-ReuseDatasource` | auto | Skip provisioning a data source; bind dashboards + alert rules to the existing `-DatasourceUid`. **Auto-enabled** when the datasources ConfigMap is absent (the appliance) — see [Observability Appliance](#observability-appliance) below. |
| `-Advanced` | off | Also provision `../dashboards/advanced/` (deep dives needing an optional data source). |
| `-SkipAlerts` | off | Install data source + dashboards only. |
| `-AlertDestination` | prompt | `Teams`\|`Slack`\|`Email`\|`PagerDuty`\|`Webhook`\|`Keep`. Skips the prompt and writes the contact point for you. |
| `-AlertUrl` | — | Webhook / Workflows URL for `Teams`, `Slack` or `Webhook`. Validated before anything is applied. |
| `-AlertEmail` | — | Comma-separated address(es) for `-AlertDestination Email`. |
| `-PagerDutyKey` | — | PagerDuty Events v2 integration key. |
| `-KeyVaultWorkload` | `moc-kms` | Pod-name substring the Key Vault appliance rule matches on. |
| `-NonInteractive` | off | Never prompt; leave `contact-points.yaml` exactly as shipped. |
| `-NoRestart` | off | Patch the ConfigMaps but don't roll Grafana (do it yourself later). |

The script restarts Grafana at the end so provisioning re-runs. It is **idempotent** — re-run
it any time (e.g. after editing a dashboard or the webhook URL).

## Observability Appliance

The Azure Local **Observability Appliance** ships a Grafana whose provisioning layout differs
from the stock chart in two ways that matter here:

- **A single `clickstack-grafana` ConfigMap** holds `datasources.yaml`, `dashboardproviders.yaml`,
  and `grafana.ini` as *subPath-mounted keys* — there is **no** separate
  `clickstack-grafana-datasources` ConfigMap.
- It **already ships an equivalent ClickHouse data source** (uid **`clickhouse`**) — native-secure
  `9440`, CA-verified, `CH_PASSWORD` from env — so there is nothing to provision.

**The script auto-detects this** — no special flags needed. Just run:

```powershell
./install-k8s.ps1 -Advanced
```

```bash
./install-k8s.sh --advanced
```

When the `clickstack-grafana-datasources` ConfigMap is absent, the installer switches to
*reuse* mode: it skips the datasource step, reads the existing data source UID out of the
`clickstack-grafana` config ConfigMap (falling back to `clickhouse`), and pins every dashboard's
datasource variable **and** every provisioned alert rule to it (the `../dashboards/*` and
`../alerting/*.yaml` files ship with `clickstack-ch` and are rewritten on the fly — the source
files are untouched). Dashboards merge into the appliance's existing `clickstack-grafana-dashboards`
ConfigMap; alerts are created and mounted as usual.

To override auto-detection, pass `-ReuseDatasource` / `--reuse-datasource` (force reuse) with an
explicit `-DatasourceUid` / `--datasource-uid <uid>`, or set `-DatasourcesConfigMap` /
`--datasources-cm` to force provisioning against a specific ConfigMap.

## Verify

```powershell
kubectl port-forward -n clickstack svc/clickstack-grafana 3010:3000

# authenticate once (enter the Grafana admin user + password when prompted)
$cred = Get-Credential
$g = 'http://localhost:3010'

# data sources — expect 'clickhouse' + 'clickstack-ch'
Invoke-RestMethod -Credential $cred "$g/api/datasources" | Select-Object name, type
# dashboards
Invoke-RestMethod -Credential $cred "$g/api/search?type=dash-db" | Select-Object title, uid
# alert-rule health — expect health=ok for every rule
Invoke-RestMethod -Credential $cred "$g/api/prometheus/grafana/api/v1/rules"
```

> On macOS/Linux (bash) use `curl` instead, e.g.
> `curl -s -u admin:'<pass>' http://localhost:3010/api/datasources`.

## Not on Kubernetes?

- **Docker / VM Grafana:** mount `../alerting/` at `/etc/grafana/provisioning/alerting` and the
  dashboards via a file provider — see the main [`../README.md`](../README.md).
- **Grafana Cloud / no filesystem access:** use the Terraform provider in
  [`../alerting/terraform/`](../alerting/terraform/).
