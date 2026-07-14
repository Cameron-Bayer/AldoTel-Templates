<#
.SYNOPSIS
  Discover the metric names that actually exist in your ClickStack install and compare
  them to what the dashboard templates expect.

.DESCRIPTION
  preflight.ps1 tells you whether a dashboard's *exact* expected metric name has data. When it
  reports MISS, the metric may be genuinely absent OR just named differently by your collector
  (e.g. k8s.node.cpu.usage vs k8s.node.cpu.utilization, or a *_total suffix that isn't there).

  This script answers that question definitively. It:
    1. Resolves your metric schema (database + gauge/sum/histogram tables) from the HyperDX API,
       so it adapts to any install.
    2. Enumerates the DISTINCT metric names present in ClickHouse over the lookback window.
    3. Compares them to the expected names in requirements.json and, for every MISSING one,
       fuzzy-matches against the names you *do* have and prints the closest candidates.

  Use it to decide, per missing metric: truly absent (collector not sending it) vs renamed
  (point the tile + requirements.json at the real name).

.PARAMETER LookbackHours
  Only consider metric names seen in the last N hours (default 24). Use 0 to scan all data.

.PARAMETER Table
  Restrict to one metric table: gauge, sum, or histogram. Default: all three.

.PARAMETER Top
  How many fuzzy suggestions to show per missing metric (default 3).

.PARAMETER DumpTo
  Optional path. Writes the full sorted list of actual metric names to this file for eyeballing.

.PARAMETER ShowAll
  Also print every actual metric name to the console (grouped by prefix), not just the comparison.

.NOTES
  Connection is via environment variables:

    HyperDX API (to resolve the metric schema - same vars preflight/import use):
      $env:HDX_API_URL  = "https://api.aldotel.local"      # or http://localhost:8000 for a port-forward
      $env:HDX_API_KEY  = "<Personal API Access Key>"

    ClickHouse HTTP (to enumerate metric names - the metrics live here, not behind the HDX API):
      $env:CH_URL       = "http://localhost:8123"          # see "Reaching ClickHouse" below
      $env:CH_USER      = "app"                             # default: app
      $env:CH_PASSWORD  = "<clickhouse password>"           # omit if the user has no password
      $env:CH_DATABASE  = "default"                         # optional; otherwise taken from the HDX source

  Reaching ClickHouse:
    * Helm / Kubernetes install (ingress at aldotel.local):
        kubectl -n <ns> port-forward svc/<clickhouse-headless-svc> 8123:8123
        # then $env:CH_URL = "http://localhost:8123"
      (find the service with:  kubectl -n <ns> get svc | Select-String clickhouse )
    * docker-compose / all-in-one:  ClickHouse HTTP is usually already on http://localhost:8123.

  If HDX_API_URL / HDX_API_KEY are not set, the script falls back to database "default" and the
  standard otel_metrics_gauge/sum/histogram table names.

.EXAMPLE
  $env:HDX_API_URL = "https://api.aldotel.local"; $env:HDX_API_KEY = "<key>"
  $env:CH_URL = "http://localhost:8123"; $env:CH_USER = "app"; $env:CH_PASSWORD = "<pw>"
  ./list-metrics.ps1

.EXAMPLE
  # Only investigate the k8s dashboard's family, scan all history, and save the full list:
  ./list-metrics.ps1 -Table gauge -LookbackHours 0 -DumpTo ./actual-metrics.txt
#>
param(
  [int]$LookbackHours = 24,
  [ValidateSet('gauge','sum','histogram')]
  [string]$Table,
  [int]$Top = 3,
  [string]$DumpTo,
  [switch]$ShowAll,
  [switch]$SkipSignals,
  [switch]$SkipCertificateCheck
)

$ErrorActionPreference = "Stop"

# ---------- ClickHouse connection ----------
$ChUrl  = if ($env:CH_URL) { $env:CH_URL.TrimEnd('/') } else { "http://localhost:8123" }
$ChUser = if ($env:CH_USER) { $env:CH_USER } else { "app" }
$ChPass = $env:CH_PASSWORD

$chHeaders = @{ 'X-ClickHouse-User' = $ChUser }
if ($ChPass) { $chHeaders['X-ClickHouse-Key'] = $ChPass }

$irmCommon = @{}
if ($SkipCertificateCheck) { $irmCommon['SkipCertificateCheck'] = $true }

function Invoke-CH([string]$sql) {
  Invoke-RestMethod -Uri "$ChUrl/" -Method Post -Body $sql -Headers $chHeaders @irmCommon
}

# ---------- Resolve metric schema (database + table names) ----------
$database = if ($env:CH_DATABASE) { $env:CH_DATABASE } else { $null }
$metricTables = [ordered]@{ gauge = 'otel_metrics_gauge'; sum = 'otel_metrics_sum'; histogram = 'otel_metrics_histogram' }
# log/trace schema (for signal-value discovery); defaults match standard ClickStack
$logSchema   = @{ db = $null; table = 'otel_logs';   ts = 'Timestamp' }
$traceSchema = @{ db = $null; table = 'otel_traces'; ts = 'Timestamp' }

if ($env:HDX_API_URL -and $env:HDX_API_KEY) {
  try {
    $base = $env:HDX_API_URL.TrimEnd('/')
    $sresp = Invoke-RestMethod -Uri "$base/api/v2/sources" -Headers @{ Authorization = "Bearer $($env:HDX_API_KEY)" } @irmCommon
    $sources = if ($sresp.data) { $sresp.data } else { $sresp }
    $m = $sources | Where-Object { $_.kind -eq 'metric' } | Select-Object -First 1
    if ($m) {
      if (-not $database -and $m.from.databaseName) { $database = $m.from.databaseName }
      if ($m.metricTables) {
        foreach ($k in @('gauge','sum','histogram')) {
          if ($m.metricTables.$k) { $metricTables[$k] = $m.metricTables.$k }
        }
      }
      Write-Host "Resolved metric schema from HyperDX: db='$database' tables=$($metricTables.Values -join ', ')" -ForegroundColor DarkGray
    }
    $lg = $sources | Where-Object { $_.kind -eq 'log' } | Select-Object -First 1
    if ($lg) {
      if ($lg.from.databaseName) { $logSchema.db = $lg.from.databaseName }
      if ($lg.from.tableName)    { $logSchema.table = $lg.from.tableName }
      if ($lg.timestampValueExpression) { $logSchema.ts = $lg.timestampValueExpression }
    }
    $tr = $sources | Where-Object { $_.kind -eq 'trace' } | Select-Object -First 1
    if ($tr) {
      if ($tr.from.databaseName) { $traceSchema.db = $tr.from.databaseName }
      if ($tr.from.tableName)    { $traceSchema.table = $tr.from.tableName }
      if ($tr.timestampValueExpression) { $traceSchema.ts = $tr.timestampValueExpression }
    }
  } catch {
    Write-Host "WARN: could not resolve schema from HyperDX API ($($_.Exception.Message)); using defaults." -ForegroundColor Yellow
  }
}
if (-not $database) { $database = 'default' }
if (-not $logSchema.db)   { $logSchema.db = $database }
if (-not $traceSchema.db) { $traceSchema.db = $database }

$tablesToScan = if ($Table) { @($Table) } else { @('gauge','sum','histogram') }

# ---------- Enumerate actual metric names ----------
$timeFilter = ''
if ($LookbackHours -gt 0) { $timeFilter = "WHERE TimeUnix >= now() - INTERVAL $LookbackHours HOUR" }

# actualByTable: tableKind -> hashset of names ; actualAll: name -> kinds[]
$actualAll = @{}
Write-Host "Enumerating metric names from ClickHouse at $ChUrl (db=$database, lookback=${LookbackHours}h) ..." -ForegroundColor Cyan
foreach ($k in $tablesToScan) {
  $tbl = $metricTables[$k]
  $sql = "SELECT DISTINCT MetricName FROM ``$database``.``$tbl`` $timeFilter FORMAT TabSeparated"
  try {
    $out = Invoke-CH $sql
    $names = @($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Host ("   {0,-10} {1,-28} {2} names" -f $k, $tbl, $names.Count) -ForegroundColor DarkGray
    foreach ($n in $names) {
      if (-not $actualAll.ContainsKey($n)) { $actualAll[$n] = New-Object System.Collections.Generic.List[string] }
      $actualAll[$n].Add($k)
    }
  } catch {
    Write-Host "   ERROR reading $database.$tbl : $($_.Exception.Message)" -ForegroundColor Red
  }
}
$actualNames = @($actualAll.Keys)
if ($actualNames.Count -eq 0) {
  throw "No metric names found. Check CH_URL/CH_USER/CH_PASSWORD and that metrics are flowing (try -LookbackHours 0)."
}
Write-Host ("Total distinct metric names: {0}" -f $actualNames.Count) -ForegroundColor Cyan

if ($DumpTo) {
  $actualNames | Sort-Object | Set-Content -Path $DumpTo -Encoding UTF8
  Write-Host "Wrote full list to $DumpTo" -ForegroundColor DarkGray
}

# ---------- Fuzzy matching ----------
function Get-Norm([string]$s) { ($s -replace '[^a-zA-Z0-9]', '').ToLowerInvariant() }
function Get-Tokens([string]$s) { @($s -split '[^a-zA-Z0-9]+' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() }) }

# Similarity: token Jaccard (weighted) + substring bonus on normalized strings. 0..1
function Get-Similarity([string]$a, [string]$b) {
  $ta = Get-Tokens $a; $tb = Get-Tokens $b
  $setA = [System.Collections.Generic.HashSet[string]]::new([string[]]$ta)
  $setB = [System.Collections.Generic.HashSet[string]]::new([string[]]$tb)
  $inter = [System.Collections.Generic.HashSet[string]]::new($setA); $inter.IntersectWith($setB)
  $union = [System.Collections.Generic.HashSet[string]]::new($setA); $union.UnionWith($setB)
  $jaccard = if ($union.Count -gt 0) { $inter.Count / $union.Count } else { 0 }

  $na = Get-Norm $a; $nb = Get-Norm $b
  $sub = 0.0
  if ($na -and $nb) {
    if ($na.Contains($nb) -or $nb.Contains($na)) {
      $sub = [Math]::Min($na.Length, $nb.Length) / [Math]::Max($na.Length, $nb.Length)
    }
  }
  [Math]::Max($jaccard, $sub * 0.9)
}

# ---------- Load expected metrics from requirements.json ----------
$req = Get-Content (Join-Path $PSScriptRoot "requirements.json") -Raw | ConvertFrom-Json
# expected: metricName -> @{ required=[bool]; dashboards=@() }
$expected = [ordered]@{}
foreach ($d in $req.dashboards) {
  foreach ($c in $d.checks) {
    if ($c.kind -ne 'metric') { continue }
    if (-not $expected.Contains($c.metricName)) {
      $expected[$c.metricName] = @{ required = [bool]$c.required; dashboards = New-Object System.Collections.Generic.List[string]; type = $c.metricType }
    }
    if ($c.required) { $expected[$c.metricName].required = $true }
    if (-not $expected[$c.metricName].dashboards.Contains($d.file)) { $expected[$c.metricName].dashboards.Add($d.file) }
  }
}

$actualSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$actualNames)

