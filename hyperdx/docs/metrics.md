# ClickStack - Metrics

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/metrics.json` · tag `tmpl:metrics`
- **Data required:** Unified metrics experience: hostmetrics receiver; kubeletstats and k8s_cluster receivers; k8sobjects receiver for events; optional process metrics for top process consumers.

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Event Namespace | `JSONExtractString(Body, 'object', 'regarding', 'namespace')` | Logs (`default.otel_logs`) |

## Metrics
Unified infrastructure and Kubernetes monitoring for **real-time status**, **historical trending**, **utilization analysis**, and **capacity planning**. Sections cover infrastructure overview, compute, storage, networking, Kubernetes nodes/namespaces/workloads/containers, events, cross-resource hotspots, and growth risk.

## 1. Infrastructure Overview
Overall infrastructure health, cluster readiness, active issues, current resource utilization, host health, and capacity risk.

### Infrastructure health score — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH cpu AS (
         SELECT avg(busy) AS value FROM (
           SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix,
                  sumIf(Value, Attributes['state'] != 'idle') AS busy
           FROM default.otel_metrics_gauge
           WHERE TimeUnix > now() - INTERVAL 1 HOUR
             AND MetricName = 'system.cpu.utilization'
           GROUP BY host, cpu, TimeUnix
         )
       ), mem AS (
         SELECT avgIf(Value, Attributes['state'] = 'used') AS value
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR
           AND MetricName = 'system.memory.utilization'
       ), ready AS (
         SELECT countIf(value = 1) / nullIf(count(), 0) AS value FROM (
           SELECT ResourceAttributes['k8s.node.name'] AS node, argMax(Value, TimeUnix) AS value
           FROM default.otel_metrics_gauge
           WHERE TimeUnix > now() - INTERVAL 1 HOUR
             AND MetricName = 'k8s.node.condition_ready'
           GROUP BY node
         )
       ), disk AS (
         SELECT max(used / nullIf(total, 0)) AS value FROM (
           SELECT host, mountpoint, sumIf(value, state = 'used') AS used, sum(value) AS total
           FROM (
             SELECT ResourceAttributes['host.name'] AS host,
                    Attributes['mountpoint'] AS mountpoint,
                    Attributes['state'] AS state,
                    argMax(Value, TimeUnix) AS value
             FROM default.otel_metrics_sum
             WHERE TimeUnix > now() - INTERVAL 1 HOUR
               AND MetricName = 'system.filesystem.usage'
             GROUP BY host, mountpoint, state
           )
           GROUP BY host, mountpoint
         )
       )
       SELECT greatest(0, round(100 - coalesce(cpu.value, 0) * 20
                                      - coalesce(mem.value, 0) * 20
                                      - coalesce(disk.value, 0) * 20
                                      - (1 - coalesce(ready.value, 1)) * 40, 0)) AS "Health score"
       FROM cpu CROSS JOIN mem CROSS JOIN ready CROSS JOIN disk
```

</details>

### Cluster health - nodes ready % — number · Raw SQL

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

### Current infrastructure issues — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
WITH nodes AS (
         SELECT countIf(ready != 1) AS issues FROM (
           SELECT ResourceAttributes['k8s.node.name'] AS node, argMax(Value, TimeUnix) AS ready
           FROM default.otel_metrics_gauge
           WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
             AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
             AND MetricName = 'k8s.node.condition_ready'
           GROUP BY node
         )
       ), pods AS (
         SELECT countIf(phase NOT IN (2, 3)) AS issues FROM (
           SELECT ResourceAttributes['k8s.pod.uid'] AS pod, argMax(Value, TimeUnix) AS phase
           FROM default.otel_metrics_gauge
           WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
             AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
             AND MetricName = 'k8s.pod.phase'
           GROUP BY pod
         )
       ), deployments AS (
         SELECT countIf(available < desired) AS issues FROM (
           SELECT ResourceAttributes['k8s.namespace.name'] AS namespace,
                  ResourceAttributes['k8s.deployment.name'] AS deployment,
                  argMaxIf(Value, TimeUnix, MetricName = 'k8s.deployment.available') AS available,
                  argMaxIf(Value, TimeUnix, MetricName = 'k8s.deployment.desired') AS desired
           FROM default.otel_metrics_gauge
           WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
             AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
             AND MetricName IN ('k8s.deployment.available', 'k8s.deployment.desired')
           GROUP BY namespace, deployment
         )
       )
       SELECT nodes.issues + pods.issues + deployments.issues AS Issues
       FROM nodes CROSS JOIN pods CROSS JOIN deployments
```

</details>

### Capacity risks — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH cpu AS (
         SELECT countIf(value >= 0.8) AS risks FROM (
           SELECT host, avg(busy) AS value FROM (
             SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix,
                    sumIf(Value, Attributes['state'] != 'idle') AS busy
             FROM default.otel_metrics_gauge
             WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.cpu.utilization'
             GROUP BY host, cpu, TimeUnix
           ) GROUP BY host
         )
       ), mem AS (
         SELECT countIf(value >= 0.85) AS risks FROM (
           SELECT ResourceAttributes['host.name'] AS host,
                  argMaxIf(Value, TimeUnix, Attributes['state'] = 'used') AS value
           FROM default.otel_metrics_gauge
           WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.memory.utilization'
           GROUP BY host
         )
       ), disk AS (
         SELECT countIf(value >= 0.85) AS risks FROM (
           SELECT host, mountpoint, used / nullIf(total, 0) AS value FROM (
             SELECT ResourceAttributes['host.name'] AS host, Attributes['mountpoint'] AS mountpoint,
                    sumIf(Value, Attributes['state'] = 'used') AS used, sum(Value) AS total
             FROM default.otel_metrics_sum
             WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.filesystem.usage'
             GROUP BY host, mountpoint, TimeUnix
             ORDER BY TimeUnix DESC LIMIT 1 BY host, mountpoint
           )
         )
       )
       SELECT cpu.risks + mem.risks + disk.risks AS Risks FROM cpu CROSS JOIN mem CROSS JOIN disk
```

