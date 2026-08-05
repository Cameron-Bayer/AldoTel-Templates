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

## Active Alerts & Guided Troubleshooting
Live alert-condition status plus guided workflows for ALM, ALRS, resource providers, Kubernetes, networking, and storage. HyperDX does not store Grafana alert state here, so the Active Alerts table recomputes the same observable conditions from current telemetry and links investigation to logs, traces, metrics, and events.

## 1. Alert Conditions
Global appliance conditions recomputed over fixed 15-minute request/log/CPU/memory windows and 1-hour pod/filesystem windows. Dashboard filters and the time picker intentionally do not scope this mixed-signal table; use the domain tiles below for filtered investigation.

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
  SELECT greatest(max(Value) - min(Value), 0) AS d
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'k8s.container.restarts' AND $__filters
  GROUP BY ResourceAttributes['k8s.namespace.name'],
           ResourceAttributes['k8s.pod.name'],
           ResourceAttributes['k8s.container.name']
)
```

</details>

## 2. Failure Tracking
Crash loops, resource exhaustion, and warning-level Kubernetes events.

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

## 3. Troubleshooting
Top error signatures, errors by service, error sources by namespace/pod, and a live error stream. Click a row to open Logs.

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
       countIf(SeverityNumber BETWEEN 17 AND 20 OR lower(SeverityText) = 'error') AS "Errors",
       countIf(SeverityNumber >= 21 OR lower(SeverityText) = 'fatal') AS "Fatal",
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

### Live error stream - click a row for full log detail — search

- **Source / table:** Logs → `default.otel_logs`
- **Columns shown:** `Timestamp, SeverityText, ServiceName, ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.pod.name'], Body`
- **Filter:** `SeverityNumber:>=17 OR SeverityText:error OR SeverityText:fatal` (lucene)
- **Columns used:** `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.pod.name']`, `ServiceName`, `SeverityText`, `Body`, `Timestamp`

### Global active alert conditions (15m / 1h) — table · Raw SQL

- **Tables:** `default.otel_traces`, `default.otel_logs`, `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT * FROM (SELECT 'Server error rate' AS Condition, if(value >= 0.05, 'Critical', if(value >= 0.01, 'Warning', 'Healthy')) AS Status, toFloat64(round(100 * value, 2)) AS Value, '%' AS Unit FROM (SELECT countIf(StatusCode = 'Error') / nullIf(count(), 0) AS value FROM default.otel_traces WHERE Timestamp > now() - INTERVAL 15 MINUTE AND SpanKind = 'Server') UNION ALL SELECT 'Log error rate', if(value >= 0.05, 'Critical', if(value >= 0.01, 'Warning', 'Healthy')), toFloat64(round(100 * value, 2)), '%' FROM (SELECT countIf(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) / nullIf(count(), 0) AS value FROM default.otel_logs WHERE Timestamp > now() - INTERVAL 15 MINUTE) UNION ALL SELECT 'Pods not running', if(value > 3, 'Critical', if(value > 0, 'Warning', 'Healthy')), toFloat64(value), 'pods' FROM (SELECT countIf(phase NOT IN (2,3)) AS value FROM (SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS phase FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.pod.phase' GROUP BY pod)) UNION ALL SELECT 'CPU saturation', if(value >= 0.9, 'Critical', if(value >= 0.75, 'Warning', 'Healthy')), toFloat64(round(100 * value, 2)), '%' FROM (SELECT avg(busy) AS value FROM (SELECT Attributes['cpu'] AS cpu, ResourceAttributes['host.name'] AS host, TimeUnix, sumIf(Value, Attributes['state'] != 'idle') AS busy FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 15 MINUTE AND MetricName = 'system.cpu.utilization' GROUP BY cpu, host, TimeUnix)) UNION ALL SELECT 'Memory saturation', if(value >= 0.9, 'Critical', if(value >= 0.8, 'Warning', 'Healthy')), toFloat64(round(100 * value, 2)), '%' FROM (SELECT avgIf(Value, Attributes['state'] = 'used') AS value FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 15 MINUTE AND MetricName = 'system.memory.utilization') UNION ALL SELECT 'Filesystem saturation', if(value >= 0.95, 'Critical', if(value >= 0.8, 'Warning', 'Healthy')), round(100 * value, 2), '%' FROM (SELECT max(used / nullIf(total, 0)) AS value FROM (SELECT ResourceAttributes['host.name'] AS host, Attributes['mountpoint'] AS volume, sumIf(Value, Attributes['state'] = 'used') AS used, sum(Value) AS total FROM default.otel_metrics_sum WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.filesystem.usage' GROUP BY host, volume))) ORDER BY multiIf(Status = 'Critical', 1, Status = 'Warning', 2, 3), Condition
```

</details>

## 4. Guided Workflows
**ALM / ALRS / Resource Providers:** start with Overview → identify the unhealthy node/service → inspect Services traces and Logs signatures.<br>**Kubernetes:** check node readiness, deployment availability, pods not running, restarts, then recent events.<br>**Networking:** check throughput, drops, and interface errors by host before correlating service/client-span latency.<br>**Storage:** check per-volume utilization, free capacity, IOPS, and latency; for ClickHouse pressure open advanced Observability Platform Health.<br>The normalized error-signature table below acts as the live known-issues index: recurring signatures can be matched to support documentation while new signatures are prioritized for investigation.

### Known issues repository - recurring error signatures — table · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT replaceRegexpAll(replaceRegexpAll(Body, '[0-9a-fA-F-]{8,}', '<id>'), '[0-9]+', '<n>') AS Signature, groupUniqArray(ServiceName) AS Services, count() AS Occurrences, min(Timestamp) AS "First seen", max(Timestamp) AS "Last seen" FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND (SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) GROUP BY Signature ORDER BY Occurrences DESC LIMIT 100
```

</details>
