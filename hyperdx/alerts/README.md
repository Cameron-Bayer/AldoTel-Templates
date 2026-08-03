# ClickStack alerts pack

Importable HyperDX **alert** definitions that ride alongside the dashboard templates. Each alert binds
to a specific dashboard tile and pages a notification channel when a high‑level signal breaches a
threshold. Portable by the same model as the dashboards: no hardcoded IDs — the importer resolves the
per‑install dashboard/tile/webhook IDs at import time.

> **Scope: four high‑level signals.** One alert each for the conditions an operator actually
> wants to be woken up for. Thresholds are opinionated defaults and are meant to be tuned per install
> (edit the file or the alert in the HyperDX UI). Every alert here is verified to bind to a tile that
> exists and is of an alertable type — signals whose tiles were retired are not shipped inert.

## The signals

| File | Alert | Bound tile (dashboard) | Condition (default) | Interval |
|---|---|---|---|---|
| `error-rate.json` | Services error rate | `Error rate %` (services) | ratio **> 2%** | 5m |
| `slo-fast-burn.json` | SLO fast burn | `Availability (SLI = success rate)` (services) | availability **< 98.56%** (= 14.4× burn of a 99.9% SLO) | 5m |
| `collector-drops.json` | Collector dropping telemetry | `Refused spans (window)` (observability‑platform) | refused spans **> 0** | 5m |
| `clickhouse-disk-low.json` | ClickHouse running out of disk | `Disk free %` (observability‑platform) | free space **< 10%** | 15m |

All four bind to `line` / `number` tiles (the tile types HyperDX can alert on). Values that HyperDX
formats as a fraction (error rate, SLI, disk free) use fractional thresholds (`0.02` = 2%).

The last two live on the **advanced** dashboard, so import it first with
`./import.ps1 -Advanced` / `./import.sh --advanced`, and run `collector/install-collector.*` so the
ClickHouse and collector metrics they read are actually being scraped.

## Notification channel (generic webhook — wire your own)

HyperDX delivers alerts to a **webhook**. The importer is channel-agnostic: point it at whatever
on-call endpoint you use — a Slack incoming webhook, a Teams Workflow "Post to a channel when a
webhook request is received" URL, PagerDuty, Discord, or any HTTP endpoint that accepts a POST.

**Recommended (UI, any channel):** in HyperDX go to **Team Settings → Webhooks**, add a webhook,
choose the service (`generic` for most endpoints, or `slack` / `incidentio`), paste your channel URL,
and name it **`ClickStack Alerts`** (or pass your own name with `-WebhookName` / `--webhook-name`). Then
run the importer — it looks the webhook up by name.

**Or let the importer create it** — pass `-WebhookUrl` / `--webhook-url` with your endpoint (see the
setup example below).

## Import

Prereq: import the dashboards first (`./import.ps1` / `./import.sh`) so the tiles exist.

```powershell
# PowerShell
$env:HDX_API_URL = "http://localhost:8000"; $env:HDX_API_KEY = "<Personal API Access Key>"

# A) webhook already created in the UI (named "ClickStack Alerts"):
./import-alerts.ps1
./import-alerts.ps1 -DryRun                      # preview, write nothing
./import-alerts.ps1 -Only error-rate.json

# B) first-time channel setup — create the webhook, then import:
$env:HDX_EMAIL = "you@corp.com"; $env:HDX_PASS = "***"
$env:HDX_APP_URL = "http://localhost:3000"       # only if the UI origin differs from the API
./import-alerts.ps1 -WebhookUrl "https://your-webhook-endpoint.example/hooks/xxxx"

./import-alerts.ps1 -Delete                       # remove the template-managed alerts
```

```bash
# bash (requires curl + jq)
export HDX_API_URL="http://localhost:8000"; export HDX_API_KEY="<Personal API Access Key>"
./import-alerts.sh                                 # upsert all (webhook must already exist)
./import-alerts.sh --dry-run
./import-alerts.sh --only error-rate.json,clickhouse-disk-low.json
# first-time channel setup:
export HDX_EMAIL="you@corp.com"; export HDX_PASS="***"; export HDX_APP_URL="http://localhost:3000"
./import-alerts.sh --webhook-url "https://your-webhook-endpoint.example/hooks/xxxx"
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
- **`clickhouse-disk-low`** is the highest-value alert in this pack. A full ClickHouse disk is the
  most common way a ClickStack deployment dies: INSERTs start failing with `NOT_ENOUGH_SPACE`,
  ingestion stops, and every dashboard silently goes blank because no new data is arriving. 10% free
  gives you room to act; raise it if your volume is small enough that 10% is only a few minutes of
  headroom.

## Alert JSON shape

```json
{
  "slug": "error-rate",
  "signal": "Error rate",
  "dashboard": "services",              // dashboard tmpl slug (tmpl:<slug> tag)
  "tile": "Error rate %",               // tile matched by name
  "alert": {
    "name": "ClickStack · Services error rate > 2%",
    "source": "tile",
    "thresholdType": "above",           // above | below | above_exclusive | below_or_equal | equal | not_equal | between | not_between
    "threshold": 0.02,
    "interval": "5m",                   // 1m | 5m | 15m | 30m | 1h | 6h | 12h | 1d
    "message": "…",                     // optional notification body
    "channel": { "type": "webhook", "webhookId": "{{ALERT_WEBHOOK_ID}}" }
  }
}
```

> **`dashboard` is a stable slug, not a filename.** It matches the target dashboard's
> `tmpl:<slug>` tag, which is deliberately short and can differ from the JSON filename —
> e.g. the alerts targeting `dashboards/advanced/observability-platform-health.json` use
> `"dashboard": "observability-platform"` (tag `tmpl:observability-platform`). The importer resolves
> the slug to the installed dashboard's real ID at import time, so the tag is what keeps upserts
> stable. Run `grep -h '"tmpl:' hyperdx/dashboards/**/*.json` to see every available slug.
