# AldoTel · Executive Overview

> Auto-generated reference (do not edit by hand — run `node gen-docs.js`).

This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/executive-overview.json` · tag `tmpl:exec-overview`
- **Data required:** Application traces (OTLP), application/container logs, ClickHouse metrics and K8s metrics — this is a cross-cutting roll-up; tiles degrade gracefully when a given signal is absent

## Preview

![AldoTel · Executive Overview](images/executive-overview.png)

_Live capture from a ClickStack install with the OpenTelemetry demo flowing._

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Service | `ServiceName` | Traces (`default.otel_traces`) |
| Namespace | `ResourceAttributes['k8s.namespace.name']` | Metrics (`default.otel_metrics_{gauge|sum|histogram}`) |

## Service health — at a glance

### Span error rate (%) — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** avg(`if(StatusCode = 'Error', 1, 0)`)
- **Columns used:** `StatusCode`

### Trace volume (spans) — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*)

### Span latency p95 — number

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** quantile(`Duration / 1000000000`)
- **Columns used:** `Duration`

### Log error rate (%) — number

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** avg(`if(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'), 1, 0)`)
- **Columns used:** `SeverityText`

## Platform — at a glance

### ClickHouse failed queries — number · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT sum(d) AS "Failed queries" FROM (
  SELECT max(Value) - min(Value) AS d
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'ClickHouseProfileEvents_FailedQuery'
  GROUP BY ResourceAttributes['service.instance.id']
)
```

</details>

### ClickHouse running queries — number · Raw SQL

- **Tables:** `default.otel_metrics_gauge`

<details><summary>SQL query</summary>

```sql
SELECT sum(v) AS "Running queries" FROM (
  SELECT argMax(Value, TimeUnix) AS v
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'ClickHouseMetrics_Query'
  GROUP BY ResourceAttributes['service.instance.id']
)
```

</details>

### K8s nodes ready — number · Raw SQL

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

### Collector refused spans — number · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT sum(d) AS "Refused spans" FROM (
  SELECT max(Value) - min(Value) AS d
  FROM default.otel_metrics_sum
  WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
    AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
    AND MetricName = 'otelcol_receiver_refused_spans_total'
  GROUP BY ResourceAttributes['service.instance.id']
)
```

</details>

## Top services

### Services by error rate — click a row to open Traces — table

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `spans`; avg(`if(StatusCode = 'Error', 100, 0)`) as `err_pct`
- **Group by:** `ServiceName`
- **Order by:** `err_pct DESC`
- **Drill-down:** click a row → opens search
- **Columns used:** `ServiceName`, `StatusCode`

### Services by log errors — click a row to open Logs — table

- **Source / table:** Logs → `default.otel_logs`
- **Measure(s):** count(*) as `logs`; sum(`if(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'), 1, 0)`) as `errors`
- **Group by:** `ServiceName`
- **Order by:** `errors DESC`
- **Drill-down:** click a row → opens search
- **Columns used:** `ServiceName`, `SeverityText`

## Traffic & ingest

### Ingest throughput — spans accepted vs refused — line · Raw SQL

- **Tables:** `default.otel_metrics_sum`

<details><summary>SQL query</summary>

```sql
SELECT ts, kind, sum(greatest(cum - prev, 0)) AS value FROM (
  SELECT ts, inst, kind, cum, lagInFrame(cum, 1, cum) OVER (PARTITION BY kind, inst ORDER BY ts) AS prev
  FROM (
    SELECT toStartOfInterval(TimeUnix, INTERVAL {intervalSeconds:Int64} SECOND) AS ts,
           ResourceAttributes['service.instance.id'] AS inst,
           if(MetricName = 'otelcol_receiver_accepted_spans_total', 'accepted', 'refused') AS kind,
           max(Value) AS cum
    FROM default.otel_metrics_sum
    WHERE TimeUnix >= fromUnixTimestamp64Milli({startDateMilliseconds:Int64})
      AND TimeUnix <= fromUnixTimestamp64Milli({endDateMilliseconds:Int64})
      AND MetricName IN ('otelcol_receiver_accepted_spans_total', 'otelcol_receiver_refused_spans_total')
    GROUP BY ts, inst, kind
  )
)
GROUP BY ts, kind
ORDER BY ts
```

</details>

### Request rate & errors (traces) — line

- **Source / table:** Traces → `default.otel_traces`
- **Measure(s):** count(*) as `requests`; sum(`if(StatusCode = 'Error', 1, 0)`) as `errors`
- **Columns used:** `StatusCode`
