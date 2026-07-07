# ClickStack Dashboards — Prioritized Roadmap

From a verified-working "starter pack" (4 dashboards) to a packageable, customer-grade product.
Grounded in a live OSS ClickStack (HyperDX 2.27, OTel demo on minikube).

---

## Prioritization framework

Each item scored **Impact** (customer value) × **Effort** (build cost), 1–5 each.
**Priority = Impact ÷ Effort** (higher = do sooner). "Gate" items block packaging regardless of score.

| Tier | Meaning |
|------|---------|
| 🟥 Gate | Must ship before any customer download is credible |
| 🟧 P1 | Highest value-to-effort; first content release |
| 🟨 P2 | Strong value, moderate effort; second release |
| 🟩 P3 | Differentiators / polish; ongoing |

---

## Master ranking

| # | Item | Type | Impact | Effort | Priority | Tier |
|---|------|------|:------:|:------:|:--------:|:----:|
| 1 | Compatibility pre-flight check script | Hardening | 5 | 2 | 2.5 | 🟥 |
| 2 | Importer upsert + versioning + `--dry-run` | Hardening | 4 | 2 | 2.0 | 🟥 |
| 3 | Dashboard filter variables (namespace/service) | Hardening | 5 | 2 | 2.5 | 🟥 |
| 4 | Support matrix + receiver docs + optional-tile tiering | Hardening | 4 | 2 | 2.0 | 🟥 |
| 5 | OTel Collector / Pipeline Health dashboard | New | 5 | 2 | 2.5 | 🟧 |
| 6 | ClickHouse Query Performance & Errors | New | 5 | 3 | 1.7 | 🟧 |
| 7 | SLO / Error-Budget (burn-rate) | New | 5 | 3 | 1.7 | 🟧 |
| 8 | Enrich existing 4 (units, limits, trace links) | Enrich | 4 | 2 | 2.0 | 🟧 |
| 9 | ClickHouse Storage / MergeTree | New | 4 | 3 | 1.3 | 🟨 |
| 10 | ClickHouse Keeper & Replication | New | 4 | 3 | 1.3 | 🟨 |
| 11 | Executive Overview (single pane) | New | 4 | 2 | 2.0 | 🟨 |
| 12 | Frontend / RUM Sessions | New | 3 | 3 | 1.0 | 🟨 |
| 13 | Service Map / Dependencies | New | 4 | 4 | 1.0 | 🟩 |
| 14 | Cost & Cardinality | New | 4 | 3 | 1.3 | 🟩 |
| 15 | Database (Postgres) & Messaging (Kafka) | New | 3 | 3 | 1.0 | 🟩 |
| 16 | Advanced DS: forecasting, change-correlation | DS | 4 | 4 | 1.0 | 🟩 |
| 17 | Bundled alerts pack (`/api/v2/alerts`) | New | 4 | 3 | 1.3 | 🟩 |

---

## Phase 0 — Harden for packaging (🟥 Gate)  → release **v1.0-rc**  ✅ DONE

The current pack works but isn't safe to hand out. Close these first; they de-risk everything else.

### 1. Compatibility pre-flight check  *(I:5 E:2)*  ✅
- Script queries the customer's ClickHouse (or `/api/v2/charts/series`) for every metric/field each
  dashboard needs; prints a red/green report and a recommended subset to import.
- **Why first:** neutralizes the #1 risk — metric-name drift causing silent empty tiles.
- **Done when:** running it against a fresh cluster correctly flags missing metrics before import.
- **Delivered:** `preflight.ps1` + `preflight.sh`, driven by `requirements.json`; rates each
  dashboard OK/DEGRADED/FAIL and emits a ready-to-run `--only` import command. Verified live.

### 2. Importer upsert + versioning + dry-run  *(I:4 E:2)*  ✅
- Match existing dashboards by a stable `tags` marker (e.g. `clickstack-templates:clickhouse-health@v1`);
  update instead of duplicate. Add `--dry-run` and a `--delete` cleanup.
