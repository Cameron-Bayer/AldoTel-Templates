# AGENTS.md — Authoring HyperDX / ClickStack Dashboards

Operational guide for an AI agent (or engineer) creating **new HyperDX dashboards** for the
ClickStack observability platform. Everything here was verified against a live OSS ClickStack
(HyperDX `2.27.0`) running the OpenTelemetry demo on minikube.

---

## 0. Golden rules (read first)

1. **A dashboard contains no data.** Every tile points at a **Source** (Logs/Traces/Metrics),
   which maps to ClickHouse tables + columns. A template is portable only if the target install
   uses the **standard OTel schema** (`default.otel_logs`, `default.otel_traces`,
   `default.otel_metrics_{gauge,sum,histogram}`).
2. **Never hardcode source IDs.** Use `{{TOKENS}}` and let the importer resolve them per install.
3. **Validate metric/field names against the live ClickHouse before shipping.** Names vary by
   collector config (see §6 gotchas — e.g. `k8s.node.cpu.usage`, NOT `...utilization`).
4. **Build against the v2 API** (`/api/v2/dashboards`). HyperDX ≥ 2.27 supports it.
5. **Definition of done:** JSON parses → importer substitutes all tokens → POST returns 200 →
   dashboard round-trips via GET → tiles actually render data in the UI.

---

## 1. The artifact: a `CreateDashboardRequest`

A dashboard file is JSON posted to `POST /api/v2/dashboards`:

```jsonc
{
  "name": "My Dashboard",
  "tags": ["clickstack-templates", "domain"],
  "tiles": [ /* TileInput[] */ ],
  "filters": [],          // optional dashboard-wide filter keys
  "savedQuery": null      // optional default query
}
```

### Tile (grid is 24 columns wide)
```jsonc
{
  "name": "Error rate",
  "x": 0, "y": 0, "w": 12, "h": 4,   // x:0-23, w:1-24, y/h:>=1
  "config": { /* TileConfig — see §2 */ }
}
```
> Legacy `series` + `asRatio` on the tile are **deprecated**. Always use `config`.

---

## 2. TileConfig — the chart

`config.displayType` is the primary discriminator:
`line | stacked_bar | table | number | pie | heatmap | search | markdown`.

For `line/stacked_bar/table/number/pie` there are **two variants**:
- **Builder** (default): requires `sourceId` + `select[]`. Omit `configType`.
- **Raw SQL**: set `configType: "sql"`, requires `connectionId` + `sqlTemplate`. Use for
  data-science tiles (§5).

**Dashboard filters & raw SQL (`$__filters`).** Dashboard `filters[]` are **global** — HyperDX
auto-injects them into every *builder* tile (regardless of which source the tile uses), but
injects **nothing** into *Raw SQL* tiles unless the template contains the `$__filters` macro.
`$__filters` expands to the active filter conditions (or `(1=1 /** no filters applied */)` when
none) and must sit where the referenced columns are in scope. This is the only lever for raw SQL
tiles: **add `$__filters`** to make a tile filter-aware, **omit it** to make a tile *immune* to a
filter. There is **no per-tile filter opt-out** for builder tiles in 2.27.0 — to make a builder
tile immune to a dashboard filter, convert it to Raw SQL without `$__filters`. Beware
cross-scope contamination: a global filter on a column some tiles lack (e.g. `k8s.namespace.name`
is absent from node metrics; `k8s.node.name` is absent from deployment metrics) will blank those
tiles — make them immune or drop the filter.

