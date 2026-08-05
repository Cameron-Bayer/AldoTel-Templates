<#
.SYNOPSIS
  Compatibility pre-flight for the ClickStack dashboard templates.

.DESCRIPTION
  For every metric/field each dashboard needs (see requirements.json), runs a lightweight
  query via the HyperDX v2 charts API and reports whether the OTel telemetry each dashboard
  reads is actually flowing. NOTE: this checks OTel data presence only - it does NOT verify
  ClickHouse Raw SQL access (system.parts / system.part_log / system.query_log) that the
  SQL-based dashboards (clickhouse-storage-mergetree, clickhouse-queryperf) additionally require.

  Statuses per dashboard:
    OK        all required + optional checks have data
    DEGRADED  all required checks pass; some optional tiles will be empty
    FAIL      one or more required checks have no data (do not import as-is)
    UNKNOWN   one or more probes still failed after retries; run again before importing

.EXAMPLE
  $env:HDX_API_URL = "http://localhost:8000"
  $env:HDX_API_KEY = "<Personal API Access Key>"
  ./preflight.ps1
  ./preflight.ps1 -LookbackHours 6
  ./preflight.ps1 -MetricProbeMinutes 15 -QueryRetries 3
#>
param(
  [ValidateRange(1, 720)]
  [int]$LookbackHours = 24,
  [ValidateRange(1, 1440)]
  [int]$MetricProbeMinutes = 60,
  [ValidateRange(0, 10)]
  [int]$QueryRetries = 2
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
$metricStartTime = [Math]::Max(
  $startTime,
  $endTime - ([int64]$MetricProbeMinutes * 60 * 1000)
)
$checkCache = @{}

# Returns whether the check has data. Metric probes use a short window because these
# signals are emitted frequently; logs/traces retain the longer configurable lookback.
function Test-Check($check) {
  $kindToSource = @{ metric = 'metric'; trace = 'trace'; log = 'log' }
  $sourceId = $srcByKind[$kindToSource[$check.kind]]
  $cacheKey = "$($check.kind)|$($check.metricType)|$($check.metricName)|$($check.where)"
  if ($checkCache.ContainsKey($cacheKey)) {
    $cached = $checkCache[$cacheKey]
    return @{ ok = $cached.ok; error = $false; detail = "$($cached.detail), cached" }
  }

  $series = @{ sourceId = $sourceId; aggFn = 'count'; where = ''; groupBy = @() }
  $isMetric = ($check.kind -eq 'metric')
  if ($isMetric) {
    # 'count' is not a valid aggregation for metric series (returns no datapoints), and a gauge
    # can legitimately read 0 while still flowing - so use avg and test for *presence* of any
    # datapoint rather than a non-zero sum. Histogram metrics reject avg/sum, so verify them with
    # count (which the charts API does support for the histogram data type).
    $series.aggFn          = if ($check.metricType -eq 'histogram') { 'count' } else { 'avg' }
    $series.metricName     = $check.metricName
    $series.metricDataType = $check.metricType
  } else {
    if ($check.where) { $series.where = $check.where; $series.whereLanguage = 'lucene' }
  }

  $queryStartTime = if ($isMetric) { $metricStartTime } else { $startTime }
  $windowLabel = if ($isMetric) { "$MetricProbeMinutes`m" } else { "$LookbackHours`h" }
  $body = @{ series = @($series); startTime = $queryStartTime; endTime = $endTime
             granularity = '1h'; seriesReturnType = 'column' } | ConvertTo-Json -Depth 6

  $lastError = $null
  for ($attempt = 0; $attempt -le $QueryRetries; $attempt++) {
    try {
      $r = Invoke-RestMethod -Uri "$BaseUrl/api/v2/charts/series" -Headers $Headers `
             -Method Post -ContentType 'application/json' -Body $body
      if ($isMetric) {
        $points = 0
        foreach ($pt in $r.data) { if ($null -ne $pt.series_0) { $points++ } }
        $result = @{ ok = ($points -gt 0); error = $false; detail = "points=$points, window=$windowLabel" }
      } else {
        $sum = 0
        foreach ($pt in $r.data) { $v = $pt.series_0; if ($v) { $sum += [double]$v } }
        $result = @{ ok = ($sum -gt 0); error = $false; detail = "rows=$sum, window=$windowLabel" }
      }
      $checkCache[$cacheKey] = $result
      return $result
    } catch {
      $lastError = $_.Exception.Message
      if ($attempt -lt $QueryRetries) {
        Start-Sleep -Milliseconds (250 * ($attempt + 1))
      }
    }
  }

  $result = @{ ok = $false; error = $true; detail = "query error after $($QueryRetries + 1) attempts: $lastError" }
  return $result
}

$recommend = @()
$summary   = @()

foreach ($d in $req.dashboards) {
  Write-Host ""
  $tierTag = if ($d.tier -eq 'advanced') { ' [advanced]' } else { '' }
  Write-Host "== $($d.name) ($($d.file))$tierTag ==" -ForegroundColor Cyan
  Write-Host ("   receivers: " + ($d.receivers -join '; ')) -ForegroundColor DarkGray

  $reqFail = 0; $optFail = 0; $queryErrors = 0
  foreach ($c in $d.checks) {
    $label = if ($c.metricName) { $c.metricName } else { $c.label }
    $res = Test-Check $c
    $tag = if ($c.required) { "[required]" } else { "[optional]" }
    if ($res.ok) {
      Write-Host ("   PASS $tag $label  ($($res.detail))") -ForegroundColor Green
    } elseif ($res.error) {
      $queryErrors++
      Write-Host ("   ERROR $tag $label  ($($res.detail))") -ForegroundColor Magenta
    } else {
      if ($c.required) { $reqFail++ } else { $optFail++ }
      $color = if ($c.required) { 'Red' } else { 'Yellow' }
      Write-Host ("   MISS $tag $label  ($($res.detail))") -ForegroundColor $color
    }
  }

  $status = if ($reqFail -gt 0) { 'FAIL' } elseif ($queryErrors -gt 0) { 'UNKNOWN' } elseif ($optFail -gt 0) { 'DEGRADED' } else { 'OK' }
  if ($status -in @('OK', 'DEGRADED')) { $recommend += $d.file }
  $summary += [pscustomobject]@{ Dashboard = $d.name; Tier = $d.tier; Status = $status; ReqMissing = $reqFail; OptMissing = $optFail; QueryErrors = $queryErrors }
}

Write-Host ""
Write-Host "===== SUMMARY =====" -ForegroundColor Cyan
$summary | Format-Table -AutoSize

if ($recommend.Count -gt 0) {
  Write-Host "OTel data present (telemetry tiles will render):" -ForegroundColor Green
  $recommend | ForEach-Object { Write-Host "   $_" }
  Write-Host ""
  Write-Host "Note: Raw-SQL dashboards also need the HyperDX ClickHouse user to have SELECT on the"
  Write-Host "      relevant system.* tables (not checked here) - see requirements.json 'receivers'."
  Write-Host ""
  Write-Host "Then run: ./import.ps1 -Only $($recommend -join ',')"
} else {
  Write-Host "No dashboards passed their required checks. Verify your OTel collector is sending data." -ForegroundColor Red
}
