# ClickStack · ClickHouse — Operations

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/advanced/clickhouse-health.json` · tag `tmpl:clickhouse-health`
- **Data required:** ClickHouse metrics scraped into OTel (Prometheus/clickhouse receiver)

## Preview

![ClickStack · ClickHouse — Operations](images/clickhouse-health.png)

_Live capture from a ClickStack install with the OpenTelemetry demo flowing._

## Operations — at a glance
Query/insert/cache counters are shown as **deltas over the selected time range**. Replication & Keeper detail lives in the **ClickHouse — Keeper & Replication** (advanced) dashboard.

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

### Memory tracking — number · Raw SQL

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

## Query activity

### Query rate (per-window) — line · Raw SQL

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

### Failed queries (per-window) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, sum(greatest(cum - prev, 0)) AS "failed" FROM (
  SELECT ts, inst, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName = 'ClickHouseProfileEvents_FailedQuery'
    GROUP BY ts, inst
  )
)
GROUP BY ts
ORDER BY ts
```

</details>

### Inserted rows (per-window) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, sum(greatest(cum - prev, 0)) AS "rows" FROM (
  SELECT ts, inst, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName = 'ClickHouseProfileEvents_InsertedRows'
    GROUP BY ts, inst
  )
)
GROUP BY ts
ORDER BY ts
```

</details>

### SELECT vs INSERT queries (per-window) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, kind, sum(greatest(cum - prev, 0)) AS value FROM (
  SELECT ts, inst, kind, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY kind, inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           if(MetricName = 'ClickHouseProfileEvents_SelectQuery', 'select', 'insert') AS kind,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName IN ('ClickHouseProfileEvents_SelectQuery', 'ClickHouseProfileEvents_InsertQuery')
    GROUP BY ts, inst, kind
  )
)
GROUP BY ts, kind
ORDER BY ts
```

</details>

## Merges & mutations

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
SELECT count() AS "Pending mutations" FROM system.mutations WHERE is_done = 0
```

</details>

### Merges in progress (gauge) — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_Merge`, `ClickHouseMetrics_PartMutation`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `merges`; max(`Value`) as `mutations`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

## I/O & cache

### Page-cache read bytes: cache vs source (per-window) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, kind, sum(greatest(cum - prev, 0)) AS value FROM (
  SELECT ts, inst, kind, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY kind, inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           if(MetricName = 'ClickHouseProfileEvents_CachedReadBufferReadFromCacheBytes', 'from cache', 'from source') AS kind,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName IN ('ClickHouseProfileEvents_CachedReadBufferReadFromCacheBytes', 'ClickHouseProfileEvents_CachedReadBufferReadFromSourceBytes')
    GROUP BY ts, inst, kind
  )
)
GROUP BY ts, kind
ORDER BY ts
```

</details>

### Async insert bytes (per-window) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, sum(greatest(cum - prev, 0)) AS "bytes" FROM (
  SELECT ts, inst, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName = 'ClickHouseProfileEvents_AsyncInsertBytes'
    GROUP BY ts, inst
  )
)
GROUP BY ts
ORDER BY ts
```

</details>
