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
  default     = ""
  description = "Webhook URL alerts POST to — your own on-call integration (Slack incoming webhook, PagerDuty, Discord, or any HTTP endpoint). Leave empty if you are using teams_workflow_url instead."
}

variable "teams_workflow_url" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Microsoft Teams Power Automate Workflows URL. When set, alerts go to Teams as an Adaptive Card via Grafana's native teams integration and alert_webhook_url is ignored. Get it in Teams: right-click channel -> Workflows -> 'Post to a channel when a webhook request is received'. Do NOT use a legacy Office 365 connector URL (outlook.office.com/webhook/...) — those are being retired."

  validation {
    condition     = var.teams_workflow_url == "" || !can(regex("outlook\\.office(365)?\\.com", var.teams_workflow_url))
    error_message = "That looks like a legacy Office 365 connector URL. Microsoft is retiring those. Create a Power Automate Workflows webhook instead (Teams: right-click channel -> Workflows)."
  }
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

# --- Appliance thresholds ---------------------------------------------------
variable "volume_critical_pct_free" {
  type        = number
  default     = 5
  description = "Appliance volume CRITICAL alert fires below this percent of free space on a node filesystem."
}

variable "volume_low_pct_free" {
  type        = number
  default     = 15
  description = "Appliance volume LOW alert fires below this percent of free space on a node filesystem."
}

variable "appliance_cpu_pct" {
  type        = number
  default     = 90
  description = "Appliance CPU alert fires above this percent of non-idle CPU, averaged over the 15m query window."
}

variable "appliance_memory_pct" {
  type        = number
  default     = 85
  description = "Appliance memory alert fires above this percent of used memory, averaged over the 15m query window."
}

variable "appliance_reboot_uptime_sec" {
  type        = number
  default     = 900
  description = "Appliance VM restart alert fires when k8s.node.uptime is below this many seconds (i.e. the node booted that recently)."
}

# --- Appliance workload matching --------------------------------------------
# These two rules find their workload by case-insensitive name substring. The
# defaults are guesses — set them to match YOUR pod/service names or the rules
# will never fire.
variable "keyvault_workload_match" {
  type        = string
  default     = "moc-kms"
  description = "Case-insensitive substring matched against k8s.pod.name to identify Key Vault pods. On an Azure Local appliance the Key Vault role is served by the moc-kms pods; set this to 'keyvault' on a stock cluster that runs a pod named accordingly."
}


