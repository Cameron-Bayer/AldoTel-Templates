# Changelog

All notable changes to the ClickStack dashboard templates are documented here.
Tested against **HyperDX 2.27.0** (OSS ClickStack) on minikube.

## [Unreleased]

### Fixed
- **Dashboards could not be saved from the HyperDX UI** after importing the section headers.
  Markdown tiles were authored as `config:{displayType:'markdown', markdown}`, which imports and
  renders but stores an incomplete internal config (missing `source`/`select`/`where`) that the UI's
  tile validation rejects on save. Re-authored all markdown header tiles as `series` tiles
  (`series:[{type:'markdown', content}]`) so the API stores a complete, UI-savable config.

### Added
- **Section headers across every dashboard** — each dashboard is now broken into labelled
  sections using full-width markdown header tiles (e.g. *At a glance*, *Throughput & latency*,
  *Nodes / Pods / Namespaces*). Tiles were regrouped and reflowed under their section so related
  charts sit together and the boards read top-to-bottom instead of as one dense grid. KPI
  "at a glance" number rows are pulled to the top of each board where they weren't already.
  Header tiles use an `h3` heading, a cleared tile title (no redundant corner label), and are
  3 rows tall so the section text isn't clipped. (Note: HyperDX renders markdown tiles with a
  plain react-markdown — no raw HTML/CSS — so headers stay left-aligned; centering isn't supported.)
- **Kubernetes dashboard — namespace views & richer tables** (parity pass vs HyperDX's built-in
  `/kubernetes` page, using only metrics present in a standard kubeletstats + k8s_cluster setup):
  - **Namespace CPU (cores)** and **Namespace memory** time charts (sum of pod metrics per namespace).
  - **Namespaces table** — phase / CPU / memory per namespace.
  - **Nodes table** — ready / CPU / memory / uptime per node (complements the existing node charts).
  - **Pods — status & resources** table consolidates the old restarts + pod-memory tables and adds
    status (`k8s.pod.phase`), CPU-vs-limit %, memory-vs-limit %, and age (`k8s.pod.uptime`).
  - **Nodes / Pods / Namespaces tables** are authored as **Raw SQL** so values are human-readable:
    status text (`Running`/`Ready`/`Active` instead of enum codes `2`/`1`), memory via
    `formatReadableSize` (`3.11 GiB`), uptime/age via `formatReadableTimeDelta` (`23 hours…`),
    limits as `15.5%`, and proper column headers. Sorted server-side (ORDER BY works in raw SQL).
  - Note: Raw SQL tables use a fixed 1-hour latest-value window and are not affected by the
    dashboard Namespace/Node filter variables.

### Changed
- **Roomier graphs** — chart tiles (`line`, `stacked_bar`, `heatmap`, `pie`) get an extra
  grid row of height for better readability; number/table/markdown tiles unchanged, `y` reflowed.
- **Taller tiles** — every tile's height increased by 1 grid row across all 10 dashboards,
  with `y` positions reflowed so nothing overlaps (KPIs 3→4, charts 4→5, tables 5→6).
- **Number formatting consistency** — ratio "rates" now render as true percentages and all
  percentage stats show **3 decimal places** (`mantissa: 3`):
  - `exec-overview` Span/Log error-rate KPIs converted from `if(…,100,0)` to a `0–1` fraction
    with `numberFormat: {output: percent, mantissa: 3}`; `colorRules` thresholds rescaled
    (`1 → 0.01`, `5 → 0.05`) to match the raw fraction.
  - `mantissa: 3` applied to existing percent tiles in `k8s-infrastructure` (×4),
    `services-red` (error rate), and `slo-errorbudget` (availability).
  - Throughput rates (req/s, query/s, packet/s, rows/s) left as counts — they are not percentages.

### Known
- The HyperDX v2 dashboards API **strips `colorRules`** from number tiles on import
  (confirmed across all number tiles, including untouched ones). Color thresholds are kept in
  the template JSON for UI use / future API support but do not currently persist via import.

## [1.0.0-rc1] — 2026-06-23

Release candidate for the first customer-downloadable pack. 10 dashboards, verified live
(all PASS `preflight` with 0 missing checks; importer upserts round-trip).

### Dashboards
- ClickHouse — Cluster Health (`clickhouse-health`)
- ClickHouse — Query Performance & Errors (`clickhouse-queryperf`)
- ClickHouse — Storage & MergeTree (`ch-storage`)
- ClickHouse — Keeper & Replication (`ch-keeper`)
- Kubernetes — Infrastructure (`k8s-infrastructure`)
- Services — RED (`services-red`)
- Services — SLO / Error Budget (`slo-errorbudget`)
- Logs — Overview (`logs-overview`)
- OTel Collector — Pipeline Health (`collector-health`)
- Executive Overview (`exec-overview`)

### Cross-cutting (applied to every dashboard)
- **Filters/variables** on all 10 dashboards (service / namespace / node / instance / severity).
- **Drill-downs** (`onClick`) on every builder table over a Logs/Traces source
  (exec-overview ×2, services-red, slo-errorbudget, logs-overview).
- **Units & formatting** — bytes (`bytes_iec`), percent, and duration; `services-red` latency now
  formats as `duration` (auto-scales via the traces source `durationPrecision`).
- **Naming/tagging** — stable `tmpl:<slug>` tag on every dashboard for idempotent upserts.
- **Branding** — every dashboard name is prefixed `AldoTel · …` (shows in the HyperDX title bar/tab; no grid space used).

### Tooling
- `preflight.ps1` / `preflight.sh` — compatibility check driven by `requirements.json`.
- `import.ps1` / `import.sh` — upsert importer with `-DryRun` / `-Only` / `-Delete` / `-Duplicate`.

### Known / to confirm before GA (`1.0.0`)
- UI click-through of the `services-red` "Slowest routes" drill-down
  (`{{SpanAttributes['http.route']}}` row variable).
- Visual render of `ch-storage` "Merge duration (ms)" Raw-SQL `output:"duration"` formatting.
- RUM / Frontend Sessions dashboard deferred — `hyperdx_sessions` has no data without a browser SDK.
