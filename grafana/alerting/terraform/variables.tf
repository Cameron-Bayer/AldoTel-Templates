variable "grafana_url" {
  type        = string
  description = "Base URL of your Grafana, e.g. https://myorg.grafana.net or http://localhost:3000"
}

variable "grafana_auth" {
  type        = string
  sensitive   = true
  description = "Grafana auth: a service account token (recommended) or 'admin:password'. The token needs Editor/Admin rights for folders, alert rules, contact points, and notification policies."
}

variable "clickhouse_datasource_uid" {
  type        = string
  default     = "clickstack-ch"
  description = "UID of the ClickHouse data source the alert queries run against. Must already exist in Grafana."
}

variable "clickhouse_database" {
  type        = string
  default     = "default"
  description = "ClickHouse database that ClickStack writes to (otel_traces/otel_logs/otel_metrics_gauge live here)."
}

variable "alert_webhook_url" {
  type        = string
  sensitive   = true
  description = "Webhook URL alerts POST to — your own on-call integration (Slack incoming webhook, a Teams Workflow URL, PagerDuty, Discord, or any HTTP endpoint)."
}

# --- Tunable thresholds -----------------------------------------------------
variable "error_rate_pct" {
  type        = number
  default     = 5
  description = "Service error rate alert fires above this percent."
}

variable "p95_latency_ms" {
  type        = number
  default     = 2000
  description = "Service p95 latency alert fires above this many milliseconds."
}

variable "error_log_rate_per_sec" {
  type        = number
  default     = 5
  description = "Error/fatal log rate alert fires above this many logs per second."
}

variable "slo_burn_rate" {
  type        = number
  default     = 14.4
  description = "SLO fast-burn alert fires above this multiple of the 99.9% error budget (14.4x = classic 1h fast-burn page)."
}

variable "ch_failed_queries_per_sec" {
  type        = number
  default     = 1
  description = "ClickHouse failed-query alert fires above this many failed queries per second."
}