- **Done when:** re-running import updates in place, no duplicates.
- **Delivered:** `import.ps1` + `import.sh` upsert by `tmpl:<slug>` tag (PUT, with filter-id
  injection), plus `-DryRun`/`-Only`/`-Delete`/`-Duplicate`. Verified idempotent against live.

### 3. Dashboard filter variables  *(I:5 E:2)*  ✅
- Add dashboard-level `filters` (e.g. `k8s.namespace.name`, `ServiceName`) so one dashboard serves
  a busy multi-tenant cluster.
- **Done when:** selecting a namespace re-scopes all tiles.
- **Delivered:** all four dashboards ship a `filters` array (namespace/service/severity scopes).

### 4. Support matrix + optional-tile tiering  *(I:4 E:2)*  ✅
- Document required receivers (`kubeletstats`, `k8s_cluster`, ClickHouse Prometheus scrape) and min
  HyperDX version. Split optional tiles (e.g. PVC/volume) so missing data degrades gracefully.
- **Done when:** README states exactly what each dashboard requires.
- **Delivered:** README "Support matrix" section + machine-readable `requirements.json`
  (required vs optional checks per dashboard; baseline = HyperDX ≥ 2.27 + standard OTel schema).

---

## Phase 1 — First content release (🟧 P1)  → release **v1.1**  ✅ DONE

### 5. OTel Collector / Pipeline Health  *(I:5 E:2)*  ✅
- Tiles: `otelcol_receiver_accepted_spans` vs `_refused`, `otelcol_exporter_queue_size` /
  `_queue_capacity`, `otelcol_exporter_send_failed_*`, `otelcol_processor_dropped_*`, collector
  CPU/mem.
- **Rationale:** customers must trust the pipeline before trusting any other dashboard.
- **Delivered:** `collector-health.json` (12 tiles). Note: this collector emits no `send_failed`/
  `processor_dropped` metrics — drops are shown via `incoming` vs `outgoing` items and refused/failed
  span counters instead. Verified live.

### 6. ClickHouse Query Performance & Errors  *(I:5 E:3)*  ✅
- Builder tiles from gauge/sum metrics + **Raw SQL** on `system.query_log`:
  queries by `query_kind`, p95 query duration, memory per query, top `ClickHouseErrorMetric_*`,
  slowest queries table (link-out).
- **Delivered:** `clickhouse-queryperf.json` (9 tiles). Raw SQL reads `system.query_log` (HyperDX
  user `app` confirmed to have access) + an error-code table from `<metrics_db>.otel_metrics_sum`
  via the new `{{METRICS_SCHEMA}}` token. All queries verified against live ClickHouse.

### 7. SLO / Error-Budget  *(I:5 E:3)*  ✅
- Per-service availability SLO, **multi-window burn-rate** (1h/6h), error-budget remaining number
  tile with `colorRules`. Depends on Phase 0 #3 (service filter).
- **Delivered:** `slo-errorbudget.json` (8 tiles). SLI via single-select `avg(if(StatusCode=...))`
  number tiles (builder number is 1-select, so ratios are computed in `valueExpression` to keep
  `colorRules`); multi-window burn-rate + trend via Raw SQL on traces. Verified live.

### 8. Enrich the existing four  *(I:4 E:2)*  ✅
- Units: cores/bytes/ms formatting; ClickHouse: inserted **bytes**, parts count, cache hit ratio;
  K8s: CPU/mem **vs limits** (`k8s.pod.cpu_limit_utilization`, `memory_limit_utilization`),
  pending pods, `k8s.node.condition_ready`; Services: latency **heatmap** (otel_metrics_histogram),
  in-flight requests, `onClick` → trace drill-down.
- **Delivered:** ClickHouse +cache-vs-source read bytes & async insert bytes; K8s +pod CPU/mem vs
  limit % & nodes-ready; Services +trace-based latency **heatmap** (HyperDX heatmaps are trace-only,
  bucketing `Duration` on a log scale). `requirements.json` updated with the new optional checks.

