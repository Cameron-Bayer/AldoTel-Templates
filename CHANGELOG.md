# Changelog

All notable changes to the ClickStack dashboard templates are documented here.
Tested against **HyperDX 2.27.0** (OSS ClickStack) on minikube.

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

### Tooling
- `preflight.ps1` / `preflight.sh` — compatibility check driven by `requirements.json`.
- `import.ps1` / `import.sh` — upsert importer with `-DryRun` / `-Only` / `-Delete` / `-Duplicate`.

### Known / to confirm before GA (`1.0.0`)
- UI click-through of the `services-red` "Slowest routes" drill-down
  (`{{SpanAttributes['http.route']}}` row variable).
- Visual render of `ch-storage` "Merge duration (ms)" Raw-SQL `output:"duration"` formatting.
- RUM / Frontend Sessions dashboard deferred — `hyperdx_sessions` has no data without a browser SDK.