**Metric ResourceAttributes vary by metric family — verify before adding a metrics filter.** On the
shared metrics source, different exporters populate different attributes. Verified facts (this
deployment): ClickHouse/Keeper metrics (`ClickHouse*`) carry **`service.instance.id`** (= the CH
instance, e.g. `clickstack-clickhouse-clickhouse-headless:9363`) and `ServiceName='otelcol'` but
**no `host.name` and no `k8s.namespace.name`**; collector metrics (`otelcol*`, `*process*`) carry
`service.instance.id`; node metrics (`k8s.node.*`) carry `k8s.node.name` but **no `ServiceName`/
`k8s.namespace.name`**; pod/deployment metrics carry `k8s.namespace.name`. Traces and logs carry
both `ServiceName` and `k8s.namespace.name`. A `service.instance.id` filter on the metrics source is
a noisy ~66-value all-pods dropdown — avoid it for single-instance ClickHouse. Probe before
filtering: `SELECT countIf(ResourceAttributes['k']!=''), count() FROM otel_metrics_gauge WHERE
MetricName LIKE '<family>%' AND TimeUnix > now()-INTERVAL 1 HOUR`.

### Builder example (line, metrics source)
```jsonc
{
  "displayType": "line",
  "sourceId": "{{METRICS_SOURCE_ID}}",
  "groupBy": "ResourceAttributes['k8s.node.name']",   // optional, splits into series
  "select": [
    { "aggFn": "avg", "valueExpression": "Value", "alias": "cpu",
      "metricName": "k8s.node.cpu.usage", "metricType": "gauge" }
  ]
}
```

