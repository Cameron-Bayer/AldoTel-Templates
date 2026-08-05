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

## Infrastructure Overview
Overall infrastructure health plus compute, memory, hosts, storage, networking, utilization analysis, and capacity planning. Values come from appliance hostmetrics and Kubernetes node health.

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
  SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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
SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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
SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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
  SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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
  concat(toString(round(c.cpu * 100, 2)), '%') AS "CPU busy",
  concat(toString(round(m.mem * 100, 2)), '%') AS "Mem used",
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
  SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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
SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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
SELECT ts, concat(host, ' · ', direction) AS series, sum(d) / greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))) AS "IOPS" FROM (
  SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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
    SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts, ResourceAttributes['host.name'] AS host, Attributes['direction'] AS direction,
           greatest(Value - lagInFrame(Value, 1, Value) OVER (
             PARTITION BY ResourceAttributes['host.name'], Attributes['device'], Attributes['direction'] ORDER BY TimeUnix), 0) AS d
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.disk.operation_time' AND $__filters
  ) GROUP BY ts, host, direction
),
o AS (
  SELECT ts, host, direction, sum(d) AS ops FROM (
    SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts, ResourceAttributes['host.name'] AS host, Attributes['direction'] AS direction,
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
SELECT ts, concat(host, ' · ', direction) AS series, sum(d) / greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))) AS "Bytes/sec" FROM (
  SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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
SELECT ts, concat(host, ' · ', direction) AS series, sum(d) / greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))) AS "Bytes/sec" FROM (
  SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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
SELECT ts, concat(host, ' · ', direction) AS series, sum(d) / greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))) AS "Dropped/sec" FROM (
  SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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
SELECT ts, concat(host, ' · ', direction) AS series, sum(d) / greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))) AS "Errors/sec" FROM (
  SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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
  SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts, ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix,
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
SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts, 1 - avgIf(Value, Attributes['state'] = 'used') AS "Memory headroom"
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
SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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
  SELECT toStartOfInterval(TimeUnix, toIntervalSecond(greatest(toInt64(1), intDiv({endDateMilliseconds:Int64} - {startDateMilliseconds:Int64}, toInt64(120000))))) AS ts,
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

## Utilization Analysis
Cross-resource consumption, saturation, top consumers, hotspots, and bottlenecks.

### Top CPU and memory consumers — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
WITH cpu AS (SELECT host, avg(busy) AS cpu_used FROM (SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix, sumIf(Value, Attributes['state'] != 'idle') AS busy FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.cpu.utilization' AND $__filters GROUP BY host, cpu, TimeUnix) GROUP BY host), mem AS (SELECT ResourceAttributes['host.name'] AS host, avgIf(Value, Attributes['state'] = 'used') AS memory_used FROM default.otel_metrics_gauge WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.memory.utilization' AND $__filters GROUP BY host) SELECT cpu.host AS Host, round(100 * cpu.cpu_used, 2) AS "CPU %", round(100 * mem.memory_used, 2) AS "Memory %", if(cpu.cpu_used >= 0.9 OR mem.memory_used >= 0.9, 'Critical', if(cpu.cpu_used >= 0.75 OR mem.memory_used >= 0.8, 'Warning', 'Healthy')) AS Status FROM cpu LEFT JOIN mem USING (host)         ORDER BY Status ASC, cpu.cpu_used DESC, mem.memory_used DESC
```

</details>

### Top storage consumers — table · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ResourceAttributes['host.name'] AS Host, Attributes['mountpoint'] AS Volume, formatReadableSize(sumIf(Value, Attributes['state'] = 'used')) AS Used, formatReadableSize(sumIf(Value, Attributes['state'] = 'free')) AS Free, round(100 * sumIf(Value, Attributes['state'] = 'used') / nullIf(sum(Value), 0), 2) AS "Used %" FROM default.otel_metrics_sum WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.filesystem.usage' AND $__filters         GROUP BY Host, Volume ORDER BY sumIf(Value, Attributes['state'] = 'used') / nullIf(sum(Value), 0) DESC
```

</details>

### Top network consumers and reliability — table · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH io AS (SELECT host, interface, sum(max_value - min_value) AS bytes FROM (SELECT ResourceAttributes['host.name'] AS host, Attributes['interface'] AS interface, Attributes['direction'] AS direction, max(Value) AS max_value, min(Value) AS min_value FROM default.otel_metrics_sum WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.network.io' AND $__filters GROUP BY host, interface, direction) GROUP BY host, interface), dropped AS (SELECT host, interface, sum(max_value - min_value) AS dropped FROM (SELECT ResourceAttributes['host.name'] AS host, Attributes['interface'] AS interface, Attributes['direction'] AS direction, max(Value) AS max_value, min(Value) AS min_value FROM default.otel_metrics_sum WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.network.dropped' AND $__filters GROUP BY host, interface, direction) GROUP BY host, interface) SELECT io.host AS Host, io.interface AS Interface, formatReadableSize(io.bytes) AS Traffic, dropped.dropped AS "Packets dropped" FROM io LEFT JOIN dropped USING (host, interface) ORDER BY io.bytes DESC
```

</details>

## Capacity Planning
CPU, memory, and storage headroom, growth trends, exhaustion risks, and scale guidance. The time-series panels above provide historical trends; the risk table turns current headroom into actionable recommendations.

### Capacity risk summary & scale recommendations — table · Raw SQL

- **Tables:** `default.otel_metrics_gauge`, `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH cpu AS (SELECT host, avg(busy) AS used FROM (SELECT ResourceAttributes['host.name'] AS host, Attributes['cpu'] AS cpu, TimeUnix, sumIf(Value, Attributes['state'] != 'idle') AS busy FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.cpu.utilization' GROUP BY host, cpu, TimeUnix) GROUP BY host), mem AS (SELECT ResourceAttributes['host.name'] AS host, avgIf(Value, Attributes['state'] = 'used') AS used FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.memory.utilization' GROUP BY host), disk AS (SELECT host, max(used / nullIf(total, 0)) AS used FROM (SELECT ResourceAttributes['host.name'] AS host, Attributes['mountpoint'] AS volume, sumIf(Value, Attributes['state'] = 'used') AS used, sum(Value) AS total FROM default.otel_metrics_sum WHERE TimeUnix > now() - INTERVAL 1 HOUR AND MetricName = 'system.filesystem.usage' GROUP BY host, volume) GROUP BY host) SELECT cpu.host AS Host, round(100 * (1 - cpu.used), 2) AS "CPU headroom %", round(100 * (1 - mem.used), 2) AS "Memory headroom %", round(100 * (1 - disk.used), 2) AS "Storage headroom %", if(disk.used >= 0.9, 'Expand storage / tighten retention', if(cpu.used >= 0.9, 'Add compute capacity', if(mem.used >= 0.9, 'Add memory capacity', if(cpu.used >= 0.75 OR mem.used >= 0.8 OR disk.used >= 0.8, 'Plan scale-up', 'No scale action')))) AS Recommendation FROM cpu LEFT JOIN mem USING (host) LEFT JOIN disk USING (host)         ORDER BY disk.used DESC, mem.used DESC, cpu.used DESC
```

</details>

### Storage growth forecast / estimated exhaustion risk — table · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
WITH points AS (SELECT host, mountpoint AS volume, toStartOfHour(TimeUnix) AS ts, avg(used / nullIf(total, 0)) AS used_ratio FROM (SELECT ResourceAttributes['host.name'] AS host, Attributes['mountpoint'] AS mountpoint, TimeUnix, sumIf(Value, Attributes['state'] = 'used') AS used, sum(Value) AS total FROM default.otel_metrics_sum WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64}) AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64}) AND MetricName = 'system.filesystem.usage' AND $__filters GROUP BY host, mountpoint, TimeUnix) GROUP BY host, volume, ts), slopes AS (SELECT host, volume, argMax(used_ratio, ts) AS current_used, covarPop(toUnixTimestamp(ts), used_ratio) / nullIf(varPop(toUnixTimestamp(ts)), 0) AS slope_per_second FROM points GROUP BY host, volume) SELECT host AS Host, volume AS Volume, round(100 * current_used, 2) AS "Current used %", round(slope_per_second * 86400 * 100, 2) AS "Growth % / day", if(slope_per_second <= 0, 'No exhaustion trend', concat(toString(round((1 - current_used) / slope_per_second / 86400, 2)), ' days')) AS "Estimated time to full" FROM slopes ORDER BY slope_per_second DESC
```

</details>
