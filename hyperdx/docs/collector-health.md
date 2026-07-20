# AldoTel · OTel Collector — Pipeline Health

> Auto-generated reference (do not edit by hand — run `node gen-docs.js`).

This page lists the ClickHouse tables and columns behind every visual on the dashboard.

[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · [Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)

- **Template:** `dashboards/collector-health.json` · tag `tmpl:collector-health`
- **Data required:** OTel Collector internal telemetry scraped into OTel (Prometheus receiver on the collector's :8888 self-metrics)

## Preview

![AldoTel · OTel Collector — Pipeline Health](images/collector-health.png)

_Live capture from a ClickStack install with the OpenTelemetry demo flowing._

## Dashboard filters

These apply to every compatible tile on the dashboard.

| Filter | Column / expression | Source |
|---|---|---|
| Collector | `ResourceAttributes['service.instance.id']` | Metrics (`default.otel_metrics_{gauge|sum|histogram}`) |

## Pipeline — at a glance

### Refused spans (should be 0) — number

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `otelcol_receiver_refused_spans_total`  (column `MetricName`)
- **Measure(s):** sum(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Failed spans (should be 0) — number

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `otelcol_receiver_failed_spans_total`  (column `MetricName`)
- **Measure(s):** sum(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Exporter queue size — number

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `otelcol_exporter_queue_size`  (column `MetricName`)
- **Measure(s):** last_value(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Exporter in-flight requests — number

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `otelcol_exporter_in_flight_requests`  (column `MetricName`)
- **Measure(s):** last_value(`Value`)
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

## Traces pipeline

### Spans: accepted vs refused vs failed — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `otelcol_receiver_accepted_spans_total`, `otelcol_receiver_refused_spans_total`, `otelcol_receiver_failed_spans_total`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `accepted`; sum(`Value`) as `refused`; sum(`Value`) as `failed`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Exporter sent spans — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `otelcol_exporter_sent_spans_total`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `sent`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Exporter queue size vs capacity — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `otelcol_exporter_queue_size`, `otelcol_exporter_queue_capacity`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `queue size`; max(`Value`) as `capacity`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Processor incoming vs outgoing items (gap = dropped) — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `otelcol_processor_incoming_items_total`, `otelcol_processor_outgoing_items_total`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `incoming`; sum(`Value`) as `outgoing`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

## Logs & metrics pipeline

### Accepted log records vs metric points — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `otelcol_receiver_accepted_log_records_total`, `otelcol_receiver_accepted_metric_points_total`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `log records`; sum(`Value`) as `metric points`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Scraper: scraped vs errored metric points — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `otelcol_scraper_scraped_metric_points`, `otelcol_scraper_errored_metric_points`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `scraped`; sum(`Value`) as `errored`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

## Collector resources

### Collector memory (RSS / heap) — line

- **Source / table:** Metrics → `default.otel_metrics_gauge`
- **Metric(s):** `otelcol_process_memory_rss_bytes`, `otelcol_process_runtime_heap_alloc_bytes`  (column `MetricName`)
- **Measure(s):** max(`Value`) as `rss`; max(`Value`) as `heap alloc`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`

### Collector CPU seconds (rate) — line

- **Source / table:** Metrics → `default.otel_metrics_sum`
- **Metric(s):** `otelcol_process_cpu_seconds_total`  (column `MetricName`)
- **Measure(s):** sum(`Value`) as `cpu seconds`
- **Columns used:** `Value`, `MetricName`, `TimeUnix`
