# ClickStack - Traces

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/traces.json` · tag `tmpl:services`
- **Data required:** Application traces (OTLP) with server/client span kinds, status, HTTP/RPC attributes, trace context propagation, and peer/service attributes. Optional platform panels use ClickHouse system tables and collector self-telemetry.

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Service | `ServiceName` | Traces (`default.otel_traces`) |

## Traces
Eight-part service reliability experience: **1. Service Overview**, **2. Latency Analysis**, **3. Request Health (RED)**, **4. End-to-End Request Tracing**, **5. Service Dependency Mapping**, **6. Error Correlation & Root Cause Analysis**, **7. SLO & Reliability**, and **8. Infrastructure & Platform Performance**. Click trace rows to open HyperDX waterfall and request-journey views.

## 1. Service Overview
High-level health of all monitored services: request rate, error rate, latency, health score, and the most impacted services.

### Request rate (RPS) — number · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT count() / greatest(({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}) / 1000, 1) AS "RPS"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Server' AND $__filters
```

</details>

### Current error rate % — number · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT countIf(StatusCode = 'Error') / nullIf(count(), 0) AS "Error rate"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Server' AND $__filters
```

</details>

### Avg server latency — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** avg(`Duration / 1000000000`) as `latency`  — where `SpanKind = 'Server'` (sql)
- **Columns used:** `Duration`, `SpanKind`

### Success rate — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** avg(`if(StatusCode = 'Error', 0, 1)`) as `success`  — where `SpanKind:Server` (lucene)
- **Columns used:** `StatusCode`, `SpanKind`

### Service health summary / top impacted services — table · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT Service, Requests,
       round(error_rate_pct, 2) AS "Error rate %",
       round(average_latency_ms, 2) AS "Average latency (ms)",
       round(p95_latency_ms, 2) AS "P95 latency (ms)",
       greatest(0, round(100 - error_rate_pct * 10 - least(p95_latency_ms / 100, 30), 2)) AS "Health score",
       if(error_rate_pct >= 5 OR p95_latency_ms >= 2000, 'Critical',
          if(error_rate_pct >= 1 OR p95_latency_ms >= 1000, 'Warning', 'Healthy')) AS Health
FROM (
  SELECT ServiceName AS Service, count() AS Requests,
         100 * countIf(StatusCode = 'Error') / nullIf(count(), 0) AS error_rate_pct,
         avg(Duration) / 1e6 AS average_latency_ms,
         quantile(0.95)(Duration) / 1e6 AS p95_latency_ms
  FROM default.otel_traces
  WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND SpanKind = 'Server' AND $__filters
  GROUP BY ServiceName
)
ORDER BY multiIf(Health = 'Critical', 0, Health = 'Warning', 1, 2), error_rate_pct DESC, p95_latency_ms DESC
```

</details>

## 1.1. RED Metrics Overview
Request volume and error-rate trends by service. RED means Rate, Errors, and Duration.

### Request volume trends by service — line

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `requests`  — where `SpanKind:Server` (lucene)
- **Group by:** `ServiceName`
- **Columns used:** `ServiceName`, `SpanKind`

### Error rate % — line

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `errors`  — where `SpanKind:Server AND StatusCode:Error` (lucene); count(*) as `total`  — where `SpanKind:Server` (lucene)
- **Group by:** `ServiceName`
- **Columns used:** `ServiceName`, `StatusCode`, `SpanKind`

## 2. Latency Analysis
Performance bottlenecks and latency trends across server, client, HTTP, RPC, service, operation, routes, and the full latency distribution.

### Average server latency — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** avg(`Duration / 1000000000`) as `latency`  — where `SpanKind = 'Server'` (sql)
- **Columns used:** `Duration`, `SpanKind`

### Average client latency — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** avg(`Duration / 1000000000`) as `latency`  — where `SpanKind = 'Client'` (sql)
- **Columns used:** `Duration`, `SpanKind`

### Avg HTTP server latency — number · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT avg(Duration) / 1e9 AS "HTTP server latency"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Server'
         AND (SpanAttributes['http.request.method'] != '' OR SpanAttributes['http.method'] != '')
         AND $__filters
```

</details>

### Avg HTTP client latency — number · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT avg(Duration) / 1e9 AS "HTTP client latency"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Client'
         AND (SpanAttributes['http.request.method'] != '' OR SpanAttributes['http.method'] != '')
         AND $__filters
```

</details>

