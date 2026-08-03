# ClickStack - Infrastructure

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/infrastructure.json` · tag `tmpl:infrastructure`
- **Data required:** hostmetrics receiver (system.* scrapers: cpu, memory, load, swap, disk, network); kubeletstats + k8s_cluster receivers (k8s.node.* for node/cluster health and filesystem)

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Host | `ResourceAttributes['host.name']` | Metrics (`default.otel_metrics_{gauge|sum|histogram}`) |

## Infrastructure Health
The physical/virtual foundation under the appliance: cluster & node health, node/host compute and memory, storage (filesystem, IOPS, latency), network (throughput, drops, errors), and capacity headroom. Compute values are absolute usage vs each node/host capacity.

## Cluster health
Are all nodes Ready? Healthy vs. NotReady counts and per-node status, CPU, memory, and uptime.

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

## Node health (hosts)
Per-host CPU, load average, memory, and swap for the machines running the cluster.

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

## Storage health
Filesystem usage and free capacity, disk IOPS, read/write latency, and throughput per node.

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

## Network health
Per-host network throughput, dropped packets, and interface errors.

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

## Capacity planning
Remaining headroom — how much CPU, memory, and disk is still free before saturation.

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