### SelectItem (one aggregated value)
| field | notes |
|-------|-------|
| `aggFn` | `count | sum | avg | min | max | quantile | count_distinct | last_value | any | none` |
| `valueExpression` | column/expr to aggregate. **Omit for `count`; required otherwise.** For metrics use `"Value"`. |
| `level` | percentile (e.g. `0.95`) — **only** with `aggFn:"quantile"`. |
| `where` / `whereLanguage` | per-series filter; `whereLanguage` is `"lucene"` or `"sql"`. **Always include both on every select item** (use `where:""`, `whereLanguage:"sql"` when there is no filter). If omitted, the external API stores `aggCondition:null`/`aggConditionLanguage:null`, which renders fine but makes the **HyperDX UI unable to save** the dashboard (the internal `SavedChartConfigSchema` requires these to be a string / `'sql'|'lucene'`, not null). Note the external field names are `where`/`whereLanguage`; the API maps them to internal `aggCondition`/`aggConditionLanguage` — do **not** author the internal names (they're ignored on input). |
| `metricName` + `metricType` | **metrics sources only**. `metricType`: `gauge | sum | histogram`. |
| `alias` | legend label. |

### Per-displayType quick reference
- **line / stacked_bar**: `select[]` (1-20), optional `groupBy`, `asRatio` (needs exactly 2 selects),
  `compareToPreviousPeriod`, `fillNulls`.
- **number**: exactly 1 select; optional `colorRules` (`operator` ∈ `gt/gte/lt/lte/between/eq/neq`,
  `color` ∈ palette tokens like `chart-error`, `chart-warning`, `chart-success`). **No `asRatio`**
  (that's line/bar only). For a single-stat **ratio** keep `colorRules` by computing it inside one
  select, e.g. availability = `aggFn:"avg"`, `valueExpression:"if(StatusCode = 'Error', 0, 1)"`.
  A number tile may also be Raw SQL (`configType:"sql"` → 1 scalar), but Raw SQL number tiles
  support only a static `color`, **not** `colorRules`.
- **heatmap**: builder-only, **trace sources only**; exactly 1 `HeatmapSelectItem`
  (`valueExpression` to bucket, e.g. `"Duration"`; optional `countExpression`, `heatmapScaleType`
  ∈ `log|linear`); chart-level `where`/`whereLanguage`. No `aggFn`/`alias` on the select.
- **table**: `select[]` (1-20), `groupBy` (a **single field-expression string**, not an array),
  `orderBy` (e.g. `"p95 DESC"`), `having`, `groupByColumnsOnLeft`. **No chart-level `where`** on
  builder tables — filter by computing conditional selects (e.g. `sum(if(SeverityText IN ('Error',
  'Fatal'), 1, 0))`). Tables (builder **or** Raw SQL) are the **only** tiles that support `onClick`
  drill-down (see §2.1).
- **pie**: exactly 1 select + `groupBy`.
- **search** (raw log/event viewer): `select` is a **comma-separated string**
  (e.g. `"Timestamp, SeverityText, ServiceName, Body"`) + `where` + `whereLanguage` (required).
- **markdown** (section headers / notes): author as a **config tile**:
  `{ "name": "", "x":0, "y":.., "w":24, "h":3, "config": { "displayType":"markdown", "markdown":"#### Title" } }`.
  ⚠️ Do **NOT** use the `series` form `series:[{ "type":"markdown", "content":"…" }]`. The series path runs
  through `translateExternalChartToTileConfig`, which stores `source:'markdown'` (a truthy placeholder). The
  UI then treats that source id as missing and shows *"The data source for this tile no longer exists."*
  The `config` path runs through `convertToInternalTileConfig`, whose markdown case stores
  `{ displayType:'markdown', markdown, source:'', where:'', select:[], name }`. Empty `source` is falsy so
  `isSourceMissing` is false (so it **renders** without the error). Verified live in MongoDB on HyperDX
  2.27.0: the config form stores `source:''`; the series form stores `source:'markdown'`. Leave `name:""`
  to hide the tile's corner title. Use `####` (h4) headings; single-line headers `h:3`, multiline notes
  `h:6` so text isn't clipped. Markdown renders with a plain react-markdown — left-aligned only, no
  HTML/CSS/centering. On GET the API converts it back to `config:{displayType:'markdown', markdown}`.
  ⚠️ **In-place editability:** the import API **forces `source:''`** for markdown. A markdown tile with
  empty `source` **cannot be saved from the tile editor** — `convertFormStateToSavedChartConfig` only
  returns a savable config `if (source)` is truthy, so Save silently no-ops (no toast, no PATCH). To make a
  header editable, patch its stored `config.source` in MongoDB to a **real, existing source id** (e.g. the
  logs source). Graph tiles already have real sources and save normally. Customers importing via the API
  get render-only headers — to change header text, edit the template JSON and re-import.

### 2.1 onClick drill-downs (table tiles only)
`config.onClick` link-outs work **only on table tiles**. Two variants (`type`):
- `"search"` → opens the HyperDX search view of a source; `"dashboard"` → opens a dashboard.
- `target`: `{mode:"id", id:"<sourceOrDashboardId>"}` (use a `{{..._SOURCE_ID}}` token for portability)
  or `{mode:"template", template:"{{Column}}"}` (resolve by **name** at click time).
- Optional `whereTemplate` + `whereLanguage` and `filters[]`, both rendered against the clicked row
  with `{{column}}` variables, e.g. `whereTemplate:"ServiceName = '{{ServiceName}}'"`.
- ⚠️ `{{Column}}` row-variables are **not** importer tokens — keep the importer's unresolved-token
  check **case-sensitive** so mixed-case `{{ServiceName}}` isn't flagged (UPPERCASE-only = real token).

### Number formatting (`numberFormat`)
`output` ∈ `number | percent | byte | currency | time | duration | data_rate | throughput`.
Optional `numericUnit` (e.g. `bytes_iec`, `bytes_sec_si`), `mantissa`, `unit`.
**`numericUnit` is byte/bit/rate units only** (no time units like `ns`/`ms`) — for time use
`output:"duration"`/`"time"` *without* `numericUnit`, or omit `numberFormat`.

---

## 3. Sources, tokens & the importer (portability)

Author tiles with these tokens; the importer resolves them from `GET /api/v2/sources`
(matching by `kind`) and substitutes before `POST`:

| Token | Resolved from |
|-------|---------------|
| `{{LOGS_SOURCE_ID}}` / `{{TRACES_SOURCE_ID}}` / `{{METRICS_SOURCE_ID}}` | source `.id` by `kind` (`log`/`trace`/`metric`) |
| `{{CONNECTION_ID}}` | any source `.connection` (ClickHouse connection) |
| `{{LOGS_SCHEMA}}.{{LOGS_TABLE}}` | logs source `.from.databaseName` / `.from.tableName` |
| `{{TRACES_SCHEMA}}.{{TRACES_TABLE}}` | traces source `.from.databaseName` / `.from.tableName` |
| `{{METRICS_SCHEMA}}` | metric source `.from.databaseName` (metrics have no single table — combine with `.otel_metrics_{gauge,sum,histogram}` in Raw SQL). |

> ClickHouse **system tables** (e.g. `system.query_log`) are fixed names — reference them directly,
> not via tokens. They require the connection's ClickHouse user to have `SELECT` on them (and
> `query_log` to be enabled); call this out in `requirements.json` `receivers`.

Use `import.ps1` (Windows) / `import.sh` (curl+jq). **The importer upserts**: it matches an existing
copy by the stable `tmpl:<slug>` tag and updates it in place (`PUT`), else creates (`POST`), so
re-running is idempotent. Flags: `-DryRun`/`--dry-run`, `-Only`/`--only`, `-Delete`/`--delete`,
`-Duplicate`/`--duplicate`. On `PUT`, every dashboard `filter` must carry an `id` (the importer
reuses the existing filter ids by expression, minting one otherwise). Run `preflight.ps1`/`.sh`
first to confirm the target install actually has data for each dashboard.

Auth = **Bearer Personal API Access Key** (HyperDX → Team Settings → API Keys).

---

## 4. Standard tile recipes by domain

**Metrics (ClickHouse / K8s)** — builder, metrics source, `valueExpression:"Value"`:
- Counters (`*ProfileEvents_*`) → `metricType:"sum"`, `aggFn:"sum"`.
- Gauges (`*Metrics_*`, `*AsyncMetrics_*`, `k8s.*`) → `metricType:"gauge"`, `aggFn:"avg|max|last_value"`.
- Ratio (availability, disk %) → `asRatio:true` with exactly 2 selects + `numberFormat.output:"percent"`.

**Traces (RED method)** — builder, traces source:
- Rate: `count`, `where:"SpanKind:Server"`, `groupBy:"ServiceName"`.
- Errors %: `asRatio` of [`count where SpanKind:Server AND StatusCode:Error`, `count where SpanKind:Server`].
- Duration: `quantile` at `0.5 / 0.95 / 0.99` on `valueExpression:"Duration"` (**nanoseconds**).
- By route: `groupBy:"SpanAttributes['http.route']"`.

**Logs** — builder, logs source:
- Volume: `count`, `groupBy:"SeverityText"`.
- Errors: `where:"SeverityText:ERROR OR SeverityText:FATAL"`.
- Live stream: `displayType:"search"`, `select:"Timestamp, SeverityText, ServiceName, Body"`.

---

## 5. Data-science tiles (Raw SQL)

Set `configType:"sql"`, `connectionId:"{{CONNECTION_ID}}"`, and a `sqlTemplate`. Reference tables
via the schema/table tokens so it stays portable. Proven patterns:

- **Anomaly (z-score)**: rolling baseline of p95 over 7d; flag `(v - avg) / stddevPop`.
- **New log patterns**: `replaceRegexpAll(Body,'[0-9]+','<n>')` → group → `HAVING prior_7d=0 AND last_24h>0`.
- **Capacity forecast**: linear fit on disk growth → ETA to full.
- **Baseline overlay**: prefer the builder flag `compareToPreviousPeriod:true` (no SQL needed).
- **SLO burn-rate**: error-budget consumption over multiple windows.

---

## 6. Verified facts & gotchas (this environment)

- ClickHouse DB is **`default`**; tables `otel_logs`, `otel_traces`, `otel_metrics_{gauge,sum,histogram}`.
- **Verified ClickHouse metric names** (sum = ProfileEvents; gauge = Metrics/AsyncMetrics):
  `ClickHouseProfileEvents_Query|FailedQuery|SelectQuery|InsertQuery|InsertedRows` (sum),
  `ClickHouseMetrics_Query|Merge|PartMutation|ReadonlyReplica|MemoryTracking` (gauge),
  `ClickHouseAsyncMetrics_ReplicasMaxAbsoluteDelay` (gauge).
  Enrichment counters (sum): `ClickHouseProfileEvents_AsyncInsertBytes`,
  `ClickHouseProfileEvents_CachedReadBufferReadFrom{Cache,Source}Bytes`.
  Per-error-code counters (sum, cumulative): `ClickHouseErrorMetric_<CODE>` — for a "top errors"
  table use `max(Value) - min(Value)` over a window from `<metrics_db>.otel_metrics_sum`.
- **OTel Collector self-telemetry** (Prometheus scrape of the collector's `:8888`): sum —
  `otelcol_receiver_{accepted,refused,failed}_{spans,log_records,metric_points}_total`,
  `otelcol_exporter_sent_{spans,log_records,metric_points}_total`,
  `otelcol_processor_{incoming,outgoing}_items_total`, `otelcol_process_cpu_seconds_total`,
  `otelcol_scraper_{scraped,errored}_metric_points`; gauge — `otelcol_exporter_{queue_size,
  queue_capacity,in_flight_requests}`, `otelcol_process_{memory_rss_bytes,runtime_heap_alloc_bytes}`.
  (This collector emits **no** `otelcol_exporter_send_failed_*` / `otelcol_processor_dropped_*` —
  infer drops from incoming-vs-outgoing items.) Group via `ResourceAttributes['service.instance.id'
  |'host.name']`.
- **`system.query_log`** is enabled; HyperDX's ClickHouse connection user here is **`app`**, which
  can read it. Useful cols: `type` (`QueryFinish`/`ExceptionWhileProcessing`/`ExceptionBeforeStart`),
  `query_kind`, `query_duration_ms`, `memory_usage`, `read_rows`, `exception_code`, `user`, `query`.
- **K8s gotchas**: there is **no** `k8s.node.cpu.utilization` → use `k8s.node.cpu.usage` (cores).
  **No** `k8s.volume.*` PVC metrics here → use `k8s.node.filesystem.usage|capacity`.
  Available: `k8s.node.{cpu.usage,memory.usage,filesystem.*}`,
  `k8s.deployment.{available,desired}`, `k8s.pod.{phase,cpu.usage,memory.usage}`,
  `k8s.container.restarts`, `k8s.*.{ready,desired}_*`.
  Limit/health gauges (verified): `k8s.pod.{cpu,memory}_limit_utilization` (0-1 ratio → format
  `percent`), `k8s.container.cpu_limit_utilization`, `k8s.node.condition_ready` (1=ready; `sum` = #
  ready nodes).
- **Resource-attribute group keys** (confirmed populated): `k8s.node.name`, `k8s.pod.name`,
  `k8s.deployment.name`, `k8s.namespace.name` — access via `ResourceAttributes['<key>']`.
- Trace `SpanKind` values are strings: `Server | Client | Internal | Consumer | Producer`.
- `Duration` (otel_traces) is in **nanoseconds** — divide by `1e6` for ms in SQL tiles.
- **Storage / MergeTree (Raw SQL)** — `system.parts` (filter `WHERE active`): `database`, `table`,
  `bytes_on_disk`, `rows`, `data_{compressed,uncompressed}_bytes`, `marks`, `part_type`; compression
  ratio = `sum(data_uncompressed_bytes)/sum(data_compressed_bytes)`. `system.part_log`: `event_type`
  (`NewPart|MergeParts|MutatePart|...`), `event_time`, `duration_ms`, `rows`, `size_in_bytes`,
  `merge_reason`, `error`, `database`, `table`. Live & rich on single-node; no metrics pipeline needed.
- **ClickHouse Keeper (metrics)** — present even on single-node (embedded Keeper). Gauges:
  `ClickHouseMetrics_{ZooKeeperSession,ZooKeeperWatch,ZooKeeperRequest,KeeperAliveConnections,
  KeeperOutstandingRequests}`. Sum (cumulative): `ClickHouseProfileEvents_Keeper{Commits,CommitsFailed,
  GetRequest,ListRequest,CreateRequest,RemoveRequest,RequestTotal,PacketsReceived,PacketsSent,
  CommitWaitElapsedMicroseconds,ProcessElapsedMicroseconds}`. Keeper/replication error codes (sum):
  `ClickHouseErrorMetric_{NO_ZOOKEEPER,KEEPER_EXCEPTION,UNEXPECTED_ZOOKEEPER_ERROR,...}`.
- **Replication tables are empty on single-node** — `system.replicas` / `system.replication_queue`
  return 0 rows here (no `ReplicatedMergeTree`). Build replication tiles anyway (valid SQL, degrade
  gracefully) and document them as populating only on replicated/clustered installs.
- **`hyperdx_sessions` (RUM)** exists as a 4th `session`-kind source but had **0 rows** (no browser
  SDK) — schema is log-shaped (`Timestamp`, `Body`, `ServiceName`, `SeverityText`, `*Attributes`),
  **not** RUM-specific fields. Don't author RUM tiles until real session data is flowing.
- **`/api/v2/charts/series` field names differ from Tile schema**: the series item uses **`field`**
  for the aggregation expression (Tile `SelectItem` uses `valueExpression`), and `metricDataType`
  (Tile uses `metricType`). For **metric** series, `aggFn:"count"` returns **no datapoints** (use
  `avg`/`sum`) and coarse `granularity:"1d"` returns **no metric datapoints** (use `1h` or finer);
  detect "is data flowing" by **presence of non-null `series_0` points**, not `sum>0` (gauges read 0).
- Dashboards/config persist in **MongoDB** (`dashboards`, `sources`, `connections` collections);
  telemetry in ClickHouse.

---

## 7. Workflow for creating a NEW dashboard

```
1. CLARIFY scope (which signal: logs/traces/metrics; which method: RED/USE/SLO).
2. DISCOVER real names in ClickHouse before writing tiles:
     kubectl exec -n clickstack clickstack-clickhouse-clickhouse-0-0-0 -- \
       clickhouse-client -q "SELECT DISTINCT MetricName FROM default.otel_metrics_gauge \
       WHERE MetricName ILIKE '%<area>%' ORDER BY 1"
3. WRITE dashboards/<name>.json using {{TOKENS}} and §2-§5 recipes.
4. VALIDATE JSON parses (ConvertFrom-Json) and every {{TOKEN}} is handled by the importer.
5. IMPORT:
     kubectl port-forward -n clickstack svc/clickstack-app 8000:8000   # API on :8000
     $env:HDX_API_URL="http://localhost:8000"; $env:HDX_API_KEY="<key>"; ./import.ps1
6. VERIFY round-trip:
     GET /api/v2/dashboards  → confirm tiles count + SQL tiles resolved (FROM default.otel_*).
     Open the UI dashboard → confirm tiles render data (not empty).
```

### Useful endpoints (Bearer auth)
- `GET  /api/v2/sources` — resolve source IDs / db / table / connection.
- `GET/POST /api/v2/dashboards` — list / create.
- `GET/POST /api/v2/alerts` — alerting.
- `POST /api/v2/charts/series` — query series data directly (debug a tile's query).
- `/health` — liveness (no auth).

---

## 8. Anti-patterns

- ❌ Hardcoding `sourceId`/`connectionId` from one install into the template.
- ❌ `valueExpression` on a `count` select (must be omitted), or missing it on non-count aggFns.
- ❌ Assuming OTel metric names without checking the live data (collector configs differ).
- ❌ Re-running the importer with `--duplicate` when you meant to update (default upserts by
  `tmpl:` tag; `--duplicate` forces new copies).
- ❌ Omitting filter `id`s when building the `PUT` body — `UpdateDashboardRequest` filters require
  `id` (only `POST`/create accepts id-less `FilterInput`).
- ❌ Treating `Duration` as ms (it's ns).
- ❌ Putting secrets (API keys) into committed files.