### 6. ClickHouse Query Performance & Errors  *(I:5 E:3)*
- Builder tiles from gauge/sum metrics + **Raw SQL** on `system.query_log`:
  queries by `query_kind`, p95 query duration, memory per query, top `ClickHouseErrorMetric_*`,
  slowest queries table (link-out).

### 7. SLO / Error-Budget  *(I:5 E:3)*
- Per-service availability SLO, **multi-window burn-rate** (1h/6h), error-budget remaining number
  tile with `colorRules`. Depends on Phase 0 #3 (service filter).

### 8. Enrich the existing four  *(I:4 E:2)*
- Units: cores/bytes/ms formatting; ClickHouse: inserted **bytes**, parts count, cache hit ratio;
  K8s: CPU/mem **vs limits** (`k8s.pod.cpu_limit_utilization`, `memory_limit_utilization`),
  pending pods, `k8s.node.condition_ready`; Services: latency **heatmap** (otel_metrics_histogram),
  in-flight requests, `onClick` → trace drill-down.

---

## Phase 2 — Depth (✅ DONE)  → release **v1.2**

- **9. ClickHouse Storage / MergeTree** ✅ — parts, disk per table, compression ratio, merge/mutation
  backlog (Raw SQL on `system.parts` / `system.part_log`).
  - **Delivered:** `ch-storage.json` (11 tiles). Raw SQL only: KPI numbers (disk, compression,
    active parts, rows), part-event/merge-duration/bytes/rows time series from `system.part_log`,
    and three tables (largest tables, too-many-parts watch, recent merges). All queries verified
    against live ClickHouse as the HyperDX `app` user. No metric receivers required.
- **10. ClickHouse Keeper & Replication** ✅ — Keeper sessions/watches/requests/commits, replication
  queue, readonly replicas, lag.
  - **Delivered:** `ch-keeper.json` (13 tiles). Builder gauges/sum metrics for live Keeper telemetry
    (`ClickHouseMetrics_ZooKeeper*`/`Keeper*`, `ClickHouseProfileEvents_Keeper*`) + a markdown
    section header and Raw SQL `system.replicas` / `system.replication_queue` tables that **degrade
    gracefully** (empty on single-node, populate on replicated/clustered installs). Keeper metrics
    verified live; replication SQL verified to execute.
