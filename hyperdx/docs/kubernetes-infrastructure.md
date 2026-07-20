# AldoTel · Kubernetes — Infrastructure

> Auto-generated reference (do not edit by hand — run `node gen-docs.js`).

This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/kubernetes-infrastructure.json` · tag `tmpl:k8s-infrastructure`
- **Data required:** kubeletstats receiver; k8s_cluster receiver

## Preview

![AldoTel · Kubernetes — Infrastructure](images/kubernetes-infrastructure.png)

_Live capture from a ClickStack install with the OpenTelemetry demo flowing._

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Namespace | `ResourceAttributes['k8s.namespace.name']` | Metrics (`default.otel_metrics_{gauge|sum|histogram}`) |

## Nodes

### Node CPU usage (cores) — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT
  toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
  ResourceAttributes['k8s.node.name'] AS node,
  avg(Value) AS "CPU (cores)"
FROM default.otel_metrics_gauge
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'k8s.node.cpu.usage'
GROUP BY ts, node
ORDER BY ts
```

</details>

### Node memory usage — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT
  toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
  ResourceAttributes['k8s.node.name'] AS node,
  avg(Value) AS "Memory"
FROM default.otel_metrics_gauge
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'k8s.node.memory.usage'
GROUP BY ts, node
ORDER BY ts
```

</details>

### Nodes — status, CPU, memory, uptime — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH g AS (
  SELECT ResourceAttributes['k8s.node.name'] AS node,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.node.condition_ready') AS ready,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.node.cpu.usage') AS cpu,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.node.memory.usage') AS mem
  FROM default.otel_metrics_gauge
  WHERE TimeUnix > now() - INTERVAL 1 HOUR
    AND MetricName IN ('k8s.node.condition_ready', 'k8s.node.cpu.usage', 'k8s.node.memory.usage')
  GROUP BY node
),
s AS (
  SELECT ResourceAttributes['k8s.node.name'] AS node, argMax(Value, TimeUnix) AS uptime
  FROM default.otel_metrics_sum
  WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.node.uptime'
  GROUP BY node
)
SELECT g.node AS Node,
  if(g.ready = 1, 'Ready', 'Not Ready') AS Status,
  round(g.cpu, 2) AS "CPU (cores)",
  formatReadableSize(g.mem) AS Memory,
  formatReadableTimeDelta(toUInt64(s.uptime)) AS Uptime
FROM g LEFT JOIN s USING (node)
ORDER BY g.cpu DESC
```

</details>

### Nodes ready — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT countIf(ready = 1) AS "Nodes ready" FROM (
  SELECT ResourceAttributes['k8s.node.name'] AS node, argMax(Value, TimeUnix) AS ready
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName = 'k8s.node.condition_ready'
  GROUP BY node
)
```

</details>

### Node filesystem usage % — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT ts, node, usage / capacity AS "Filesystem" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
    ResourceAttributes['k8s.node.name'] AS node,
    avgIf(Value, MetricName = 'k8s.node.filesystem.usage') AS usage,
    avgIf(Value, MetricName = 'k8s.node.filesystem.capacity') AS capacity
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName IN ('k8s.node.filesystem.usage', 'k8s.node.filesystem.capacity')
  GROUP BY ts, node
) WHERE capacity > 0 ORDER BY ts
```

</details>

## Pods

### Deployment availability (ready / desired) — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `k8s.deployment.available`, `k8s.deployment.desired`  (column `MetricName`)
- **Measure(s):** last_value(`Value`) as `available`; last_value(`Value`) as `desired`
- **Group by:** `ResourceAttributes['k8s.deployment.name']`
- **Columns used:** `ResourceAttributes['k8s.deployment.name']`, `Value`, `MetricName`, `TimeUnix`

### Pods by phase — stacked_bar

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `k8s.pod.phase`  (column `MetricName`)
- **Measure(s):** last_value(`Value`) as `pods`
- **Group by:** `ResourceAttributes['k8s.namespace.name']`
- **Columns used:** `ResourceAttributes['k8s.namespace.name']`, `Value`, `MetricName`, `TimeUnix`

