<#
.SYNOPSIS
  Imports / upserts the ClickStack dashboard templates into a self-hosted (OSS) HyperDX instance.

.DESCRIPTION
  Resolves install-specific source IDs / connection / table names from the HyperDX v2 API,
  substitutes the {{TOKENS}} in each template, then UPSERTS each dashboard: dashboards are matched
  by their stable "tmpl:<slug>" tag and updated in place (PUT) instead of duplicated. If no match
  exists, a new dashboard is created (POST).

.PARAMETER DryRun
  Show what would happen without writing anything.

.PARAMETER Delete
  Delete the template-managed dashboards (matched by tmpl tag) instead of importing.

.PARAMETER Duplicate
  Force-create new dashboards even if a matching one exists (legacy behavior).

.PARAMETER Only
  Comma-separated list of dashboard file names to act on (e.g. "services-red.json,logs-overview.json").

.EXAMPLE
  $env:HDX_API_URL = "http://localhost:8000"; $env:HDX_API_KEY = "<key>"
  ./import.ps1                 # upsert all
  ./import.ps1 -DryRun         # preview
  ./import.ps1 -Only services-red.json
  ./import.ps1 -Delete         # remove template-managed dashboards
#>
param(
  [switch]$DryRun,
  [switch]$Delete,
  [switch]$Duplicate,
  [string]$Only
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
  if ($r.data) { return $r.data } else { return $r }
}

# --- resolve sources / tokens ---
$sources = Get-List "/api/v2/sources"
function Src($kind) {
  $s = $sources | Where-Object { $_.kind -eq $kind } | Select-Object -First 1
  if (-not $s) { throw "No source of kind '$kind' found. Create it in HyperDX first." }
  return $s
}
$logSrc = Src "log"; $traceSrc = Src "trace"; $metricSrc = Src "metric"

$tokens = @{
  "{{LOGS_SOURCE_ID}}"    = $logSrc.id
  "{{TRACES_SOURCE_ID}}"  = $traceSrc.id
  "{{METRICS_SOURCE_ID}}" = $metricSrc.id
  "{{CONNECTION_ID}}"     = $metricSrc.connection
  "{{LOGS_SCHEMA}}"       = $logSrc.from.databaseName
  "{{LOGS_TABLE}}"        = $logSrc.from.tableName
  "{{TRACES_SCHEMA}}"     = $traceSrc.from.databaseName
  "{{TRACES_TABLE}}"      = $traceSrc.from.tableName
  "{{METRICS_SCHEMA}}"    = $metricSrc.from.databaseName
}
Write-Host "Resolved sources: logs=$($logSrc.id) traces=$($traceSrc.id) metrics=$($metricSrc.id)"
if ($DryRun) { Write-Host "[DRY RUN] no changes will be written." -ForegroundColor Yellow }

# --- existing dashboards indexed by tmpl tag ---
$existing = Get-List "/api/v2/dashboards"
function Find-Existing($tmplTag) {
  return $existing | Where-Object { $_.tags -contains $tmplTag } | Select-Object -First 1
}

# --- select files ---
$files = Get-ChildItem -Path (Join-Path $PSScriptRoot "dashboards") -Filter *.json
if ($Only) {
  $wanted = $Only.Split(',') | ForEach-Object { $_.Trim() }
  $files = $files | Where-Object { $wanted -contains $_.Name }
}

foreach ($f in $files) {
  $raw = Get-Content $f.FullName -Raw
  $obj = $raw | ConvertFrom-Json
  $tmplTag = $obj.tags | Where-Object { $_ -like 'tmpl:*' } | Select-Object -First 1
  if (-not $tmplTag) { Write-Warning "$($f.Name) has no 'tmpl:' tag; skipping."; continue }
  $match = Find-Existing $tmplTag

  # --- delete mode ---
  if ($Delete) {
    if ($match) {
      if ($DryRun) { Write-Host "[DRY RUN] would DELETE $($f.Name) -> $($match.id)" -ForegroundColor Yellow }
      else {
        Invoke-RestMethod -Uri "$BaseUrl/api/v2/dashboards/$($match.id)" -Headers $Headers -Method Delete | Out-Null
        Write-Host "Deleted $($f.Name) -> $($match.id)" -ForegroundColor Red
      }
    } else { Write-Host "No existing dashboard for $($f.Name) ($tmplTag)" }
    continue
  }

  # --- token substitution ---
  foreach ($k in $tokens.Keys) { $raw = $raw.Replace($k, [string]$tokens[$k]) }
  # Case-SENSITIVE check: tokens are UPPERCASE (e.g. {{TRACES_SOURCE_ID}}). A case-insensitive
  # match would falsely flag intentional onClick row-variables like {{ServiceName}}.
  if ($raw -cmatch "\{\{[A-Z_]+\}\}") { Write-Warning "$($f.Name) has unresolved tokens; skipping."; continue }

  $useUpdate = ($match -and -not $Duplicate)
  $action = if ($useUpdate) { "UPDATE -> $($match.id)" } else { "CREATE" }

  if ($DryRun) { Write-Host "[DRY RUN] would $action  $($f.Name)" -ForegroundColor Yellow; continue }

  try {
    if ($useUpdate) {
      # On update (PUT), each filter requires an "id" (UpdateDashboardRequest uses Filter, not
      # FilterInput). Reuse the existing dashboard's filter ids (matched by expression); mint a
      # new id for any filter the existing dashboard doesn't have.
      $putBody = $raw
      $payload = $raw | ConvertFrom-Json
      if ($payload.filters) {
        $existingFilterId = @{}
        if ($match.filters) { foreach ($ef in $match.filters) { $existingFilterId[$ef.expression] = $ef.id } }
        foreach ($fl in @($payload.filters)) {
          $fid = if ($existingFilterId.ContainsKey($fl.expression)) { $existingFilterId[$fl.expression] }
                 else { [guid]::NewGuid().ToString('N').Substring(0, 24) }
          if ($fl.PSObject.Properties.Name -contains 'id') { $fl.id = $fid }
          else { $fl | Add-Member -NotePropertyName id -NotePropertyValue $fid }
        }
        $putBody = $payload | ConvertTo-Json -Depth 40
      }
      $resp = Invoke-RestMethod -Uri "$BaseUrl/api/v2/dashboards/$($match.id)" -Headers $Headers `
                -Method Put -ContentType "application/json" -Body $putBody
      Write-Host "Updated $($f.Name) -> $($match.id)" -ForegroundColor Green
    } else {
      $resp = Invoke-RestMethod -Uri "$BaseUrl/api/v2/dashboards" -Headers $Headers `
                -Method Post -ContentType "application/json" -Body $raw
      $id = if ($resp.data.id) { $resp.data.id } else { $resp.id }
      Write-Host "Created $($f.Name) -> $id" -ForegroundColor Green
    }
  } catch {
    Write-Warning "Failed on $($f.Name): $($_.Exception.Message)"
  }
}

Write-Host "Done."
