# ClickStack - Operations Center

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/operations-center.json` · tag `tmpl:operations-center`
- **Data required:** Cross-cutting roll-up: application traces (OTLP), application/container logs, Kubernetes metrics (kubeletstats + k8s_cluster + k8sobjects events), and host metrics (hostmetrics). Every tile degrades gracefully when a signal is absent.

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Service | `ServiceName` | Traces (`default.otel_traces`) |
| Namespace | `ResourceAttributes['k8s.namespace.name']` | Metrics (`default.otel_metrics_{gauge|sum|histogram}`) |

## Operations Center
Single-pane health for the AldoTel appliance: cluster health, resource utilization, service & platform status, and recent cluster events. Sourced from OpenTelemetry metrics, traces, and logs. Amber/red stats mean elevated errors, saturation, or unready nodes.

## Cluster health
Node readiness, pod health, and restarts — the fastest signal that the appliance is up and serving.

### Cluster health score — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT round(100 * (nodes_ready + pods_ok) / 2, 0) AS "Cluster health score" FROM (
  SELECT
    (SELECT if(count() = 0, 1, countIf(r = 1) / count()) FROM (
       SELECT ResourceAttributes['k8s.node.name'] AS n, argMax(Value, TimeUnix) AS r
       FROM default.otel_metrics_gauge
       WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'k8s.node.condition_ready'
       GROUP BY n)) AS nodes_ready,
    (SELECT if(count() = 0, 1, countIf(p IN (2, 3)) / count()) FROM (
       SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS p
       FROM default.otel_metrics_gauge
       WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'k8s.pod.phase'
       GROUP BY pod)) AS pods_ok
)
```

</details>

### Kubernetes nodes ready % — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT if(total = 0, 0, ready / total) AS "Nodes ready" FROM (
  SELECT countIf(ready = 1) AS ready, count() AS total FROM (
    SELECT ResourceAttributes['k8s.node.name'] AS node, argMax(Value, TimeUnix) AS ready
    FROM default.otel_metrics_gauge
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName = 'k8s.node.condition_ready'
    GROUP BY node
  )
)
```

</details>

### Healthy nodes — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT countIf(ready = 1) AS "Healthy nodes" FROM (
  SELECT ResourceAttributes['k8s.node.name'] AS node, argMax(Value, TimeUnix) AS ready
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'k8s.node.condition_ready'
  GROUP BY node
)
```

</details>

### Unhealthy nodes (NotReady) — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT countIf(ready != 1) AS "Unhealthy nodes" FROM (
  SELECT ResourceAttributes['k8s.node.name'] AS node, argMax(Value, TimeUnix) AS ready
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'k8s.node.condition_ready'
  GROUP BY node
)
```

</details>

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

## Resource utilization
Cluster-wide CPU, memory, and disk usage, shown as current values and short-term trends.

### Cluster CPU busy % (avg of hosts) — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT avg(b) AS "Cluster CPU busy" FROM (
  SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix,
         sumIf(Value, Attributes['state'] != 'idle') AS b
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.cpu.utilization'
  GROUP BY host, cpu, TimeUnix
)
```

</details>

### Cluster memory used % (avg of hosts) — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT avgIf(Value, Attributes['state'] = 'used') AS "Cluster memory used"
FROM default.otel_metrics_gauge
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.memory.utilization'
```

</details>

### Cluster disk used % (volumes) — number · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT if(sum(total) = 0, 0, sum(used) / sum(total)) AS "Cluster disk used" FROM (
  SELECT concat(ResourceAttributes['host.name'], ' ', Attributes['mountpoint']) AS volume,
         argMaxIf(Value, TimeUnix, Attributes['state'] = 'used') AS used,
         argMaxIf(Value, TimeUnix, Attributes['state'] = 'used')
           + argMaxIf(Value, TimeUnix, Attributes['state'] = 'free')
           + argMaxIf(Value, TimeUnix, Attributes['state'] = 'reserved') AS total
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.filesystem.usage'
  GROUP BY volume
)
```

</details>

### Cluster CPU busy % over time — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT ts, avg(b) AS "Cluster CPU busy" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix,
         sumIf(Value, Attributes['state'] != 'idle') AS b
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.cpu.utilization'
  GROUP BY ts, host, cpu, TimeUnix
) GROUP BY ts ORDER BY ts
```

</details>

### Cluster memory used % over time — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, avgIf(Value, Attributes['state'] = 'used') AS "Cluster memory used"
FROM default.otel_metrics_gauge
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.memory.utilization'
GROUP BY ts ORDER BY ts
```

</details>

## Service & platform status
Application request errors, latency, and log error rate from traces and logs.

### Server error rate (%) — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** avg(`if(StatusCode = 'Error', 1, 0)`)  — where `SpanKind = 'Server'` (sql)
- **Columns used:** `StatusCode`, `SpanKind`

### 95th-percentile server latency (p95) — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** quantile(`Duration / 1000000000`)  — where `SpanKind = 'Server'` (sql)
- **Columns used:** `Duration`, `SpanKind`

### Log error rate (%) — number

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** avg(`if(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'), 1, 0)`)
- **Columns used:** `SeverityText`

### Request & error counts over time (traces) — line

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `requests`  — where `SpanKind = 'Server'` (sql); sum(`if(StatusCode = 'Error', 1, 0)`) as `errors`  — where `SpanKind = 'Server'` (sql)
- **Columns used:** `StatusCode`, `SpanKind`

## Recent activity (cluster events)
Recent Kubernetes warning events — what changed or started failing lately.

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

### Recent events — table · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT Timestamp AS "Time",
  JSONExtractString(Body, 'object', 'type') AS "Type",
  JSONExtractString(Body, 'object', 'reason') AS "Reason",
  concat(JSONExtractString(Body, 'object', 'regarding', 'kind'), ' ', JSONExtractString(Body, 'object', 'regarding', 'namespace'), '/', JSONExtractString(Body, 'object', 'regarding', 'name')) AS "Object",
  substring(JSONExtractString(Body, 'object', 'note'), 1, 160) AS "Message"
FROM default.otel_logs
WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND ScopeName LIKE '%k8sobjectsreceiver%'
ORDER BY Timestamp DESC
LIMIT 200
```

</details>
