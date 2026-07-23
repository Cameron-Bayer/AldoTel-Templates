# ClickStack · OTel Collector — Pipeline Health

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/advanced/collector-health.json` · tag `tmpl:collector-health`
- **Data required:** OTel Collector internal telemetry scraped into OTel (Prometheus receiver on the collector's :8888 self-metrics)

## Preview

![ClickStack · OTel Collector — Pipeline Health](images/collector-health.png)

_Live capture from a ClickStack install with the OpenTelemetry demo flowing._

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Collector | `ResourceAttributes['service.instance.id']` | Metrics (`default.otel_metrics_{gauge|sum|histogram}`) |

## Pipeline — at a glance
Counters below are shown as **deltas over the selected time range** (not raw cumulative totals). Refused / failed / send-failed should stay at **0**.

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

## Traces pipeline

### Spans: accepted vs refused vs failed (per-window rate) — line · Raw SQL

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

### Exporter sent spans (per-window rate) — line · Raw SQL

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

### Exporter queue size vs capacity — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `otelcol_exporter_queue_size`, `otelcol_exporter_queue_capacity`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `queue size`; max(`Value`) as `capacity`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Exporter queue utilization % (size / capacity) — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT ts, max(util) AS "queue utilization" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
         ResourceAttributes['service.instance.id'] AS inst,
         maxIf(Value, MetricName = 'otelcol_exporter_queue_size') /
         nullIf(maxIf(Value, MetricName = 'otelcol_exporter_queue_capacity'), 0) AS util
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName IN ('otelcol_exporter_queue_size', 'otelcol_exporter_queue_capacity') AND $__filters
  GROUP BY ts, inst
)
GROUP BY ts
ORDER BY ts
```

</details>

## Logs & metrics pipeline

### Logs: accepted vs refused vs send-failed (per-window rate) — line · Raw SQL

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

### Metric points: accepted vs refused (per-window rate) — line · Raw SQL

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

### Scraper: scraped vs errored metric points (per-window rate) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, kind, sum(greatest(cum - prev, 0)) AS value FROM (
  SELECT ts, inst, kind, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY kind, inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           if(MetricName = 'otelcol_scraper_scraped_metric_points', 'scraped', 'errored') AS kind,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName IN ('otelcol_scraper_scraped_metric_points', 'otelcol_scraper_errored_metric_points') AND $__filters
    GROUP BY ts, inst, kind
  )
)
GROUP BY ts, kind
ORDER BY ts
```

</details>

### Exporter in-flight requests — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `otelcol_exporter_in_flight_requests`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `in-flight`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

## Collector resources

### Collector memory (RSS / heap) — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `otelcol_process_memory_rss_bytes`, `otelcol_process_runtime_heap_alloc_bytes`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `rss`; max(`Value`) as `heap alloc`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Collector CPU (cores, per-window rate) — line · Raw SQL

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
