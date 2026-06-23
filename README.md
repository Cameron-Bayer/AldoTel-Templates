# ClickStack Dashboard Templates (Open Source / self-hosted HyperDX)

Download-and-go HyperDX dashboards for customers running **Open Source ClickStack**
(HyperDX + ClickHouse + OpenTelemetry). Each domain is a separate dashboard so customers
enable only what they run.

| File | What it shows | Source kind |
|------|---------------|-------------|
| `dashboards/clickhouse-health.json` | Query/insert rate, failed queries, memory, merges/mutations, replication lag, readonly replicas | metric |
| `dashboards/k8s-infrastructure.json` | Node CPU/mem, deployment availability, pod phase, restarts, top pod memory, node filesystem usage | metric |
| `dashboards/services-red.json` | RED method: request rate, error rate %, p50/p95/p99 latency, slowest routes, latency anomaly (z-score), latency heatmap | trace |
| `dashboards/logs-overview.json` | Log volume by severity, error rate, top errors, **new** error patterns, live error stream | log |
| `dashboards/collector-health.json` | OTel Collector pipeline: accepted/refused/failed spans, exporter queue & sent, processor in/out (drops), scraper errors, collector CPU/mem | metric |
| `dashboards/clickhouse-queryperf.json` | Query rate by kind, p95/p99 duration, memory/query, exceptions, slowest queries, top error codes (`system.query_log` + metrics) | metric |
| `dashboards/slo-errorbudget.json` | Per-service availability SLI, error budget, multi-window burn-rate (1h/6h/24h/3d), burn-rate trend | trace |
| `dashboards/ch-storage.json` | MergeTree storage: disk & compression KPIs, part-events / merge-duration / bytes & rows over time, largest tables, too-many-parts watch, recent merges (`system.parts` / `system.part_log`) | SQL |
| `dashboards/ch-keeper.json` | ClickHouse Keeper: sessions, watches, request rate by type, commits vs failed, packets, in-flight, commit/process time, Keeper errors; plus replication status & queue tables (empty on single-node, populate when replicated) | metric + SQL |
| `dashboards/exec-overview.json` | One landing page: cross-domain KPI tiles (span/log error %, p95, CH queries, nodes ready, collector drops) + **click-through** tables (services → Traces / Logs) + ingest & request/error trends | trace + log + metric |

## Why these "just work": the schema contract

A HyperDX dashboard does not contain data — every tile points at a **Source** (Logs / Traces /
Metrics) which maps to **ClickHouse tables and column names**. Templates are portable only when
everyone lands data in the **standard ClickStack OTel schema** (`otel_logs`, `otel_traces`,
`otel_metrics_gauge/sum/histogram`). That is exactly what the default ClickStack OTel collector
produces, so ship the collector config alongside these dashboards as the contract.

The one thing that differs per install is the **Source IDs / connection ID / database name**.
The importer resolves those at install time, so the JSON stays portable.

## Prerequisites

1. A running OSS ClickStack with the three default sources created in HyperDX:
   a **Logs** (kind `log`), **Traces** (kind `trace`), and **Metrics** (kind `metric`) source.
2. Telemetry flowing in via the standard OTel collector:
   - ClickHouse metrics (Prometheus/system metrics) for `clickhouse-health`
   - `kubeletstats` + `k8s_cluster` receivers for `k8s-infrastructure`
   - app traces + logs for `services-red` / `logs-overview`
3. A **Personal API Access Key**: HyperDX → **Team Settings → API Keys**.

## Install

