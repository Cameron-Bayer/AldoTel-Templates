# Install into a ClickStack-on-Kubernetes Grafana (durable)

ClickStack ships a bundled Grafana. On Kubernetes that Grafana stores everything in
an **ephemeral SQLite database** — there is no PersistentVolume on `/var/lib/grafana`.

> **The gotcha:** anything you create through the Grafana **HTTP API** — a data source,
> an imported dashboard — **disappears the next time the Grafana pod restarts** (and it
> restarts often: chart upgrades, node pressure, cold-start crash-loops). Only Grafana's
> **file-based provisioning** survives, and on this chart that provisioning is fed by
> **ConfigMaps**.

`install-k8s.ps1` does the durable thing: it patches the Grafana provisioning ConfigMaps
so the data source, dashboards, and alerts all come back automatically on every restart.

## What it installs

| Component | ConfigMap patched | Notes |
|-----------|-------------------|-------|
| `clickstack-ch` ClickHouse data source | `clickstack-grafana-datasources` | From [`datasource-clickstack-ch.yaml`](datasource-clickstack-ch.yaml). The alert rules reference this fixed UID. |
| 4 dashboards (`../dashboards/*.json`) | `clickstack-grafana-dashboards` | Each dashboard's `ds` variable is pinned to `clickstack-ch` so panels resolve with no prompt. |
| 6 alert rules + contact point + policy (`../alerting/*.yaml`) | `clickstack-grafana-alerting` | Also ensures the Grafana Deployment mounts it at `/etc/grafana/provisioning/alerting`. |

## Prerequisites

- `kubectl` pointed at the cluster running ClickStack.
- The ClickStack Grafana Deployment already injects a `CH_PASSWORD` env var (its built-in
  `clickhouse` data source uses it) — the provisioned `clickstack-ch` data source reuses it,
  so **you don't pass a password**.

## Usage

```powershell
# From the repo, in grafana/kubernetes/
./install-k8s.ps1

# Different namespace, data source + dashboards only (no alerts):
./install-k8s.ps1 -Namespace obs -SkipAlerts

# Non-default ClickHouse endpoint:
./install-k8s.ps1 -ChServer my-clickhouse-headless -ChPort 9000
```

Key parameters (all optional, defaults match the stock ClickStack chart):

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-Namespace` | `clickstack` | Namespace of the Grafana deployment/ConfigMaps. |
| `-Deployment` | `clickstack-grafana` | Grafana Deployment name. |
| `-DatasourcesConfigMap` / `-DashboardsConfigMap` / `-AlertingConfigMap` | `clickstack-grafana-*` | Override if your release prefix differs. |
| `-ChServer` / `-ChPort` | `clickstack-clickhouse-clickhouse-headless` / `9000` | ClickHouse endpoint baked into the data source. |
| `-SkipAlerts` | off | Install data source + dashboards only. |
| `-NoRestart` | off | Patch the ConfigMaps but don't roll Grafana (do it yourself later). |

The script restarts Grafana at the end so provisioning re-runs. It is **idempotent** — re-run
it any time (e.g. after editing a dashboard or the webhook URL).

## Verify

```powershell
kubectl port-forward -n clickstack svc/clickstack-grafana 3010:3000
# data sources — expect 'clickhouse' + 'clickstack-ch'
curl -s -u <admin>:<pass> http://localhost:3010/api/datasources
# dashboards
curl -s -u <admin>:<pass> "http://localhost:3010/api/search?type=dash-db"
# alert-rule health — expect health=ok for every rule
curl -s -u <admin>:<pass> http://localhost:3010/api/prometheus/grafana/api/v1/rules
```

## Wire up notifications

The shipped `../alerting/contact-points.yaml` has a **placeholder webhook URL** — rules
evaluate and fire, but nothing is delivered until you set a real one:

1. Edit the `url` in [`../alerting/contact-points.yaml`](../alerting/contact-points.yaml)
   (Slack/Teams/PagerDuty/Discord/any HTTP endpoint).
2. Re-run `./install-k8s.ps1` (or `kubectl apply` the alerting ConfigMap and restart Grafana).

## Not on Kubernetes?

- **Docker / VM Grafana:** mount `../alerting/` at `/etc/grafana/provisioning/alerting` and the
  dashboards via a file provider — see the main [`../README.md`](../README.md).
- **Grafana Cloud / no filesystem access:** use the Terraform provider in
  [`../alerting/terraform/`](../alerting/terraform/).
