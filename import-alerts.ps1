<#
.SYNOPSIS
  Imports / upserts the ClickStack ALERT templates into a self-hosted (OSS) HyperDX instance.

.DESCRIPTION
  Ships alongside the dashboard templates. Each file in alerts/ describes one high-level alert bound
  to a specific dashboard tile (by dashboard tmpl-slug + tile name). Because dashboard and tile IDs are
  assigned per-install, this script resolves them at import time from the HyperDX v2 API, wires the
  alert to a notification webhook, and UPSERTS it (matched by dashboard+tile+source; updated in place).

  Run import.ps1 FIRST so the dashboards exist, then run this.

  Notification channel: alerts need a webhook. HyperDX has no native "Teams" service, so a Microsoft
  Teams channel is a `generic` webhook whose URL is a Teams *Incoming Webhook*. Resolution order:
    1. -WebhookId <id>                              (use this webhook verbatim)
    2. an existing webhook named -WebhookName        (default "AldoTel Alerts (Teams)")
    3. if -WebhookUrl is given, CREATE one           (needs HDX_EMAIL/HDX_PASS; see note below)
  Webhook CREATE is only exposed on the cookie-authed root route (POST /webhooks), so creating a
  webhook requires an interactive login (HDX_EMAIL/HDX_PASS), and HDX_APP_URL if the HyperDX UI is on
  a different origin than the API. Looking up / using an existing webhook needs only the API key.

.PARAMETER DryRun     Show what would happen without writing anything.
.PARAMETER Delete     Delete the template-managed alerts (matched by name) instead of importing.
.PARAMETER Only       Comma-separated alert file names (e.g. "error-rate.json,replication-lag.json").
.PARAMETER WebhookId    Use this webhook id verbatim (skips lookup/creation).
.PARAMETER WebhookName  Name of the webhook to look up / create. Default "AldoTel Alerts (Teams)".
.PARAMETER WebhookUrl   If set and no webhook is found, create a `generic` webhook with this URL
                        (your Teams Incoming Webhook URL). Requires HDX_EMAIL / HDX_PASS.
.PARAMETER WebhookService  Webhook service when creating: generic (Teams/other), slack, incidentio.

.EXAMPLE
  $env:HDX_API_URL = "http://localhost:8000"; $env:HDX_API_KEY = "<key>"
  ./import-alerts.ps1                                  # upsert all (webhook must already exist)
  ./import-alerts.ps1 -DryRun                          # preview
  ./import-alerts.ps1 -Only error-rate.json
  # First-time channel setup (creates the Teams webhook, then imports):
  $env:HDX_EMAIL="you@corp.com"; $env:HDX_PASS="***"; $env:HDX_APP_URL="http://localhost:3000"
  ./import-alerts.ps1 -WebhookUrl "https://<tenant>.webhook.office.com/webhookb2/xxxx"
  ./import-alerts.ps1 -Delete                          # remove template-managed alerts
#>
param(
  [switch]$DryRun,
  [switch]$Delete,
  [string]$Only,
  [string]$WebhookId,
  [string]$WebhookName = "AldoTel Alerts (Teams)",
  [string]$WebhookUrl,
  [ValidateSet("generic", "slack", "incidentio")]
  [string]$WebhookService = "generic"
)

$ErrorActionPreference = "Stop"

$BaseUrl = $env:HDX_API_URL
$ApiKey  = $env:HDX_API_KEY
if (-not $BaseUrl) { throw "Set HDX_API_URL (e.g. http://localhost:8000)" }
if (-not $ApiKey)  { throw "Set HDX_API_KEY (Team Settings -> API Keys -> Personal API Access Key)" }
$BaseUrl = $BaseUrl.TrimEnd('/')
$Headers = @{ Authorization = "Bearer $ApiKey" }

function Get-List($path) {
  $r = Invoke-RestMethod -Uri "$BaseUrl$path" -Headers $Headers -Method Get
  if ($null -ne $r.data) { return $r.data } else { return $r }
}
function Id-Of($o) { if ($o._id) { return [string]$o._id } elseif ($o.id) { return [string]$o.id } else { return $null } }

