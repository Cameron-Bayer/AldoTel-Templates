# AldoTel · ClickHouse — Cluster Health

> Auto-generated reference (do not edit by hand — run `node gen-docs.js`).

This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/clickhouse-health.json` · tag `tmpl:clickhouse-health`
- **Data required:** ClickHouse metrics scraped into OTel (Prometheus/clickhouse receiver)

## Preview

![AldoTel · ClickHouse — Cluster Health](images/clickhouse-health.png)

_Live capture from a ClickStack install with the OpenTelemetry demo flowing._

## Cluster health — at a glance

### Running queries — number

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_Query`  (column `MetricName`)
- **Measure(s):** last_value(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Max replication lag (s) — number

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseAsyncMetrics_ReplicasMaxAbsoluteDelay`  (column `MetricName`)
- **Measure(s):** max(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Readonly replicas — number

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_ReadonlyReplica`  (column `MetricName`)
- **Measure(s):** max(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Memory tracking — number

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_MemoryTracking`  (column `MetricName`)
- **Measure(s):** max(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

## Query activity

### Query rate (vs previous week) — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `ClickHouseProfileEvents_Query`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `queries`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Failed queries — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `ClickHouseProfileEvents_FailedQuery`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `failed`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Inserted rows rate — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `ClickHouseProfileEvents_InsertedRows`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `rows`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### SELECT vs INSERT queries — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `ClickHouseProfileEvents_SelectQuery`, `ClickHouseProfileEvents_InsertQuery`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `select`; sum(`Value`) as `insert`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

## Merges & mutations

### Merges in progress — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_Merge`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `merges`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Mutations in progress — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_PartMutation`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `mutations`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

## I/O & cache

### Page-cache read bytes: cache vs source — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `ClickHouseProfileEvents_CachedReadBufferReadFromCacheBytes`, `ClickHouseProfileEvents_CachedReadBufferReadFromSourceBytes`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `from cache`; sum(`Value`) as `from source`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Async insert bytes — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `ClickHouseProfileEvents_AsyncInsertBytes`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `bytes`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`