</details>

### Resource utilization summary — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH cpu AS (
         SELECT avg(busy) AS value FROM (
           SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix,
                  sumIf(Value, Attributes['state'] != 'idle') AS busy
           FROM default.otel_metrics_gauge
           WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.cpu.utilization'
           GROUP BY host, cpu, TimeUnix
         )
       ), mem AS (
         SELECT avgIf(Value, Attributes['state'] = 'used') AS value
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.memory.utilization'
       ), disk AS (
         SELECT max(used / nullIf(total, 0)) AS value FROM (
           SELECT ResourceAttributes['host.name'] AS host, Attributes['mountpoint'] AS mountpoint, TimeUnix,
                  sumIf(Value, Attributes['state'] = 'used') AS used, sum(Value) AS total
           FROM default.otel_metrics_sum
           WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.filesystem.usage'
           GROUP BY host, mountpoint, TimeUnix
         )
       ), nodes AS (
         SELECT countIf(ready = 1) / nullIf(count(), 0) AS value FROM (
           SELECT ResourceAttributes['k8s.node.name'] AS node, argMax(Value, TimeUnix) AS ready
           FROM default.otel_metrics_gauge
           WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.node.condition_ready'
           GROUP BY node
         )
       )
       SELECT 'Compute' AS Resource, concat(toString(round(cpu.value * 100, 1)), '% used') AS Current
       FROM cpu
       UNION ALL SELECT 'Memory', concat(toString(round(mem.value * 100, 1)), '% used') FROM mem
       UNION ALL SELECT 'Storage', concat(toString(round(disk.value * 100, 1)), '% max used') FROM disk
       UNION ALL SELECT 'Kubernetes', concat(toString(round(nodes.value * 100, 1)), '% nodes ready') FROM nodes
```

</details>

### Host health summary — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
WITH c AS (
         SELECT host, avg(busy) AS cpu FROM (
           SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix,
                  sumIf(Value, Attributes['state'] != 'idle') AS busy
           FROM default.otel_metrics_gauge
           WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.cpu.utilization' AND $__filters
           GROUP BY host, cpu, TimeUnix
         ) GROUP BY host
       ), m AS (
         SELECT ResourceAttributes['host.name'] AS host,
                argMaxIf(Value, TimeUnix, Attributes['state'] = 'used') AS mem
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.memory.utilization' AND $__filters
         GROUP BY host
       ), l AS (
         SELECT ResourceAttributes['host.name'] AS host, argMax(Value, TimeUnix) AS load1
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.cpu.load_average.1m' AND $__filters
         GROUP BY host
       )
       SELECT c.host AS Host,
              multiIf(c.cpu >= 0.9 OR m.mem >= 0.95, 'Critical',
                      c.cpu >= 0.75 OR m.mem >= 0.85, 'Warning', 'Healthy') AS Status,
              concat(toString(round(c.cpu * 100, 1)), '%') AS CPU,
              concat(toString(round(m.mem * 100, 1)), '%') AS Memory,
              round(l.load1, 2) AS "Load (1m)"
       FROM c LEFT JOIN m USING (host) LEFT JOIN l USING (host)
       ORDER BY multiIf(Status = 'Critical', 0, Status = 'Warning', 1, 2), c.cpu DESC
```

</details>

## 2. Compute
Host and node CPU, load, process consumption, memory, swap, saturation, headroom, inventory, status, and uptime.

### Host CPU busy % — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT ts, host, avg(cpu_busy) AS "CPU busy" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
         ResourceAttributes['host.name'] AS host,
         Attributes['cpu'] AS cpu,
         TimeUnix,
         sumIf(Value, Attributes['state'] != 'idle') AS cpu_busy
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.cpu.utilization' AND $__filters
  GROUP BY ts, host, cpu, TimeUnix
)
GROUP BY ts, host
ORDER BY ts
```

</details>

### 1-minute load average (vs CPU cores) — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
       ResourceAttributes['host.name'] AS host,
       avg(Value) AS "Load (1m)"
FROM default.otel_metrics_gauge
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.cpu.load_average.1m' AND $__filters
GROUP BY ts, host
ORDER BY ts
```

</details>

### Current CPU headroom % — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT 1 - avg(busy) AS "CPU headroom" FROM (
         SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix,
                sumIf(Value, Attributes['state'] != 'idle') AS busy
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR
           AND MetricName = 'system.cpu.utilization' AND $__filters
         GROUP BY host, cpu, TimeUnix
       )
```

</details>

### Current memory headroom % — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT 1 - avgIf(Value, Attributes['state'] = 'used') AS "Memory headroom"
       FROM default.otel_metrics_gauge
       WHERE TimeUnix > now() - INTERVAL 1 HOUR
         AND MetricName = 'system.memory.utilization' AND $__filters
```

</details>

### Observed hosts — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT uniqExact(ResourceAttributes['host.name']) AS Hosts
       FROM default.otel_metrics_gauge
       WHERE TimeUnix > now() - INTERVAL 1 HOUR
         AND MetricName = 'system.cpu.utilization' AND $__filters
```

</details>

### Process / service instances observed — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT uniqExact(identity) AS Processes FROM (
         SELECT coalesce(nullIf(ResourceAttributes['service.instance.id'], ''),
                         nullIf(concat(ResourceAttributes['host.name'], '/',
                                       ResourceAttributes['process.pid']), '/'),
                         concat(ResourceAttributes['service.name'], '@', ResourceAttributes['host.name'])) AS identity
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR
           AND MetricName = 'process.cpu.utilization'
         UNION ALL
         SELECT coalesce(nullIf(ResourceAttributes['service.instance.id'], ''),
                         nullIf(concat(ResourceAttributes['host.name'], '/',
                                       ResourceAttributes['process.pid']), '/'),
                         concat(ResourceAttributes['service.name'], '@', ResourceAttributes['host.name'])) AS identity
         FROM default.otel_metrics_sum
         WHERE TimeUnix > now() - INTERVAL 1 HOUR
           AND MetricName = 'process.memory.usage'
       ) WHERE identity != ''
```

