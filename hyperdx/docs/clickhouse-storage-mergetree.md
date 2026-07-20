# AldoTel · ClickHouse — Storage & MergeTree

> Auto-generated reference (do not edit by hand — run `node gen-docs.js`).

This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/clickhouse-storage-mergetree.json` · tag `tmpl:ch-storage`
- **Data required:** All tiles read system.parts / system.part_log via Raw SQL — the HyperDX ClickHouse connection user must be able to SELECT from system.parts and system.part_log (part_log must be enabled, which it is by default)

## Preview

![AldoTel · ClickHouse — Storage & MergeTree](images/clickhouse-storage-mergetree.png)

_Live capture from a ClickStack install with the OpenTelemetry demo flowing._

## Storage — at a glance

### Disk used (active parts) — number · Raw SQL

- **Tables:** `system.parts`

<details><summary>SQL query</summary>

```sql
SELECT sum(bytes_on_disk) FROM system.parts WHERE active
```

</details>

### Compression ratio (uncompressed / compressed) — number · Raw SQL

- **Tables:** `system.parts`

<details><summary>SQL query</summary>

```sql
SELECT round(sum(data_uncompressed_bytes) / nullIf(sum(data_compressed_bytes), 0), 2) FROM system.parts WHERE active
```

</details>

### Active parts (total) — number · Raw SQL

- **Tables:** `system.parts`

<details><summary>SQL query</summary>

```sql
SELECT count() FROM system.parts WHERE active
```

</details>

### Rows stored (active) — number · Raw SQL

- **Tables:** `system.parts`

<details><summary>SQL query</summary>

```sql
SELECT sum(rows) FROM system.parts WHERE active
```

</details>

## Throughput & merges

### Part events / 5 min (inserts, merges, mutations) — stacked_bar · Raw SQL

- **Tables:** `system.part_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL 5 MINUTE) AS t,
       countIf(event_type = 'NewPart') AS new_parts,
       countIf(event_type = 'MergeParts') AS merges,
       countIf(event_type = 'MutatePart') AS mutations
FROM system.part_log
WHERE event_time > now() - INTERVAL 6 HOUR
GROUP BY t
ORDER BY t
```

</details>

### Merge duration — p95 / max — line · Raw SQL

- **Tables:** `system.part_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL 5 MINUTE) AS t,
       quantile(0.95)(duration_ms) / 1000 AS p95,
       max(duration_ms) / 1000 AS max
FROM system.part_log
WHERE event_type = 'MergeParts' AND event_time > now() - INTERVAL 6 HOUR
GROUP BY t
ORDER BY t
```

</details>

### Bytes written — inserted vs merged / 5 min — line · Raw SQL

- **Tables:** `system.part_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL 5 MINUTE) AS t,
       sumIf(size_in_bytes, event_type = 'NewPart') AS inserted_bytes,
       sumIf(size_in_bytes, event_type = 'MergeParts') AS merged_bytes
FROM system.part_log
WHERE event_time > now() - INTERVAL 6 HOUR
GROUP BY t
ORDER BY t
```

</details>

### Rows processed — inserted vs merged / 5 min — line · Raw SQL

- **Tables:** `system.part_log`

<details><summary>SQL query</summary>

```sql
SELECT toStartOfInterval(event_time, INTERVAL 5 MINUTE) AS t,
       sumIf(rows, event_type = 'NewPart') AS inserted_rows,
       sumIf(rows, event_type = 'MergeParts') AS merged_rows
FROM system.part_log
WHERE event_time > now() - INTERVAL 6 HOUR
GROUP BY t
ORDER BY t
```

</details>

## Tables & parts

### Largest tables by disk — table · Raw SQL

- **Tables:** `system.parts`

<details><summary>SQL query</summary>

```sql
SELECT database,
       table,
       formatReadableSize(sum(bytes_on_disk)) AS disk,
       sum(rows) AS rows,
       count() AS parts,
       round(sum(data_uncompressed_bytes) / nullIf(sum(data_compressed_bytes), 0), 2) AS compression
FROM system.parts
WHERE active
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 30
```

</details>

### Active parts per table (too-many-parts watch) — table · Raw SQL

- **Tables:** `system.parts`

<details><summary>SQL query</summary>

```sql
SELECT database,
       table,
       count() AS active_parts,
       sum(marks) AS marks,
       any(part_type) AS part_type,
       formatReadableSize(avg(bytes_on_disk)) AS avg_part_size
FROM system.parts
WHERE active
GROUP BY database, table
ORDER BY active_parts DESC
LIMIT 30
```

</details>

### Recent merges (last 6h) — table · Raw SQL

- **Tables:** `system.part_log`

<details><summary>SQL query</summary>

```sql
SELECT event_time,
       database || '.' || table AS tbl,
       duration_ms,
       rows,
       formatReadableSize(size_in_bytes) AS size,
       merge_reason,
       if(error = 0, 'ok', toString(error)) AS status
FROM system.part_log
WHERE event_type = 'MergeParts' AND event_time > now() - INTERVAL 6 HOUR
ORDER BY event_time DESC
LIMIT 30
```

</details>
