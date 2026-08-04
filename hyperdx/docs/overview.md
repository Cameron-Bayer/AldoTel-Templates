# ClickStack - Overview

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/overview.json` · tag `tmpl:operations-center`
- **Data required:** Cross-cutting roll-up: traces, logs, Kubernetes metrics/events, host metrics, and ClickHouse system tables. Signal-specific tiles degrade gracefully; ClickHouse workload tiles require SELECT access to system.processes, system.query_log, system.disks, system.metrics, system.merges, and system.mutations.

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Service | `ServiceName` | Traces (`default.otel_traces`) |
| Namespace | `ResourceAttributes['k8s.namespace.name']` | Metrics (`default.otel_metrics_{gauge|sum|histogram}`) |
| Log Service | `ServiceName` | Logs (`default.otel_logs`) |

## Overview
High-level snapshot of the entire environment, arranged for a top-to-bottom operational read: environment summary, platform health, resource consumption, service health, ClickHouse workload, impacted clusters/nodes, and recent events. Amber/red values identify conditions that need investigation.

## Environment Summary
Deployed cluster inventory and overall environment state.

### Total clusters — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT if(count() > 0, 1, 0) AS "Clusters" FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'k8s.node.condition_ready'
```

</details>

### Healthy clusters — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT if(score IS NULL, NULL, if(score >= 90, 1, 0)) AS "Healthy clusters" FROM (SELECT if(node_total + pod_total = 0, NULL,
  round(100 * (
    if(node_total = 0, 0, node_ready / node_total) +
    if(pod_total = 0, 0, pod_ok / pod_total)
  ) / ((node_total > 0) + (pod_total > 0)), 0)
) AS score
FROM (
  SELECT
    (SELECT count() FROM (
      SELECT ResourceAttributes['k8s.node.name'] AS n, argMax(Value, TimeUnix) AS r
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.node.condition_ready'
      GROUP BY n
    )) AS node_total,
    (SELECT countIf(r = 1) FROM (
      SELECT ResourceAttributes['k8s.node.name'] AS n, argMax(Value, TimeUnix) AS r
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.node.condition_ready'
      GROUP BY n
    )) AS node_ready,
    (SELECT count() FROM (
      SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS p
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.pod.phase'
      GROUP BY pod
    )) AS pod_total,
    (SELECT countIf(p IN (2, 3)) FROM (
      SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS p
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.pod.phase'
      GROUP BY pod
    )) AS pod_ok
))
```

</details>

### Warning clusters — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT if(score IS NULL, NULL, if(score >= 75 AND score < 90, 1, 0)) AS "Warning clusters" FROM (SELECT if(node_total + pod_total = 0, NULL,
  round(100 * (
    if(node_total = 0, 0, node_ready / node_total) +
    if(pod_total = 0, 0, pod_ok / pod_total)
  ) / ((node_total > 0) + (pod_total > 0)), 0)
) AS score
FROM (
  SELECT
    (SELECT count() FROM (
      SELECT ResourceAttributes['k8s.node.name'] AS n, argMax(Value, TimeUnix) AS r
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.node.condition_ready'
      GROUP BY n
    )) AS node_total,
    (SELECT countIf(r = 1) FROM (
      SELECT ResourceAttributes['k8s.node.name'] AS n, argMax(Value, TimeUnix) AS r
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.node.condition_ready'
      GROUP BY n
    )) AS node_ready,
    (SELECT count() FROM (
      SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS p
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.pod.phase'
      GROUP BY pod
    )) AS pod_total,
    (SELECT countIf(p IN (2, 3)) FROM (
      SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS p
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.pod.phase'
      GROUP BY pod
    )) AS pod_ok
))
```

</details>