</details>

### Host memory used % — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
       ResourceAttributes['host.name'] AS host,
       avgIf(Value, Attributes['state'] = 'used') AS "Memory used"
FROM default.otel_metrics_gauge
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.memory.utilization' AND $__filters
GROUP BY ts, host
ORDER BY ts
```

</details>

### Host swap used % — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
              ResourceAttributes['host.name'] AS host,
              avgIf(Value, Attributes['state'] = 'used') AS "Swap used"
       FROM default.otel_metrics_gauge
       WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND MetricName = 'system.swap.utilization' AND $__filters
       GROUP BY ts, host ORDER BY ts
```

</details>

### Free memory per host (GB) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
       ResourceAttributes['host.name'] AS host,
       avgIf(Value, Attributes['state'] = 'free') / 1e9 AS "Free (GB)"
FROM default.otel_metrics_sum
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.memory.usage'
GROUP BY ts, host ORDER BY ts
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

### Top process / service consumers — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH c AS (
         SELECT ResourceAttributes['service.name'] AS service,
                coalesce(nullIf(ResourceAttributes['service.instance.id'], ''),
                         nullIf(concat(ResourceAttributes['host.name'], '/',
                                       ResourceAttributes['process.pid']), '/')) AS instance,
                ResourceAttributes['host.name'] AS host,
                argMax(Value, TimeUnix) AS cpu
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR
           AND MetricName = 'process.cpu.utilization'
         GROUP BY service, instance, host
       ), m AS (
         SELECT ResourceAttributes['service.name'] AS service,
                coalesce(nullIf(ResourceAttributes['service.instance.id'], ''),
                         nullIf(concat(ResourceAttributes['host.name'], '/',
                                       ResourceAttributes['process.pid']), '/')) AS instance,
                ResourceAttributes['host.name'] AS host,
                argMax(Value, TimeUnix) AS memory
         FROM default.otel_metrics_sum
         WHERE TimeUnix > now() - INTERVAL 1 HOUR
           AND MetricName = 'process.memory.usage'
         GROUP BY service, instance, host
       )
       SELECT if(c.service = '', c.instance, c.service) AS Process, c.host AS Host,
              concat(toString(round(c.cpu * 100, 1)), '%') AS CPU,
              formatReadableSize(m.memory) AS Memory
       FROM c LEFT JOIN m USING (service, instance, host)
       ORDER BY c.cpu DESC LIMIT 50
```

</details>

### Hosts - CPU, memory, load — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
WITH c AS (
  SELECT host, avg(b) AS cpu FROM (
    SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix,
           sumIf(Value, Attributes['state'] != 'idle') AS b
    FROM default.otel_metrics_gauge
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName = 'system.cpu.utilization' AND $__filters
    GROUP BY host, cpu, TimeUnix
  ) GROUP BY host
),
m AS (
  SELECT ResourceAttributes['host.name'] AS host, avgIf(Value, Attributes['state'] = 'used') AS mem
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.memory.utilization' AND $__filters
  GROUP BY host
),
l AS (
  SELECT ResourceAttributes['host.name'] AS host, avg(Value) AS load1
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.cpu.load_average.1m' AND $__filters
  GROUP BY host
)
SELECT c.host AS Host,
  concat(toString(round(c.cpu * 100, 1)), '%') AS "CPU busy",
  concat(toString(round(m.mem * 100, 1)), '%') AS "Mem used",
  round(l.load1, 2) AS "Load (1m)"
FROM c LEFT JOIN m USING (host) LEFT JOIN l USING (host)
ORDER BY c.cpu DESC
```

</details>

## 3. Storage
Filesystem capacity and availability, inode pressure, IOPS, throughput, latency, disk health, top consumers, trends, and growth risk.

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

### Free filesystem capacity per volume (GB) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
       concat(ResourceAttributes['host.name'], ' ', Attributes['mountpoint']) AS volume,
       avgIf(Value, Attributes['state'] = 'free') / 1e9 AS "Free (GB)"
FROM default.otel_metrics_sum
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.filesystem.usage'
GROUP BY ts, volume ORDER BY ts
```

</details>

### Inode used % per volume — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, volume, used / nullIf(total, 0) AS "Inodes used" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
         concat(ResourceAttributes['host.name'], ' ', Attributes['mountpoint']) AS volume,
         sumIf(Value, Attributes['state'] = 'used') AS used,
         sum(Value) AS total
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName = 'system.filesystem.inodes.usage' AND $__filters
  GROUP BY ts, volume
) WHERE total > 0 ORDER BY ts
```

</details>

### Disk IOPS (read / write, per host) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, concat(host, ' · ', direction) AS series, sum(d) / {intervalSeconds:Int64} AS "IOPS" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
         ResourceAttributes['host.name'] AS host,
         Attributes['direction'] AS direction,
         greatest(Value - lagInFrame(Value, 1, Value) OVER (
           PARTITION BY ResourceAttributes['host.name'], Attributes['device'], Attributes['direction'] ORDER BY TimeUnix), 0) AS d
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.disk.operations' AND $__filters
)
GROUP BY ts, host, direction
ORDER BY ts
```

</details>

### Disk latency (ms, per host · direction) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH t AS (
  SELECT ts, host, direction, sum(d) AS tsec FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, ResourceAttributes['host.name'] AS host, Attributes['direction'] AS direction,
           greatest(Value - lagInFrame(Value, 1, Value) OVER (
             PARTITION BY ResourceAttributes['host.name'], Attributes['device'], Attributes['direction'] ORDER BY TimeUnix), 0) AS d
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.disk.operation_time' AND $__filters
  ) GROUP BY ts, host, direction
),
o AS (
  SELECT ts, host, direction, sum(d) AS ops FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, ResourceAttributes['host.name'] AS host, Attributes['direction'] AS direction,
           greatest(Value - lagInFrame(Value, 1, Value) OVER (
             PARTITION BY ResourceAttributes['host.name'], Attributes['device'], Attributes['direction'] ORDER BY TimeUnix), 0) AS d
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.disk.operations' AND $__filters
  ) GROUP BY ts, host, direction
)
SELECT t.ts AS ts, concat(t.host, ' · ', t.direction) AS series,
       if(o.ops = 0, 0, t.tsec / o.ops * 1000) AS "Latency (ms)"
FROM t JOIN o ON t.ts = o.ts AND t.host = o.host AND t.direction = o.direction
ORDER BY ts
```

