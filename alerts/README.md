# AldoTel alerts pack

Importable HyperDX **alert** definitions that ride alongside the dashboard templates. Each alert binds
to a specific dashboard tile and pages a notification channel when a high‑level signal breaches a
threshold. Portable by the same model as the dashboards: no hardcoded IDs — the importer resolves the
per‑install dashboard/tile/webhook IDs at import time.

> **v1 scope: the five high‑level signals.** One alert each for the conditions an operator actually
> wants to be woken up for. Thresholds are opinionated defaults and are meant to be tuned per install
> (edit the file or the alert in the HyperDX UI).

## The signals

| File | Alert | Bound tile (dashboard) | Condition (default) | Interval |
|---|---|---|---|---|
| `error-rate.json` | Services error rate | `Error rate %` (services‑red) | ratio **> 2%** | 5m |
| `slo-fast-burn.json` | SLO fast burn | `Error rate (1 - SLI)` (slo‑errorbudget) | error rate **> 1.44%** (= 14.4× burn of a 99.9% SLO) | 5m |
| `collector-drops.json` | Collector dropping telemetry | `Refused spans (should be 0)` (collector‑health) | refused spans **> 0** | 5m |
| `too-many-parts.json` | ClickHouse too many parts | `Active parts (total)` (ch‑storage) | total active parts **> 5000** | 15m |
| `replication-lag.json` | ClickHouse replication lag | `Max replication lag (s)` (clickhouse‑health) | lag **> 60s** | 5m |

All five bind to `line` / `number` tiles (the tile types HyperDX can alert on). Values that HyperDX
formats as a fraction (error rate, SLI) use fractional thresholds (`0.02` = 2%).

## Notification channel (Microsoft Teams by default)

HyperDX has no dedicated Teams service — a Teams channel is a **`generic` webhook** whose URL is a
**Teams Incoming Webhook**. You choose the channel; Teams is just the default assumption.

**Recommended (UI, any channel):** in HyperDX go to **Team Settings → Webhooks**, add a webhook,
choose the service (`generic` for Teams, or `slack` / `incidentio`), paste the channel URL, and name it
**`AldoTel Alerts (Teams)`** (or pass your own name with `-WebhookName` / `--webhook-name`). Then run
the importer — it looks the webhook up by name.

**Or let the importer create it** (Teams/generic) — see the setup example below.

To get a Teams Incoming Webhook URL: Teams channel → **⋯ → Connectors → Incoming Webhook → Configure**,
name it, **Create**, copy the URL.

## Import

Prereq: import the dashboards first (`./import.ps1` / `./import.sh`) so the tiles exist.

```powershell
# PowerShell
$env:HDX_API_URL = "http://localhost:8000"; $env:HDX_API_KEY = "<Personal API Access Key>"

# A) webhook already created in the UI (named "AldoTel Alerts (Teams)"):
./import-alerts.ps1
./import-alerts.ps1 -DryRun                      # preview, write nothing
./import-alerts.ps1 -Only error-rate.json

# B) first-time channel setup — create the Teams webhook, then import:
$env:HDX_EMAIL = "you@corp.com"; $env:HDX_PASS = "***"
$env:HDX_APP_URL = "http://localhost:3000"       # only if the UI origin differs from the API
./import-alerts.ps1 -WebhookUrl "https://<tenant>.webhook.office.com/webhookb2/xxxx"

./import-alerts.ps1 -Delete                       # remove the template-managed alerts
```

```bash
# bash (requires curl + jq)
export HDX_API_URL="http://localhost:8000"; export HDX_API_KEY="<Personal API Access Key>"
./import-alerts.sh                                 # upsert all (webhook must already exist)
./import-alerts.sh --dry-run
./import-alerts.sh --only error-rate.json,replication-lag.json
# first-time channel setup:
export HDX_EMAIL="you@corp.com"; export HDX_PASS="***"; export HDX_APP_URL="http://localhost:3000"
./import-alerts.sh --webhook-url "https://<tenant>.webhook.office.com/webhookb2/xxxx"
./import-alerts.sh --delete
```

The importer is **idempotent**: alerts are matched by `(dashboard, tile)` and updated in place, so
re‑running never creates duplicates.

### Why webhook creation needs a login

Alerts are created with the bearer **API key** (`POST /api/v2/alerts`). Webhook *creation* is only
exposed on the cookie‑authed root route (`POST /webhooks`), so the `-WebhookUrl` / `--webhook-url`
convenience path performs an interactive login with `HDX_EMAIL` / `HDX_PASS` (and `HDX_APP_URL` if the
HyperDX UI is served from a different origin than the API). Looking up or reusing an existing webhook
needs only the API key.

## Tuning

- **Thresholds / intervals** — edit the `alert.threshold` / `alert.interval` in the JSON and re‑import,
  or change the alert in the HyperDX UI (the importer will pick your edits back up only on the fields
  it manages, so prefer editing the JSON if you re‑import).
- **`collector-drops` is zero‑tolerance** (`> 0`). If your environment has benign transient refusals,
  raise the threshold or lengthen the interval.
- **`too-many-parts`** watches *total* active parts as a coarse canary; the precise per‑table view is
  the `Active parts per table` tile on the Storage dashboard.

## Alert JSON shape

```json
{
  "slug": "error-rate",
  "signal": "Error rate",
  "dashboard": "services-red",          // dashboard tmpl slug (tmpl:<slug> tag)
  "tile": "Error rate %",               // tile matched by name
  "alert": {
    "name": "AldoTel · Services error rate > 2%",
    "source": "tile",
    "thresholdType": "above",           // above | below | above_exclusive | below_or_equal | equal | not_equal | between | not_between
    "threshold": 0.02,
    "interval": "5m",                   // 1m | 5m | 15m | 30m | 1h | 6h | 12h | 1d
    "message": "…",                     // optional notification body
    "channel": { "type": "webhook", "webhookId": "{{ALERT_WEBHOOK_ID}}" }
  }
}
```