### HTTP server latency by service — table · Raw SQL

- **Tables:** `default.otel_traces`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Service, count() AS Requests,
              round(avg(Duration) / 1e6, 2) AS "Average (ms)",
              round(quantile(0.95)(Duration) / 1e6, 2) AS "P95 (ms)",
              round(quantile(0.99)(Duration) / 1e6, 2) AS "P99 (ms)"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Server'
         AND (SpanAttributes['http.request.method'] != '' OR SpanAttributes['http.method'] != '')
         AND $__filters
       GROUP BY ServiceName
               ORDER BY quantile(0.95)(Duration) DESC
```

</details>

### HTTP client latency by service — table · Raw SQL

- **Tables:** `default.otel_traces`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Service, count() AS Requests,
              round(avg(Duration) / 1e6, 2) AS "Average (ms)",
              round(quantile(0.95)(Duration) / 1e6, 2) AS "P95 (ms)",
              round(quantile(0.99)(Duration) / 1e6, 2) AS "P99 (ms)"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Client'
         AND (SpanAttributes['http.request.method'] != '' OR SpanAttributes['http.method'] != '')
         AND $__filters
       GROUP BY ServiceName
               ORDER BY quantile(0.95)(Duration) DESC
```

</details>

### RPC server latency by service — table · Raw SQL

- **Tables:** `default.otel_traces`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Service, SpanAttributes['rpc.system'] AS RPC,
              count() AS Requests, round(avg(Duration) / 1e6, 2) AS "Average (ms)",
              round(quantile(0.95)(Duration) / 1e6, 2) AS "P95 (ms)",
              round(quantile(0.99)(Duration) / 1e6, 2) AS "P99 (ms)"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Server' AND SpanAttributes['rpc.system'] != '' AND $__filters
       GROUP BY ServiceName, RPC
               ORDER BY quantile(0.95)(Duration) DESC
```

</details>

### Server latency percentiles (p50 / p95 / p99) — line

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** quantile(`Duration / 1000000000`) as `p50`  — where `SpanKind = 'Server'` (sql); quantile(`Duration / 1000000000`) as `p95`  — where `SpanKind = 'Server'` (sql); quantile(`Duration / 1000000000`) as `p99`  — where `SpanKind = 'Server'` (sql)
- **Columns used:** `Duration`, `SpanKind`

### Average server latency by service (ms) — line · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(Timestamp, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
              ServiceName AS Service, avg(Duration) / 1e6 AS "Average latency (ms)"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Server' AND $__filters
       GROUP BY ts, Service
       ORDER BY ts
```

</details>

### Latency by service & operation — table · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Service, SpanName AS Operation, SpanKind AS Kind, round(avg(Duration) / 1e6, 2) AS "Average (ms)", round(quantile(0.50)(Duration) / 1e6, 2) AS "P50 (ms)", round(quantile(0.95)(Duration) / 1e6, 2) AS "P95 (ms)", round(quantile(0.99)(Duration) / 1e6, 2) AS "P99 (ms)", count() AS Requests FROM default.otel_traces WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND SpanKind IN ('Server','Client') AND $__filters GROUP BY ServiceName, SpanName, SpanKind         HAVING Requests >= 5 ORDER BY quantile(0.95)(Duration) DESC LIMIT 100
```

</details>

### Slowest routes (p95) - min 20 requests — table · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS "Service", route AS "Route", round(p95_ms, 2) AS "p95 (ms)", round(p50_ms, 2) AS "p50 (ms)", requests AS "Requests" FROM (
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
         avg(p95_ms)       OVER (ORDER BY t ROWS BETWEEN 2304 PRECEDING AND 12 PRECEDING) AS base,
         stddevPop(p95_ms) OVER (ORDER BY t ROWS BETWEEN 2304 PRECEDING AND 12 PRECEDING) AS sigma
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

### Keeper operation latency percentiles — table · Raw SQL

- **Tables:** _derived in query_

<details><summary>SQL query</summary>

```sql
SELECT 'Unavailable' AS Status,
              'ClickHouse Keeper operation latency is not emitted by the current appliance telemetry. Enable Keeper metrics scraping to populate percentiles.' AS Detail
```

</details>

## 3. Request Health (RED Metrics)
Request volume, throughput, reliability, status errors, failed requests, and success rate.

### Server request rate by service (per interval) — line · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(Timestamp, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
              ServiceName AS Service, count() / greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))) AS RPS
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Server' AND $__filters
       GROUP BY ts, Service
       ORDER BY ts
```