# ---------- Compare ----------
$present = @(); $missing = @()
foreach ($name in $expected.Keys) {
  $info = $expected[$name]
  # When restricted to one table, only audit expected metrics of that type — otherwise metrics
  # that legitimately live in a different table would be reported as falsely absent.
  if ($Table -and $info.type -ne $Table) { continue }
  $row = [pscustomobject]@{
    Metric = $name; Required = $info.required; Type = $info.type; Dashboards = ($info.dashboards -join ', ')
  }
  if ($actualSet.Contains($name)) { $present += $row } else { $missing += $row }
}
$auditedCount = $present.Count + $missing.Count

Write-Host ""
Write-Host "===== EXPECTED METRICS AUDIT =====" -ForegroundColor Cyan
Write-Host ("Present: {0}   Missing: {1}   (of {2} expected metric names{3})" -f $present.Count, $missing.Count, $auditedCount, $(if ($Table) { " of type '$Table'" } else { "" }))

if ($missing.Count -eq 0) {
  Write-Host "Every expected metric name exists in your install. Any preflight MISS is a lookback/aggregation quirk, not a naming issue." -ForegroundColor Green
} else {
  Write-Host ""
  Write-Host "----- MISSING expected metrics (with closest actual names) -----" -ForegroundColor Yellow
  foreach ($row in ($missing | Sort-Object -Property @{e={-[int]$_.Required}}, Metric)) {
    $tag = if ($row.Required) { "[required]" } else { "[optional]" }
    $color = if ($row.Required) { 'Red' } else { 'Yellow' }
    Write-Host ("`n{0} {1}   (type={2}; used by {3})" -f $tag, $row.Metric, $row.Type, $row.Dashboards) -ForegroundColor $color

    $scored = foreach ($an in $actualNames) {
      [pscustomobject]@{ Name = $an; Score = (Get-Similarity $row.Metric $an) }
    }
    $best = $scored | Where-Object { $_.Score -gt 0.34 } | Sort-Object Score -Descending | Select-Object -First $Top
    if ($best) {
      foreach ($b in $best) {
        $kinds = ($actualAll[$b.Name] -join '/')
        Write-Host ("     ~ {0,-6:P0}  {1}  ({2})" -f $b.Score, $b.Name, $kinds) -ForegroundColor Gray
      }
      Write-Host "       -> likely RENAMED. If one matches, update the tile + requirements.json metricName." -ForegroundColor DarkGray
    } else {
      Write-Host "     (no similar name found) -> likely TRULY ABSENT: this collector/receiver isn't sending it." -ForegroundColor DarkGray
    }
  }
}