### Pods — status & resources — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH g AS (
  SELECT ResourceAttributes['k8s.pod.name'] AS pod,
    any(ResourceAttributes['k8s.namespace.name']) AS ns,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.pod.phase') AS phase,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.pod.cpu_limit_utilization') AS cpu_lim,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.pod.memory_limit_utilization') AS mem_lim,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.pod.memory.usage') AS mem,
    maxIf(Value, MetricName = 'k8s.container.restarts') AS restarts
  FROM default.otel_metrics_gauge
  WHERE TimeUnix > now() - INTERVAL 1 HOUR
    AND MetricName IN ('k8s.pod.phase', 'k8s.pod.cpu_limit_utilization', 'k8s.pod.memory_limit_utilization', 'k8s.pod.memory.usage', 'k8s.container.restarts')
    AND $__filters
  GROUP BY pod
),
s AS (
  SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS uptime
  FROM default.otel_metrics_sum
  WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.pod.uptime'
  GROUP BY pod
)
SELECT g.ns AS Namespace,
  g.pod AS Pod,
  multiIf(g.phase = 1, 'Pending', g.phase = 2, 'Running', g.phase = 3, 'Succeeded', g.phase = 4, 'Failed', 'Unknown') AS Status,
  if(isNaN(g.cpu_lim), '-', concat(toString(round(g.cpu_lim * 100, 1)), '%')) AS "CPU/limit",
  if(isNaN(g.mem_lim), '-', concat(toString(round(g.mem_lim * 100, 1)), '%')) AS "Mem/limit",
  formatReadableSize(g.mem) AS Memory,
  formatReadableTimeDelta(toUInt64(s.uptime)) AS Age,
  toUInt64(g.restarts) AS Restarts
FROM g LEFT JOIN s USING (pod)
ORDER BY g.restarts DESC, g.cpu_lim DESC
LIMIT 100
```

</details>

### Pod CPU vs limit % — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `k8s.pod.cpu_limit_utilization`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `cpu vs limit`
- **Group by:** `ResourceAttributes['k8s.pod.name']`
- **Columns used:** `ResourceAttributes['k8s.pod.name']`, `Value`, `MetricName`, `TimeUnix`

### Pod memory vs limit % — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `k8s.pod.memory_limit_utilization`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `mem vs limit`
- **Group by:** `ResourceAttributes['k8s.pod.name']`
- **Columns used:** `ResourceAttributes['k8s.pod.name']`, `Value`, `MetricName`, `TimeUnix`

## Namespaces

### Namespace CPU usage (cores) — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `k8s.pod.cpu.usage`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `cpu`
- **Group by:** `ResourceAttributes['k8s.namespace.name']`
- **Columns used:** `ResourceAttributes['k8s.namespace.name']`, `Value`, `MetricName`, `TimeUnix`

### Namespace memory usage — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `k8s.pod.memory.usage`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `memory`
- **Group by:** `ResourceAttributes['k8s.namespace.name']`
- **Columns used:** `ResourceAttributes['k8s.namespace.name']`, `Value`, `MetricName`, `TimeUnix`

### Namespaces — phase, CPU, memory — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
WITH pods AS (
  SELECT ResourceAttributes['k8s.namespace.name'] AS ns,
    ResourceAttributes['k8s.pod.name'] AS pod,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.pod.cpu.usage') AS cpu,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.pod.memory.usage') AS mem
  FROM default.otel_metrics_gauge
  WHERE TimeUnix > now() - INTERVAL 1 HOUR
    AND MetricName IN ('k8s.pod.cpu.usage', 'k8s.pod.memory.usage')
    AND $__filters
  GROUP BY ns, pod
),
agg AS ( SELECT ns, sum(cpu) AS cpu, sum(mem) AS mem FROM pods GROUP BY ns ),
ph AS (
  SELECT ResourceAttributes['k8s.namespace.name'] AS ns, argMax(Value, TimeUnix) AS phase
  FROM default.otel_metrics_gauge
  WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.namespace.phase'
  GROUP BY ns
)
SELECT agg.ns AS Namespace,
  multiIf(ph.phase = 1, 'Active', ph.phase = 2, 'Terminating', 'Unknown') AS Phase,
  round(agg.cpu, 2) AS "CPU (cores)",
  formatReadableSize(agg.mem) AS Memory
FROM agg LEFT JOIN ph USING (ns)
ORDER BY agg.cpu DESC
```

</details>