</details>

### Server request count over time, by service — line

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `requests`  — where `SpanKind:Server` (lucene)
- **Group by:** `ServiceName`
- **Columns used:** `ServiceName`, `SpanKind`

### Errors by status message — pie

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `errors`  — where `SpanKind:Server AND StatusCode:Error` (lucene)
- **Group by:** `StatusMessage`
- **Columns used:** `StatusCode`, `StatusMessage`, `SpanKind`

### Failed request analysis — table · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Service, SpanName AS Operation, StatusMessage AS Error, count() AS Failures, round(quantile(0.95)(Duration) / 1e6, 2) AS "P95 (ms)", max(Timestamp) AS "Last seen" FROM default.otel_traces WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND SpanKind = 'Server' AND StatusCode = 'Error' AND $__filters GROUP BY ServiceName, SpanName, StatusMessage ORDER BY Failures DESC LIMIT 100
```

</details>

### Server requests / sec — number · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT count() / greatest(({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}) / 1000, 1) AS "Requests / sec"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Server' AND $__filters
```

</details>

### Server requests (selected range) — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `requests`  — where `SpanKind:Server` (lucene)
- **Columns used:** `SpanKind`

### Request success rate — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** avg(`if(StatusCode = 'Error', 0, 1)`) as `success`  — where `SpanKind:Server` (lucene)
- **Columns used:** `StatusCode`, `SpanKind`

## 4. End-to-End Request Tracing
Distributed trace search and request journeys across services. Open any result in HyperDX for the trace waterfall, critical path, and full request visualization.

### Distributed trace search — search

- **Source / table:** Traces → `default.otel_traces`
- **Columns shown:** `Timestamp, ServiceName, SpanName, SpanKind, Duration, StatusCode, StatusMessage, TraceId, SpanId, ParentSpanId`
- **Filter:** `SpanKind = 'Server'` (sql)
- **Columns used:** `ServiceName`, `Timestamp`, `Duration`, `StatusCode`, `StatusMessage`, `SpanName`, `SpanKind`, `TraceId`, `SpanId`, `ParentSpanId`

### Slow request traces — search

- **Source / table:** Traces → `default.otel_traces`
- **Columns shown:** `Timestamp, ServiceName, SpanName, SpanKind, Duration, StatusCode, StatusMessage, TraceId, SpanId, ParentSpanId`
- **Filter:** `SpanKind = 'Server' AND Duration >= 1000000000` (sql)
- **Columns used:** `ServiceName`, `Timestamp`, `Duration`, `StatusCode`, `StatusMessage`, `SpanName`, `SpanKind`, `TraceId`, `SpanId`, `ParentSpanId`

### Failed request traces — search

- **Source / table:** Traces → `default.otel_traces`
- **Columns shown:** `Timestamp, ServiceName, SpanName, SpanKind, Duration, StatusCode, StatusMessage, TraceId, SpanId, ParentSpanId`
- **Filter:** `SpanKind = 'Server' AND StatusCode = 'Error'` (sql)
- **Columns used:** `ServiceName`, `Timestamp`, `Duration`, `StatusCode`, `StatusMessage`, `SpanName`, `SpanKind`, `TraceId`, `SpanId`, `ParentSpanId`

### Critical path candidates by trace — table · Raw SQL

- **Tables:** `default.otel_traces`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT TraceId, argMax(ServiceName, Duration) AS "Slowest service",
              argMax(SpanName, Duration) AS "Slowest operation",
              round(max(Duration) / 1e6, 2) AS "Longest span (ms)",
              round(sum(Duration) / 1e6, 2) AS "Total span time (ms)",
              count() AS Spans
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND $__filters
       GROUP BY TraceId
               ORDER BY max(Duration) DESC
       LIMIT 100
```

</details>

### Trace sampling analytics — table · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Service, uniqExact(TraceId) AS Traces, count() AS Spans, round(count() / nullIf(uniqExact(TraceId), 0), 2) AS "Spans / trace", round(quantile(0.95)(Duration) / 1e6, 2) AS "P95 span (ms)" FROM default.otel_traces WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND $__filters GROUP BY ServiceName ORDER BY Traces DESC
```

</details>

## 5. Service Dependency Mapping
Upstream/downstream service relationships, request flow, dependency latency, dependency error rate, and the most impacted dependencies.

