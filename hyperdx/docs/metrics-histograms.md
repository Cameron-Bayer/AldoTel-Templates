# ClickStack · Latency Histograms

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/advanced/metrics-histograms.json` · tag `tmpl:metrics-histograms`
- **Data required:** Application OTLP explicit-bucket histogram metrics (http.*.duration / rpc.*.duration); ClickHouse Keeper histogram metrics (ClickHouseHistogramMetrics_keeper_*) for the Keeper latency tile

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Service | `ServiceName` | Metrics (`default.otel_metrics_{gauge|sum|histogram}`) |

## Request latency percentiles (OTLP histograms)
Percentiles are interpolated from explicit-bucket histogram metrics (`otel_metrics_histogram`) over the selected window: per-series bucket deltas are summed, then linearly interpolated. Values are in **milliseconds** (`http.*.duration` / `rpc.*.duration` semconv). Avg = Σ / count.

### HTTP server latency by service — table · Raw SQL

- **Tables:** `default.otel_metrics_histogram`

<details><summary>SQL query</summary>

```sql
WITH per_series AS (
  SELECT ServiceName AS svc,
    arrayMap((a, b) -> greatest(a - b, 0), argMax(BucketCounts, TimeUnix), argMin(BucketCounts, TimeUnix)) AS d_bc,
    greatest(argMax(Sum, TimeUnix) - argMin(Sum, TimeUnix), 0) AS d_sum,
    any(ExplicitBounds) AS eb
  FROM default.otel_metrics_histogram
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'http.server.duration' AND $__filters
  GROUP BY svc, ResourceAttributes['service.instance.id'], Attributes
),
agg AS (SELECT svc, sumForEach(d_bc) AS bc, any(eb) AS eb, sum(d_sum) AS sm FROM per_series GROUP BY svc),
c AS (SELECT svc, bc, eb, sm, arraySum(bc) AS total, arrayCumSum(bc) AS cum, length(eb) AS le FROM agg),
p AS (SELECT svc, sm, bc, eb, total, cum, le, arrayMap(Q -> arrayFirstIndex(x -> x >= Q * total, cum), [0.5, 0.95, 0.99]) AS idxs FROM c)
SELECT svc AS Service, toUInt64(total) AS Samples, round(sm / nullIf(total, 0), 1) AS "Avg (ms)",
  round(pv[1], 1) AS "p50 (ms)", round(pv[2], 1) AS "p95 (ms)", round(pv[3], 1) AS "p99 (ms)"
FROM (
  SELECT svc, total, sm,
    arrayMap((Q, idx) -> if(total = 0 OR idx = 0, 0,
      if(idx = 1, Q * total / bc[1] * eb[1],
        (if(idx > le, eb[le], eb[idx]) - eb[idx-1]) * (Q * total - cum[idx-1]) / bc[idx] + eb[idx-1])),
      [0.5, 0.95, 0.99], idxs) AS pv
  FROM p
)
WHERE total > 0
ORDER BY total DESC
LIMIT 50
```

</details>

### HTTP client latency by service — table · Raw SQL

- **Tables:** `default.otel_metrics_histogram`

<details><summary>SQL query</summary>

```sql
WITH per_series AS (
  SELECT ServiceName AS svc,
    arrayMap((a, b) -> greatest(a - b, 0), argMax(BucketCounts, TimeUnix), argMin(BucketCounts, TimeUnix)) AS d_bc,
    greatest(argMax(Sum, TimeUnix) - argMin(Sum, TimeUnix), 0) AS d_sum,
    any(ExplicitBounds) AS eb
  FROM default.otel_metrics_histogram
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'http.client.duration' AND $__filters
  GROUP BY svc, ResourceAttributes['service.instance.id'], Attributes
),
agg AS (SELECT svc, sumForEach(d_bc) AS bc, any(eb) AS eb, sum(d_sum) AS sm FROM per_series GROUP BY svc),
c AS (SELECT svc, bc, eb, sm, arraySum(bc) AS total, arrayCumSum(bc) AS cum, length(eb) AS le FROM agg),
p AS (SELECT svc, sm, bc, eb, total, cum, le, arrayMap(Q -> arrayFirstIndex(x -> x >= Q * total, cum), [0.5, 0.95, 0.99]) AS idxs FROM c)
SELECT svc AS Service, toUInt64(total) AS Samples, round(sm / nullIf(total, 0), 1) AS "Avg (ms)",
  round(pv[1], 1) AS "p50 (ms)", round(pv[2], 1) AS "p95 (ms)", round(pv[3], 1) AS "p99 (ms)"
