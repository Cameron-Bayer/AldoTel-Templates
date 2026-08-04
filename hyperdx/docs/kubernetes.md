# ClickStack - Kubernetes

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/kubernetes.json` · tag `tmpl:kubernetes`
- **Data required:** kubeletstats receiver; k8s_cluster receiver; k8sobjects receiver (events.k8s.io) for the cluster-events tiles

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Namespace | `ResourceAttributes['k8s.namespace.name']` | Metrics (`default.otel_metrics_{gauge|sum|histogram}`) |
| Event Namespace | `JSONExtractString(Body, 'object', 'regarding', 'namespace')` | Logs (`default.otel_logs`) |

## Kubernetes Overview
Cluster, nodes, namespaces, pods/workloads, containers, resource utilization, and events/issues. Filter by Namespace and use the inventory and troubleshooting tables to move from cluster health to the affected resource.

## Cluster overview
Node readiness and per-node CPU, memory, and filesystem usage against capacity.

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

### Host CPU utilization % — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT ts, host, avg(busy) AS "CPU" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
         ResourceAttributes['host.name'] AS host,
         Attributes['cpu'] AS cpu,
         TimeUnix AS t,
         sumIf(Value, Attributes['state'] != 'idle') AS busy
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName = 'system.cpu.utilization'
  GROUP BY ts, host, cpu, t
) GROUP BY ts, host ORDER BY ts
```

</details>

### Host memory utilization % — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
       ResourceAttributes['host.name'] AS host,
       avgIf(Value, Attributes['state'] = 'used') AS "Memory"
FROM default.otel_metrics_gauge
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.memory.utilization'
GROUP BY ts, host ORDER BY ts
```

</details>

### Filesystem used % per volume — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, volume, used / nullIf(total, 0) AS "Filesystem" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
    concat(ResourceAttributes['host.name'], ' ', Attributes['mountpoint']) AS volume,
    sumIf(Value, Attributes['state'] = 'used') AS used,
    sum(Value) AS total
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.filesystem.usage'
  GROUP BY ts, volume
) WHERE total > 0 ORDER BY ts
```

</details>

### Nodes - status & uptime — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH g AS (
  SELECT ResourceAttributes['k8s.node.name'] AS node,
    argMax(Value, TimeUnix) AS ready
  FROM default.otel_metrics_gauge
  WHERE TimeUnix > now() - INTERVAL 1 HOUR
    AND MetricName = 'k8s.node.condition_ready'
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
  formatReadableTimeDelta(toUInt64(s.uptime)) AS Uptime
FROM g LEFT JOIN s USING (node)
ORDER BY Status DESC, s.uptime ASC
```

</details>

## Namespace overview
Resource consumption broken down by namespace.

### Namespace CPU usage (cores) — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT ts, ns, sum(pod_cpu) AS "CPU (cores)" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
         ResourceAttributes['k8s.namespace.name'] AS ns,
         ResourceAttributes['k8s.pod.name'] AS pod,
         avg(Value) AS pod_cpu
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'k8s.pod.cpu.usage' AND $__filters
  GROUP BY ts, ns, pod
)
GROUP BY ts, ns
ORDER BY ts
```

</details>

### Namespace memory usage — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT ts, ns, sum(pod_mem) AS "Memory" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
         ResourceAttributes['k8s.namespace.name'] AS ns,
         ResourceAttributes['k8s.pod.name'] AS pod,
         avg(Value) AS pod_mem
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'k8s.pod.memory.usage' AND $__filters
  GROUP BY ts, ns, pod
)
GROUP BY ts, ns
ORDER BY ts
```

</details>

### Namespaces - phase, CPU, memory — table · Raw SQL

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

## Workload health
Deployment availability, pod phases, restarts, and the pods using the most resources.

### Deployment availability (ready / desired) — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `k8s.deployment.available`, `k8s.deployment.desired`  (column `MetricName`)
- **Measure(s):** last_value(`Value`) as `available`; last_value(`Value`) as `desired`
- **Group by:** `concat(ResourceAttributes['k8s.namespace.name'], '/', ResourceAttributes['k8s.deployment.name'])`
- **Columns used:** `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.deployment.name']`, `Value`, `MetricName`, `TimeUnix`

### Pods by phase (count) — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT multiIf(phase = 1, 'Pending', phase = 2, 'Running', phase = 3, 'Succeeded', phase = 4, 'Failed', 'Unknown') AS "Phase", count() AS "Pods" FROM (
  SELECT ResourceAttributes['k8s.pod.name'] AS pod, argMax(Value, TimeUnix) AS phase
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'k8s.pod.phase' AND $__filters
  GROUP BY pod
)
GROUP BY phase
ORDER BY count() DESC
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

### Pods - status & resources — table · Raw SQL

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

## Cluster utilization (vs limits)
How close pods and containers are running to their configured CPU and memory limits.

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

### Container CPU vs limit % — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
       concat(ResourceAttributes['k8s.namespace.name'], '/', ResourceAttributes['k8s.pod.name'], '/', ResourceAttributes['k8s.container.name']) AS container,
       avg(Value) AS "CPU vs limit"