</details>

### Disk I/O (bytes/sec) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, concat(host, ' · ', direction) AS series, sum(d) / {intervalSeconds:Int64} AS "Bytes/sec" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
         ResourceAttributes['host.name'] AS host,
         Attributes['direction'] AS direction,
         greatest(Value - lagInFrame(Value, 1, Value) OVER (
           PARTITION BY ResourceAttributes['host.name'], Attributes['device'], Attributes['direction'] ORDER BY TimeUnix), 0) AS d
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.disk.io' AND $__filters
)
GROUP BY ts, host, direction
ORDER BY ts
```

</details>

### Storage health & alerts — table · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT host AS Host, mountpoint AS Filesystem,
              concat(toString(round(used / nullIf(total, 0) * 100, 1)), '%') AS "Used",
              formatReadableSize(free) AS Free,
              multiIf(used / nullIf(total, 0) >= 0.95, 'Critical',
                      used / nullIf(total, 0) >= 0.85, 'Warning', 'Healthy') AS Status
       FROM (
         SELECT ResourceAttributes['host.name'] AS host, Attributes['mountpoint'] AS mountpoint,
                sumIf(Value, Attributes['state'] = 'used') AS used,
                sumIf(Value, Attributes['state'] = 'free') AS free,
                sum(Value) AS total
         FROM default.otel_metrics_sum
         WHERE TimeUnix > now() - INTERVAL 1 HOUR
           AND MetricName = 'system.filesystem.usage' AND $__filters
         GROUP BY host, mountpoint, TimeUnix
         ORDER BY TimeUnix DESC LIMIT 1 BY host, mountpoint
       )
       ORDER BY multiIf(Status = 'Critical', 0, Status = 'Warning', 1, 2), used / nullIf(total, 0) DESC
```

</details>

## 4. Networking
Bandwidth usage, traffic trends, per-host throughput, top consumers, packet loss, interface errors, reliability, and bottlenecks.

### Network I/O (bytes/sec) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, concat(host, ' · ', direction) AS series, sum(d) / {intervalSeconds:Int64} AS "Bytes/sec" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
         ResourceAttributes['host.name'] AS host,
         Attributes['direction'] AS direction,
         greatest(Value - lagInFrame(Value, 1, Value) OVER (
           PARTITION BY ResourceAttributes['host.name'], Attributes['device'], Attributes['direction'] ORDER BY TimeUnix), 0) AS d
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.network.io' AND $__filters
)
GROUP BY ts, host, direction
ORDER BY ts
```

</details>

### Network health score — number · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH d AS (
         SELECT sum(delta) AS drops FROM (
           SELECT greatest(max(Value) - min(Value), 0) AS delta
           FROM default.otel_metrics_sum
           WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
             AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
             AND MetricName = 'system.network.dropped' AND $__filters
           GROUP BY ResourceAttributes['host.name'], Attributes['device'], Attributes['direction']
         )
       ), e AS (
         SELECT sum(delta) AS errors FROM (
           SELECT greatest(max(Value) - min(Value), 0) AS delta
           FROM default.otel_metrics_sum
           WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
             AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
             AND MetricName = 'system.network.errors' AND $__filters
           GROUP BY ResourceAttributes['host.name'], Attributes['device'], Attributes['direction']
         )
       )
       SELECT greatest(0, 100 - least(coalesce(d.drops, 0), 50) - least(coalesce(e.errors, 0) * 2, 50)) AS "Network health"
       FROM d CROSS JOIN e
```

</details>

### Network packets dropped / sec (per host) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, concat(host, ' · ', direction) AS series, sum(d) / {intervalSeconds:Int64} AS "Dropped/sec" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
         ResourceAttributes['host.name'] AS host,
         Attributes['direction'] AS direction,
         greatest(Value - lagInFrame(Value, 1, Value) OVER (
           PARTITION BY ResourceAttributes['host.name'], Attributes['device'], Attributes['direction'] ORDER BY TimeUnix), 0) AS d
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.network.dropped' AND $__filters
)
GROUP BY ts, host, direction
ORDER BY ts
```

</details>

### Network interface errors / sec (per host) — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, concat(host, ' · ', direction) AS series, sum(d) / {intervalSeconds:Int64} AS "Errors/sec" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
         ResourceAttributes['host.name'] AS host,
         Attributes['direction'] AS direction,
         greatest(Value - lagInFrame(Value, 1, Value) OVER (
           PARTITION BY ResourceAttributes['host.name'], Attributes['device'], Attributes['direction'] ORDER BY TimeUnix), 0) AS d
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.network.errors' AND $__filters
)
GROUP BY ts, host, direction
ORDER BY ts
```

</details>