### Service dependency map / most impacted dependencies — table · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Upstream, coalesce(nullIf(SpanAttributes['peer.service'], ''), nullIf(SpanAttributes['server.address'], ''), nullIf(SpanAttributes['net.peer.name'], ''), SpanName) AS Downstream, count() AS Requests, round(100 * countIf(StatusCode = 'Error') / nullIf(count(), 0), 2) AS "Error rate %", round(quantile(0.95)(Duration) / 1e6, 2) AS "P95 latency (ms)" FROM default.otel_traces WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND SpanKind = 'Client' AND $__filters         GROUP BY Upstream, Downstream ORDER BY countIf(StatusCode = 'Error') / nullIf(count(), 0) DESC, quantile(0.95)(Duration) DESC
```

</details>

### Upstream and downstream dependencies — table · Raw SQL

- **Tables:** `default.otel_traces`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Upstream,
              coalesce(nullIf(SpanAttributes['peer.service'], ''),
                       nullIf(SpanAttributes['server.address'], ''),
                       nullIf(SpanAttributes['net.peer.name'], ''), SpanName) AS Downstream,
              count() AS Requests,
              round(avg(Duration) / 1e6, 2) AS "Average latency (ms)",
              round(quantile(0.95)(Duration) / 1e6, 2) AS "P95 latency (ms)",
              round(100 * countIf(StatusCode = 'Error') / nullIf(count(), 0), 2) AS "Error rate %"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Client' AND $__filters
       GROUP BY Upstream, Downstream
               ORDER BY countIf(StatusCode = 'Error') / nullIf(count(), 0) DESC, quantile(0.95)(Duration) DESC
```

</details>

## 6. Error Correlation & Root Cause Analysis
Error correlation across services and traces, propagation paths, exceptions, spikes, root-cause candidates, and the error timeline.

### Root cause candidate services / error propagation — table · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT TraceId, argMin(ServiceName, Timestamp) AS "First error service", min(Timestamp) AS "First error", groupUniqArray(ServiceName) AS "Impacted services", count() AS "Error spans" FROM default.otel_traces WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND StatusCode = 'Error' AND $__filters GROUP BY TraceId HAVING "Error spans" > 0 ORDER BY "Error spans" DESC, "First error" DESC LIMIT 100
```

</details>

### Exceptions by service — table · Raw SQL

- **Tables:** `default.otel_traces`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Service, StatusMessage AS Exception,
              count() AS Errors, uniqExact(TraceId) AS Traces,
              min(Timestamp) AS "First seen", max(Timestamp) AS "Last seen"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND StatusCode = 'Error' AND $__filters
       GROUP BY Service, Exception
       ORDER BY Errors DESC
       LIMIT 100
```

</details>

### Error timeline by service — line · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(Timestamp, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
              ServiceName AS Service, count() AS Errors
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND StatusCode = 'Error' AND $__filters
       GROUP BY ts, Service
       ORDER BY ts
```

</details>

### Error spikes & anomalies - last 24h vs 8-day baseline — line · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
WITH points AS (
         SELECT toStartOfInterval(Timestamp, INTERVAL 5 MINUTE) AS t,
                countIf(StatusCode = 'Error') AS errors
         FROM default.otel_traces
         WHERE Timestamp > now() - INTERVAL 8 DAY AND $__filters
         GROUP BY t
       ), scored AS (
         SELECT t, errors,
                avg(errors) OVER (ORDER BY t ROWS BETWEEN 2304 PRECEDING AND 12 PRECEDING) AS baseline,
                stddevPop(errors) OVER (ORDER BY t ROWS BETWEEN 2304 PRECEDING AND 12 PRECEDING) AS sigma
         FROM points
       )
       SELECT t, errors, baseline, baseline + 3 * sigma AS upper
       FROM scored
       WHERE t >= now() - INTERVAL 24 HOUR
       ORDER BY t
```

</details>

## 7. SLO & Reliability
Availability SLI, error budget remaining and consumption, multi-window burn rate, availability trend, compliance, violations, and alert-backed reliability.

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

### Error budget consumed (window) — number · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT (countIf(SpanKind = 'Server' AND StatusCode = 'Error') /
              nullIf(countIf(SpanKind = 'Server'), 0)) / 0.001 AS "Budget consumed"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND $__filters
