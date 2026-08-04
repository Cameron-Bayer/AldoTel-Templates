# ClickStack - Logs

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/logs.json` · tag `tmpl:logs`
- **Data required:** Application/container logs (filelog or OTLP)

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Service | `ServiceName` | Logs (`default.otel_logs`) |
| Severity | `SeverityText` | Logs (`default.otel_logs`) |
| Host | `ResourceAttributes['host.name']` | Logs (`default.otel_logs`) |
| Namespace | `ResourceAttributes['k8s.namespace.name']` | Logs (`default.otel_logs`) |
| Pod | `ResourceAttributes['k8s.pod.name']` | Logs (`default.otel_logs`) |
| Cluster | `ResourceAttributes['k8s.cluster.name']` | Logs (`default.otel_logs`) |
| Resource | `ResourceAttributes['service.instance.id']` | Logs (`default.otel_logs`) |

## Logs
Three-part workflow: **1. Log Overview** for health and volume, **2. Log Search & Exploration** for full-text investigation and filters, and **3. Live Log Streaming** for real-time monitoring. HyperDX search provides the query builder, saved searches, bookmarks/favorites, export, and log-to-trace correlation.

## 1. Log Overview
High-level log health and volume: totals, logs/sec, error/fatal share, severity, and service trends.

### Log volume by severity — stacked_bar

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** count(*) as `logs`
- **Group by:** `SeverityText`
- **Columns used:** `SeverityText`

### Error & fatal log count over time, by service — line

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** count(*) as `errors`  — where `SeverityNumber:>=17 OR SeverityText:error OR SeverityText:fatal` (lucene)
- **Group by:** `ServiceName`
- **Columns used:** `ServiceName`, `SeverityText`

## 2. Log Search & Exploration
Use the search workspace below for full-text queries and filter by service, host, namespace, pod, severity, or time. Click grouped rows to open matching logs; use native HyperDX saved searches, bookmarks/favorites, exports, and correlation actions.

### Top error signatures (normalized) - click a row to open Logs — table · Raw SQL

- **Tables:** `default.otel_logs`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS "Service", pattern AS "Signature", count() AS "Count" FROM (
  SELECT ServiceName,
         replaceRegexpAll(replaceRegexpAll(Body, '[0-9a-fA-F-]{8,}', '<id>'), '[0-9]+', '<n>') AS pattern
  FROM default.otel_logs
  WHERE (SeverityNumber >= 17 OR lower(SeverityText) IN ('error', 'fatal'))
    AND Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND $__filters
)
GROUP BY ServiceName, pattern
ORDER BY count() DESC
LIMIT 50
```

</details>

### Errors & fatals by service (last 24h) - click a row to open Logs — table · Raw SQL

- **Tables:** `default.otel_logs`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS "Service",
       countIf(SeverityNumber = 17 OR lower(SeverityText) = 'error') AS "Errors",
       countIf(SeverityNumber = 21 OR lower(SeverityText) = 'fatal') AS "Fatal",
       max(Timestamp) AS "Last seen"
FROM default.otel_logs
WHERE (SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'))
  AND Timestamp > now() - INTERVAL 24 HOUR AND $__filters
GROUP BY ServiceName
ORDER BY "Errors" + "Fatal" DESC
LIMIT 50
```

</details>

## 3. Live Log Streaming
Real-time monitoring for all logs and the focused error stream. Pause/resume and open any row for full details in HyperDX.

### Live error stream - click a row for full log detail — search

- **Source / table:** Logs → `default.otel_logs`
- **Columns shown:** `Timestamp, SeverityText, ServiceName, ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.pod.name'], Body`
- **Filter:** `SeverityNumber:>=17 OR SeverityText:error OR SeverityText:fatal` (lucene)
- **Columns used:** `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.pod.name']`, `ServiceName`, `SeverityText`, `Body`, `Timestamp`

### Top Kubernetes error sources (namespace / pod) - click a row to open Logs — table · Raw SQL

- **Tables:** `default.otel_logs`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT ResourceAttributes['k8s.namespace.name'] AS "Namespace", ResourceAttributes['k8s.pod.name'] AS "Pod", ServiceName AS "Service", count() AS "Errors"
FROM default.otel_logs
WHERE (SeverityNumber >= 17 OR lower(SeverityText) IN ('error', 'fatal'))
  AND Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
  AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
  AND $__filters
GROUP BY "Namespace", "Pod", ServiceName
ORDER BY count() DESC
LIMIT 50
```

</details>

### Log error rate % — number

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** avg(`if(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'), 1, 0)`)
- **Columns used:** `SeverityText`

### Total logs (selected range) — number

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** count(*)

### Error + fatal logs (selected range) — number

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** sum(`if(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'), 1, 0)`)
- **Columns used:** `SeverityText`

### Average logs / sec — number · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT count() / greatest(({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}) / 1000, 1) AS "Logs / sec" FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND $__filters
```

</details>

### Average error + fatal logs / sec — number · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT countIf(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) / greatest(({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}) / 1000, 1) AS "Errors / sec" FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND $__filters
```

</details>

### Error + fatal share of logs — number · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT countIf(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) / nullIf(count(), 0) AS "Error share" FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND $__filters
```

</details>

### Fatal log count — number · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT countIf(SeverityNumber >= 21 OR lower(SeverityText) = 'fatal') AS "Fatal logs" FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND $__filters
```

</details>

### Log search workspace - click a row for full details — search

- **Source / table:** Logs → `default.otel_logs`
- **Columns shown:** `Timestamp, SeverityText, ServiceName, ResourceAttributes['service.instance.id'], ResourceAttributes['k8s.cluster.name'], ResourceAttributes['host.name'], ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.pod.name'], Body`
- **Columns used:** `ResourceAttributes['service.instance.id']`, `ResourceAttributes['k8s.cluster.name']`, `ResourceAttributes['host.name']`, `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.pod.name']`, `ServiceName`, `SeverityText`, `Body`, `Timestamp`

### Live log stream — search

- **Source / table:** Logs → `default.otel_logs`
- **Columns shown:** `Timestamp, SeverityText, ServiceName, ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.pod.name'], Body`
- **Columns used:** `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.pod.name']`, `ServiceName`, `SeverityText`, `Body`, `Timestamp`

### New error patterns in the past 24h — table · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Service, signature AS "New signature", count() AS Occurrences, min(Timestamp) AS "First seen", max(Timestamp) AS "Last seen" FROM (SELECT Timestamp, ServiceName, replaceRegexpAll(replaceRegexpAll(Body, '[0-9a-fA-F-]{8,}', '<id>'), '[0-9]+', '<n>') AS signature FROM default.otel_logs WHERE Timestamp > now() - INTERVAL 8 DAY AND (SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) AND $__filters) GROUP BY ServiceName, signature HAVING "First seen" >= now() - INTERVAL 24 HOUR ORDER BY Occurrences DESC LIMIT 100
```

</details>
