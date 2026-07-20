# AldoTel · ClickHouse — Keeper & Replication

> Auto-generated reference (do not edit by hand — run `node gen-docs.js`).

This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/clickhouse-keeper-replication.json` · tag `tmpl:ch-keeper`
- **Data required:** ClickHouse metrics scraped into OTel (Keeper gauges/ProfileEvents); Replication tables read system.replicas / system.replication_queue via Raw SQL — these are empty on single-node installs and populate only on replicated/clustered ClickHouse

## Preview

![AldoTel · ClickHouse — Keeper & Replication](images/clickhouse-keeper-replication.png)

_Live capture from a ClickStack install with the OpenTelemetry demo flowing._

## Keeper — at a glance

### Active sessions — number

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_ZooKeeperSession`  (column `MetricName`)
- **Measure(s):** last_value(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Watches — number

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_ZooKeeperWatch`  (column `MetricName`)
- **Measure(s):** last_value(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Outstanding requests — number

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_KeeperOutstandingRequests`  (column `MetricName`)
- **Measure(s):** last_value(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Alive connections — number

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_KeeperAliveConnections`  (column `MetricName`)
- **Measure(s):** last_value(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

## Throughput & latency

### Keeper request rate by type — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `ClickHouseProfileEvents_KeeperGetRequest`, `ClickHouseProfileEvents_KeeperListRequest`, `ClickHouseProfileEvents_KeeperCreateRequest`, `ClickHouseProfileEvents_KeeperRemoveRequest`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `get`; sum(`Value`) as `list`; sum(`Value`) as `create`; sum(`Value`) as `remove`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Commits vs failed commits — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `ClickHouseProfileEvents_KeeperCommits`, `ClickHouseProfileEvents_KeeperCommitsFailed`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `commits`; sum(`Value`) as `failed`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Packets received / sent — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `ClickHouseProfileEvents_KeeperPacketsReceived`, `ClickHouseProfileEvents_KeeperPacketsSent`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `received`; sum(`Value`) as `sent`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### In-flight requests & watches — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `ClickHouseMetrics_ZooKeeperRequest`, `ClickHouseMetrics_ZooKeeperWatch`  (column `MetricName`)
- **Measure(s):** avg(`Value`) as `in_flight_requests`; avg(`Value`) as `watches`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Keeper commit-wait & process time (µs) — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `ClickHouseProfileEvents_KeeperCommitWaitElapsedMicroseconds`, `ClickHouseProfileEvents_KeeperProcessElapsedMicroseconds`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `commit_wait_us`; sum(`Value`) as `process_us`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Keeper / ZooKeeper errors (last 24h) — table · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT replaceOne(MetricName, 'ClickHouseErrorMetric_', '') AS error,
       toUInt64(max(Value) - min(Value)) AS errors_in_window
FROM default.otel_metrics_sum
WHERE (MetricName LIKE '%ZOOKEEPER%' OR MetricName LIKE '%KEEPER%')
  AND MetricName LIKE 'ClickHouseErrorMetric_%'
  AND TimeUnix > now() - INTERVAL 24 HOUR
GROUP BY error
HAVING errors_in_window > 0
ORDER BY errors_in_window DESC
LIMIT 20
```

</details>

## Replication
The tables below populate only on **replicated / clustered** ClickHouse installs (`ReplicatedMergeTree`). On a single-node ClickStack they are expected to be empty — that is healthy, not an error. Non-empty `replication_queue` rows or a growing `absolute_delay` indicate a replica falling behind.

### Replica status — table · Raw SQL

- **Tables:** `system.replicas`

<details><summary>SQL query</summary>

```sql
SELECT database,
       table,
       is_leader,
       is_readonly,
       absolute_delay,
       queue_size,
       inserts_in_queue,
       merges_in_queue,
       total_replicas,
       active_replicas
FROM system.replicas
ORDER BY absolute_delay DESC, queue_size DESC
LIMIT 30
```

</details>

### Replication queue (stuck tasks) — table · Raw SQL

- **Tables:** `system.replication_queue`

<details><summary>SQL query</summary>

```sql
SELECT database,
       table,
       type,
       num_tries,
       num_postponed,
       last_exception,
       create_time
FROM system.replication_queue
ORDER BY num_tries DESC
LIMIT 30
```

</details>
