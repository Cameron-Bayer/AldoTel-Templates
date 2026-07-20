# AldoTel · ClickHouse — Query Performance & Errors

> Auto-generated reference (do not edit by hand — run `node gen-docs.js`).

This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/clickhouse-queryperf.json` · tag `tmpl:clickhouse-queryperf`
- **Data required:** ClickHouse metrics scraped into OTel (for the summary number tiles); Most tiles read system.query_log via Raw SQL — the HyperDX ClickHouse connection user must be able to SELECT from system.query_log, and query_log must be enabled

## Preview

![AldoTel · ClickHouse — Query Performance & Errors](images/clickhouse-queryperf.png)

_Live capture from a ClickStack install with the OpenTelemetry demo flowing._

## Query performance — at a glance

### Failed queries — number

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `ClickHouseProfileEvents_FailedQuery`  (column `MetricName`)
- **Measure(s):** sum(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Running queries (now) — number

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_Query`  (column `MetricName`)
- **Measure(s):** last_value(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Memory tracking — number

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_MemoryTracking`  (column `MetricName`)
- **Measure(s):** max(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

## Query trends

### Query rate by kind — stacked_bar · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL 1 MINUTE) AS t,
       countIf(query_kind = 'Select') AS selects,
       countIf(query_kind = 'Insert') AS inserts,
       countIf(query_kind NOT IN ('Select','Insert')) AS other
FROM system.query_log
WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 6 HOUR
GROUP BY t
ORDER BY t
```

</details>

### Query duration — p95 / p99 — line · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL 1 MINUTE) AS t,
       quantile(0.95)(query_duration_ms) / 1000 AS p95,
       quantile(0.99)(query_duration_ms) / 1000 AS p99
FROM system.query_log
WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 6 HOUR
GROUP BY t
ORDER BY t
```

</details>

### Peak memory per query — p95 / max — line · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL 1 MINUTE) AS t,
       quantile(0.95)(memory_usage) AS p95,
       max(memory_usage) AS max
FROM system.query_log
WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 6 HOUR
GROUP BY t
ORDER BY t
```

</details>

### Query exceptions — line · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL 1 MINUTE) AS t,
       countIf(exception_code != 0) AS exceptions
FROM system.query_log
WHERE type IN ('QueryFinish','ExceptionWhileProcessing','ExceptionBeforeStart')
  AND event_time > now() - INTERVAL 6 HOUR
GROUP BY t
ORDER BY t
```

</details>

## Slowest queries & errors

### Slowest queries (last 6h) — table · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT event_time,
       user,
       query_kind,
       query_duration_ms,
       formatReadableSize(memory_usage) AS memory,
       read_rows,
       substring(query, 1, 160) AS query
FROM system.query_log
WHERE type = 'QueryFinish' AND event_time > now() - INTERVAL 6 HOUR
ORDER BY query_duration_ms DESC
LIMIT 20
```

</details>

### Top ClickHouse error codes (last 24h) — table · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT replaceOne(MetricName, 'ClickHouseErrorMetric_', '') AS error,
       toUInt64(max(Value) - min(Value)) AS errors_in_window
FROM default.otel_metrics_sum
WHERE MetricName LIKE 'ClickHouseErrorMetric_%' AND TimeUnix > now() - INTERVAL 24 HOUR
GROUP BY error
HAVING errors_in_window > 0
ORDER BY errors_in_window DESC
LIMIT 20
```

</details>
