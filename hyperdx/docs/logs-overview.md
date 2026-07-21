# ClickStack · Logs — Overview

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/logs-overview.json` · tag `tmpl:logs-overview`
- **Data required:** Application/container logs (filelog or OTLP)

## Preview

![ClickStack · Logs — Overview](images/logs-overview.png)

_Live capture from a ClickStack install with the OpenTelemetry demo flowing._

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Service | `ServiceName` | Logs (`default.otel_logs`) |
| Severity | `SeverityText` | Logs (`default.otel_logs`) |

## Volume & error rate

### Log volume by severity — stacked_bar

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** count(*) as `logs`
- **Group by:** `SeverityText`
- **Columns used:** `SeverityText`

### Error / fatal rate by service — line

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** count(*) as `errors`  — where `SeverityNumber:>=17 OR SeverityText:error OR SeverityText:fatal` (lucene)
- **Group by:** `ServiceName`
- **Columns used:** `ServiceName`, `SeverityText`

## Top errors & patterns

### Top error signatures (normalized) — click a row to open Logs — table · Raw SQL

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

### New log patterns in last 24h (vs prior 7d) — click a row to open Logs — table · Raw SQL

- **Tables:** `default.otel_logs`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
WITH normalized AS (
  SELECT ServiceName,
         replaceRegexpAll(replaceRegexpAll(Body, '[0-9]+', '<n>'), '[0-9a-fA-F-]{8,}', '<id>') AS pattern,
         Timestamp
  FROM default.otel_logs
  WHERE (SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) AND Timestamp > now() - INTERVAL 8 DAY AND $__filters
)
SELECT ServiceName, pattern,
       countIf(Timestamp > now() - INTERVAL 1 DAY) AS last_24h,
       countIf(Timestamp <= now() - INTERVAL 1 DAY) AS prior_7d
FROM normalized
GROUP BY ServiceName, pattern
HAVING prior_7d = 0 AND last_24h > 0
ORDER BY last_24h DESC
LIMIT 50
```

</details>

## Live stream

### Live error stream — click a row for full log detail — search

- **Source / table:** Logs → `default.otel_logs`
- **Columns shown:** `Timestamp, SeverityText, ServiceName, ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.pod.name'], Body`
- **Filter:** `SeverityNumber:>=17 OR SeverityText:error OR SeverityText:fatal` (lucene)
- **Columns used:** `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.pod.name']`, `ServiceName`, `SeverityText`, `Body`, `Timestamp`

### Top error sources (namespace / pod) — click a row to open Logs — table · Raw SQL

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
