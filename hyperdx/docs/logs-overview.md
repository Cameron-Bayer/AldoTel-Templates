# AldoTel · Logs — Overview

> Auto-generated reference (do not edit by hand — run `node gen-docs.js`).

This page lists the ClickHouse tables and columns behind every visual on the dashboard.

- **Template:** `dashboards/logs-overview.json` · tag `tmpl:logs-overview`
- **Data required:** Application/container logs (filelog or OTLP)

## Preview

![AldoTel · Logs — Overview](images/logs-overview.png)

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
- **Measure(s):** count(*) as `errors`  — where `SeverityNumber:>=17 OR SeverityText:ERROR OR SeverityText:FATAL` (lucene)
- **Group by:** `ServiceName`
- **Columns used:** `ServiceName`, `SeverityText`

## Top errors & patterns

### Top error messages — table

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** count(*) as `count`  — where `SeverityNumber:>=17 OR SeverityText:ERROR OR SeverityText:FATAL` (lucene)
- **Group by:** `Body`
- **Order by:** `count DESC`
- **Drill-down:** click a row → opens search
- **Columns used:** `SeverityText`, `Body`

### New log patterns in last 24h (vs prior 7d) — table · Raw SQL

- **Tables:** `default.otel_logs`

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

### Live error stream — search

- **Source / table:** Logs → `default.otel_logs`
- **Columns shown:** `Timestamp, SeverityText, ServiceName, Body`
- **Filter:** `SeverityNumber:>=17 OR SeverityText:ERROR OR SeverityText:FATAL` (lucene)
- **Columns used:** `ServiceName`, `SeverityText`, `Body`, `Timestamp`