FROM (
  SELECT svc, total, sm,
    arrayMap((Q, idx) -> if(total = 0 OR idx = 0, 0,
      if(idx = 1, Q * total / bc[1] * eb[1],
        (if(idx > le, eb[le], eb[idx]) - eb[idx-1]) * (Q * total - cum[idx-1]) / bc[idx] + eb[idx-1])),
      [0.5, 0.95, 0.99], idxs) AS pv
  FROM p
)
WHERE total > 0
ORDER BY total DESC
LIMIT 50
```

</details>

### RPC server latency by service — table · Raw SQL

- **Tables:** `default.otel_metrics_histogram`

<details><summary>SQL query</summary>

```sql
WITH per_series AS (
  SELECT ServiceName AS svc,
    arrayMap((a, b) -> greatest(a - b, 0), argMax(BucketCounts, TimeUnix), argMin(BucketCounts, TimeUnix)) AS d_bc,
    greatest(argMax(Sum, TimeUnix) - argMin(Sum, TimeUnix), 0) AS d_sum,
    any(ExplicitBounds) AS eb
  FROM default.otel_metrics_histogram
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'rpc.server.duration' AND $__filters
  GROUP BY svc, ResourceAttributes['service.instance.id'], Attributes
),
agg AS (SELECT svc, sumForEach(d_bc) AS bc, any(eb) AS eb, sum(d_sum) AS sm FROM per_series GROUP BY svc),
c AS (SELECT svc, bc, eb, sm, arraySum(bc) AS total, arrayCumSum(bc) AS cum, length(eb) AS le FROM agg),
p AS (SELECT svc, sm, bc, eb, total, cum, le, arrayMap(Q -> arrayFirstIndex(x -> x >= Q * total, cum), [0.5, 0.95, 0.99]) AS idxs FROM c)
SELECT svc AS Service, toUInt64(total) AS Samples, round(sm / nullIf(total, 0), 1) AS "Avg (ms)",
  round(pv[1], 1) AS "p50 (ms)", round(pv[2], 1) AS "p95 (ms)", round(pv[3], 1) AS "p99 (ms)"
FROM (
  SELECT svc, total, sm,
    arrayMap((Q, idx) -> if(total = 0 OR idx = 0, 0,
      if(idx = 1, Q * total / bc[1] * eb[1],
        (if(idx > le, eb[le], eb[idx]) - eb[idx-1]) * (Q * total - cum[idx-1]) / bc[idx] + eb[idx-1])),
      [0.5, 0.95, 0.99], idxs) AS pv
  FROM p
)
WHERE total > 0
ORDER BY total DESC
LIMIT 50
```

</details>

## Latency & throughput trend (HTTP server)
Per-interval average latency and request rate, derived from consecutive-scrape deltas of the cumulative `http.server.duration` Sum/Count counters.

### Avg HTTP server latency by service — line · Raw SQL

- **Tables:** `default.otel_metrics_histogram`

<details><summary>SQL query</summary>

```sql
SELECT ts, svc, sum(dsum) / nullIf(sum(dcnt), 0) AS "Avg latency (ms)" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, ServiceName AS svc,
    greatest(Sum - lagInFrame(Sum, 1, Sum) OVER w, 0) AS dsum,
    greatest(Count - lagInFrame(Count, 1, Count) OVER w, 0) AS dcnt
  FROM default.otel_metrics_histogram
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'http.server.duration' AND $__filters
  WINDOW w AS (PARTITION BY ServiceName, ResourceAttributes['service.instance.id'], toString(Attributes) ORDER BY TimeUnix)
)
GROUP BY ts, svc
HAVING sum(dcnt) > 0
ORDER BY ts
```

</details>

### HTTP request rate by service — line · Raw SQL

- **Tables:** `default.otel_metrics_histogram`

<details><summary>SQL query</summary>

```sql
SELECT ts, svc, sum(dcnt) / {intervalSeconds:Int64} AS "Requests/sec" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, ServiceName AS svc,
    greatest(Count - lagInFrame(Count, 1, Count) OVER w, 0) AS dcnt
  FROM default.otel_metrics_histogram
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'http.server.duration' AND $__filters
  WINDOW w AS (PARTITION BY ServiceName, ResourceAttributes['service.instance.id'], toString(Attributes) ORDER BY TimeUnix)
)
GROUP BY ts, svc
HAVING sum(dcnt) > 0
ORDER BY ts
```

</details>

## ClickHouse Keeper latency (histograms)
Keeper operation latency distributions from ClickHouse's own histogram metrics (`ClickHouseHistogramMetrics_keeper_*`). Values are in **milliseconds**. Cluster-wide (not affected by the Service filter).

### Keeper operation latency percentiles — table · Raw SQL

- **Tables:** `default.otel_metrics_histogram`

<details><summary>SQL query</summary>

```sql
WITH per_series AS (
  SELECT MetricName AS m,
    arrayMap((a, b) -> greatest(a - b, 0), argMax(BucketCounts, TimeUnix), argMin(BucketCounts, TimeUnix)) AS d_bc,
    any(ExplicitBounds) AS eb
  FROM default.otel_metrics_histogram
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName LIKE 'ClickHouseHistogramMetrics_keeper%'
  GROUP BY m, ResourceAttributes['service.instance.id'], Attributes
),
agg AS (SELECT m, sumForEach(d_bc) AS bc, any(eb) AS eb FROM per_series GROUP BY m),
c AS (SELECT m, bc, eb, arraySum(bc) AS total, arrayCumSum(bc) AS cum, length(eb) AS le FROM agg),
p AS (SELECT m, bc, eb, total, cum, le, arrayMap(Q -> arrayFirstIndex(x -> x >= Q * total, cum), [0.5, 0.95, 0.99]) AS idxs FROM c)
SELECT replaceOne(m, 'ClickHouseHistogramMetrics_', '') AS Operation, toUInt64(total) AS Samples,
  round(pv[1], 2) AS "p50 (ms)", round(pv[2], 2) AS "p95 (ms)", round(pv[3], 2) AS "p99 (ms)"
FROM (
  SELECT m, total,
    arrayMap((Q, idx) -> if(total = 0 OR idx = 0, 0,
      if(idx = 1, Q * total / bc[1] * eb[1],
        (if(idx > le, eb[le], eb[idx]) - eb[idx-1]) * (Q * total - cum[idx-1]) / bc[idx] + eb[idx-1])),
      [0.5, 0.95, 0.99], idxs) AS pv
  FROM p
)
WHERE total > 0
ORDER BY total DESC
LIMIT 50
```

</details>