### Critical clusters — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT if(score IS NULL, NULL, if(score < 75, 1, 0)) AS "Critical clusters" FROM (SELECT if(node_total + pod_total = 0, NULL,
  round(100 * (
    if(node_total = 0, 0, node_ready / node_total) +
    if(pod_total = 0, 0, pod_ok / pod_total)
  ) / ((node_total > 0) + (pod_total > 0)), 0)
) AS score
FROM (
  SELECT
    (SELECT count() FROM (
      SELECT ResourceAttributes['k8s.node.name'] AS n, argMax(Value, TimeUnix) AS r
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.node.condition_ready'
      GROUP BY n
    )) AS node_total,
    (SELECT countIf(r = 1) FROM (
      SELECT ResourceAttributes['k8s.node.name'] AS n, argMax(Value, TimeUnix) AS r
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.node.condition_ready'
      GROUP BY n
    )) AS node_ready,
    (SELECT count() FROM (
      SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS p
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.pod.phase'
      GROUP BY pod
    )) AS pod_total,
    (SELECT countIf(p IN (2, 3)) FROM (
      SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS p
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.pod.phase'
      GROUP BY pod
    )) AS pod_ok
))
```

</details>

### Appliance version — table · Raw SQL

- **Tables:** _derived in query_

<details><summary>SQL query</summary>

```sql
SELECT 'Not emitted by current telemetry' AS "Appliance Version", version() AS "ClickHouse Version"
```

</details>

### Total nodes — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT uniqExact(ResourceAttributes['k8s.node.name']) AS "Nodes" FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'k8s.node.condition_ready'
```

</details>

### Running workloads — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT countIf(phase = 2) AS "Running workloads" FROM (SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS phase FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'k8s.pod.phase' GROUP BY pod)
```

</details>

## Platform Health
Overall health score, active conditions, node readiness, and workload availability.

### Overall platform health score — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT score AS "Overall platform health score" FROM (SELECT if(node_total + pod_total = 0, NULL,
  round(100 * (
    if(node_total = 0, 0, node_ready / node_total) +
    if(pod_total = 0, 0, pod_ok / pod_total)
  ) / ((node_total > 0) + (pod_total > 0)), 0)
) AS score
FROM (
  SELECT
    (SELECT count() FROM (
      SELECT ResourceAttributes['k8s.node.name'] AS n, argMax(Value, TimeUnix) AS r
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.node.condition_ready'
      GROUP BY n
    )) AS node_total,
    (SELECT countIf(r = 1) FROM (
      SELECT ResourceAttributes['k8s.node.name'] AS n, argMax(Value, TimeUnix) AS r
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.node.condition_ready'
      GROUP BY n
    )) AS node_ready,
    (SELECT count() FROM (
      SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS p
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.pod.phase'
      GROUP BY pod
    )) AS pod_total,
    (SELECT countIf(p IN (2, 3)) FROM (
      SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS p
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.pod.phase'
      GROUP BY pod
    )) AS pod_ok
))
```

</details>

### Active alert conditions (recomputed) — number · Raw SQL