### Top network consumers and reliability — table · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH io AS (
         SELECT host, device, sum(greatest(max_value - min_value, 0)) AS bytes FROM (
           SELECT ResourceAttributes['host.name'] AS host, Attributes['device'] AS device,
                  Attributes['direction'] AS direction, max(Value) AS max_value, min(Value) AS min_value
           FROM default.otel_metrics_sum
           WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
             AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
             AND MetricName = 'system.network.io' AND $__filters
           GROUP BY host, device, direction
         ) GROUP BY host, device
       ), dropped AS (
         SELECT host, device, sum(greatest(max_value - min_value, 0)) AS dropped FROM (
           SELECT ResourceAttributes['host.name'] AS host, Attributes['device'] AS device,
                  Attributes['direction'] AS direction, max(Value) AS max_value, min(Value) AS min_value
           FROM default.otel_metrics_sum
           WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
             AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
             AND MetricName = 'system.network.dropped' AND $__filters
           GROUP BY host, device, direction
         ) GROUP BY host, device
       )
       SELECT io.host AS Host, io.device AS Interface, formatReadableSize(io.bytes) AS Traffic,
              coalesce(dropped.dropped, 0) AS "Packets dropped"
       FROM io LEFT JOIN dropped USING (host, device)
       ORDER BY io.bytes DESC
```

</details>

## 5. Kubernetes Overview & Nodes
Cluster health and inventory, Ready/NotReady nodes, CPU versus observed host cores, memory versus observed capacity, filesystem usage, status, and uptime.

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

### Cluster inventory — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT uniqExact(ResourceAttributes['k8s.node.name']) AS Nodes
       FROM default.otel_metrics_gauge
       WHERE TimeUnix > now() - INTERVAL 1 HOUR
         AND MetricName = 'k8s.node.condition_ready'
```

</details>

### Node CPU usage (cores vs observed host cores) — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
WITH u AS (
         SELECT ResourceAttributes['k8s.node.name'] AS node, argMax(Value, TimeUnix) AS used
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.node.cpu.usage'
         GROUP BY node
       ), c AS (
         SELECT ResourceAttributes['k8s.node.name'] AS node, uniqExact(Attributes['cpu']) AS cores
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.cpu.utilization'
         GROUP BY node
       )
       SELECT u.node AS Node, round(u.used, 2) AS "Used cores", c.cores AS "Observed cores",
              concat(toString(round(u.used / nullIf(c.cores, 0) * 100, 1)), '%') AS Utilization
       FROM u LEFT JOIN c USING (node) ORDER BY u.used DESC
```

</details>

### Node memory used (vs observed capacity) — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
WITH p AS (
         SELECT ResourceAttributes['k8s.node.name'] AS node,
                argMaxIf(Value, TimeUnix, MetricName = 'k8s.node.memory.usage') AS used,
                argMaxIf(Value, TimeUnix, MetricName = 'k8s.node.memory.available') AS available
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR
           AND MetricName IN ('k8s.node.memory.usage', 'k8s.node.memory.available')
         GROUP BY node
       )
       SELECT node AS Node, formatReadableSize(used) AS Used,
              formatReadableSize(used + available) AS "Observed capacity",
              concat(toString(round(used / nullIf(used + available, 0) * 100, 1)), '%') AS Utilization
       FROM p ORDER BY used / nullIf(used + available, 0) DESC
```

</details>

### Node filesystem usage % — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT ResourceAttributes['k8s.node.name'] AS Node,
              concat(toString(round(argMaxIf(Value, TimeUnix, MetricName = 'k8s.node.filesystem.usage') /
                                    nullIf(argMaxIf(Value, TimeUnix, MetricName = 'k8s.node.filesystem.capacity'), 0) * 100, 1)), '%') AS "Filesystem used"
       FROM default.otel_metrics_gauge
       WHERE TimeUnix > now() - INTERVAL 1 HOUR
         AND MetricName IN ('k8s.node.filesystem.usage', 'k8s.node.filesystem.capacity')
       GROUP BY Node ORDER BY "Filesystem used" DESC
```

</details>

### Nodes - status, CPU, memory, uptime — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH g AS (
         SELECT ResourceAttributes['k8s.node.name'] AS node,
                argMaxIf(Value, TimeUnix, MetricName = 'k8s.node.condition_ready') AS ready,
                argMaxIf(Value, TimeUnix, MetricName = 'k8s.node.cpu.usage') AS cpu,
                argMaxIf(Value, TimeUnix, MetricName = 'k8s.node.memory.usage') AS memory
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR
           AND MetricName IN ('k8s.node.condition_ready','k8s.node.cpu.usage','k8s.node.memory.usage')
         GROUP BY node
       ), s AS (
         SELECT ResourceAttributes['k8s.node.name'] AS node, argMax(Value, TimeUnix) AS uptime
         FROM default.otel_metrics_sum
         WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.node.uptime'
         GROUP BY node
       )
       SELECT g.node AS Node, if(g.ready = 1, 'Ready', 'Not Ready') AS Status,
              round(g.cpu, 2) AS "CPU cores", formatReadableSize(g.memory) AS Memory,
              formatReadableTimeDelta(toUInt64(s.uptime)) AS Uptime
       FROM g LEFT JOIN s USING (node)
       ORDER BY if(Status = 'Not Ready', 0, 1), g.cpu DESC
```

</details>

## 6. Namespaces
Namespace CPU and memory usage, historical resource trends, phase/status, and the highest-consuming namespaces.

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

## 7. Pods & Workloads
Deployment availability, pod phases and status, pods not running, restarts, failed containers, workload resources, and restart hotspots.

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
SELECT multiIf(phase = 1, 'Pending', phase = 2, 'Running', phase = 3, 'Succeeded',
                      phase = 4, 'Failed', 'Unknown') AS "Phase", count() AS "Pods"
       FROM (
         SELECT ResourceAttributes['k8s.namespace.name'] AS namespace,
                ResourceAttributes['k8s.pod.uid'] AS uid,
                ResourceAttributes['k8s.pod.name'] AS pod,
                argMax(Value, TimeUnix) AS phase
         FROM default.otel_metrics_gauge
         WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
           AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
           AND MetricName = 'k8s.pod.phase' AND $__filters
         GROUP BY namespace, uid, pod
       )
       GROUP BY phase ORDER BY count() DESC