FROM default.otel_metrics_gauge
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'k8s.container.cpu_limit_utilization' AND $__filters
GROUP BY ts, container
ORDER BY ts
```

</details>

### Container memory vs limit % — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
       concat(ResourceAttributes['k8s.namespace.name'], '/', ResourceAttributes['k8s.pod.name'], '/', ResourceAttributes['k8s.container.name']) AS container,
       avg(Value) AS "Mem vs limit"
FROM default.otel_metrics_gauge
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'k8s.container.memory_limit_utilization' AND $__filters
GROUP BY ts, container
ORDER BY ts
```

</details>

### Host memory saturation % — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT max(sat) AS "Host mem saturation" FROM (
  SELECT ResourceAttributes['host.name'] AS host,
         argMaxIf(Value, TimeUnix, Attributes['state'] = 'used') AS sat
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.memory.utilization'
  GROUP BY host
)
```

</details>

### Containers - utilization vs limit / request — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH g AS (
  SELECT ResourceAttributes['k8s.namespace.name'] AS ns,
    ResourceAttributes['k8s.pod.name'] AS pod,
    ResourceAttributes['k8s.container.name'] AS container,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.container.cpu_limit_utilization') AS cpu_lim,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.container.cpu_request_utilization') AS cpu_req,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.container.memory_limit_utilization') AS mem_lim,
    argMaxIf(Value, TimeUnix, MetricName = 'k8s.container.memory_request_utilization') AS mem_req
  FROM default.otel_metrics_gauge
  WHERE TimeUnix > now() - INTERVAL 1 HOUR
    AND MetricName IN ('k8s.container.cpu_limit_utilization', 'k8s.container.cpu_request_utilization', 'k8s.container.memory_limit_utilization', 'k8s.container.memory_request_utilization')
    AND $__filters
  GROUP BY ns, pod, container
),
u AS (
  SELECT ResourceAttributes['k8s.namespace.name'] AS ns, ResourceAttributes['k8s.pod.name'] AS pod,
    ResourceAttributes['k8s.container.name'] AS container, argMax(Value, TimeUnix) AS uptime
  FROM default.otel_metrics_sum
  WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'container.uptime'
  GROUP BY ns, pod, container
)
SELECT g.ns AS Namespace, g.pod AS Pod, g.container AS Container,
  if(isNaN(g.cpu_lim), '-', concat(toString(round(g.cpu_lim * 100, 1)), '%')) AS "CPU/limit",
  if(isNaN(g.cpu_req), '-', concat(toString(round(g.cpu_req * 100, 1)), '%')) AS "CPU/request",
  if(isNaN(g.mem_lim), '-', concat(toString(round(g.mem_lim * 100, 1)), '%')) AS "Mem/limit",
  if(isNaN(g.mem_req), '-', concat(toString(round(g.mem_req * 100, 1)), '%')) AS "Mem/request",
  if(u.uptime > 0, formatReadableTimeDelta(toUInt64(u.uptime)), '-') AS Uptime
FROM g LEFT JOIN u USING (ns, pod, container)
ORDER BY g.cpu_lim DESC
LIMIT 100
```

</details>

## Cluster Inventory
Deployed nodes, namespaces, workloads, pods, and containers observed in the selected time range.

### Observed namespaces — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT uniqExact(ResourceAttributes['k8s.namespace.name']) AS "Namespaces" FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'k8s.pod.phase' AND $__filters
```

</details>

### Observed pods — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT uniqExact(tuple(ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.pod.name'])) AS "Pods" FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'k8s.pod.phase' AND $__filters
```

</details>

### Observed containers — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT uniqExact(tuple(ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.pod.name'], ResourceAttributes['k8s.container.name'])) AS "Containers" FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'k8s.container.restarts' AND $__filters
```

</details>

### Observed deployments — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT uniqExact(tuple(ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.deployment.name'])) AS "Deployments" FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName IN ('k8s.deployment.available','k8s.deployment.desired') AND $__filters
```

</details>

## Events & Issues
Central Kubernetes troubleshooting view for warning/critical events, top reasons, recent events, and impacted resources.

### Recent Kubernetes warning events — table · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT Timestamp, JSONExtractString(Body, 'object', 'reason') AS Reason, JSONExtractString(Body, 'object', 'regarding', 'namespace') AS Namespace, concat(JSONExtractString(Body, 'object', 'regarding', 'kind'), ' ', JSONExtractString(Body, 'object', 'regarding', 'name')) AS Resource, substring(JSONExtractString(Body, 'object', 'note'), 1, 240) AS Message FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND ScopeName LIKE '%k8sobjectsreceiver%' AND JSONExtractString(Body, 'object', 'type') = 'Warning' AND $__filters ORDER BY Timestamp DESC LIMIT 100
```

</details>

### Top Kubernetes event reasons / impacted resources — table · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT JSONExtractString(Body, 'object', 'reason') AS Reason, JSONExtractString(Body, 'object', 'regarding', 'namespace') AS Namespace, count() AS Events, uniqExact(concat(JSONExtractString(Body, 'object', 'regarding', 'kind'), '/', JSONExtractString(Body, 'object', 'regarding', 'name'))) AS "Impacted resources", max(Timestamp) AS "Last seen" FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND ScopeName LIKE '%k8sobjectsreceiver%' AND $__filters GROUP BY Reason, Namespace ORDER BY Events DESC LIMIT 50
```

</details>