- **Tables:** `default.otel_traces`, `default.otel_logs`, `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT countIf(active = 1) AS "Active alerts" FROM (
        SELECT if(value >= 0.01, 1, 0) AS active FROM (
          SELECT countIf(StatusCode = 'Error') / nullIf(count(), 0) AS value
          FROM default.otel_traces
          WHERE Timestamp > now() - INTERVAL 15 MINUTE AND SpanKind = 'Server'
        )
        UNION ALL
        SELECT if(value >= 0.01, 1, 0) FROM (
          SELECT countIf(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) / nullIf(count(), 0) AS value
          FROM default.otel_logs
          WHERE Timestamp > now() - INTERVAL 15 MINUTE
        )
        UNION ALL
        SELECT if(value > 0, 1, 0) FROM (
          SELECT countIf(phase NOT IN (2,3)) AS value FROM (
            SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS phase
            FROM default.otel_metrics_gauge
            WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.pod.phase'
            GROUP BY pod
          )
        )
        UNION ALL
        SELECT if(value >= 0.75, 1, 0) FROM (
          SELECT avg(busy) AS value FROM (
            SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix,
                   sumIf(Value, Attributes['state'] != 'idle') AS busy
            FROM default.otel_metrics_gauge
            WHERE TimeUnix > now() - INTERVAL 15 MINUTE AND MetricName = 'system.cpu.utilization'
            GROUP BY host, cpu, TimeUnix
          )
        )
        UNION ALL
        SELECT if(value >= 0.8, 1, 0) FROM (
          SELECT avgIf(Value, Attributes['state'] = 'used') AS value
          FROM default.otel_metrics_gauge
          WHERE TimeUnix > now() - INTERVAL 15 MINUTE AND MetricName = 'system.memory.utilization'
        )
        UNION ALL
        SELECT if(value >= 0.8, 1, 0) FROM (
          SELECT max(used / nullIf(total, 0)) AS value FROM (
            SELECT ResourceAttributes['host.name'] AS host, Attributes['mountpoint'] AS volume,
                   sumIf(Value, Attributes['state'] = 'used') AS used, sum(Value) AS total
            FROM default.otel_metrics_sum
            WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.filesystem.usage'
            GROUP BY host, volume
          )
        )
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

### Cluster health score — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT score AS "Cluster health score" FROM (SELECT if(node_total + pod_total = 0, NULL,
  round(100 * (
    if(node_total = 0, 0, node_ready / node_total) +
    if(pod_total = 0, 0, pod_ok / pod_total)
  ) / ((node_total > 0) + (pod_total > 0)), 0)
) AS score
FROM (
  SELECT
    (SELECT count() FROM (
      SELECT ResourceAttributes['k8s.node.name'] AS n, argMax(Value, TimeUnix) AS r
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.node.condition_ready'
      GROUP BY n
    )) AS node_total,
    (SELECT countIf(r = 1) FROM (
      SELECT ResourceAttributes['k8s.node.name'] AS n, argMax(Value, TimeUnix) AS r
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.node.condition_ready'
      GROUP BY n
    )) AS node_ready,
    (SELECT count() FROM (
      SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS p
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.pod.phase'
      GROUP BY pod
    )) AS pod_total,
    (SELECT countIf(p IN (2, 3)) FROM (
      SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS p
      FROM default.otel_metrics_gauge
      WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
        AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
        AND MetricName = 'k8s.pod.phase'
      GROUP BY pod
    )) AS pod_ok
))
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

## Resource Consumption
Current compute, memory, storage, and network consumption followed by CPU and memory trends.

### Compute usage - Cluster CPU busy % (avg of hosts) — number · Raw SQL

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

### Memory usage - Cluster memory used % (avg of hosts) — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT avgIf(Value, Attributes['state'] = 'used') AS "Cluster memory used"
FROM default.otel_metrics_gauge
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.memory.utilization'
```

</details>

### Storage usage - Cluster disk used % (nodes / volumes) — number · Raw SQL

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

### Network consumption — number · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT sum(greatest(max_value - min_value, 0)) AS "Network consumption" FROM (
        SELECT ResourceAttributes['host.name'] AS host, Attributes['interface'] AS interface,
               Attributes['direction'] AS direction, max(Value) AS max_value, min(Value) AS min_value
        FROM default.otel_metrics_sum
        WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
          AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
          AND MetricName = 'system.network.io'
        GROUP BY host, interface, direction
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

## Service Health
Request volume, reliability, latency, log health, and the services contributing the most errors.

### Request volume - Server requests (selected range) — number · Raw SQL

- **Tables:** `default.otel_traces`

<details><summary>SQL query</summary>

```sql
SELECT count() AS "Server requests" FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Server' AND $__filters
```

</details>

### Error rate - Server error rate (%) — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** avg(`if(StatusCode = 'Error', 1, 0)`)  — where `SpanKind = 'Server'` (sql)
- **Columns used:** `StatusCode`, `SpanKind`

### P95 latency - 95th-percentile server latency — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** quantile(`Duration / 1000000000`)  — where `SpanKind = 'Server'` (sql)
- **Columns used:** `Duration`, `SpanKind`

### Log error rate (%) — number

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** avg(`if(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'), 1, 0)`)
- **Columns used:** `SeverityText`

### Services by error rate - click a row to open traces — table · Raw SQL

- **Tables:** `default.otel_traces`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Service, count() AS Requests,
              round(100 * countIf(StatusCode = 'Error') / nullIf(count(), 0), 3) AS "Error rate %",
              round(quantile(0.95)(Duration) / 1e6, 1) AS "P95 latency (ms)"
       FROM default.otel_traces
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND SpanKind = 'Server' AND $__filters
       GROUP BY ServiceName
       ORDER BY "Error rate %" DESC, Requests DESC
       LIMIT 50
```

</details>

### Services by log error - click a row to open logs — table · Raw SQL

- **Tables:** `default.otel_logs`
- **Drill-down:** click a row → opens search

<details><summary>SQL query</summary>

```sql
SELECT ServiceName AS Service, count() AS Logs,
              countIf(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) AS Errors,
              round(100 * Errors / nullIf(Logs, 0), 3) AS "Error rate %",
              maxIf(Timestamp, SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) AS "Last error"
       FROM default.otel_logs
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND $__filters
       GROUP BY ServiceName
       HAVING Errors > 0
       ORDER BY "Error rate %" DESC, Errors DESC
       LIMIT 50
