# ClickStack - Logs

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/logs.json` · tag `tmpl:logs`
- **Data required:** Application/container logs (filelog or OTLP)

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Resource | `ResourceAttributes['service.instance.id']` | Logs (`default.otel_logs`) |
| Cluster | `ResourceAttributes['k8s.cluster.name']` | Logs (`default.otel_logs`) |
| Host | `ResourceAttributes['host.name']` | Logs (`default.otel_logs`) |
| Namespace | `ResourceAttributes['k8s.namespace.name']` | Logs (`default.otel_logs`) |
| Pod | `ResourceAttributes['k8s.pod.name']` | Logs (`default.otel_logs`) |
| Application / Service | `ServiceName` | Logs (`default.otel_logs`) |
| Severity | `SeverityText` | Logs (`default.otel_logs`) |

## Logs
A three-stage log experience: **1. Log Overview** for health and volume, **2. Log Search & Exploration** for investigation, and **3. Live Log Streaming** for real-time monitoring. The dashboard filter bar provides Resource, Cluster, Host, Namespace, Pod, Application / Service, and Severity filters; the global time picker provides Timestamp filtering.

## 1. Log Overview
High-level understanding of log health and volume across the selected time range.

### Total logs (selected range) — number

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** count(*)

### Average logs / sec — number · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT count() / greatest(({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}) / 1000, 1) AS "Logs / sec" FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND $__filters
```

</details>

### Error + fatal logs (selected range) — number

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** sum(`if(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'), 1, 0)`)
- **Columns used:** `SeverityText`

### Log error rate % — number

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** avg(`if(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'), 1, 0)`)
- **Columns used:** `SeverityText`

### Fatal log count — number · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT countIf(SeverityNumber >= 21 OR lower(SeverityText) = 'fatal') AS "Fatal logs" FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND $__filters
```

</details>

### Average error + fatal logs / sec — number · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT countIf(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) / greatest(({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}) / 1000, 1) AS "Errors / sec" FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND $__filters
```

</details>

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

### Log volume trends — line · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(Timestamp, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
            count() AS Logs
     FROM default.otel_logs
     WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
       AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
       AND $__filters
     GROUP BY ts
     ORDER BY ts
```

</details>

### Log count per time bucket by severity — line · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(Timestamp, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
            SeverityText AS Severity, count() AS Logs
     FROM default.otel_logs
     WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
       AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
       AND $__filters
     GROUP BY ts, Severity
     ORDER BY ts
```

</details>

### Error + fatal share of logs — number · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT countIf(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) / nullIf(count(), 0) AS "Error share" FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND $__filters
```

</details>

### Services generating the most error and fatal logs — table · Raw SQL

- **Tables:** `default.otel_logs`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Service,
       countIf((SeverityNumber >= 17 AND SeverityNumber < 21) OR lower(SeverityText) = 'error') AS Errors,
       countIf(SeverityNumber >= 21 OR lower(SeverityText) = 'fatal') AS Fatals,
       countIf(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) AS Total,
       maxIf(Timestamp, SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) AS "Last error"
FROM default.otel_logs
WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
  AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
  AND $__filters
GROUP BY ServiceName
HAVING Total > 0
ORDER BY Total DESC
LIMIT 50
```

</details>

## 2. Log Search & Exploration
Primary workspace for full-text investigation. Enter text or structured expressions in HyperDX search; combine the dashboard filters with the global time picker. Native HyperDX supplies the Log Query Builder, Saved Searches, Bookmarks & Favorites, Export Results, and log correlation actions.

### Full-text log search - click a row for full details — search

- **Source / table:** Logs → `default.otel_logs`
- **Columns shown:** `Timestamp, SeverityText, ServiceName, ResourceAttributes['service.instance.id'], ResourceAttributes['k8s.cluster.name'], ResourceAttributes['host.name'], ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.pod.name'], Body`
- **Columns used:** `ResourceAttributes['service.instance.id']`, `ResourceAttributes['k8s.cluster.name']`, `ResourceAttributes['host.name']`, `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.pod.name']`, `ServiceName`, `SeverityText`, `Body`, `Timestamp`

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