> **Run the pre-flight check first.** It queries your live install and tells you which dashboards
> have data flowing (so you don't import a dashboard that renders empty). See
> [Pre-flight](#pre-flight-will-it-work-here) below.

### Windows (PowerShell)
```powershell
$env:HDX_API_URL = "http://localhost:8000"
$env:HDX_API_KEY = "<your Personal API Access Key>"
./preflight.ps1            # check compatibility (recommended)
./import.ps1               # upsert all dashboards
```

### macOS / Linux (bash, needs `curl` + `jq`)
```bash
export HDX_API_URL="http://localhost:8000"
export HDX_API_KEY="<your Personal API Access Key>"
./preflight.sh            # check compatibility (recommended)
./import.sh              # upsert all dashboards
```

The importer:
1. `GET /api/v2/sources` → picks source IDs by `kind`, plus the ClickHouse `connection` id and
   database/table names.
2. Substitutes the `{{TOKENS}}` in each template.
3. **Upserts** each dashboard: it matches an existing copy by the stable `tmpl:<slug>` tag and
   updates it in place (`PUT`); otherwise it creates a new one (`POST`). Re-running is therefore
   idempotent — no duplicates.

### Importer flags (same on PowerShell `-Flag` and bash `--flag`)

| Flag | Effect |
|------|--------|
| `-DryRun` / `--dry-run` | Print what would be created/updated/deleted; write nothing. |
| `-Only <files>` / `--only <files>` | Comma-separated file names to act on (e.g. `services-red.json,logs-overview.json`). |
| `-Delete` / `--delete` | Remove the template-managed dashboards (matched by `tmpl:` tag). |
| `-Duplicate` / `--duplicate` | Force-create new copies even if a matching dashboard exists. |

```powershell
./import.ps1 -DryRun
./import.ps1 -Only services-red.json,logs-overview.json
./import.ps1 -Delete
```

## Pre-flight: will it work here?

`preflight.ps1` / `preflight.sh` reads `requirements.json` and, for every metric/field a dashboard
needs, runs a lightweight `POST /api/v2/charts/series` query against your install to see whether
data is actually flowing. Each dashboard is rated:

- **OK** — all required *and* optional checks have data.
- **DEGRADED** — all required checks pass; some optional tiles will be empty.
- **FAIL** — a required check has no data; don't import as-is (your collector isn't sending it).

It prints a `--only` command listing exactly the dashboards that are safe to import.

## Support matrix

What each dashboard needs from your OpenTelemetry collector. **Required** checks must have data or
the dashboard is rated FAIL; **optional** tiles degrade gracefully (render empty) when absent.
Authoritative, machine-readable version: [`requirements.json`](./requirements.json).

| Dashboard | Source kind | Required receivers / signals | Optional (degrades) |
|-----------|-------------|------------------------------|---------------------|
| `clickhouse-health` | metric | ClickHouse metrics scraped into OTel — `ClickHouseProfileEvents_{Query,FailedQuery,SelectQuery,InsertQuery}` (sum), `ClickHouseMetrics_{Query,MemoryTracking}` (gauge) | `*_InsertedRows`, `ClickHouseMetrics_{Merge,PartMutation,ReadonlyReplica}`, `ClickHouseAsyncMetrics_ReplicasMaxAbsoluteDelay` |
| `k8s-infrastructure` | metric | `kubeletstats` + `k8s_cluster` receivers — `k8s.node.{cpu,memory}.usage`, `k8s.deployment.{available,desired}`, `k8s.pod.{phase,memory.usage}`, `k8s.container.restarts` | `k8s.node.filesystem.{usage,capacity}` |
| `services-red` | trace | Application traces (OTLP) — server spans (`SpanKind:Server`) | error spans (`StatusCode:Error`) |
| `logs-overview` | log | Application/container logs (filelog or OTLP) — any log volume | error logs (`SeverityText:ERROR/FATAL`) |
| `collector-health` | metric | OTel Collector self-telemetry scraped into OTel (Prometheus receiver on the collector's `:8888`) — `otelcol_receiver_accepted_spans_total`, `otelcol_exporter_{sent_spans_total,queue_size,queue_capacity}` | processor in/out items, scraper points, collector CPU/mem |
| `clickhouse-queryperf` | metric + SQL | `ClickHouseMetrics_{Query,MemoryTracking}` (gauge) **and** Raw SQL on `system.query_log` — the HyperDX ClickHouse user (`app` here) must be able to `SELECT` from `system.query_log`, and `query_log` must be enabled | `ClickHouseProfileEvents_FailedQuery`; error-code table reads `<metrics_db>.otel_metrics_sum` |
| `slo-errorbudget` | trace + SQL | Application traces (OTLP) with server spans + `StatusCode` | error spans; burn-rate tiles need the traces table (`{{TRACES_SCHEMA}}.{{TRACES_TABLE}}`) |
| `ch-storage` | SQL only | Raw SQL on `system.parts` + `system.part_log` — the HyperDX ClickHouse user (`app` here) must be able to `SELECT` from them (`part_log` is on by default). No metric receivers required. | — (all tiles are Raw SQL) |
| `ch-keeper` | metric + SQL | None hard-required (degrades). Keeper tiles use `ClickHouseMetrics_ZooKeeper*`/`Keeper*` + `ClickHouseProfileEvents_Keeper*` if scraped | Keeper metrics; **replication tables** (`system.replicas` / `system.replication_queue`) are empty on single-node and populate only on replicated/clustered installs |
| `exec-overview` | trace + log + metric | None hard-required — cross-cutting roll-up; every tile degrades when its signal is absent | traces (error %, p95, drill-down), logs (error %, drill-down), CH metrics, collector metrics |

**Baseline requirements (all dashboards):** HyperDX **≥ 2.27** (v2 dashboard API), the three
default sources created in HyperDX (`log` / `trace` / `metric`), and data landed in the standard
ClickStack OTel schema (`otel_logs`, `otel_traces`, `otel_metrics_{gauge,sum,histogram}`).

> Metric names vary by collector config. The names above are the defaults verified against a live
> OSS ClickStack; if `preflight` reports a required metric missing, your exporter likely emits it
> under a different name — adjust `metricName` in the tile (and `requirements.json`).

## Dashboard filters (variables)

Every dashboard ships a top-of-page **filter bar** (`filters[]`) so one template serves a busy
multi-tenant cluster without editing tiles. Pick a value and all tiles bound to that source
re-scope. What each exposes:

- **Service** — `services-red`, `slo-errorbudget`, `logs-overview`, `exec-overview`.
- **Namespace / Node** — `k8s-infrastructure`, `exec-overview` (Namespace).
- **Instance / Collector** — the ClickHouse dashboards (`host.name`) and `collector-health`
  (`service.instance.id`).
- **Severity** — `logs-overview`.

> Filters bind to one source. On the cross-source `exec-overview`, the **Service** filter scopes the
> trace tiles and **Namespace** scopes the metric tiles; tiles from other sources are unaffected.

## Customizing

- **Metric names depend on how ClickHouse exposes metrics.** The `clickhouse-health` tiles use
  the common `ClickHouseProfileEvents_*` / `ClickHouseMetrics_*` / `ClickHouseAsyncMetrics_*`
  names. If you scrape via a different exporter, adjust `metricName` in the tiles.
- Grid is **24 columns wide**; tiles use `x,y,w,h`.
- `aggFn` options: `count`, `sum`, `avg`, `min`, `max`, `quantile` (needs `level`),
  `count_distinct`, `last_value`.
- Number tiles support conditional coloring via `colorRules`
  (operators `gt/gte/lt/lte`, palette tokens like `chart-error`, `chart-warning`).

## Data-science tiles (Raw SQL)

Several tiles use the **Raw SQL** variant (`configType: "sql"`) to go beyond static charts:

- **`services-red` → latency anomaly:** computes a 7-day rolling **z-score** of p95 latency, so a
  spike is flagged relative to its own baseline rather than a static threshold.
- **`logs-overview` → new log patterns:** normalizes error bodies (digits/IDs → placeholders) and
  surfaces patterns that appeared in the **last 24h but never in the prior 7 days** — a cheap
  Drain-style "what's new since the deploy?" detector.
- **`clickhouse-queryperf` → `system.query_log`:** query rate by kind, p95/p99 duration, peak
  memory per query, exceptions, and a slowest-queries table — read directly from ClickHouse's own
  `system.query_log` (requires the HyperDX ClickHouse user to have `SELECT` on it).
- **`slo-errorbudget` → multi-window burn-rate:** error-budget consumption over 1h/6h/24h/3d
  windows against a 99.9% SLO, plus a burn-rate trend line (`>1` = burning budget too fast).
- **`ch-storage` → `system.parts` / `system.part_log`:** live disk & compression KPIs, part-event /
  merge-duration / bytes & rows time series, largest-tables and **too-many-parts** watch tables, and
  a recent-merges audit — read straight from ClickHouse's own storage system tables (no metrics
  pipeline needed).
- **All builder tables over Logs/Traces → click-through drill-downs:** table tiles use tile
  `onClick` (table-only) to link a clicked row straight into the **Traces** or **Logs** search,
  pre-filtered from the row — turning every table into a triage launcher:
  - `exec-overview`: services → Traces / Logs (`ServiceName = '{{ServiceName}}'`).
  - `services-red`: slowest routes → Traces (`SpanAttributes['http.route'] = '{{...}}'`).
  - `slo-errorbudget`: errors-by-service → Traces (`ServiceName = '{{ServiceName}}' AND StatusCode = 'Error'`).
  - `logs-overview`: top error messages → Logs (`Body = '{{Body}}'`).

Both run entirely as ClickHouse SQL — no extra service. Other easy extensions:
disk-fill forecasting (linear fit on disk growth), `compareToPreviousPeriod: true` for instant
week-over-week baselining (already enabled on the ClickHouse query-rate tile), and SLO
error-budget burn-rate tiles.

## Notes

- Built against the HyperDX **v2** dashboard API
  (`packages/api/openapi.json` in the hyperdx repo).
- **HTTP-oriented tiles degrade on non-HTTP services.** `services-red`'s route tiles read
  `SpanAttributes['http.route']` and `StatusMessage`; pure gRPC/messaging services that don't set
  those will show empty/`(none)` rows there while the rate/error/latency tiles still work.
- The importer **upserts** (matches by the `tmpl:<slug>` tag), so re-running updates dashboards in
  place instead of duplicating them. Use `-Delete` / `--delete` to remove them, or
  `-Duplicate` / `--duplicate` to force new copies.