```

</details>

### Request & error counts over time (traces) — line

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `requests`  — where `SpanKind = 'Server'` (sql); sum(`if(StatusCode = 'Error', 1, 0)`) as `errors`  — where `SpanKind = 'Server'` (sql)
- **Columns used:** `StatusCode`, `SpanKind`

## ClickHouse Workload & Storage
Database workload, failures, disk/memory health, query mix, inserts, merges, mutations, cache efficiency, and async inserts.

### Running queries — number · Raw SQL

- **Tables:** `system.processes`

<details><summary>SQL query</summary>

```sql
SELECT greatest(count() - 1, 0) AS "Running queries" FROM system.processes
```

</details>

### Failed queries — number · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT countIf(exception_code != 0) AS "Failed queries"
       FROM system.query_log
       WHERE event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
```

</details>

### Disk free % — number · Raw SQL

- **Tables:** `system.disks`

<details><summary>SQL query</summary>

```sql
SELECT min(free_space / nullIf(total_space, 0)) AS "Disk free" FROM system.disks
```

</details>

### Current tracked memory — number · Raw SQL

- **Tables:** `system.metrics`

<details><summary>SQL query</summary>

```sql
SELECT value AS "Memory tracked" FROM system.metrics WHERE metric = 'MemoryTracking'
```

</details>

### Queries (per interval) — line · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
              countIf(type = 'QueryFinish') AS Queries
       FROM system.query_log
       WHERE event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
       GROUP BY ts ORDER BY ts
```

</details>

### Failed queries (per interval) — line · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
              countIf(exception_code != 0) AS "Failed queries"
       FROM system.query_log
       WHERE event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
       GROUP BY ts ORDER BY ts
```

</details>

### Inserted rows (per interval) — table · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, sum(written_rows) AS "Inserted rows", formatReadableSize(sum(written_bytes)) AS "Inserted bytes" FROM system.query_log WHERE event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND type = 'QueryFinish' AND query_kind = 'Insert' GROUP BY ts ORDER BY ts
```

</details>

### Select vs insert queries (per interval) — table · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, countIf(query_kind = 'Select') AS Selects, countIf(query_kind = 'Insert') AS Inserts FROM system.query_log WHERE event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND type = 'QueryFinish' GROUP BY ts ORDER BY ts
```

</details>

### Active merges — number · Raw SQL

- **Tables:** `system.merges`

<details><summary>SQL query</summary>

```sql
SELECT count() AS "Active merges" FROM system.merges
```

</details>

### Pending mutations — number · Raw SQL

- **Tables:** `system.mutations`

<details><summary>SQL query</summary>

```sql
SELECT countIf(NOT is_done) AS "Pending mutations" FROM system.mutations
```

</details>

### Merges in progress (average progress) — number · Raw SQL

- **Tables:** `system.merges`

<details><summary>SQL query</summary>

```sql
SELECT if(count() = 0, 0, avg(progress)) AS "Merge progress" FROM system.merges
```

</details>

### Merges in progress (detail) — table · Raw SQL

- **Tables:** `system.merges`

<details><summary>SQL query</summary>

```sql
SELECT database AS Database, table AS Table, round(progress * 100, 1) AS "Progress %", formatReadableSize(total_size_bytes_compressed) AS Size, elapsed AS "Elapsed seconds", num_parts AS Parts FROM system.merges ORDER BY elapsed DESC
```

</details>

