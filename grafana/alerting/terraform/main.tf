# ClickStack Grafana alerts — Terraform
# ============================================================================
# Creates the same 10 alert rules, the alert contact point, and the notification
# policy as the provisioning YAML in the parent folder — but through the Grafana
# HTTP API. Use this when you CANNOT drop files into /etc/grafana/provisioning
# (e.g. Grafana Cloud, or a locked-down managed Grafana).
#
# Quick start:
#   1. cp terraform.tfvars.example terraform.tfvars   # then edit it
#   2. terraform init
#   3. terraform apply
#
# See README.md in this folder for details.

terraform {
  required_version = ">= 1.3"
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.0"
    }
  }
}

provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_auth
}

# ----------------------------------------------------------------------------
# Folder that holds the alert rules
# ----------------------------------------------------------------------------
resource "grafana_folder" "clickstack_alerts" {
  title = "ClickStack Alerts"
}

# ----------------------------------------------------------------------------
# Contact point: generic webhook. Paste your own on-call webhook URL — a Slack
# incoming webhook, a Teams Workflow URL, PagerDuty, Discord, or any HTTP endpoint.
# ----------------------------------------------------------------------------
resource "grafana_contact_point" "clickstack_alerts" {
  name = "ClickStack Alerts"

  webhook {
    url                     = var.alert_webhook_url
    disable_resolve_message = false
  }
}

# ----------------------------------------------------------------------------
# Notification policy: route stack=clickstack alerts to the ClickStack contact point.
# NOTE: grafana_notification_policy manages the org's ROOT policy. The root
# contact point stays "grafana-default-email"; a nested route sends ClickStack
# alerts to your contact point. If you already manage your policy in Terraform
# elsewhere, fold the nested `policy` block into that resource instead of using this one.
# ----------------------------------------------------------------------------
resource "grafana_notification_policy" "root" {
  group_by      = ["grafana_folder", "alertname"]
  contact_point = "grafana-default-email"

  policy {
    contact_point = grafana_contact_point.clickstack_alerts.name
    group_by      = ["alertname", "service"]

    matcher {
      label = "stack"
      match = "="
      value = "clickstack"
    }

    group_wait      = "30s"
    group_interval  = "5m"
    repeat_interval = "4h"
  }
}

