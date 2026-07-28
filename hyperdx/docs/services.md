# ClickStack - Services (RED)

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/services.json` · tag `tmpl:services`
- **Data required:** Application traces (OTLP)

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Service | `ServiceName` | Traces (`default.otel_traces`) |

## Service request health (RED)
**RED** summarizes each service's request **R**ate, **E**rror rate, and **D**uration (latency), from OpenTelemetry **server spans**. Filter by **Service** and adjust the time range. Watch for rising error rates, latency above your service target, and an SLO burn rate above 1.

## Rate & errors
Server request throughput and error percentage per service, from OpenTelemetry server spans.

### Server request count over time, by service — line

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `requests`  — where `SpanKind:Server` (lucene)
- **Group by:** `ServiceName`
- **Columns used:** `ServiceName`, `SpanKind`

### Error rate % — line

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `errors`  — where `SpanKind:Server AND StatusCode:Error` (lucene); count(*) as `total`  — where `SpanKind:Server` (lucene)
- **Group by:** `ServiceName`
- **Columns used:** `ServiceName`, `StatusCode`, `SpanKind`

## Latency & error breakdown
**p50 / p95 / p99** are latency percentiles: 50%, 95%, and 99% of requests complete within that time. A widening gap between p50 and p99 indicates worsening tail latency.

### Server latency percentiles (p50 / p95 / p99) — line

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** quantile(`Duration / 1000000000`) as `p50`  — where `SpanKind = 'Server'` (sql); quantile(`Duration / 1000000000`) as `p95`  — where `SpanKind = 'Server'` (sql); quantile(`Duration / 1000000000`) as `p99`  — where `SpanKind = 'Server'` (sql)
- **Columns used:** `Duration`, `SpanKind`

### Errors by status message — pie

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `errors`  — where `SpanKind:Server AND StatusCode:Error` (lucene)
- **Group by:** `StatusMessage`
- **Columns used:** `StatusCode`, `StatusMessage`, `SpanKind`

## Slow routes & distribution
Slowest HTTP routes by p95, plus a latency anomaly detector and a distribution heatmap. The anomaly chart compares recent p95 against a rolling baseline; the shaded ±3σ band is three standard deviations around that baseline, so points above it are unusually slow. That chart uses a fixed last-24h window (against an 8-day baseline) and ignores the time picker.

### Slowest routes (p95) - min 20 requests — table · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS "Service", route AS "Route", round(p95_ms, 1) AS "p95 (ms)", round(p50_ms, 1) AS "p50 (ms)", requests AS "Requests" FROM (
  SELECT ServiceName,
         SpanAttributes['http.route'] AS route,
         quantile(0.95)(Duration) / 1e6 AS p95_ms,
         quantile(0.5)(Duration) / 1e6 AS p50_ms,
         count() AS requests
  FROM default.otel_traces
  WHERE SpanKind = 'Server'
    AND Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND SpanAttributes['http.route'] != ''
    AND $__filters
  GROUP BY ServiceName, route
  HAVING requests >= 20
)
ORDER BY p95_ms DESC
LIMIT 50
```

</details>

### P95 latency anomaly — last 24h vs 8-day baseline (±3σ band) — line · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
WITH points AS (
  SELECT toStartOfInterval(Timestamp, INTERVAL 5 MINUTE) AS t,
         quantile(0.95)(Duration)/1e6 AS p95_ms
  FROM default.otel_traces
  WHERE SpanKind = 'Server' AND Timestamp > now() - INTERVAL 8 DAY AND $__filters
  GROUP BY t
),
scored AS (
  SELECT t, p95_ms,
         avg(p95_ms)       OVER (ORDER BY t ROWS BETWEEN 288 PRECEDING AND 12 PRECEDING) AS base,
         stddevPop(p95_ms) OVER (ORDER BY t ROWS BETWEEN 288 PRECEDING AND 12 PRECEDING) AS sigma
  FROM points
)
SELECT t,
       p95_ms,
       base AS baseline_ms,
       base + 3 * sigma AS upper_ms,
       greatest(base - 3 * sigma, 0) AS lower_ms
FROM scored
WHERE t >= now() - INTERVAL 24 HOUR
ORDER BY t
```

</details>

### Server latency distribution (heatmap, seconds) — heatmap

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** `Duration / 1000000000` bucketed, count `count()`
- **Filter:** `SpanKind:Server` (lucene)
- **Columns used:** `Duration`, `SpanKind`

## SLO & error budget
An **SLO** (service-level objective) is your reliability target; the **SLI** (service-level indicator) is the measured value. Availability = successful server requests ÷ total server requests. Burn-rate windows (1h / 6h / 24h / 3d) are **fixed SLO windows** and intentionally ignore the time picker; a burn rate > 1 means the 99.9% error budget is being spent faster than sustainable.

### Availability (SLI = success rate) — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** avg(`if(StatusCode = 'Error', 0, 1)`) as `availability`  — where `SpanKind:Server` (lucene)
- **Columns used:** `StatusCode`, `SpanKind`

### Error budget remaining (window, SLO 99.9%) — number · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT 1 - (countIf(SpanKind = 'Server' AND StatusCode = 'Error') / nullIf(countIf(SpanKind = 'Server'), 0)) / 0.001 AS "Budget remaining"
FROM default.otel_traces
WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
  AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
  AND $__filters
```

</details>

### Multi-window burn rate (SLO 99.9%) — table · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
WITH 0.001 AS budget
SELECT window AS "Window",
       round(error_ratio, 5) AS "Error rate",
       round(error_ratio / budget, 2) AS "Burn rate (×)"
FROM (
  SELECT '1h' AS window, 1 AS ord,
         countIf(SpanKind = 'Server' AND StatusCode = 'Error') / nullIf(countIf(SpanKind = 'Server'), 0) AS error_ratio
  FROM default.otel_traces WHERE Timestamp > now() - INTERVAL 1 HOUR AND $__filters
  UNION ALL
  SELECT '6h', 2,
         countIf(SpanKind = 'Server' AND StatusCode = 'Error') / nullIf(countIf(SpanKind = 'Server'), 0)
  FROM default.otel_traces WHERE Timestamp > now() - INTERVAL 6 HOUR AND $__filters
  UNION ALL
  SELECT '24h', 3,
         countIf(SpanKind = 'Server' AND StatusCode = 'Error') / nullIf(countIf(SpanKind = 'Server'), 0)
  FROM default.otel_traces WHERE Timestamp > now() - INTERVAL 24 HOUR AND $__filters
  UNION ALL
  SELECT '3d', 4,
         countIf(SpanKind = 'Server' AND StatusCode = 'Error') / nullIf(countIf(SpanKind = 'Server'), 0)
  FROM default.otel_traces WHERE Timestamp > now() - INTERVAL 3 DAY AND $__filters
)
ORDER BY ord
```

</details>

### Availability over time (target 99.9%) — line

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `good`  — where `SpanKind:Server AND NOT StatusCode:Error` (lucene); count(*) as `total`  — where `SpanKind:Server` (lucene)
- **Columns used:** `StatusCode`, `SpanKind`