- **11. Executive Overview** ✅ — one landing page: KPI number tiles per domain + drill-down tables.
  - **Delivered:** `exec-overview.json` (12 tiles). 8 cross-domain KPI number tiles (span error %,
    volume, p95, log error %, CH failed/running queries, nodes ready, collector drops) with
    `colorRules`; two **`onClick` drill-down tables** ("services by error rate" → Traces, "services by
    log errors" → Logs) using `whereTemplate: "ServiceName = '{{ServiceName}}'"`; ingest + request/error
    trend lines. Builder patterns verified live. **onClick is table-only** (builder or Raw SQL).
- **12. Frontend / RUM Sessions** ⏸️ **DEFERRED** — `hyperdx_sessions` exists but has **0 rows** in the
  reference environment (no browser RUM SDK configured), so tiles cannot be authored or validated
  against real data. Re-open once a customer/demo emits browser session data via the HyperDX SDK.

**Phase 2 also hardened the toolkit:** fixed two `preflight.ps1`/`.sh` false-negatives on metric checks
(`aggFn:"count"` returns no datapoints for metric series → use `avg`; coarse `granularity:"1d"` returns
no metric datapoints → use `1h`; detect *presence of datapoints*, not `sum>0`, since gauges can read 0),
and fixed `import.ps1` flagging intentional `{{ServiceName}}` onClick row-variables as "unresolved
tokens" (PowerShell `-match` is case-insensitive → switched to case-sensitive `-cmatch`).

---

## Phase 3 — Differentiators (🟩 P3)  → ongoing

- **13. Service Map / Dependencies** — latency & error rate per downstream call from spans.
- **14. Cost & Cardinality** — rows/bytes per table, top high-cardinality attributes, retention/disk
  forecast (resonates with ClickHouse buyers).
- **15. Database (Postgres) & Messaging (Kafka)** — `db.*` and messaging spans; query latency,
  consumer lag.
- **16. Advanced data science** — disk-full forecasting, request-growth projection, deploy/change
  correlation overlays, seasonality-aware anomaly.
- **17. Bundled alerts pack** ✅ **SHIPPED** — importable `/api/v2/alerts` definitions alongside the
  dashboards (`alerts/` + `import-alerts.ps1`/`.sh`): services error rate, SLO fast burn, collector
  drops, ClickHouse too-many-parts, replication lag. Bound to dashboard tiles, idempotent upsert,
  Teams (`generic` webhook) default channel. Verified live (HyperDX 2.27.0). See `alerts/README.md`.

---

## Cross-cutting workstreams (apply to every dashboard)

| Workstream | What | When | Status (audit 2026-06-23) |
|-----------|------|------|---------------------------|
| Filters/variables | namespace / service / cluster selectors | Phase 0, then standard | ✅ **10/10** — every dashboard has a `filters[]` (exec-overview backfilled with Service + Namespace). |
| Drill-downs | `onClick` → traces / filtered search | Phase 1 onward | ✅ **All applicable tables** — every builder table over a Logs/Traces source has an `onClick` (exec ×2, services-red, slo, logs). Raw-SQL tables over ClickHouse `system.*` (ch-storage, ch-keeper, clickhouse-queryperf) have no HyperDX source to drill into → N/A by design. |
| Units & formatting | bytes_iec / percent / ms / duration | Phase 1 | ✅ bytes/percent/duration applied; services-red latency now `output:"duration"` (auto-scales via traces source `durationPrecision:9`). |
| Alerts | paired alert per critical tile | Phase 3 | ✅ **Alerts pack shipped** (#17) — 5 high-level alerts bound to tiles (`alerts/`), idempotent import, Teams-default channel. |
| Naming/tagging | versioned tags for upsert | Phase 0 | ✅ **10/10** — every dashboard carries `clickstack-templates` + a stable `tmpl:<slug>` tag; importer upserts idempotently. |

> Verified live (HyperDX 2.27.0, minikube): all 10 dashboards PASS `preflight` with 0 missing
> required/optional checks, and upsert-import round-trips (filters resolve to real source ids with
> PUT-safe `id`s; onClick targets + whereTemplates persist). One drill-down to UI-confirm:
> services-red "Slowest routes" uses the `{{SpanAttributes['http.route']}}` row variable (others use
> proven plain-column vars `{{ServiceName}}` / `{{Body}}`).

---

## Suggested milestones

| Release | Contents | Theme |
|---------|----------|-------|
| **v1.0-rc** | Phase 0 (#1–4) on the existing 4 dashboards | "Safe to download" |
| **v1.1** | + Collector Health, Query Perf, SLO, enriched core (#5–8) | "Credible product" |
| **v1.2** | + Storage, Keeper, Exec Overview, RUM (#9–12) | "Depth" |
| **v2.0** | + Service Map, Cost, DB/Kafka, DS, Alerts (#13–17) | "Differentiated" |

---

## Top risks

1. **Metric-name drift across customers** → mitigated by Phase 0 #1 (pre-flight).
2. **Receiver assumptions** (k8s volume metrics, ClickHouse scrape) → Phase 0 #4 (support matrix + tiering).
3. **Scope creep on Service Map/DS** (#13, #16 are E:4) → keep in Phase 3, timebox.
4. **HyperDX API churn** → pin to v2, note tested version (2.27).

---

## Immediate next 3 actions

1. Build the **compatibility pre-flight script** (#1) — unblocks safe distribution.
2. Add **upsert + versioned tags** to the importer (#2).
3. Spec the **OTel Collector Health** dashboard (#5) against live collector self-metrics.