# ----------------------------------------------------------------------------
# Reusable expression models (B = reduce last, C = threshold)
# ----------------------------------------------------------------------------
locals {
  reduce_last = jsonencode({ refId = "B", type = "reduce", reducer = "last", expression = "A" })

  # helper producing a threshold model for a given operator + value
  threshold = {
    gt_error_rate = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "gt", params = [var.error_rate_pct] } }] })
    gt_latency    = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "gt", params = [var.p95_latency_ms] } }] })
    gt_log_rate   = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "gt", params = [var.error_log_rate_per_sec] } }] })
    gt_slo_burn   = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "gt", params = [var.slo_burn_rate] } }] })
    gt_ch_failed  = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "gt", params = [var.ch_failed_queries_per_sec] } }] })
    gt_zero       = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "gt", params = [0] } }] })
    lt_one        = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "lt", params = [1] } }] })
  }

  # builds the ClickHouse query model (A) for a given SQL string
  query_model = { for k, sql in local.sql : k => jsonencode({
    refId         = "A"
    editorType    = "sql"
    queryType     = "table"
    format        = 1
    intervalMs    = 1000
    maxDataPoints = 43200
    rawSql        = sql
  }) }

  sql = {
    svc_error_rate    = <<-SQL
      SELECT ServiceName AS service,
             100.0 * countIf(StatusCode = 'Error') / count() AS value
      FROM ${var.clickhouse_database}.otel_traces
      WHERE $__timeFilter(Timestamp) AND SpanKind = 'Server'
      GROUP BY service
      HAVING count() >= 20
      ORDER BY value DESC
    SQL
    svc_latency       = <<-SQL
      SELECT ServiceName AS service,
             quantile(0.95)(Duration) / 1e6 AS value
      FROM ${var.clickhouse_database}.otel_traces
      WHERE $__timeFilter(Timestamp) AND SpanKind = 'Server'
      GROUP BY service
      HAVING count() >= 20
      ORDER BY value DESC
    SQL
    slo_fast_burn     = <<-SQL
      SELECT ServiceName AS service,
             (countIf(StatusCode = 'Error') / nullIf(count(), 0)) / 0.001 AS value
      FROM ${var.clickhouse_database}.otel_traces
      WHERE $__timeFilter(Timestamp) AND SpanKind = 'Server'
      GROUP BY service
      HAVING count() >= 20
      ORDER BY value DESC
    SQL
    ingestion_stalled = <<-SQL
      SELECT count() AS value
      FROM ${var.clickhouse_database}.otel_traces
      WHERE $__timeFilter(Timestamp)
    SQL
    pods_not_running  = <<-SQL
      SELECT count() AS value
      FROM (
        SELECT ResourceAttributes['k8s.pod.uid'] AS uid,
               argMax(Value, TimeUnix) AS phase
        FROM ${var.clickhouse_database}.otel_metrics_gauge
        WHERE MetricName = 'k8s.pod.phase' AND $__timeFilter(TimeUnix)
        GROUP BY uid
        HAVING phase NOT IN (2, 3)
      )
    SQL
    container_restarts = <<-SQL
      SELECT sum(d) AS value
      FROM (
        SELECT concat(ResourceAttributes['k8s.pod.uid'], '/',
                      ResourceAttributes['k8s.container.name']) AS c,
               max(Value) - min(Value) AS d
        FROM ${var.clickhouse_database}.otel_metrics_gauge
        WHERE MetricName = 'k8s.container.restarts' AND $__timeFilter(TimeUnix)
        GROUP BY c
      )
    SQL
    error_log_rate    = <<-SQL
      SELECT countIf(SeverityNumber >= 17 OR lower(SeverityText) IN ('error', 'fatal'))
             / greatest(dateDiff('second', $__fromTime, $__toTime), 1) AS value
      FROM ${var.clickhouse_database}.otel_logs
      WHERE $__timeFilter(Timestamp)
    SQL
    fatal_logs        = <<-SQL
      SELECT countIf(SeverityNumber >= 21 OR lower(SeverityText) = 'fatal') AS value
      FROM ${var.clickhouse_database}.otel_logs
      WHERE $__timeFilter(Timestamp)
    SQL
    collector_dropping = <<-SQL
      SELECT sum(d) AS value
      FROM (
        SELECT ResourceAttributes['service.instance.id'] AS i,
               max(Value) - min(Value) AS d
        FROM ${var.clickhouse_database}.otel_metrics_sum
        WHERE MetricName IN (
                'otelcol_receiver_refused_spans_total',
                'otelcol_receiver_refused_log_records_total',
                'otelcol_receiver_refused_metric_points_total')
          AND $__timeFilter(TimeUnix)
        GROUP BY i, MetricName
      )
    SQL
    ch_failed_queries = <<-SQL
      SELECT sum(d) / greatest(dateDiff('second', $__fromTime, $__toTime), 1) AS value
      FROM (
        SELECT ResourceAttributes['service.instance.id'] AS i,
               max(Value) - min(Value) AS d
        FROM ${var.clickhouse_database}.otel_metrics_sum
        WHERE MetricName = 'ClickHouseProfileEvents_FailedQuery'
          AND $__timeFilter(TimeUnix)
        GROUP BY i
      )
    SQL
  }
}

# ============================================================================
# Rule group: Services
# ============================================================================
resource "grafana_rule_group" "services" {
  name             = "ClickStack Services"
  folder_uid       = grafana_folder.clickstack_alerts.uid
  interval_seconds = 60
  org_id           = "0"

  rule {
    name           = "Service error rate high"
    condition      = "C"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "warning", stack = "clickstack" }
    annotations = {
      summary     = "High error rate on {{ $labels.service }}"
      description = "{{ $labels.service }} server-span error rate is {{ printf \"%.1f\" $values.B.Value }}% over the last 10m."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.query_model["svc_error_rate"]
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.reduce_last
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.threshold.gt_error_rate
    }
  }

  rule {
    name           = "Service p95 latency high"
    condition      = "C"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "warning", stack = "clickstack" }
    annotations = {
      summary     = "High p95 latency on {{ $labels.service }}"
      description = "{{ $labels.service }} p95 server latency is {{ printf \"%.0f\" $values.B.Value }} ms over the last 10m."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.query_model["svc_latency"]
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.reduce_last
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.threshold.gt_latency
    }
  }

  rule {
    name           = "Trace ingestion stalled"
    condition      = "C"
    for            = "10m"
    no_data_state  = "Alerting"
    exec_err_state = "Error"
    labels         = { severity = "critical", stack = "clickstack" }
    annotations = {
      summary     = "No traces ingested for 10m"
      description = "Zero spans landed in otel_traces over the last 10m. Check the collector and the ClickHouse writer."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.query_model["ingestion_stalled"]
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.reduce_last
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.threshold.lt_one
    }
  }

  rule {
    name           = "SLO error budget fast burn"
    condition      = "C"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "critical", stack = "clickstack" }
    annotations = {
      summary     = "{{ $labels.service }} is burning its error budget fast"
      description = "{{ $labels.service }} burn rate is {{ printf \"%.1f\" $values.B.Value }}x the 99.9% SLO budget over the last 1h."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      relative_time_range {
        from = 3600
        to   = 0
      }
      model = local.query_model["slo_fast_burn"]
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 3600
        to   = 0
      }
      model = local.reduce_last
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 3600
        to   = 0
      }
      model = local.threshold.gt_slo_burn
    }
  }
}