if ($ShowAll) {
  Write-Host ""
  Write-Host "===== ALL ACTUAL METRIC NAMES (grouped by prefix) =====" -ForegroundColor Cyan
  $actualNames | Group-Object { ($_ -split '[._]')[0] } | Sort-Object Name | ForEach-Object {
    Write-Host ("`n[{0}]  ({1})" -f $_.Name, $_.Count) -ForegroundColor Cyan
    $_.Group | Sort-Object | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
  }
}

# ---------- Signal-value discovery (logs severity, trace kind/status) ----------
# Trace/log tiles filter on column *values* (SpanKind:Server, StatusCode:Error, error/fatal severity),
# not metric names. A preflight MISS there can mean the value is labelled differently. Enumerate the
# actual distinct values so a value-mismatch is obvious.
if (-not $SkipSignals) {
  $tsWhere = { param($col) if ($LookbackHours -gt 0) { "WHERE $col >= now() - INTERVAL $LookbackHours HOUR" } else { "" } }

  Write-Host ""
  Write-Host "===== SIGNAL VALUE DISCOVERY (logs & traces) =====" -ForegroundColor Cyan

  # --- Logs: severity labelling ---
  try {
    $lw = & $tsWhere $logSchema.ts
    $sql = "SELECT SeverityText, SeverityNumber, count() AS c FROM ``$($logSchema.db)``.``$($logSchema.table)`` $lw GROUP BY SeverityText, SeverityNumber ORDER BY c DESC LIMIT 30 FORMAT TabSeparated"
    $rows = @((Invoke-CH $sql) -split "`n" | Where-Object { $_ })
    if ($rows.Count -eq 0) {
      Write-Host "Logs: no rows in window." -ForegroundColor DarkGray
    } else {
      Write-Host "`nLogs — SeverityText / SeverityNumber distribution ($($logSchema.db).$($logSchema.table)):" -ForegroundColor White
      $errTotal = 0
      foreach ($r in $rows) {
        $f = $r -split "`t"; $txt = $f[0]; $num = [int]($f[1]); $cnt = [int64]($f[2])
        $isErr = ($num -ge 17) -or ($txt.ToLower() -in @('error','fatal','err','critical','crit','emerg','alert'))
        if ($isErr) { $errTotal += $cnt }
        $mark = if ($isErr) { 'ERR' } else { '   ' }
        Write-Host ("   {0}  {1,-14} num={2,-3} {3,12:N0}" -f $mark, $(if($txt){$txt}else{'(empty)'}), $num, $cnt) -ForegroundColor $(if($isErr){'Yellow'}else{'DarkGray'})
      }
      if ($errTotal -gt 0) {
        Write-Host ("   => error/fatal logs ARE present ({0:N0} rows). The error tiles should populate; if preflight said MISS, widen the lookback." -f $errTotal) -ForegroundColor Green
      } else {
        Write-Host "   => no error/fatal-level logs in window. 'error logs' is TRULY ABSENT (not a naming issue) — nothing is logging at ERROR/FATAL." -ForegroundColor DarkGray
      }
    }
  } catch {
    Write-Host "Logs: could not read $($logSchema.db).$($logSchema.table) ($($_.Exception.Message))." -ForegroundColor Yellow
  }

  # --- Traces: span kind + status ---
  try {
    $tw = & $tsWhere $traceSchema.ts
    $sql = "SELECT SpanKind, StatusCode, count() AS c FROM ``$($traceSchema.db)``.``$($traceSchema.table)`` $tw GROUP BY SpanKind, StatusCode ORDER BY c DESC LIMIT 30 FORMAT TabSeparated"
    $rows = @((Invoke-CH $sql) -split "`n" | Where-Object { $_ })
    if ($rows.Count -eq 0) {
      Write-Host "`nTraces: no rows in window => trace dashboards (services-red, slo-errorbudget) are TRULY EMPTY: no spans are being ingested." -ForegroundColor DarkGray
    } else {
      Write-Host "`nTraces — SpanKind / StatusCode distribution ($($traceSchema.db).$($traceSchema.table)):" -ForegroundColor White
      $kinds = @{}; $statuses = @{}
      foreach ($r in $rows) {
        $f = $r -split "`t"; $k = $f[0]; $st = $f[1]; $cnt = [int64]($f[2])
        Write-Host ("   SpanKind={0,-12} StatusCode={1,-8} {2,12:N0}" -f $(if($k){$k}else{'(empty)'}), $(if($st){$st}else{'(empty)'}), $cnt) -ForegroundColor DarkGray
        $kinds[$k] = $true; $statuses[$st] = $true
      }
      # Templates filter SpanKind:Server and StatusCode:Error — flag if those exact values are absent
      if (-not ($kinds.Keys | Where-Object { $_ -ieq 'Server' })) {
        Write-Host ("   ! No SpanKind='Server' found (present: {0}). The templates filter SpanKind:Server — adjust the tile filter to your value." -f (($kinds.Keys | Sort-Object) -join ', ')) -ForegroundColor Yellow
      }
      if (-not ($statuses.Keys | Where-Object { $_ -ieq 'Error' })) {
        Write-Host ("   ! No StatusCode='Error' found (present: {0}). Error-span tiles filter StatusCode:Error." -f (($statuses.Keys | Sort-Object) -join ', ')) -ForegroundColor Yellow
      }
    }
  } catch {
    Write-Host "Traces: could not read $($traceSchema.db).$($traceSchema.table) ($($_.Exception.Message))." -ForegroundColor Yellow
  }
}

Write-Host ""
Write-Host "Done. Present metrics: $($present.Count). Investigate the MISSING list above." -ForegroundColor Cyan