### New error patterns in the past 24h — table · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Service, signature AS "New signature", count() AS Occurrences, min(Timestamp) AS "First seen", max(Timestamp) AS "Last seen" FROM (SELECT Timestamp, ServiceName, replaceRegexpAll(replaceRegexpAll(Body, '[0-9a-fA-F-]{8,}', '<id>'), '[0-9]+', '<n>') AS signature FROM default.otel_logs WHERE Timestamp > now() - INTERVAL 8 DAY AND (SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) AND $__filters) GROUP BY ServiceName, signature HAVING "First seen" >= now() - INTERVAL 24 HOUR ORDER BY Occurrences DESC LIMIT 100
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

### 100 most recent error and fatal logs — table · Raw SQL

- **Tables:** `default.otel_logs`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT Timestamp, SeverityText AS Severity, ServiceName AS Service,
       ResourceAttributes['service.instance.id'] AS Resource,
       ResourceAttributes['k8s.cluster.name'] AS Cluster,
       ResourceAttributes['host.name'] AS Host,
       ResourceAttributes['k8s.namespace.name'] AS Namespace,
       ResourceAttributes['k8s.pod.name'] AS Pod,
       substring(Body, 1, 500) AS Message
FROM default.otel_logs
WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
  AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
  AND (SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'))
  AND $__filters
ORDER BY Timestamp DESC
LIMIT 100
```

</details>

## Log Query Builder, Saved Searches & Correlation
Use the native HyperDX query builder above the search results to create full-text or structured queries. Save reusable queries, bookmark/favorite investigations, export result sets, and open correlated traces. Alert and metric context is available through the **Supportability**, **Overview**, **Traces**, and **Infrastructure** dashboards. For true live tail and Pause & Resume, open any stream row in the native Logs search workspace.

## 3. Live Log Streaming
Recent logs automatically refresh with the dashboard. Click a row to open the native HyperDX search workspace for true live-tail monitoring, Pause & Resume, full log details, and continued filtering by service, namespace, or pod.

### Live log stream (dashboard refresh) — search

- **Source / table:** Logs → `default.otel_logs`
- **Columns shown:** `Timestamp, SeverityText, ServiceName, ResourceAttributes['service.instance.id'], ResourceAttributes['k8s.cluster.name'], ResourceAttributes['host.name'], ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.pod.name'], Body`
- **Columns used:** `ResourceAttributes['service.instance.id']`, `ResourceAttributes['k8s.cluster.name']`, `ResourceAttributes['host.name']`, `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.pod.name']`, `ServiceName`, `SeverityText`, `Body`, `Timestamp`

### Live error stream (dashboard refresh) - click a row for full detail — search

- **Source / table:** Logs → `default.otel_logs`
- **Columns shown:** `Timestamp, SeverityText, ServiceName, ResourceAttributes['service.instance.id'], ResourceAttributes['k8s.cluster.name'], ResourceAttributes['host.name'], ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.pod.name'], Body`
- **Filter:** `SeverityNumber:>=17 OR SeverityText:error OR SeverityText:fatal` (lucene)
- **Columns used:** `ResourceAttributes['service.instance.id']`, `ResourceAttributes['k8s.cluster.name']`, `ResourceAttributes['host.name']`, `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.pod.name']`, `ServiceName`, `SeverityText`, `Body`, `Timestamp`

### Stream by service - click a row to open logs — table · Raw SQL

- **Tables:** `default.otel_logs`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT Timestamp, ServiceName AS Service, SeverityText AS Severity,
            substring(Body, 1, 240) AS Message
     FROM default.otel_logs
     WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
       AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
       AND $__filters
     ORDER BY Timestamp DESC
     LIMIT 100
```

</details>

### Stream by namespace / pod - click a row to open logs — table · Raw SQL

- **Tables:** `default.otel_logs`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT Timestamp,
            ResourceAttributes['k8s.namespace.name'] AS Namespace,
            ResourceAttributes['k8s.pod.name'] AS Pod,
            ServiceName AS Service, SeverityText AS Severity,
            substring(Body, 1, 200) AS Message
     FROM default.otel_logs
     WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
       AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
       AND $__filters
     ORDER BY Timestamp DESC
     LIMIT 100
```

</details>
