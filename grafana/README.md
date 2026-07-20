# ClickStack Grafana Dashboards

High-level Grafana dashboards that read the **same ClickHouse data** your HyperDX /
ClickStack deployment already stores. They give you executive-style "golden signal"
views over your services, Kubernetes cluster, and logs — no extra collectors or
schema changes required.

These complement the per-domain HyperDX dashboards in [`../hyperdx/dashboards/`](../hyperdx/dashboards/):
HyperDX for deep, interactive investigation; Grafana for at-a-glance health and for
teams that already standardize on Grafana.

> **Running ClickStack on Kubernetes?** Its bundled Grafana uses ephemeral storage, so
> UI/API imports vanish on the next pod restart. Use the durable ConfigMap-provisioning
> installer in [`kubernetes/`](kubernetes/README.md) — one command installs the data
> source, all four dashboards, and the alerts so they survive restarts.

---

## Customer quick-start (dashboards + alerts)

The two packages install through **different mechanisms**: dashboards import through the
UI in seconds; alert rules load from Grafana's provisioning folder and need a restart.
Follow these steps once and you'll have both.

> **Prerequisites:** a running Grafana (v10.4+), the
> [ClickHouse data source plugin](https://grafana.com/grafana/plugins/grafana-clickhouse-datasource/)
> installed, and network access from Grafana to the ClickHouse that ClickStack writes to.
> On **Grafana Cloud** (or anywhere you can't write to `/etc/grafana/provisioning`), see
> [Installing alerts without filesystem access](#installing-alerts-without-filesystem-access-grafana-cloud).

**1. Download the two folders** — `grafana/dashboards/` (4 JSON files) and
`grafana/alerting/` (3 YAML files).

**2. Add the ClickHouse data source** — *Connections → Data sources → Add → ClickHouse*.
Enter host/port/user/password/database. **Set its UID to `clickstack-ch`** (the *UID*
field). This is the one gotcha:
   - **Dashboards** use a datasource *variable* — you pick your connection on import, so
     the UID doesn't matter for them.
   - **Alert rules** reference a *fixed* UID (`clickstack-ch`) because provisioned rules
     can't prompt for one. So either name the UID `clickstack-ch`, **or** find/replace
     `clickstack-ch` in `alerting/alert-rules.yaml` with your datasource's UID.

**3. Import the dashboards (UI, no restart)** — for each JSON:
*Dashboards → New → Import → Upload JSON file →* pick your ClickHouse datasource →
**Import**. Repeat for all four.

**4. Install the alerts (provisioning, needs a restart)** — copy `grafana/alerting/` onto
your Grafana server and mount/place it at `/etc/grafana/provisioning/alerting/`, then
restart Grafana:
   ```yaml
   # docker-compose / Kubernetes volume mount example
   volumes:
     - ./alerting:/etc/grafana/provisioning/alerting
   ```
   Rules appear under **Alerting → Alert rules → "ClickStack Alerts"** (6 rules).

**5. Connect your notification channel + tune thresholds** —
   - In `alerting/contact-points.yaml`, replace the placeholder `url` with a
     webhook URL for the channel you want — a Slack incoming webhook, a Teams
     Workflow "Post to a channel when a webhook request is received" URL,
     PagerDuty, Discord, or any HTTP endpoint that accepts a POST.
   - Adjust the `params: [...]` numbers in `alerting/alert-rules.yaml` (see
     [alerting/README.md](alerting/README.md#tuning-thresholds)).
   - Restart Grafana again, or `POST /api/admin/provisioning/alerting/reload`.

**6. Verify** — dashboards show live data; every alert rule reports **health = ok**; and
*Contact points → ClickStack Alerts → Test* delivers a notification to your channel.

### Installing alerts without filesystem access (Grafana Cloud)

File-based provisioning needs write access to `/etc/grafana/provisioning/`, which Grafana
Cloud and some managed setups don't allow. In that case the **dashboards still import
normally** (step 3); for the **alerts**, use the Terraform provider instead — see
[`alerting/terraform/`](alerting/terraform/README.md) for a ready-to-apply example that
creates the same 6 rules, the alert contact point, and the notification policy via the
Grafana API.

---

## What's included

| File | Dashboard | Reads from | Answers |
|------|-----------|-----------|---------|
| `dashboards/00-executive-summary.json` | **Executive Summary** | all three | One-pane health across services, Kubernetes, and logs — top signals only. |
| `dashboards/service-health-golden-signals.json` | **Service Health (Golden Signals)** | `otel_traces` | Are my services up, fast, and error-free? (Rate / Errors / Duration per service) |
| `dashboards/kubernetes-cluster-overview.json` | **Kubernetes Cluster Overview** | `otel_metrics_gauge` | Are nodes/pods healthy? CPU, memory, restarts, deployment availability. |
| `dashboards/logs-errors-overview.json` | **Logs & Errors Overview** | `otel_logs` | How much are we logging, what's erroring, and what do the latest errors say? |

All four use only the **default OpenTelemetry ClickHouse schema** that ClickStack ships
with, so they work on any ClickStack / HyperDX + ClickHouse deployment.

**Filters:** the Service Health, Kubernetes, and Logs dashboards include a **Service** or
**Namespace** drop-down (multi-select, defaults to *All*) at the top, so you can narrow
every panel to the workloads you care about. The Executive Summary is intentionally
unfiltered — it's the always-on overview.

**Alerts:** a companion set of Grafana unified-alerting rules (error rate, latency,
ingestion stalled, pods not running, error/fatal logs) lives in
[`alerting/`](alerting/README.md) — a generic webhook by default, tunable thresholds. Use these when
you want Grafana to *page you*, not just visualize.

---

## Requirements

1. **Grafana 10.4+** (tested on 11.2).
2. The **ClickHouse data source plugin** (`grafana-clickhouse-datasource`), installed and
   configured to point at the ClickHouse that ClickStack writes to.
   ```bash
   grafana-cli plugins install grafana-clickhouse-datasource
   ```
   Or in Grafana Cloud / container: add it from **Connections → Add new connection → ClickHouse**.
3. Your ClickHouse contains the standard ClickStack tables in the `default` database:
   `otel_traces`, `otel_logs`, `otel_metrics_gauge` (this is the default — nothing to change).

> **Different database name?** These dashboards assume the `default` database. If your
> ClickStack instance uses another database, do a find/replace of `default.otel_` →
> `<your_db>.otel_` in the JSON before importing.

---

## Install (import into your Grafana)

1. In Grafana, go to **Dashboards → New → Import**.
2. Upload one of the JSON files from `dashboards/` (or paste its contents).
3. When prompted, the dashboard exposes a **"ClickHouse datasource"** variable at the top —
   pick your ClickHouse connection. That's the only wiring step; every panel follows it.
4. Repeat for the other three dashboards.

No panel is hard-wired to a specific data source — they all reference a dashboard
**datasource variable** (`${ds}`), so the same file works in any environment.

### Optional: provision them (GitOps)

Drop the JSON into a Grafana dashboard provisioning folder and point a provider at it:

```yaml
# /etc/grafana/provisioning/dashboards/clickstack.yaml
apiVersion: 1
providers:
  - name: ClickStack
    type: file
    options:
      path: /var/lib/grafana/dashboards/clickstack
```

---

## Dashboard details

### Executive Summary (all three sources)
- **Services:** requests/sec, error rate %, latency p95, active-service count; request-volume
  and overall error-rate trends.
- **Kubernetes:** Nodes Ready, Pods Running, Pods Not Running, Container Restarts.
- **Logs:** logs/sec, error+ logs/sec, error log %, fatal count; volume-by-severity and
  error-by-service trends.
- **Needs attention:** every service ranked by error rate, color-coded.
- *A single at-a-glance page for status pages, war-rooms, or a leadership screen. No filters.*

### Service Health — Golden Signals (`otel_traces`)
- **Filter:** `Service` (multi-select, default All).
- **Stats:** requests/sec, error rate %, latency p95, latency p99 (whole selected range).
- **Timeseries:** request volume by service, latency percentiles (p50/p95/p99),
  overall error rate, errors per interval by service.
- **Table:** per-service RED breakdown (Req/s, Errors, Error %, p50/p95/p99) with a
  color-coded Error % column.
- *Only inbound "server" spans are counted (`SpanKind = 'Server'`), so numbers reflect
  requests the service handled — not every internal/outbound span.*

### Kubernetes Cluster Overview (`otel_metrics_gauge`)
- **Filter:** `Namespace` (multi-select, default All) — applies to pod/deployment/container
  panels; node-level panels always show the whole cluster.
- **Stats:** Nodes Ready, Pods Running, Pods Not Running, total Container Restarts.
- **Timeseries:** node CPU (cores), node memory (bytes), pod CPU by pod, deployment
  available replicas.
- **Tables:** top pods by working-set memory, container restarts by pod (color-coded).
- *Requires the OpenTelemetry **k8s cluster receiver** + **kubelet stats receiver**
  (ClickStack's infrastructure collectors ship these). Pod phase `2` = Running.*

### Logs & Errors Overview (`otel_logs`)
- **Filter:** `Service` (multi-select, default All).
- **Stats:** logs/sec, error+fatal logs/sec, error log %, fatal log count.
- **Timeseries:** log volume by severity, error+ logs by service.
- **Tables:** top services by error logs, most recent errors (with message body).
- *"Error+" means `SeverityText` of `error` or `fatal`. Includes both Kubernetes
  container logs and application OTLP logs, exactly as ClickStack ingests them.*

---

## Local development harness (maintainers only)

This folder also contains a throwaway Grafana wired to a ClickStack ClickHouse for
authoring/validating the dashboards. **Customers do not need this.**

```powershell
# 1. Expose ClickHouse from your cluster
kubectl port-forward -n clickstack svc/clickstack-clickhouse-clickhouse-headless 9000:9000

# 2. Start the dev Grafana (http://localhost:3005, admin/admin)
#    Set CH_PASSWORD first — it feeds the dev ClickHouse datasource (no default is baked in).
$env:CH_PASSWORD = "<your ClickHouse password>"
docker compose -f grafana/docker-compose.yml up -d

# 3. Regenerate dashboards after editing the generator
node grafana/gen-dashboards.js

# 4. Validate every panel query against real data
node grafana/validate.js
```

- `docker-compose.yml` — dev Grafana with the ClickHouse plugin pre-installed.
- `provisioning/` — dev data source + dashboard provider (points at `host.docker.internal:9000`).
- `gen-dashboards.js` — source of truth that emits the shippable JSON in `dashboards/`.
- `validate.js` — runs each panel's SQL through Grafana's query API and reports row counts.
