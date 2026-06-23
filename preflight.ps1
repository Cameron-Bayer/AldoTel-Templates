<#
.SYNOPSIS
  Compatibility pre-flight for the ClickStack dashboard templates.

.DESCRIPTION
  For every metric/field each dashboard needs (see requirements.json), runs a lightweight
  query via the HyperDX v2 charts API and reports whether data is actually flowing. Tells you
  which dashboards are safe to import BEFORE you import them.

  Statuses per dashboard:
    OK        all required + optional checks have data
    DEGRADED  all required checks pass; some optional tiles will be empty
    FAIL      one or more required checks have no data (do not import as-is)

.EXAMPLE
  $env:HDX_API_URL = "http://localhost:8000"
  $env:HDX_API_KEY = "<Personal API Access Key>"
  ./preflight.ps1
  ./preflight.ps1 -LookbackHours 6
#>
param(
  [int]$LookbackHours = 24
)

$ErrorActionPreference = "Stop"

$BaseUrl = $env:HDX_API_URL
$ApiKey  = $env:HDX_API_KEY
if (-not $BaseUrl) { throw "Set HDX_API_URL (e.g. http://localhost:8000)" }
if (-not $ApiKey)  { throw "Set HDX_API_KEY (Team Settings -> API Keys)" }
$BaseUrl = $BaseUrl.TrimEnd('/')
$Headers = @{ Authorization = "Bearer $ApiKey" }

$req = Get-Content (Join-Path $PSScriptRoot "requirements.json") -Raw | ConvertFrom-Json

Write-Host "Resolving sources from $BaseUrl ..."
$sresp = Invoke-RestMethod -Uri "$BaseUrl/api/v2/sources" -Headers $Headers -Method Get
$sources = if ($sresp.data) { $sresp.data } else { $sresp }
$srcByKind = @{}
foreach ($s in $sources) { if (-not $srcByKind.ContainsKey($s.kind)) { $srcByKind[$s.kind] = $s.id } }
foreach ($k in 'log','trace','metric') {
  if (-not $srcByKind.ContainsKey($k)) { throw "No source of kind '$k' found in HyperDX." }
}

$endTime   = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$startTime = $endTime - ($LookbackHours * 3600 * 1000)

# Returns $true if the check's query returns any non-zero data in the window.
function Test-Check($check) {
  $kindToSource = @{ metric = 'metric'; trace = 'trace'; log = 'log' }
  $sourceId = $srcByKind[$kindToSource[$check.kind]]

  $series = @{ sourceId = $sourceId; aggFn = 'count'; where = ''; groupBy = @() }
  $isMetric = ($check.kind -eq 'metric')
  if ($isMetric) {
    # 'count' is not a valid aggregation for metric series (returns no datapoints), and a gauge
    # can legitimately read 0 while still flowing — so use avg and test for *presence* of any
    # datapoint rather than a non-zero sum.
    $series.aggFn          = 'avg'
    $series.metricName     = $check.metricName
    $series.metricDataType = $check.metricType
  } else {
    if ($check.where) { $series.where = $check.where; $series.whereLanguage = 'lucene' }
  }

  $body = @{ series = @($series); startTime = $startTime; endTime = $endTime
             granularity = $(if ($isMetric) { '1h' } else { '1d' }); seriesReturnType = 'column' } | ConvertTo-Json -Depth 6

  try {
    $r = Invoke-RestMethod -Uri "$BaseUrl/api/v2/charts/series" -Headers $Headers `
           -Method Post -ContentType 'application/json' -Body $body
    if ($isMetric) {
      $points = 0
      foreach ($pt in $r.data) { if ($null -ne $pt.series_0) { $points++ } }
      return @{ ok = ($points -gt 0); detail = "points=$points" }
    }
    $sum = 0
    foreach ($pt in $r.data) { $v = $pt.series_0; if ($v) { $sum += [double]$v } }
    return @{ ok = ($sum -gt 0); detail = "rows=$sum" }
  } catch {
    return @{ ok = $false; detail = "query error: $($_.Exception.Message)" }
  }
}

$recommend = @()
$summary   = @()

foreach ($d in $req.dashboards) {
  Write-Host ""
  Write-Host "== $($d.name) ($($d.file)) ==" -ForegroundColor Cyan
  Write-Host ("   receivers: " + ($d.receivers -join '; ')) -ForegroundColor DarkGray

  $reqFail = 0; $optFail = 0
  foreach ($c in $d.checks) {
    $label = if ($c.metricName) { $c.metricName } else { $c.label }
    $res = Test-Check $c
    $tag = if ($c.required) { "[required]" } else { "[optional]" }
    if ($res.ok) {
      Write-Host ("   PASS $tag $label  ($($res.detail))") -ForegroundColor Green
    } else {
      if ($c.required) { $reqFail++ } else { $optFail++ }
      $color = if ($c.required) { 'Red' } else { 'Yellow' }
      Write-Host ("   MISS $tag $label  ($($res.detail))") -ForegroundColor $color
    }
  }

  $status = if ($reqFail -gt 0) { 'FAIL' } elseif ($optFail -gt 0) { 'DEGRADED' } else { 'OK' }
  if ($status -ne 'FAIL') { $recommend += $d.file }
  $summary += [pscustomobject]@{ Dashboard = $d.name; Status = $status; ReqMissing = $reqFail; OptMissing = $optFail }
}

Write-Host ""
Write-Host "===== SUMMARY =====" -ForegroundColor Cyan
$summary | Format-Table -AutoSize

if ($recommend.Count -gt 0) {
  Write-Host "Safe to import:" -ForegroundColor Green
  $recommend | ForEach-Object { Write-Host "   $_" }
  Write-Host ""
  Write-Host "Then run: ./import.ps1 -Only $($recommend -join ',')"
} else {
  Write-Host "No dashboards passed their required checks. Verify your OTel collector is sending data." -ForegroundColor Red
}
