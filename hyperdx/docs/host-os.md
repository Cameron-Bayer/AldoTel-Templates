# ClickStack - Host / OS Metrics

> This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/host-os.json` · tag `tmpl:host-os`
- **Data required:** hostmetrics receiver (system.* scrapers: cpu, memory, load, disk, network, paging)

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Host | `ResourceAttributes['host.name']` | Metrics (`default.otel_metrics_{gauge|sum|histogram}`) |

## Host / OS health
Per-host CPU, load, memory, swap, disk, and network from the OpenTelemetry hostmetrics receiver (`system.*`). Use the **Host** filter and the time range to focus on specific machines. Watch for sustained CPU or memory pressure, any swap usage, load above the host's CPU-core count, and unusual disk or network spikes.

## CPU & load
Host CPU and load average from the OpenTelemetry hostmetrics receiver (`system.*`). CPU busy = 1 − idle, averaged across cores per host — investigate values sustained above ~85%. Load average counts the tasks running or waiting to run (it is **not** a percentage); compare it with the host's CPU-core count, since sustained load above that count means work is queuing.

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

## Memory & swap
Memory and swap utilization per host. Investigate memory sustained above ~85%; any persistent swap usage usually signals memory pressure.

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
GROUP BY ts, host
ORDER BY ts
```

</details>

## Disk & network
Throughput is the per-second rate of the cumulative `system.disk.io` / `system.network.io` byte counters (per host, split by direction).

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

## Hosts

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