```

</details>

### Pods not Running — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT countIf(phase NOT IN (2, 3)) AS "Not running" FROM (
         SELECT ResourceAttributes['k8s.namespace.name'] AS namespace,
                ResourceAttributes['k8s.pod.uid'] AS uid,
                ResourceAttributes['k8s.pod.name'] AS pod,
                argMax(Value, TimeUnix) AS phase
         FROM default.otel_metrics_gauge
         WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
           AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
           AND MetricName = 'k8s.pod.phase' AND $__filters
         GROUP BY namespace, uid, pod
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
                  ResourceAttributes['k8s.pod.uid'],
                  ResourceAttributes['k8s.pod.name'],
                  ResourceAttributes['k8s.container.name']
       )
```

</details>

### Failed pods — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT uniqExact(concat(ResourceAttributes['k8s.namespace.name'], '/',
                              ResourceAttributes['k8s.pod.name'])) AS "Failed pods"
       FROM default.otel_metrics_gauge
       WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND MetricName = 'k8s.pod.phase' AND Value = 4 AND $__filters
```

</details>

### Observed deployments — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT uniqExact(tuple(ResourceAttributes['k8s.namespace.name'], ResourceAttributes['k8s.deployment.name'])) AS "Deployments" FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName IN ('k8s.deployment.available','k8s.deployment.desired') AND $__filters
```

</details>

### Pods - status & resources — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH p AS (
         SELECT ResourceAttributes['k8s.namespace.name'] AS ns,
                ResourceAttributes['k8s.pod.uid'] AS uid,
                ResourceAttributes['k8s.pod.name'] AS pod,
                argMaxIf(Value, TimeUnix, MetricName = 'k8s.pod.phase') AS phase,
                argMaxIf(Value, TimeUnix, MetricName = 'k8s.pod.cpu_limit_utilization') AS cpu_lim,
                argMaxIf(Value, TimeUnix, MetricName = 'k8s.pod.memory_limit_utilization') AS mem_lim,
                argMaxIf(Value, TimeUnix, MetricName = 'k8s.pod.memory.usage') AS mem
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR
           AND MetricName IN ('k8s.pod.phase','k8s.pod.cpu_limit_utilization',
                              'k8s.pod.memory_limit_utilization','k8s.pod.memory.usage')
           AND $__filters
         GROUP BY ns, uid, pod
       ), container_latest AS (
         SELECT ResourceAttributes['k8s.namespace.name'] AS ns,
                ResourceAttributes['k8s.pod.uid'] AS uid,
                ResourceAttributes['k8s.pod.name'] AS pod,
                ResourceAttributes['k8s.container.name'] AS container,
                argMax(Value, TimeUnix) AS restarts
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR
           AND MetricName = 'k8s.container.restarts' AND $__filters
         GROUP BY ns, uid, pod, container
       ), r AS (
         SELECT ns, uid, pod, sum(restarts) AS restarts FROM container_latest GROUP BY ns, uid, pod
       ), s AS (
         SELECT ResourceAttributes['k8s.namespace.name'] AS ns,
                ResourceAttributes['k8s.pod.uid'] AS uid,
                ResourceAttributes['k8s.pod.name'] AS pod,
                argMax(Value, TimeUnix) AS uptime
         FROM default.otel_metrics_sum
         WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.pod.uptime'
         GROUP BY ns, uid, pod
       )
       SELECT p.ns AS Namespace, p.pod AS Pod,
              multiIf(p.phase = 1, 'Pending', p.phase = 2, 'Running', p.phase = 3, 'Succeeded',
                      p.phase = 4, 'Failed', 'Unknown') AS Status,
              if(isNaN(p.cpu_lim), '-', concat(toString(round(p.cpu_lim * 100, 1)), '%')) AS "CPU/limit",
              if(isNaN(p.mem_lim), '-', concat(toString(round(p.mem_lim * 100, 1)), '%')) AS "Mem/limit",
              formatReadableSize(p.mem) AS Memory,
              formatReadableTimeDelta(toUInt64(s.uptime)) AS Age,
              toUInt64(coalesce(r.restarts, 0)) AS Restarts
       FROM p LEFT JOIN r USING (ns, uid, pod) LEFT JOIN s USING (ns, uid, pod)
       ORDER BY Restarts DESC, p.cpu_lim DESC LIMIT 100
```

</details>

### Top pods by restarts — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT ns AS Namespace, pod AS Pod, toUInt64(sum(restarts)) AS Restarts
       FROM (
         SELECT ResourceAttributes['k8s.namespace.name'] AS ns,
                ResourceAttributes['k8s.pod.uid'] AS uid,
                ResourceAttributes['k8s.pod.name'] AS pod,
                ResourceAttributes['k8s.container.name'] AS container,
                argMax(Value, TimeUnix) AS restarts
         FROM default.otel_metrics_gauge
         WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
           AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
           AND MetricName = 'k8s.container.restarts' AND $__filters
         GROUP BY ns, uid, pod, container
       )
       GROUP BY ns, pod HAVING Restarts > 0
       ORDER BY Restarts DESC LIMIT 50
```

</details>

## 8. Container Resource Utilization
Pod and container CPU/memory versus limits and requests, saturation, utilization details, and resource-pressure troubleshooting.

### Pod CPU vs limit % — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `k8s.pod.cpu_limit_utilization`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `cpu vs limit`
- **Group by:** `concat(ResourceAttributes['k8s.namespace.name'], '/', ResourceAttributes['k8s.pod.name'])`
- **Columns used:** `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.pod.name']`, `Value`, `MetricName`, `TimeUnix`

### Pod memory vs limit % — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `k8s.pod.memory_limit_utilization`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `mem vs limit`
- **Group by:** `concat(ResourceAttributes['k8s.namespace.name'], '/', ResourceAttributes['k8s.pod.name'])`
- **Columns used:** `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.pod.name']`, `Value`, `MetricName`, `TimeUnix`

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