# ============================================================================
# Rule group: Kubernetes
# ============================================================================
resource "grafana_rule_group" "kubernetes" {
  name             = "ClickStack Kubernetes"
  folder_uid       = grafana_folder.clickstack_alerts.uid
  interval_seconds = 60
  org_id           = "0"

  rule {
    name           = "Pods not Running"
    condition      = "C"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "warning", stack = "clickstack" }
    annotations = {
      summary     = "{{ printf \"%.0f\" $values.B.Value }} pod(s) not in Running phase"
      description = "One or more pods have been outside the Running phase for 5m."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.query_model["pods_not_running"]
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.reduce_last
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.threshold.gt_zero
    }
  }

  rule {
    name           = "Container restarts detected"
    condition      = "C"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "warning", stack = "clickstack" }
    annotations = {
      summary     = "{{ printf \"%.0f\" $values.B.Value }} container restart(s) in the last 15m"
      description = "One or more containers restarted in the last 15m (possible crash loop)."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      relative_time_range {
        from = 900
        to   = 0
      }
      model = local.query_model["container_restarts"]
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 900
        to   = 0
      }
      model = local.reduce_last
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 900
        to   = 0
      }
      model = local.threshold.gt_zero
    }
  }
}

# ============================================================================
# Rule group: Platform (OTel collector + ClickHouse, from otel_metrics_sum)
# ============================================================================
resource "grafana_rule_group" "platform" {
  name             = "ClickStack Platform"
  folder_uid       = grafana_folder.clickstack_alerts.uid
  interval_seconds = 60
  org_id           = "0"

  rule {
    name           = "Collector dropping telemetry"
    condition      = "C"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "warning", stack = "clickstack" }
    annotations = {
      summary     = "OTel collector refused {{ printf \"%.0f\" $values.B.Value }} item(s) in 10m"
      description = "The OpenTelemetry collector refused spans/logs/metric points over the last 10m — telemetry is being dropped."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.query_model["collector_dropping"]
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.reduce_last
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.threshold.gt_zero
    }
  }

  rule {
    name           = "ClickHouse failed queries elevated"
    condition      = "C"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "warning", stack = "clickstack" }
    annotations = {
      summary     = "ClickHouse failing {{ printf \"%.2f\" $values.B.Value }} queries/sec"
      description = "ClickHouse is failing queries over the last 10m. Check ClickHouse load/errors and the Executive Summary platform row."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.query_model["ch_failed_queries"]
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.reduce_last
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.threshold.gt_ch_failed
    }
  }
}

# ============================================================================
# Rule group: Logs
# ============================================================================
resource "grafana_rule_group" "logs" {
  name             = "ClickStack Logs"
  folder_uid       = grafana_folder.clickstack_alerts.uid
  interval_seconds = 60
  org_id           = "0"

  rule {
    name           = "Error log rate high"
    condition      = "C"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "warning", stack = "clickstack" }
    annotations = {
      summary     = "Elevated error/fatal log rate"
      description = "error+fatal logs are arriving at {{ printf \"%.1f\" $values.B.Value }} per second over the last 5m."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = local.query_model["error_log_rate"]
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 300
        to   = 0
      }
      model = local.reduce_last
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 300
        to   = 0
      }
      model = local.threshold.gt_log_rate
    }
  }

  rule {
    name           = "Fatal logs present"
    condition      = "C"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "critical", stack = "clickstack" }
    annotations = {
      summary     = "Fatal logs detected"
      description = "{{ printf \"%.0f\" $values.B.Value }} fatal log line(s) in the last 5m."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = local.query_model["fatal_logs"]
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 300
        to   = 0
      }
      model = local.reduce_last
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 300
        to   = 0
      }
      model = local.threshold.gt_zero
    }
  }
}
