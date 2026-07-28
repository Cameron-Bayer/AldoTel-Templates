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

## Log health & investigation
Application and infrastructure logs ingested into ClickStack via OpenTelemetry. Filter by **Service** or **Severity** and adjust the time range. Look for error/fatal spikes, newly appearing error signatures, and failures concentrated on specific services or pods; click any row to open the matching logs.

## Volume & error rate
Log throughput by severity and the error/fatal rate over time — the first place a problem shows up.

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

## Top errors & patterns
Error/fatal messages grouped into **signatures** — similar messages collapsed together after replacing IDs and numbers with `<id>`/`<n>`, so recurring failures stand out. The second table highlights signatures that are new in the last 24h (absent in the prior 7 days). These two tables use fixed 24h/7d windows, not the dashboard time range.

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

### New log patterns in last 24h (vs prior 7d) - click a row to open Logs — table · Raw SQL

- **Tables:** `default.otel_logs`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
WITH normalized AS (
  SELECT ServiceName,
         substring(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(Body, '[0-9a-fA-F]{8}-[0-9a-fA-F-]{4,}', '<id>'), '[0-9a-fA-F]{16,}', '<id>'), '[0-9]+', '<n>'), 1, 160) AS pattern,
         Timestamp
  FROM default.otel_logs
  WHERE (SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) AND Timestamp > now() - INTERVAL 8 DAY AND $__filters
)
SELECT ServiceName AS "Service", any(pattern) AS "Error signature",
       countIf(Timestamp > now() - INTERVAL 1 DAY) AS "Last 24h",
       countIf(Timestamp <= now() - INTERVAL 1 DAY) AS "Prior 7d"
FROM normalized
GROUP BY ServiceName, cityHash64(pattern)
HAVING "Prior 7d" = 0 AND "Last 24h" > 0
ORDER BY "Last 24h" DESC
LIMIT 50
```

</details>

## Live stream
Most recent error/fatal logs. The Namespace and Pod columns are populated only for Kubernetes workloads and may be blank for other log sources.

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