### Node memory saturation % — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT max(used / nullIf(used + available, 0)) AS "Node memory saturation"
       FROM (
         SELECT ResourceAttributes['k8s.node.name'] AS node,
                argMaxIf(Value, TimeUnix, MetricName = 'k8s.node.memory.usage') AS used,
                argMaxIf(Value, TimeUnix, MetricName = 'k8s.node.memory.available') AS available
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR
           AND MetricName IN ('k8s.node.memory.usage', 'k8s.node.memory.available')
         GROUP BY node
       )
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

### Observed namespaces — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT uniqExact(ResourceAttributes['k8s.namespace.name']) AS "Namespaces" FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'k8s.pod.phase' AND $__filters
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

## 9. Events & Issues
Warning and critical events, top reasons, impacted resources, and recent event details for central troubleshooting.

### Warning events (in range) — number · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT count() AS "Warning events"
       FROM default.otel_logs
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND ScopeName LIKE '%k8sobjectsreceiver%'
         AND JSONExtractString(Body, 'object', 'type') = 'Warning' AND $__filters
```

</details>

### Critical events (in range) — number · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT count() AS "Critical events"
       FROM default.otel_logs
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND ScopeName LIKE '%k8sobjectsreceiver%'
         AND JSONExtractString(Body, 'object', 'type') = 'Warning'
         AND JSONExtractString(Body, 'object', 'reason') IN
             ('Failed','FailedMount','FailedScheduling','BackOff','CrashLoopBackOff','OOMKilling','NodeNotReady','Unhealthy')
         AND $__filters
```

</details>

### Impacted resources — number · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT uniqExact(concat(JSONExtractString(Body, 'object', 'regarding', 'kind'), '/',
                                JSONExtractString(Body, 'object', 'regarding', 'name'))) AS Resources
       FROM default.otel_logs
       WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
         AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
         AND ScopeName LIKE '%k8sobjectsreceiver%'
         AND JSONExtractString(Body, 'object', 'type') = 'Warning' AND $__filters
```

</details>

### Top Kubernetes event reasons / impacted resources — table · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT JSONExtractString(Body, 'object', 'reason') AS Reason, JSONExtractString(Body, 'object', 'regarding', 'namespace') AS Namespace, count() AS Events, uniqExact(concat(JSONExtractString(Body, 'object', 'regarding', 'kind'), '/', JSONExtractString(Body, 'object', 'regarding', 'name'))) AS "Impacted resources", max(Timestamp) AS "Last seen" FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND ScopeName LIKE '%k8sobjectsreceiver%' AND $__filters GROUP BY Reason, Namespace ORDER BY Events DESC LIMIT 50
```

</details>

### Recent Kubernetes warning events — table · Raw SQL

- **Tables:** `default.otel_logs`

<details><summary>SQL query</summary>

```sql
SELECT Timestamp, JSONExtractString(Body, 'object', 'reason') AS Reason, JSONExtractString(Body, 'object', 'regarding', 'namespace') AS Namespace, concat(JSONExtractString(Body, 'object', 'regarding', 'kind'), ' ', JSONExtractString(Body, 'object', 'regarding', 'name')) AS Resource, substring(JSONExtractString(Body, 'object', 'note'), 1, 240) AS Message FROM default.otel_logs WHERE Timestamp >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND Timestamp <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND ScopeName LIKE '%k8sobjectsreceiver%' AND JSONExtractString(Body, 'object', 'type') = 'Warning' AND $__filters ORDER BY Timestamp DESC LIMIT 100
```

</details>

## 10. Utilization Analysis
Cross-resource consumption, saturation, top consumers, hotspots, and bottlenecks across compute, storage, networking, and Kubernetes.

