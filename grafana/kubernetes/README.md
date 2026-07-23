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
| 8 alert rules + contact point + policy (`../alerting/*.yaml`) | `clickstack-grafana-alerting` | Also ensures the Grafana Deployment mounts it at `/etc/grafana/provisioning/alerting`. |

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

## Wire up notifications (do this first)

The shipped `../alerting/contact-points.yaml` has a **placeholder webhook URL** — rules
evaluate and fire, but nothing is delivered until you set a real one. Edit it **before**
you run the installer so Grafana only restarts once:

1. Edit the `url` in [`../alerting/contact-points.yaml`](../alerting/contact-points.yaml)
   (Slack/Teams/PagerDuty/Discord/any HTTP endpoint).
2. Then run the installer (below) — it applies the alerting ConfigMap and restarts Grafana.

(Not deploying alerts? Skip this and pass `-SkipAlerts` / `--skip-alerts`.)

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
| `-Namespace` | `clickstack` | Namespace of the Grafana deployment/ConfigMaps. |
| `-Deployment` | `clickstack-grafana` | Grafana Deployment name. |
| `-DatasourcesConfigMap` / `-DashboardsConfigMap` / `-AlertingConfigMap` | `clickstack-grafana-*` | Override if your release prefix differs. |
| `-ChServer` / `-ChPort` | `clickstack-clickhouse-clickhouse-headless` / `9440` | ClickHouse endpoint baked into the data source (`9440` = native-secure; `-Insecure` defaults it to `9000`). |
| `-CaCertPath` | `/etc/grafana/certs/ca.crt` | CA cert file (already mounted in the Grafana pod) used to verify ClickHouse TLS. |
| `-Insecure` | off | Plaintext (non-TLS) ClickStack: strip TLS from the data source, default the port to `9000`. |
| `-Advanced` | off | Also provision `../dashboards/advanced/` (deep dives needing an optional data source). |
| `-SkipAlerts` | off | Install data source + dashboards only. |
| `-NoRestart` | off | Patch the ConfigMaps but don't roll Grafana (do it yourself later). |

The script restarts Grafana at the end so provisioning re-runs. It is **idempotent** — re-run
it any time (e.g. after editing a dashboard or the webhook URL).

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
