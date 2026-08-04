# ClickStack - Observability Platform Health

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/advanced/observability-platform-health.json` · tag `tmpl:observability-platform`
- **Data required:** OTel Collector internal telemetry scraped into OTel (Prometheus receiver on the collector's :8888 self-metrics); ClickHouse metrics scraped into OTel (Prometheus/clickhouse receiver); ClickHouse workload, merge, mutation, cache, insert, retention, and query-performance tiles use Raw SQL — the HyperDX ClickHouse connection user must be able to SELECT from system.query_log, system.parts, system.merges, and system.mutations, and query_log must be enabled

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Collector | `ResourceAttributes['service.instance.id']` | Metrics (`default.otel_metrics_{gauge|sum|histogram}`) |

## Observability Platform Health
Health of the telemetry pipeline itself: OpenTelemetry collector ingestion & queues, and ClickHouse storage / query performance. **Advanced tier** — needs the metrics-scraper add-on (collector self-metrics + ClickHouse metrics). Empty here means that optional scraping is not enabled.

This board also covers the requested ClickHouse workload panels. ClickHouse Keeper operation latency is shown only when Keeper metrics are scraped; the standard appliance telemetry currently does not emit that signal, so the dashboard does not fabricate a latency value.

## Telemetry ingestion
Accepted vs. refused spans, logs, and metric points at the collector. Refusals mean data is being dropped.

### Refused spans (window) — number · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT sum(d) AS "Refused spans" FROM (
  SELECT max(Value) - min(Value) AS d
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'otelcol_receiver_refused_spans_total' AND $__filters
  GROUP BY ResourceAttributes['service.instance.id']
)
```

</details>

### Refused log records (window) — number · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT sum(d) AS "Refused logs" FROM (
  SELECT max(Value) - min(Value) AS d
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'otelcol_receiver_refused_log_records_total' AND $__filters
  GROUP BY ResourceAttributes['service.instance.id']
)
```

</details>

### Refused metric points (window) — number · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT sum(d) AS "Refused metrics" FROM (
  SELECT max(Value) - min(Value) AS d
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'otelcol_receiver_refused_metric_points_total' AND $__filters
  GROUP BY ResourceAttributes['service.instance.id']
)
```

</details>

### Spans: accepted vs refused vs failed (per interval) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, kind, sum(greatest(cum - prev, 0)) AS value FROM (
  SELECT ts, inst, kind, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY kind, inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           multiIf(MetricName = 'otelcol_receiver_accepted_spans_total', 'accepted', MetricName = 'otelcol_receiver_refused_spans_total', 'refused', 'failed') AS kind,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName IN ('otelcol_receiver_accepted_spans_total', 'otelcol_receiver_refused_spans_total', 'otelcol_receiver_failed_spans_total') AND $__filters
    GROUP BY ts, inst, kind
  )
)
GROUP BY ts, kind
ORDER BY ts
```

</details>

### Logs: accepted vs refused vs send-failed (per interval) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, kind, sum(greatest(cum - prev, 0)) AS value FROM (
  SELECT ts, inst, kind, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY kind, inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           multiIf(MetricName = 'otelcol_receiver_accepted_log_records_total', 'accepted', MetricName = 'otelcol_receiver_refused_log_records_total', 'refused', 'send-failed') AS kind,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName IN ('otelcol_receiver_accepted_log_records_total', 'otelcol_receiver_refused_log_records_total', 'otelcol_exporter_send_failed_log_records_total') AND $__filters
    GROUP BY ts, inst, kind
  )
)
GROUP BY ts, kind
ORDER BY ts
```

</details>

### Metric points: accepted vs refused (per interval) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, kind, sum(greatest(cum - prev, 0)) AS value FROM (
  SELECT ts, inst, kind, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY kind, inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           if(MetricName = 'otelcol_receiver_accepted_metric_points_total', 'accepted', 'refused') AS kind,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName IN ('otelcol_receiver_accepted_metric_points_total', 'otelcol_receiver_refused_metric_points_total') AND $__filters
    GROUP BY ts, inst, kind
  )
)
GROUP BY ts, kind
ORDER BY ts
```

</details>

## Pipeline health
Exporter queue utilization, throughput, and collector CPU/memory. A full queue signals backpressure.

### Exporter queue utilization % — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT max(util) AS "Queue utilization" FROM (
  SELECT ResourceAttributes['service.instance.id'] AS inst,
         argMaxIf(Value, TimeUnix, MetricName = 'otelcol_exporter_queue_size') /
         nullIf(argMaxIf(Value, TimeUnix, MetricName = 'otelcol_exporter_queue_capacity'), 0) AS util
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName IN ('otelcol_exporter_queue_size', 'otelcol_exporter_queue_capacity') AND $__filters
  GROUP BY inst
)
```

</details>

### Exporter queue size vs capacity — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `otelcol_exporter_queue_size`, `otelcol_exporter_queue_capacity`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `queue size`; max(`Value`) as `capacity`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Exporter sent spans (per interval) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, sum(greatest(cum - prev, 0)) AS "sent spans" FROM (
  SELECT ts, inst, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName = 'otelcol_exporter_sent_spans_total' AND $__filters
    GROUP BY ts, inst
  )
)
GROUP BY ts
ORDER BY ts
```

</details>

### Collector CPU (cores) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, sum(greatest(cum - prev, 0)) / {intervalSeconds:Int64} AS "cores" FROM (
  SELECT ts, inst, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName = 'otelcol_process_cpu_seconds_total' AND $__filters
    GROUP BY ts, inst
  )
)
GROUP BY ts
ORDER BY ts
```

</details>

### Collector memory (RSS / heap) — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `otelcol_process_memory_rss_bytes`, `otelcol_process_runtime_heap_alloc_bytes`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `rss`; max(`Value`) as `heap alloc`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

