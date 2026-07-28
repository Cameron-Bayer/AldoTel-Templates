# ClickStack - Supportability

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/supportability.json` · tag `tmpl:supportability`
- **Data required:** Application/container logs, application traces (OTLP), and Kubernetes metrics + events (kubeletstats + k8s_cluster + k8sobjects). Alert-condition tiles recompute rules live; there is no separate alert-state store.

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Service | `ServiceName` | Traces (`default.otel_traces`) |
| Namespace | `ResourceAttributes['k8s.namespace.name']` | Metrics (`default.otel_metrics_{gauge|sum|histogram}`) |
| Severity | `SeverityText` | Logs (`default.otel_logs`) |

## Supportability
For CSS, support, and operations: recomputed alert conditions, failure tracking (crashes, exhaustion, warning events), and troubleshooting (top errors, new log patterns, error sources, live stream). Use with the Logs and Services dashboards for drill-down.

## Alert conditions (recomputed live)

### Server error rate (%) — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** avg(`if(StatusCode = 'Error', 1, 0)`)  — where `SpanKind = 'Server'` (sql)
- **Columns used:** `StatusCode`, `SpanKind`

### Log error rate (%) — number

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** avg(`if(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'), 1, 0)`)
- **Columns used:** `SeverityText`

### Pods not Running — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT countIf(phase NOT IN (2, 3)) AS "Not running" FROM (
  SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS phase
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'k8s.pod.phase' AND $__filters
  GROUP BY pod
)
```

</details>

### Container restarts (selected range) — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT sum(d) AS "New restarts" FROM (
  SELECT max(Value) - min(Value) AS d
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'k8s.container.restarts' AND $__filters
  GROUP BY ResourceAttributes['k8s.pod.name']
)
```

</details>

## Failure tracking

### Top pods by restarts — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT ns AS "Namespace", pod AS "Pod", toUInt64(restarts) AS "Restarts" FROM (
  SELECT ResourceAttributes['k8s.namespace.name'] AS ns,
         ResourceAttributes['k8s.pod.name'] AS pod,
         argMax(Value, TimeUnix) AS restarts
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'k8s.container.restarts' AND $__filters
  GROUP BY ns, pod
)
WHERE restarts > 0
ORDER BY restarts DESC
LIMIT 50
```

</details>

### Warning events (in range) — number · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT countIf(JSONExtractString(Body, 'object', 'type') = 'Warning') AS "Warning events"
FROM default.otel_logs
WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND ScopeName LIKE '%k8sobjectsreceiver%'
```

</details>

### Top event reasons — table · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT JSONExtractString(Body, 'object', 'reason') AS "Reason",
  JSONExtractString(Body, 'object', 'type') AS "Type",
  count() AS "Count"
FROM default.otel_logs
WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND ScopeName LIKE '%k8sobjectsreceiver%'
GROUP BY Reason, Type
ORDER BY Count DESC
LIMIT 50
```

</details>

## Troubleshooting

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
         replaceRegexpAll(replaceRegexpAll(Body, '[0-9]+', '<n>'), '[0-9a-fA-F-]{8,}', '<id>') AS pattern,
         Timestamp
  FROM default.otel_logs
  WHERE (SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) AND Timestamp > now() - INTERVAL 8 DAY AND $__filters
)
SELECT ServiceName AS "Service", pattern AS "Error signature",
       countIf(Timestamp > now() - INTERVAL 1 DAY) AS "Last 24h",
       countIf(Timestamp <= now() - INTERVAL 1 DAY) AS "Prior 7d"
FROM normalized
GROUP BY ServiceName, pattern
HAVING "Prior 7d" = 0 AND "Last 24h" > 0
ORDER BY "Last 24h" DESC
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

### Live error stream - click a row for full log detail — search

- **Source / table:** Logs → `default.otel_logs`
- **Columns shown:** `Timestamp, SeverityText, ServiceName, ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.pod.name'], Body`
- **Filter:** `SeverityNumber:>=17 OR SeverityText:error OR SeverityText:fatal` (lucene)
- **Columns used:** `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.pod.name']`, `ServiceName`, `SeverityText`, `Body`, `Timestamp`
