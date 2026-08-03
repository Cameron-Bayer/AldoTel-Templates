# ClickStack Grafana alerts — Terraform
# ============================================================================
# Creates the same 16 alert rules (8 platform + 8 appliance), the alert contact
# point, and the notification policy as the provisioning YAML in the parent
# folder — but through the Grafana HTTP API. Use this when you CANNOT drop files
# into /etc/grafana/provisioning (e.g. Grafana Cloud, or a locked-down managed
# Grafana).
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

# Route to Teams when a Workflows URL is supplied, otherwise the generic webhook.
# nonsensitive() is required because a sensitive value cannot drive for_each;
# this only exposes WHETHER the variable is set, never its contents.
locals {
  use_teams = nonsensitive(var.teams_workflow_url) != ""
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
#
# FOR MICROSOFT TEAMS: set var.teams_workflow_url to a Power Automate Workflows
# URL and the native `teams` receiver below is used instead of the webhook —
# it posts a proper Adaptive Card. Get the URL from Teams: right-click the
# channel -> Workflows -> "Post to a channel when a webhook request is
# received". Do NOT use a legacy Office 365 connector URL
# (outlook.office.com/webhook/...); those are being retired in 2026.
# ----------------------------------------------------------------------------
resource "grafana_contact_point" "clickstack_alerts" {
  name = "ClickStack Alerts"

  dynamic "webhook" {
    for_each = local.use_teams ? toset([]) : toset(["webhook"])
    content {
      url                     = var.alert_webhook_url
      disable_resolve_message = false
    }
  }

  dynamic "teams" {
    for_each = local.use_teams ? toset(["teams"]) : toset([])
    content {
      url                     = var.teams_workflow_url
      disable_resolve_message = false
    }
  }

  lifecycle {
    precondition {
      condition     = var.alert_webhook_url != "" || var.teams_workflow_url != ""
      error_message = "Set either alert_webhook_url (generic webhook) or teams_workflow_url (Microsoft Teams). Both are empty, so alerts would have nowhere to go."
    }
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
    gt_zero       = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "gt", params = [0] } }] })
    lt_one        = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "lt", params = [1] } }] })

    # --- appliance ---
    lt_vol_critical = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "lt", params = [var.volume_critical_pct_free] } }] })
    lt_vol_low      = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "lt", params = [var.volume_low_pct_free] } }] })
    gt_cpu          = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "gt", params = [var.appliance_cpu_pct] } }] })
    gt_memory       = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "gt", params = [var.appliance_memory_pct] } }] })
    lt_uptime       = jsonencode({ refId = "C", type = "threshold", expression = "B", conditions = [{ evaluator = { type = "lt", params = [var.appliance_reboot_uptime_sec] } }] })
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
    svc_error_rate     = <<-SQL
      SELECT ServiceName AS service,
             100.0 * countIf(StatusCode = 'Error') / count() AS value
      FROM ${var.clickhouse_database}.otel_traces
      WHERE $__timeFilter(Timestamp) AND SpanKind = 'Server'
      GROUP BY service
      HAVING count() >= 20
      ORDER BY value DESC
    SQL
    svc_latency        = <<-SQL
      SELECT ServiceName AS service,
             quantile(0.95)(Duration) / 1e6 AS value
      FROM ${var.clickhouse_database}.otel_traces
      WHERE $__timeFilter(Timestamp) AND SpanKind = 'Server'
      GROUP BY service
      HAVING count() >= 20
      ORDER BY value DESC
    SQL
    slo_fast_burn      = <<-SQL
      SELECT ServiceName AS service,
             (countIf(StatusCode = 'Error') / nullIf(count(), 0)) / 0.001 AS value
      FROM ${var.clickhouse_database}.otel_traces
      WHERE $__timeFilter(Timestamp) AND SpanKind = 'Server'
      GROUP BY service
      HAVING count() >= 20
      ORDER BY value DESC
    SQL
    ingestion_stalled  = <<-SQL
      SELECT count() AS value
      FROM ${var.clickhouse_database}.otel_traces
      WHERE $__timeFilter(Timestamp)
    SQL
    pods_not_running   = <<-SQL
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
    error_log_rate     = <<-SQL
      SELECT countIf(SeverityNumber >= 17 OR lower(SeverityText) IN ('error', 'fatal'))
             / greatest(dateDiff('second', $__fromTime, $__toTime), 1) AS value
      FROM ${var.clickhouse_database}.otel_logs
      WHERE $__timeFilter(Timestamp)
    SQL
    fatal_logs         = <<-SQL
      SELECT countIf(SeverityNumber >= 21 OR lower(SeverityText) = 'fatal') AS value
      FROM ${var.clickhouse_database}.otel_logs
      WHERE $__timeFilter(Timestamp)
    SQL

    # --- appliance ------------------------------------------------------
    # Free space per mounted volume. system.filesystem.usage lives in the SUM
    # table and is split by a `state` attribute (used / free / reserved), so the
    # volume total is the sum of every state. Grouping by (host, mountpoint)
    # rather than by node is deliberate: a node mounts several volumes and it is
    # always one specific volume that fills up first.
    volume_free_pct = <<-SQL
      SELECT volume,
             100 * avail / nullIf(cap, 0) AS value
      FROM (
        SELECT volume,
               sumIf(v, st = 'free') AS avail,
               sum(v) AS cap
        FROM (
          SELECT concat(ResourceAttributes['host.name'], ' ', Attributes['mountpoint']) AS volume,
                 Attributes['state'] AS st,
                 argMax(Value, TimeUnix) AS v
          FROM ${var.clickhouse_database}.otel_metrics_sum
          WHERE MetricName = 'system.filesystem.usage'
            AND $__timeFilter(TimeUnix)
          GROUP BY volume, st
        )
        GROUP BY volume
      )
      WHERE cap > 0
      ORDER BY value ASC
    SQL

    # Non-idle CPU. Group by host+cpu+TimeUnix FIRST so multiple state rows and
    # multiple cores are not double-counted, then average.
    appliance_cpu = <<-SQL
      SELECT host, 100 * avg(busy) AS value
      FROM (
        SELECT ResourceAttributes['host.name'] AS host,
               Attributes['cpu'] AS cpu,
               TimeUnix,
               sumIf(Value, Attributes['state'] != 'idle') AS busy
        FROM ${var.clickhouse_database}.otel_metrics_gauge
        WHERE MetricName = 'system.cpu.utilization'
          AND $__timeFilter(TimeUnix)
        GROUP BY host, cpu, TimeUnix
      )
      GROUP BY host
      ORDER BY value DESC
    SQL

    appliance_memory = <<-SQL
      SELECT ResourceAttributes['host.name'] AS host,
             100 * avgIf(Value, Attributes['state'] = 'used') AS value
      FROM ${var.clickhouse_database}.otel_metrics_gauge
      WHERE MetricName = 'system.memory.utilization'
        AND $__timeFilter(TimeUnix)
      GROUP BY host
      ORDER BY value DESC
    SQL

    # k8s.node.uptime lives in otel_metrics_sum and resets to 0 on boot, which
    # is what makes this rule both fire and self-resolve.
    node_uptime = <<-SQL
      SELECT ResourceAttributes['k8s.node.name'] AS node,
             argMax(Value, TimeUnix) AS value
      FROM ${var.clickhouse_database}.otel_metrics_sum
      WHERE MetricName = 'k8s.node.uptime'
        AND $__timeFilter(TimeUnix)
      GROUP BY node
      ORDER BY value ASC
    SQL

    # Restarted during the window AND currently Running (phase 2) => recovered.
    service_recovered = <<-SQL
      SELECT r.pod AS pod, r.d AS value
      FROM (
        SELECT ResourceAttributes['k8s.pod.name'] AS pod,
               max(Value) - min(Value) AS d
        FROM ${var.clickhouse_database}.otel_metrics_gauge
        WHERE MetricName = 'k8s.container.restarts'
          AND $__timeFilter(TimeUnix)
        GROUP BY pod
        HAVING d > 0
      ) r
      INNER JOIN (
        SELECT ResourceAttributes['k8s.pod.name'] AS pod,
               argMax(Value, TimeUnix) AS phase
        FROM ${var.clickhouse_database}.otel_metrics_gauge
        WHERE MetricName = 'k8s.pod.phase'
          AND $__timeFilter(TimeUnix)
        GROUP BY pod
        HAVING phase = 2
      ) p ON r.pod = p.pod
      ORDER BY value DESC
    SQL

    # EDIT-ME-WORKLOAD: var.keyvault_workload_match must match your real pod name.
    keyvault_down = <<-SQL
      SELECT pod, 1 AS value
      FROM (
        SELECT ResourceAttributes['k8s.pod.name'] AS pod,
               argMax(Value, TimeUnix) AS phase
        FROM ${var.clickhouse_database}.otel_metrics_gauge
        WHERE MetricName = 'k8s.pod.phase'
          AND $__timeFilter(TimeUnix)
          AND positionCaseInsensitive(ResourceAttributes['k8s.pod.name'], '${var.keyvault_workload_match}') > 0
        GROUP BY pod
        HAVING phase NOT IN (2, 3)
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
      query_type     = "table"
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
      query_type     = "table"
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
      query_type     = "table"
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
      query_type     = "table"
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
      query_type     = "table"
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
      query_type     = "table"
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
# Rule group: Logs
# ============================================================================
resource "grafana_rule_group" "logs" {
  name             = "ClickStack Logs"
  folder_uid       = grafana_folder.clickstack_alerts.uid
  interval_seconds = 60

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
      query_type     = "table"
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
      query_type     = "table"
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

# ============================================================================
# Rule group: Appliance Capacity
# ----------------------------------------------------------------------------
# Mirrors ../appliance-alert-rules.yaml. These cover the appliance VM's OWN
# resources as seen from inside the VM. They cannot report the VM being down,
# and they say nothing about the Hyper-V hosts, S2D, or physical NICs.
#
# NOTE on "sustained": for CPU/memory the 15m query window IS the sustained-ness
# (the query averages over 15m), so `for` is only a 1m debounce. Stacking
# for = "15m" on top of a 15m average would double the effective delay.
# ============================================================================
resource "grafana_rule_group" "appliance_capacity" {
  name             = "ClickStack Appliance Capacity"
  folder_uid       = grafana_folder.clickstack_alerts.uid
  interval_seconds = 60

  rule {
    name           = "Appliance volume critically low"
    condition      = "C"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "critical", stack = "clickstack" }
    annotations = {
      summary     = "Volume critically low on {{ $labels.node }}"
      description = "{{ $labels.node }} has {{ printf \"%.1f\" $values.B.Value }}% free space. Expand the volume or clean up logs/images now."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      query_type     = "table"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.query_model["volume_free_pct"]
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
      model = local.threshold.lt_vol_critical
    }
  }

  rule {
    name           = "Appliance volume low"
    condition      = "C"
    for            = "15m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "warning", stack = "clickstack" }
    annotations = {
      summary     = "Volume low on {{ $labels.node }}"
      description = "{{ $labels.node }} has {{ printf \"%.1f\" $values.B.Value }}% free space. Plan cleanup; review container image retention."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      query_type     = "table"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.query_model["volume_free_pct"]
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
      model = local.threshold.lt_vol_low
    }
  }

  rule {
    name           = "Appliance CPU sustained high"
    condition      = "C"
    for            = "1m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "warning", stack = "clickstack" }
    annotations = {
      summary     = "Sustained high CPU on {{ $labels.host }}"
      description = "{{ $labels.host }} averaged {{ printf \"%.1f\" $values.B.Value }}% non-idle CPU over 15m. Identify top processes; check for runaway containers."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      query_type     = "table"
      relative_time_range {
        from = 900
        to   = 0
      }
      model = local.query_model["appliance_cpu"]
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
      model = local.threshold.gt_cpu
    }
  }

  rule {
    name           = "Appliance memory pressure"
    condition      = "C"
    for            = "1m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "warning", stack = "clickstack" }
    annotations = {
      summary     = "Memory pressure on {{ $labels.host }}"
      description = "{{ $labels.host }} averaged {{ printf \"%.1f\" $values.B.Value }}% memory used over 15m. Identify memory consumers; check for leaks."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      query_type     = "table"
      relative_time_range {
        from = 900
        to   = 0
      }
      model = local.query_model["appliance_memory"]
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
      model = local.threshold.gt_memory
    }
  }
}

# ============================================================================
# Rule group: Appliance Platform
# ============================================================================
resource "grafana_rule_group" "appliance_platform" {
  name             = "ClickStack Appliance Platform"
  folder_uid       = grafana_folder.clickstack_alerts.uid
  interval_seconds = 60

  rule {
    name           = "Appliance VM restarted"
    condition      = "C"
    for            = "1m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "warning", stack = "clickstack" }
    annotations = {
      summary     = "Appliance node {{ $labels.node }} restarted"
      description = "{{ $labels.node }} has been up for only {{ printf \"%.0f\" $values.B.Value }}s. Confirm services resumed and verify portal access."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      query_type     = "table"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = local.query_model["node_uptime"]
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
      model = local.threshold.lt_uptime
    }
  }

  rule {
    name           = "Service recovered after failure"
    condition      = "C"
    for            = "0s"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "info", stack = "clickstack" }
    annotations = {
      summary     = "{{ $labels.pod }} recovered after restart"
      description = "{{ $labels.pod }} restarted {{ printf \"%.0f\" $values.B.Value }} time(s) in the last 15m and is Running again. Review root cause; check whether data was lost."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      query_type     = "table"
      relative_time_range {
        from = 900
        to   = 0
      }
      model = local.query_model["service_recovered"]
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

  rule {
    # EDIT-ME-WORKLOAD: set var.keyvault_workload_match to your real pod name.
    name           = "Key Vault service unavailable"
    condition      = "C"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Error"
    labels         = { severity = "critical", stack = "clickstack" }
    annotations = {
      summary     = "Key Vault pod {{ $labels.pod }} is not running"
      description = "{{ $labels.pod }} has been outside Running/Succeeded for over 5m. Restart the KV service; check appliance resource pressure."
    }
    data {
      ref_id         = "A"
      datasource_uid = var.clickhouse_datasource_uid
      query_type     = "table"
      relative_time_range {
        from = 300
        to   = 0
      }
      model = local.query_model["keyvault_down"]
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