## ClickHouse storage & availability
Backend database health: running/failed queries, free disk, memory, and retention.

### Running queries — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT sum(v) AS "Running queries" FROM (
  SELECT argMax(Value, TimeUnix) AS v
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'ClickHouseMetrics_Query'
  GROUP BY ResourceAttributes['service.instance.id']
)
```

</details>

### Failed queries (window) — number · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT sum(d) AS "Failed queries" FROM (
  SELECT max(Value) - min(Value) AS d
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'ClickHouseProfileEvents_FailedQuery'
  GROUP BY ResourceAttributes['service.instance.id']
)
```

</details>

### Disk free % — number · Raw SQL

- **Tables:** `system.disks`

<details><summary>SQL query</summary>

```sql
SELECT min(free_space / total_space) AS "Disk free" FROM system.disks WHERE total_space > 0
```

</details>

### Current tracked memory — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT sum(v) AS "Memory tracked" FROM (
  SELECT argMax(Value, TimeUnix) AS v
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'ClickHouseMetrics_MemoryTracking'
  GROUP BY ResourceAttributes['service.instance.id']
)
```

</details>

### Queries (per interval) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, sum(greatest(cum - prev, 0)) AS "queries" FROM (
  SELECT ts, inst, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName = 'ClickHouseProfileEvents_Query'
    GROUP BY ts, inst
  )
)
GROUP BY ts
ORDER BY ts
```

</details>

### Data retention & size by table (system.parts) — table · Raw SQL

- **Tables:** `system.parts`

<details><summary>SQL query</summary>

```sql
SELECT table AS "Table",
       formatReadableSize(sum(bytes_on_disk)) AS "Disk",
       sum(rows) AS "Rows",
       toString(min(min_time)) AS "Oldest data",
       toString(max(max_time)) AS "Newest data",
       dateDiff('day', min(min_time), max(max_time)) AS "Retention span (days)"
FROM system.parts
WHERE active AND database = 'default' AND table LIKE 'otel_%'
GROUP BY table
ORDER BY sum(bytes_on_disk) DESC
```

</details>

## Dashboard query performance
How fast dashboard queries run: p95/p99 duration, failures, and top errors from the query log.

### Query duration - p95 / p99 — line · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL {intervalSeconds:Int64} SECOND) AS t,
       quantile(0.95)(query_duration_ms) / 1000 AS p95,
       quantile(0.99)(query_duration_ms) / 1000 AS p99
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
  AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
GROUP BY t
ORDER BY t
```

</details>

### Failed queries (selected window) — number · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT sum(d) AS "Failed queries" FROM (
  SELECT greatest(max(Value) - min(Value), 0) AS d
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'ClickHouseProfileEvents_FailedQuery'
  GROUP BY ResourceAttributes['service.instance.id']
)
```

</details>

### Top errors (from query_log) — table · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT exception_code,
       count() AS errors,
       substring(argMax(exception, event_time), 1, 500) AS sample_exception
FROM system.query_log
WHERE type >= 2
  AND event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
  AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
  AND exception_code != 0
GROUP BY exception_code
ORDER BY errors DESC
LIMIT 20
```

</details>

## ClickHouse Workload & Merge Activity
Query mix, inserts, active merges/mutations, page-cache reads, and asynchronous insert activity from ClickHouse system tables. These advanced panels require query_log and system-table access.

### Select vs insert queries (per interval) — table · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, countIf(query_kind = 'Select') AS Selects, countIf(query_kind = 'Insert') AS Inserts FROM system.query_log WHERE event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND type = 'QueryFinish' GROUP BY ts ORDER BY ts
```

</details>

### Inserted rows (per interval) — table · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, sum(written_rows) AS "Inserted rows", formatReadableSize(sum(written_bytes)) AS "Inserted bytes" FROM system.query_log WHERE event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND type = 'QueryFinish' AND query_kind = 'Insert' GROUP BY ts ORDER BY ts
```

</details>

### Active merges — number · Raw SQL

- **Tables:** `system.merges`

<details><summary>SQL query</summary>

```sql
SELECT count() AS "Active merges" FROM system.merges
```

</details>

### Pending mutations — number · Raw SQL

- **Tables:** `system.mutations`

<details><summary>SQL query</summary>

```sql
SELECT countIf(NOT is_done) AS "Pending mutations" FROM system.mutations
```

</details>

### Merges in progress (average progress) — number · Raw SQL

- **Tables:** `system.merges`

<details><summary>SQL query</summary>

```sql
SELECT if(count() = 0, 0, avg(progress)) AS "Merge progress" FROM system.merges
```

</details>

### Merges in progress (detail) — table · Raw SQL

- **Tables:** `system.merges`

<details><summary>SQL query</summary>

```sql
SELECT database AS Database, table AS Table, round(progress * 100, 1) AS "Progress %", formatReadableSize(total_size_bytes_compressed) AS Size, elapsed AS "Elapsed seconds", num_parts AS Parts FROM system.merges ORDER BY elapsed DESC
```

</details>

### Page-cache read bytes: cache vs source (per interval) — table · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, formatReadableSize(sum(ProfileEvents['PageCacheReadBytes'])) AS "From cache", formatReadableSize(sum(greatest(read_bytes - ProfileEvents['PageCacheReadBytes'], 0))) AS "From source" FROM system.query_log WHERE event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND type = 'QueryFinish' GROUP BY ts ORDER BY ts
```

</details>

### Async insert bytes (per interval) — table · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, formatReadableSize(sum(ProfileEvents['AsyncInsertBytes'])) AS "Async insert bytes" FROM system.query_log WHERE event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND type = 'QueryFinish' GROUP BY ts ORDER BY ts
```

</details>