### Page-cache read bytes: cache vs source (per interval) — table · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, formatReadableSize(sum(ProfileEvents['PageCacheReadBytes'])) AS "From cache", formatReadableSize(sum(greatest(read_bytes - ProfileEvents['PageCacheReadBytes'], 0))) AS "From source" FROM system.query_log WHERE event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND type = 'QueryFinish' GROUP BY ts ORDER BY ts
```

</details>

### Async insert bytes (per interval) — table · Raw SQL

- **Tables:** `system.query_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, formatReadableSize(sum(ProfileEvents['AsyncInsertBytes'])) AS "Async insert bytes" FROM system.query_log WHERE event_time >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND event_time <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND type = 'QueryFinish' GROUP BY ts ORDER BY ts
```

</details>

## Top Impacted Clusters
Cluster/node health, alert pressure, CPU, storage, network consumption, and workloads.

### Top impacted clusters / nodes — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH ready AS (SELECT ResourceAttributes['k8s.node.name'] AS node, argMax(Value, TimeUnix) AS ready FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.node.condition_ready' GROUP BY node), cpu AS (SELECT host AS node, avg(busy) AS cpu_used FROM (SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix, sumIf(Value, Attributes['state'] != 'idle') AS busy FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.cpu.utilization' GROUP BY host, cpu, TimeUnix) GROUP BY node), mem AS (SELECT ResourceAttributes['host.name'] AS node, avgIf(Value, Attributes['state'] = 'used') AS memory_used FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.memory.utilization' GROUP BY node), disk AS (SELECT node, max(used / nullIf(total, 0)) AS disk_used FROM (SELECT ResourceAttributes['host.name'] AS node, Attributes['mountpoint'] AS mountpoint, sumIf(Value, Attributes['state'] = 'used') AS used, sum(Value) AS total FROM default.otel_metrics_sum WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.filesystem.usage' GROUP BY node, mountpoint) GROUP BY node), net AS (SELECT node, sum(max_value - min_value) AS bytes FROM (SELECT ResourceAttributes['host.name'] AS node, Attributes['interface'] AS interface, Attributes['direction'] AS direction, max(Value) AS max_value, min(Value) AS min_value FROM default.otel_metrics_sum WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.network.io' GROUP BY node, interface, direction) GROUP BY node), pods AS (SELECT ResourceAttributes['k8s.node.name'] AS node, uniqExact(ResourceAttributes['k8s.pod.name']) AS workloads FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.pod.phase' GROUP BY node) SELECT 'Appliance cluster' AS Cluster, ready.node AS Node, multiIf(ready.ready != 1, 'Critical', isNull(cpu.cpu_used) AND isNull(mem.memory_used) AND isNull(disk.disk_used), 'Unknown', ifNull(disk.disk_used >= 0.95, 0) OR ifNull(cpu.cpu_used >= 0.9, 0) OR ifNull(mem.memory_used >= 0.9, 0), 'Critical', ifNull(disk.disk_used >= 0.8, 0) OR ifNull(cpu.cpu_used >= 0.75, 0) OR ifNull(mem.memory_used >= 0.8, 0), 'Warning', 'Healthy') AS Health, (ready.ready != 1) + ifNull(cpu.cpu_used >= 0.75, 0) + ifNull(mem.memory_used >= 0.8, 0) + ifNull(disk.disk_used >= 0.8, 0) AS Alerts, round(100 * cpu.cpu_used, 1) AS "CPU %", round(100 * mem.memory_used, 1) AS "Memory %", round(100 * disk.disk_used, 1) AS "Storage %", formatReadableSize(net.bytes) AS "Network consumption", pods.workloads AS Workloads FROM ready LEFT JOIN cpu USING (node) LEFT JOIN mem USING (node) LEFT JOIN disk USING (node) LEFT JOIN net USING (node) LEFT JOIN pods USING (node) ORDER BY multiIf(Health = 'Critical', 1, Health = 'Warning', 2, Health = 'Unknown', 3, 4), Alerts DESC
```

</details>

### Detailed environment inventory — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT 'Appliance cluster' AS "Cluster name",
            'Not emitted by current telemetry' AS "Appliance version",
            'Not emitted by current telemetry' AS "Physical nodes",
            'Not emitted by current telemetry' AS "Virtual machines",
            if(count() > 0, 1, 0) AS "Kubernetes clusters",
            countIf(phase = 2) AS "Running workloads"
     FROM (
       SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS phase
       FROM default.otel_metrics_gauge
       WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND MetricName = 'k8s.pod.phase'
       GROUP BY pod
     )
```

</details>

## Recent Activity
Warning count, recurring Kubernetes event reasons, and chronological event detail.

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

## Related Control Plane & Data Plane Views
Use **Infrastructure** for host/storage/network detail, **Kubernetes** for nodes/namespaces/workloads, **Traces** for trace and dependency analysis, **Logs** for full-text investigation, and **Supportability** for guided incident workflows.
