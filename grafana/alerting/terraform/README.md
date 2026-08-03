# ClickStack Grafana alerts — Terraform install

Use this when you **can't drop files** into `/etc/grafana/provisioning/` — most
commonly **Grafana Cloud**, or a managed/locked-down Grafana. It creates exactly
the same objects as the provisioning YAML in the parent folder, but through the
Grafana HTTP API using the official
[`grafana/grafana` Terraform provider](https://registry.terraform.io/providers/grafana/grafana/latest/docs):

- a **folder** `ClickStack Alerts`,
- the **16 alert rules** (5 groups: Services, Kubernetes, Logs, Appliance
  Capacity, Appliance Platform),
- the **ClickStack Alerts** contact point,
- a **notification policy** routing `stack=clickstack` alerts to that contact point.

> Prefer file provisioning if you can — it needs no tokens and no Terraform.
> This path exists purely for environments where filesystem provisioning isn't
> available. Use **one** method, not both, or they'll fight over the same rules.

## Prerequisites

1. [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.3.
2. Your **ClickHouse data source already created** in Grafana (dashboards step).
   Note its **UID** — pass it as `clickhouse_datasource_uid` (defaults to
   `clickstack-ch`).
3. A **Grafana service account token** with Editor/Admin rights
   (*Administration → Service accounts → Add token*). On Grafana Cloud you can
   also use a Cloud Access Policy token.
4. A **webhook URL** for your on-call channel (a Slack incoming webhook, a Teams
   Workflow "Post to a channel when a webhook request is received" URL, PagerDuty,
   Discord, or any HTTP endpoint that accepts a POST).

## Usage

```bash
cd grafana/alerting/terraform
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan     # review what will be created
terraform apply
```

After apply, open **Alerting → Alert rules** in Grafana — the *ClickStack Alerts*
folder holds all 16 rules. Test delivery via **Contact points → ClickStack Alerts
→ Test**.

`terraform plan` is idempotent: a second run against an unchanged Grafana reports
*No changes*.

## Setting thresholds

Override any of these in `terraform.tfvars` (defaults shown):

| Variable | Default | Controls |
|----------|---------|----------|
| `error_rate_pct` | `5` | Service error rate alert (% ) |
| `p95_latency_ms` | `2000` | Service p95 latency alert (ms) |
| `error_log_rate_per_sec` | `5` | Error/fatal log-rate alert (logs/s) |
| `slo_burn_rate` | `14.4` | SLO error-budget fast-burn alert (× budget) |

Appliance thresholds:

| Variable | Default | Controls |
|----------|---------|----------|
| `volume_critical_pct_free` | `5` | Appliance volume **critical** (% free) |
| `volume_low_pct_free` | `15` | Appliance volume **low** (% free) |
| `appliance_cpu_pct` | `90` | Appliance CPU sustained high (%) |
| `appliance_memory_pct` | `85` | Appliance memory pressure (%) |
| `appliance_reboot_uptime_sec` | `900` | Appliance VM restarted (uptime seconds) |
| `keyvault_workload_match` | `moc-kms` | Substring identifying the Key Vault / KMS pods |

> **One appliance rule is workload-specific.** *Key Vault service unavailable*
> locates its workload by case-insensitive **name substring**. The default
> `keyvault_workload_match = "moc-kms"` matches the pods that serve the Key Vault
> / KMS role on an Azure Local appliance; on a stock cluster set it to your real
> pod names or the rule will never fire. Find your names with
> `kubectl get pods -A`.

The two boolean-style thresholds — *Pods not Running* (`> 0`) and *Fatal logs
present* (`> 0`), plus *Container restarts detected* (`> 0`), *Collector dropping
telemetry* (`> 0`), and *Trace ingestion stalled* (`< 1`) — are structural and
live inline in `main.tf` if you ever need to change them.

`for` durations and evaluation `interval` are set per rule / per group in
`main.tf` (mirroring the YAML): edit there and re-apply.

## Changing the notification channel

### Microsoft Teams

Set `teams_workflow_url` in `terraform.tfvars` and leave `alert_webhook_url`
empty. The module then uses Grafana's native `teams` integration, which posts an
Adaptive Card, instead of the generic webhook:

```hcl
teams_workflow_url = "https://prod-12.westus.logic.azure.com:443/workflows/..."
```

Get that URL from Teams: **right-click the channel → Workflows →
"Post to a channel when a webhook request is received" → Add workflow**, then
copy the generated URL.

> Legacy **Office 365 connector** URLs (`outlook.office.com/webhook/...`) are
> rejected by a variable validation. Microsoft blocked creation of new ones in
> 2024 and is fully retiring them in 2026 — Power Automate Workflows is the
> supported replacement.

Setting neither variable fails the plan with a clear error rather than silently
creating a contact point that goes nowhere.

### Anything else

`main.tf` falls back to a generic `webhook` contact point. To use a native
email / Slack / PagerDuty integration instead, swap the `webhook { ... }` block in
`grafana_contact_point.clickstack_alerts` for the matching block from the
[provider docs](https://registry.terraform.io/providers/grafana/grafana/latest/docs/resources/contact_point)
(e.g. `email { addresses = [...] }`), then `terraform apply`.

## Teardown

```bash
terraform destroy
```

Removes the folder, rules, contact point, and resets the notification policy
managed here. It does **not** touch your ClickHouse data source or dashboards.

## Notes

- `terraform.tfvars` holds a token and a webhook URL — keep it out of version
  control (it's ignored by the repo `.gitignore` convention; verify in yours).
- This manages the org's **root** notification policy. If you already manage
  that policy in Terraform, move the nested `policy` block into your existing
  `grafana_notification_policy` resource instead of using the one here.