```

</details>

### SLO violations — number · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT countIf(availability < 0.999) AS "SLO violations" FROM (
         SELECT ServiceName,
                countIf(StatusCode != 'Error') / nullIf(count(), 0) AS availability
         FROM default.otel_traces
         WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
           AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
           AND SpanKind = 'Server' AND $__filters
         GROUP BY ServiceName
       )
```

</details>

### Error budget consumption trend — line · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(Timestamp, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
              ServiceName AS Service,
              (countIf(StatusCode = 'Error') / nullIf(count(), 0)) / 0.001 AS "Budget consumption"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Server' AND $__filters
       GROUP BY ts, Service
       ORDER BY ts
```

</details>

### Availability over time (target 99.9%) — line

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `good`  — where `SpanKind:Server AND NOT StatusCode:Error` (lucene); count(*) as `total`  — where `SpanKind:Server` (lucene)
- **Columns used:** `StatusCode`, `SpanKind`

### Multi-window burn rate (SLO 99.9%) — table · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
WITH 0.001 AS budget
SELECT window AS "Window",
       round(100 * error_ratio, 2) AS "Error rate %",
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

### SLO compliance dashboard / violations — table · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT Service, round(availability_pct, 2) AS "Availability %", 99.9 AS "SLO target %", round(error_budget_remaining_pct, 2) AS "Error budget remaining %", if(availability_pct >= 99.9, 'Compliant', 'Violation') AS Status FROM (
  SELECT ServiceName AS Service,
         100 * countIf(StatusCode != 'Error') / nullIf(count(), 0) AS availability_pct,
         100 * (1 - (countIf(StatusCode = 'Error') / nullIf(count(), 0)) / 0.001) AS error_budget_remaining_pct
  FROM default.otel_traces
  WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND SpanKind = 'Server' AND $__filters
  GROUP BY ServiceName
)
ORDER BY Status DESC, availability_pct
```

</details>

## 8. Infrastructure & Platform Performance
Underlying ClickHouse, Keeper, collector, and OTel pipeline health. These panels are optional and depend on platform telemetry; use **Overview**, **Infrastructure**, and advanced **Observability Platform Health** for deeper investigation.

### ClickHouse running queries — number · Raw SQL

- **Tables:** `system.processes`

<details><summary>SQL query</summary>

```sql
SELECT greatest(count() - 1, 0) AS "Running queries" FROM system.processes
```

</details>

### Storage utilization — number · Raw SQL

- **Tables:** `system.disks`

<details><summary>SQL query</summary>

```sql
SELECT max(1 - free_space / nullIf(total_space, 0)) AS "Storage used" FROM system.disks
```

</details>

### Collector queue utilization — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT max(size / nullIf(capacity, 0)) AS "Queue utilization" FROM (
         SELECT ResourceAttributes['service.instance.id'] AS instance,
                Attributes['exporter'] AS exporter,
                Attributes['data_type'] AS data_type,
                argMaxIf(Value, TimeUnix, MetricName = 'otelcol_exporter_queue_size') AS size,
                argMaxIf(Value, TimeUnix, MetricName = 'otelcol_exporter_queue_capacity') AS capacity
         FROM default.otel_metrics_gauge
         WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
           AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
           AND MetricName IN ('otelcol_exporter_queue_size','otelcol_exporter_queue_capacity')
         GROUP BY instance, exporter, data_type
       )
```

</details>

### OTel pipeline refused spans — number · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT sum(if(value >= previous, value - previous, value)) AS "Refused spans" FROM (
         SELECT value,
                lagInFrame(value, 1, value) OVER (
                  PARTITION BY instance, receiver, transport
                  ORDER BY TimeUnix ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                ) AS previous
         FROM (
           SELECT ResourceAttributes['service.instance.id'] AS instance,
                  Attributes['receiver'] AS receiver,
                  Attributes['transport'] AS transport,
                  TimeUnix, max(Value) AS value
           FROM default.otel_metrics_sum
           WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
             AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
             AND MetricName = 'otelcol_receiver_refused_spans_total'
           GROUP BY instance, receiver, transport, TimeUnix
         )
       )
```

</details>

### ClickHouse query performance (p95 / p99) — line · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS t,
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

### ClickHouse Keeper latency — table · Raw SQL

- **Tables:** _derived in query_

<details><summary>SQL query</summary>

```sql
SELECT 'Unavailable' AS Status,
              'Keeper operation latency is not emitted by the current appliance telemetry. Enable Keeper metrics scraping for live percentiles.' AS Detail
```

</details>