### Top CPU and memory consumers — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
WITH cpu AS (SELECT host, avg(busy) AS cpu_used FROM (SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix, sumIf(Value, Attributes['state'] != 'idle') AS busy FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.cpu.utilization' AND $__filters GROUP BY host, cpu, TimeUnix) GROUP BY host), mem AS (SELECT ResourceAttributes['host.name'] AS host, avgIf(Value, Attributes['state'] = 'used') AS memory_used FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.memory.utilization' AND $__filters GROUP BY host) SELECT cpu.host AS Host, round(100 * cpu.cpu_used, 1) AS "CPU %", round(100 * mem.memory_used, 1) AS "Memory %", if(cpu.cpu_used >= 0.9 OR mem.memory_used >= 0.9, 'Critical', if(cpu.cpu_used >= 0.75 OR mem.memory_used >= 0.8, 'Warning', 'Healthy')) AS Status FROM cpu LEFT JOIN mem USING (host) ORDER BY Status ASC, "CPU %" DESC, "Memory %" DESC
```

</details>

### Top storage consumers — table · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT Host, Volume,
              formatReadableSize(sumIf(value, state = 'used')) AS Used,
              formatReadableSize(sumIf(value, state = 'free')) AS Free,
              round(100 * sumIf(value, state = 'used') / nullIf(sum(value), 0), 1) AS "Used %"
       FROM (
         SELECT ResourceAttributes['host.name'] AS Host,
                Attributes['mountpoint'] AS Volume,
                Attributes['state'] AS state,
                argMax(Value, TimeUnix) AS value
         FROM default.otel_metrics_sum
         WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
           AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
           AND MetricName = 'system.filesystem.usage' AND $__filters
         GROUP BY Host, Volume, state
       )
       GROUP BY Host, Volume ORDER BY "Used %" DESC
```

</details>

### Cross-resource hotspots & bottlenecks — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
WITH host_cpu AS (
         SELECT host AS Resource, 'Host CPU' AS Type, cpu AS Utilization FROM (
           SELECT host, avg(busy) AS cpu FROM (
             SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu_id, TimeUnix,
                    sumIf(Value, Attributes['state'] != 'idle') AS busy
             FROM default.otel_metrics_gauge
             WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.cpu.utilization'
             GROUP BY host, cpu_id, TimeUnix
           ) GROUP BY host
         )
       ), host_mem AS (
         SELECT ResourceAttributes['host.name'] AS Resource, 'Host memory' AS Type,
                argMaxIf(Value, TimeUnix, Attributes['state'] = 'used') AS Utilization
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.memory.utilization'
         GROUP BY Resource
       ), pod_cpu AS (
         SELECT concat(ResourceAttributes['k8s.namespace.name'], '/', ResourceAttributes['k8s.pod.name']) AS Resource,
                'Pod CPU/limit' AS Type, argMax(Value, TimeUnix) AS Utilization
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.pod.cpu_limit_utilization'
         GROUP BY Resource
       ), pod_mem AS (
         SELECT concat(ResourceAttributes['k8s.namespace.name'], '/', ResourceAttributes['k8s.pod.name']) AS Resource,
                'Pod memory/limit' AS Type, argMax(Value, TimeUnix) AS Utilization
         FROM default.otel_metrics_gauge
         WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'k8s.pod.memory_limit_utilization'
         GROUP BY Resource
       )
       SELECT Resource, Type, concat(toString(round(utilization_ratio * 100, 1)), '%') AS Utilization,
              multiIf(utilization_ratio >= 0.95, 'Critical',
                      utilization_ratio >= 0.8, 'Warning', 'Healthy') AS Status
       FROM (
         SELECT Resource, Type, Utilization AS utilization_ratio FROM host_cpu
         UNION ALL SELECT Resource, Type, Utilization FROM host_mem
         UNION ALL SELECT Resource, Type, Utilization FROM pod_cpu
         UNION ALL SELECT Resource, Type, Utilization FROM pod_mem
       )
       ORDER BY utilization_ratio DESC LIMIT 100
```

</details>

## 11. Capacity Planning
CPU, memory, and storage headroom; growth trends; capacity forecasts; exhaustion risks; and scale recommendations.

### CPU headroom % (100 - cluster busy) — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT ts, 1 - avg(b) AS "CPU headroom" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix,
         sumIf(Value, Attributes['state'] != 'idle') AS b
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.cpu.utilization' AND $__filters
  GROUP BY ts, host, cpu, TimeUnix
) GROUP BY ts ORDER BY ts
```

</details>

### Memory headroom % (100 - used) — line · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts, 1 - avgIf(Value, Attributes['state'] = 'used') AS "Memory headroom"
FROM default.otel_metrics_gauge
WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.memory.utilization' AND $__filters
GROUP BY ts ORDER BY ts
```

</details>

### Disk free % per volume over time — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, volume, avail / nullIf(total, 0) AS "Disk free" FROM (
  SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
    concat(ResourceAttributes['host.name'], ' ', Attributes['mountpoint']) AS volume,
    sumIf(Value, Attributes['state'] = 'free') AS avail,
    sum(Value) AS total
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'system.filesystem.usage'
  GROUP BY ts, volume
) WHERE total > 0 ORDER BY ts
```

</details>

### Storage growth forecast / estimated exhaustion risk — table · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH points AS (SELECT host, mountpoint AS volume, toStartOfHour(TimeUnix) AS ts, avg(used / nullIf(total, 0)) AS used_ratio FROM (SELECT ResourceAttributes['host.name'] AS host, Attributes['mountpoint'] AS mountpoint, TimeUnix, sumIf(Value, Attributes['state'] = 'used') AS used, sum(Value) AS total FROM default.otel_metrics_sum WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.filesystem.usage' AND $__filters GROUP BY host, mountpoint, TimeUnix) GROUP BY host, volume, ts), slopes AS (SELECT host, volume, argMax(used_ratio, ts) AS current_used, covarPop(toUnixTimestamp(ts), used_ratio) / nullIf(varPop(toUnixTimestamp(ts)), 0) AS slope_per_second FROM points GROUP BY host, volume) SELECT host AS Host, volume AS Volume, round(100 * current_used, 1) AS "Current used %", round(slope_per_second * 86400 * 100, 3) AS "Growth % / day", if(slope_per_second <= 0, 'No exhaustion trend', concat(toString(round((1 - current_used) / slope_per_second / 86400, 1)), ' days')) AS "Estimated time to full" FROM slopes ORDER BY slope_per_second DESC
```

</details>

### Capacity risk summary & scale recommendations — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH cpu AS (SELECT host, avg(busy) AS used FROM (SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix, sumIf(Value, Attributes['state'] != 'idle') AS busy FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.cpu.utilization' GROUP BY host, cpu, TimeUnix) GROUP BY host), mem AS (SELECT ResourceAttributes['host.name'] AS host, avgIf(Value, Attributes['state'] = 'used') AS used FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.memory.utilization' GROUP BY host), disk AS (SELECT host, max(used / nullIf(total, 0)) AS used FROM (SELECT ResourceAttributes['host.name'] AS host, Attributes['mountpoint'] AS volume, sumIf(Value, Attributes['state'] = 'used') AS used, sum(Value) AS total FROM default.otel_metrics_sum WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.filesystem.usage' GROUP BY host, volume) GROUP BY host) SELECT cpu.host AS Host, round(100 * (1 - cpu.used), 1) AS "CPU headroom %", round(100 * (1 - mem.used), 1) AS "Memory headroom %", round(100 * (1 - disk.used), 1) AS "Storage headroom %", if(disk.used >= 0.9, 'Expand storage / tighten retention', if(cpu.used >= 0.9, 'Add compute capacity', if(mem.used >= 0.9, 'Add memory capacity', if(cpu.used >= 0.75 OR mem.used >= 0.8 OR disk.used >= 0.8, 'Plan scale-up', 'No scale action')))) AS Recommendation FROM cpu LEFT JOIN mem USING (host) LEFT JOIN disk USING (host) ORDER BY "Storage headroom %", "Memory headroom %", "CPU headroom %"
```

</details>