# --- resolve the notification webhook id ---
function Resolve-WebhookId {
  if ($WebhookId) { return $WebhookId }

  $webhooks = @(Get-List "/api/v2/webhooks")
  $wh = $webhooks | Where-Object { $_.name -eq $WebhookName } | Select-Object -First 1
  if ($wh) { Write-Host "Using existing webhook '$WebhookName' -> $(Id-Of $wh)"; return (Id-Of $wh) }

  if (-not $WebhookUrl) {
    throw @"
No webhook named '$WebhookName' exists. Either:
  - create one in HyperDX (Team Settings -> Webhooks -> service 'generic', paste your Microsoft Teams
    Incoming Webhook URL) named '$WebhookName', then re-run; or
  - pass -WebhookUrl "<your Teams Incoming Webhook URL>" to have this script create it
    (that path also needs HDX_EMAIL / HDX_PASS, and HDX_APP_URL if the UI origin differs from the API).
"@
  }

  # Create the webhook. This uses the cookie-authed root route (POST /webhooks), which the API key
  # cannot reach, so we log in with HDX_EMAIL / HDX_PASS to obtain a session cookie.
  $email = $env:HDX_EMAIL; $pass = $env:HDX_PASS
  if (-not $email -or -not $pass) { throw "Creating a webhook needs HDX_EMAIL and HDX_PASS (a HyperDX login)." }
  $appUrl = $env:HDX_APP_URL; if (-not $appUrl) { $appUrl = $BaseUrl }
  $appUrl = $appUrl.TrimEnd('/')

  if ($DryRun) { Write-Host "[DRY RUN] would create webhook '$WebhookName' ($WebhookService) -> $WebhookUrl" -ForegroundColor Yellow; return "{{DRYRUN_WEBHOOK_ID}}" }

  $login = Invoke-WebRequest -Uri "$appUrl/api/login/password" -Method Post `
             -Headers @{ 'X-Forwarded-Proto' = 'https' } `
             -Body @{ email = $email; password = $pass } `
             -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
  $setCookie = @($login.Headers['Set-Cookie']) -join ' ;; '
  if ($setCookie -notmatch 'connect\.sid=([^;]+)') { throw "Login to $appUrl failed (no session cookie). Check HDX_EMAIL/HDX_PASS and HDX_APP_URL." }
  $sid = $Matches[1]

  $whBody = @{ name = $WebhookName; service = $WebhookService; url = $WebhookUrl;
               description = "Managed by clickstack-dashboards alerts pack" } | ConvertTo-Json -Compress
  $created = Invoke-RestMethod -Uri "$BaseUrl/webhooks" -Method Post `
               -Headers @{ Cookie = "connect.sid=$sid"; 'X-Forwarded-Proto' = 'https'; 'Content-Type' = 'application/json' } `
               -Body $whBody
  $newId = Id-Of $created.data
  Write-Host "Created webhook '$WebhookName' -> $newId" -ForegroundColor Green
  return $newId
}

# --- index dashboards by tmpl tag; build tile-name -> id maps ---
$dashboards = @(Get-List "/api/v2/dashboards")
function Find-Dashboard($slug) {
  return $dashboards | Where-Object { $_.tags -contains "tmpl:$slug" } | Select-Object -First 1
}

# --- existing alerts (for upsert / delete) ---
$existingAlerts = @(Get-List "/api/v2/alerts")

# --- select files ---
$alertDir = Join-Path $PSScriptRoot "alerts"
if (-not (Test-Path $alertDir)) { throw "No alerts/ directory found next to this script." }
$files = Get-ChildItem -Path $alertDir -Filter *.json
if ($Only) {
  $wanted = $Only.Split(',') | ForEach-Object { $_.Trim() }
  $files = $files | Where-Object { $wanted -contains $_.Name }
}

# Resolve webhook only when we actually need it (not for delete).
$resolvedWebhookId = $null
if (-not $Delete) { $resolvedWebhookId = Resolve-WebhookId }

foreach ($f in $files) {
  $tmpl = Get-Content $f.FullName -Raw | ConvertFrom-Json
  $slug = $tmpl.dashboard
  $tileName = $tmpl.tile
  $a = $tmpl.alert
  $alertName = $a.name

  # --- delete mode: match by name ---
  if ($Delete) {
    $match = $existingAlerts | Where-Object { $_.name -eq $alertName } | Select-Object -First 1
    if ($match) {
      if ($DryRun) { Write-Host "[DRY RUN] would DELETE '$alertName' -> $(Id-Of $match)" -ForegroundColor Yellow }
      else {
        Invoke-RestMethod -Uri "$BaseUrl/api/v2/alerts/$(Id-Of $match)" -Headers $Headers -Method Delete | Out-Null
        Write-Host "Deleted '$alertName' -> $(Id-Of $match)" -ForegroundColor Red
      }
    } else { Write-Host "No existing alert named '$alertName'" }
    continue
  }

  # --- resolve dashboard + tile ---
  $dash = Find-Dashboard $slug
  if (-not $dash) { Write-Warning "$($f.Name): dashboard 'tmpl:$slug' not found (import.ps1 first?); skipping."; continue }
  $tile = $dash.tiles | Where-Object { $_.name -eq $tileName } | Select-Object -First 1
  if (-not $tile) { Write-Warning "$($f.Name): tile '$tileName' not found on '$slug'; skipping."; continue }

  $body = [ordered]@{
    source        = "tile"
    dashboardId   = [string]$dash.id
    tileId        = [string]$tile.id
    threshold     = $a.threshold
    thresholdType = $a.thresholdType
    interval      = $a.interval
    channel       = @{ type = "webhook"; webhookId = $resolvedWebhookId }
    name          = $a.name
  }
  if ($a.message) { $body.message = $a.message }
  $json = $body | ConvertTo-Json -Depth 10 -Compress

  # upsert key: same tile on the same dashboard
  $match = $existingAlerts | Where-Object {
    $_.source -eq 'tile' -and [string]$_.dashboardId -eq [string]$dash.id -and [string]$_.tileId -eq [string]$tile.id
  } | Select-Object -First 1
  $action = if ($match) { "UPDATE -> $(Id-Of $match)" } else { "CREATE" }

  if ($DryRun) { Write-Host "[DRY RUN] would $action  $($f.Name)  ($slug / '$tileName')" -ForegroundColor Yellow; continue }

  try {
    if ($match) {
      Invoke-RestMethod -Uri "$BaseUrl/api/v2/alerts/$(Id-Of $match)" -Headers $Headers -Method Put -ContentType "application/json" -Body $json | Out-Null
      Write-Host "Updated '$alertName' -> $(Id-Of $match)" -ForegroundColor Green
    } else {
      $resp = Invoke-RestMethod -Uri "$BaseUrl/api/v2/alerts" -Headers $Headers -Method Post -ContentType "application/json" -Body $json
      Write-Host "Created '$alertName' -> $(Id-Of $resp.data)" -ForegroundColor Green
    }
  } catch {
    Write-Warning "Failed on $($f.Name): $($_.Exception.Message)"
  }
}

Write-Host "Done."
