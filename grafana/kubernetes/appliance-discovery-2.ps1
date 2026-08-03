<#
.SYNOPSIS
  Follow-up discovery: diagnose stalled telemetry ingestion and recover the
  inventory answers from the last known-good data window.
.DESCRIPTION
  Run #1 returned empty for sections 5-8 and 13-14 because every one of those
  queries filters on `now() - INTERVAL 2 HOUR`, and the newest row in ClickHouse
  was ~46 hours old. This script:
    * proves (or disproves) that ingestion has stalled, using ClickHouse's own clock
    * shows collector pod health and logs so we can see WHY it stalled
    * re-runs the empty sections anchored to max(TimeUnix) instead of now(),
      so the pod/metric/log inventory is recovered even while ingestion is down
  Read-only: `get`/`logs` and SELECT only.
.EXAMPLE
  ./appliance-discovery-2.ps1
#>
[CmdletBinding()]
param(
  [string]$Namespace,
  [string]$ClickHousePod,
  [string]$ChUser = 'default',
  [string]$ChPassword,
  [string]$OutFile = "appliance-discovery-2.txt"
)

$ErrorActionPreference = 'Continue'
$out = New-Object System.Collections.Generic.List[string]
function W([string]$s = '') { $out.Add($s); Write-Host $s }
function Section([string]$s) { W ''; W ("=" * 70); W "== $s"; W ("=" * 70) }

W "ClickStack stall diagnosis - $(Get-Date -Format o)"
W "context: $(kubectl config current-context 2>&1)"

# --- resolve targets (same logic as run #1) ----------------------------------
if (-not $Namespace) {
  $g = kubectl get deploy -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers 2>&1 |
       Select-String -Pattern 'grafana' | Select-Object -First 1
  if ($g) { $Namespace = ($g.ToString().Trim() -split '\s+')[0] }
}
if (-not $Namespace) { $Namespace = 'aldotel' }

$ChNs = $Namespace
if (-not $ClickHousePod) {
  $p = kubectl get pods -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers 2>&1 |
       Select-String -Pattern 'clickhouse' |
       Where-Object { $_ -notmatch 'operator|probe|version' } | Select-Object -First 1
  if ($p) {
    $parts = ($p.ToString().Trim() -split '\s+')
    $ChNs = $parts[0]; $ClickHousePod = $parts[1]
  }
}
W "resolved: namespace='$Namespace'  clickhouse='$ClickHousePod' (ns '$ChNs')"

function Invoke-Ch([string]$sql) {
  if ($ChPassword) {
    $r = $sql | kubectl exec -i -n $ChNs $ClickHousePod -- clickhouse-client --user $ChUser --password $ChPassword 2>&1
  } else {
    $r = $sql | kubectl exec -i -n $ChNs $ClickHousePod -- clickhouse-client --user $ChUser 2>&1
  }
  ($r | ForEach-Object { $_.ToString() }) -join "`n"
}

$probe = Invoke-Ch "SELECT 1 FORMAT TSV"
if ($probe -notmatch '^\s*1\s*$') {
  W ''
  W "!! Could not query ClickHouse in pod '$ClickHousePod' (ns '$ChNs')."
  W "!! Response was: $probe"
  W "!! Re-run with -Namespace / -ClickHousePod / -ChUser / -ChPassword."
}

# =============================================================================
Section "A. Is ingestion actually stalled? (ClickHouse's OWN clock vs newest row)"
# Using CH's now() removes any client/server timezone doubt.
W (Invoke-Ch @"
SELECT
  name AS tbl, newest,
  ch_now,
  age('minute', newest, ch_now) AS minutes_behind,
  round(age('minute', newest, ch_now) / 60.0, 1) AS hours_behind
FROM (
  SELECT 'otel_metrics_gauge' AS name, max(TimeUnix) AS newest, now() AS ch_now FROM default.otel_metrics_gauge
  UNION ALL SELECT 'otel_metrics_sum',   max(TimeUnix), now() FROM default.otel_metrics_sum
  UNION ALL SELECT 'otel_logs',          max(Timestamp), now() FROM default.otel_logs
  UNION ALL SELECT 'otel_traces',        max(Timestamp), now() FROM default.otel_traces
)
ORDER BY tbl FORMAT PrettyCompact
"@ | Out-String).Trim()
W ''
W "  hours_behind under ~0.1 = healthy. Anything over 1 = ingestion is stopped."
W (Invoke-Ch "SELECT timezone() AS clickhouse_timezone FORMAT PrettyCompact" | Out-String).Trim()

# =============================================================================
Section "B. Ingestion timeline - when exactly did it stop?"
W (Invoke-Ch @"
SELECT toStartOfHour(TimeUnix) AS hour, count() AS rows
FROM default.otel_metrics_gauge
WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_gauge) - INTERVAL 12 HOUR
GROUP BY hour ORDER BY hour FORMAT PrettyCompact
"@ | Out-String).Trim()
W ''
W "  A clean cliff = collectors died. A gradual taper = backpressure/resource issue."

# =============================================================================
Section "C. Collector + ClickHouse pod health (restarts are the smoking gun)"
W (kubectl get pods -A -o wide --no-headers 2>&1 |
   Select-String -Pattern 'otel|collector|clickhouse|keeper' | Out-String).Trim()

# =============================================================================
Section "D. Recent collector logs (why did it stop?)"
foreach ($sel in @('app.kubernetes.io/name=opentelemetry-collector','component=otel-collector')) {
  $pods = kubectl get pods -n $Namespace -l $sel -o name 2>&1
  foreach ($pod in $pods) {
    if ($pod -notmatch '^pod/') { continue }
    W "--- $pod (last 25 lines) ---"
    W (kubectl logs -n $Namespace $pod --tail=25 --all-containers 2>&1 | Out-String).Trim()
    W ''
  }
}
W "--- any collector pod, error lines only ---"
foreach ($line in (kubectl get pods -n $Namespace -o name 2>&1 | Select-String -Pattern 'otel|collector')) {
  $pod = $line.ToString().Trim()
  if ($pod -notmatch '^pod/') { continue }
  $errs = kubectl logs -n $Namespace $pod --tail=200 --all-containers 2>&1 |
          Select-String -Pattern 'error|fail|refused|denied|timeout|exceed|full|no space' |
          Select-Object -Last 12
  if ($errs) { W "--- $pod ---"; W (($errs | ForEach-Object { $_.ToString() }) -join "`n") }
}

# =============================================================================
Section "E. Is ClickHouse out of disk / rejecting writes?"
W (Invoke-Ch @"
SELECT name, formatReadableSize(free_space) AS free, formatReadableSize(total_space) AS total,
       round(100.0 * free_space / total_space, 1) AS pct_free
FROM system.disks FORMAT PrettyCompact
"@ | Out-String).Trim()
W ''
W "--- recent ClickHouse errors ---"
W (Invoke-Ch @"
SELECT name, value, last_error_time FROM system.errors
WHERE value > 0 ORDER BY last_error_time DESC LIMIT 15 FORMAT PrettyCompact
"@ | Out-String).Trim()

# =============================================================================
#  Everything below re-runs run #1's empty sections against the LAST GOOD
#  WINDOW (anchored to max(TimeUnix)) so the answers are recovered regardless
#  of the stall.
# =============================================================================
Section "F. [was 5] Do the 7 metrics the 8 rules need exist? (last-good window)"
W (Invoke-Ch @"
SELECT * FROM (
  SELECT 'gauge' AS tbl, MetricName, count() AS pts, max(TimeUnix) AS latest
  FROM default.otel_metrics_gauge
  WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_gauge) - INTERVAL 2 HOUR
    AND MetricName IN ('k8s.node.filesystem.available','k8s.node.filesystem.capacity',
                       'system.cpu.utilization','system.memory.utilization',
                       'k8s.pod.phase','k8s.container.restarts')
  GROUP BY MetricName
  UNION ALL
  SELECT 'sum' AS tbl, MetricName, count() AS pts, max(TimeUnix) AS latest
  FROM default.otel_metrics_sum
  WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_sum) - INTERVAL 2 HOUR
    AND MetricName = 'k8s.node.uptime'
  GROUP BY MetricName
) ORDER BY tbl, MetricName FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "G. [was 6] Node names"
W (Invoke-Ch @"
SELECT DISTINCT ResourceAttributes['k8s.node.name'] AS node
FROM default.otel_metrics_gauge
WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_gauge) - INTERVAL 2 HOUR
  AND MetricName='k8s.node.filesystem.capacity'
FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "H. [was 7] FULL pod inventory in telemetry (Key Vault candidate)"
W (Invoke-Ch @"
SELECT DISTINCT replaceRegexpOne(ResourceAttributes['k8s.pod.name'], '-[a-z0-9]{6,10}-[a-z0-9]{5}$|-[0-9]+$', '') AS workload
FROM default.otel_metrics_gauge
WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_gauge) - INTERVAL 2 HOUR
  AND MetricName='k8s.pod.phase'
ORDER BY workload FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "I. [was 8] FULL ServiceName inventory in logs (policy-engine candidate)"
W (Invoke-Ch @"
SELECT ServiceName, count() AS log_rows,
       countIf(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) AS errors
FROM default.otel_logs
WHERE Timestamp > (SELECT max(Timestamp) FROM default.otel_logs) - INTERVAL 2 HOUR
GROUP BY ServiceName ORDER BY log_rows DESC LIMIT 60 FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "J. [was 10] PER-VOLUME disk data? (filesystem scraper IS enabled here)"
W "-- (a) hostmetrics system.filesystem.* metrics --"
W (Invoke-Ch @"
SELECT MetricName, count() AS pts, uniqExact(toString(Attributes)) AS distinct_attr_sets,
       any(toString(Attributes)) AS sample_attrs
FROM default.otel_metrics_gauge
WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_gauge) - INTERVAL 2 HOUR
  AND MetricName LIKE 'system.filesystem%'
GROUP BY MetricName ORDER BY MetricName FORMAT PrettyCompact
"@ | Out-String).Trim()
W ''
W "-- (b) distinct mountpoints/devices, if present (this is what 'per volume' needs) --"
W (Invoke-Ch @"
SELECT DISTINCT Attributes['device'] AS device, Attributes['mountpoint'] AS mountpoint,
       Attributes['type'] AS fstype
FROM default.otel_metrics_gauge
WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_gauge) - INTERVAL 2 HOUR
  AND MetricName LIKE 'system.filesystem%'
ORDER BY mountpoint LIMIT 40 FORMAT PrettyCompact
"@ | Out-String).Trim()
W ''
W "-- (c) kubeletstats node filesystem attributes --"
W (Invoke-Ch @"
SELECT MetricName, count() AS pts, length(any(Attributes)) AS attr_count,
       any(toString(Attributes)) AS sample_attrs
FROM default.otel_metrics_gauge
WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_gauge) - INTERVAL 2 HOUR
  AND MetricName LIKE 'k8s.node.filesystem%'
GROUP BY MetricName FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "K. [was 13] FULL metric inventory (which of the other 35 alerts are reachable)"
W (Invoke-Ch @"
SELECT prefix, count() AS distinct_metrics FROM (
  SELECT DISTINCT MetricName, splitByChar('.', MetricName)[1] AS prefix
  FROM default.otel_metrics_gauge
  WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_gauge) - INTERVAL 2 HOUR
    AND MetricName NOT LIKE 'ClickHouse%'
) GROUP BY prefix ORDER BY distinct_metrics DESC FORMAT PrettyCompact
"@ | Out-String).Trim()
W ''
W "-- infrastructure-relevant metric names --"
W (Invoke-Ch @"
SELECT DISTINCT MetricName FROM (
  SELECT MetricName FROM default.otel_metrics_gauge
  WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_gauge) - INTERVAL 2 HOUR
  UNION ALL
  SELECT MetricName FROM default.otel_metrics_sum
  WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_sum) - INTERVAL 2 HOUR
)
WHERE MetricName LIKE 'system.%' OR MetricName LIKE 'k8s.node.%'
   OR MetricName LIKE 'host.%' OR MetricName LIKE 'process.%'
ORDER BY MetricName LIMIT 120 FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "L. [was 14] cert-manager / Windows / Hyper-V / cluster host-side signal"
W "-- cert-manager exposes cert expiry via Prometheus; are those metrics landing? --"
W (Invoke-Ch @"
SELECT DISTINCT MetricName FROM (
  SELECT MetricName FROM default.otel_metrics_gauge
  WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_gauge) - INTERVAL 2 HOUR
  UNION ALL
  SELECT MetricName FROM default.otel_metrics_sum
  WHERE TimeUnix > (SELECT max(TimeUnix) FROM default.otel_metrics_sum) - INTERVAL 2 HOUR
)
WHERE MetricName ILIKE '%cert%' OR MetricName ILIKE '%x509%' OR MetricName ILIKE '%expir%'
   OR MetricName ILIKE '%windows%' OR MetricName ILIKE '%hyperv%' OR MetricName ILIKE '%cluster%'
   OR MetricName ILIKE '%smart%' OR MetricName ILIKE '%volume%' OR MetricName ILIKE '%nic%'
ORDER BY MetricName LIMIT 80 FORMAT PrettyCompact
"@ | Out-String).Trim()
W ''
W "-- is cert-manager being scraped at all? --"
W (kubectl get svc -n cert-manager -o wide --no-headers 2>&1 | Out-String).Trim()

$out | Set-Content -Path $OutFile -Encoding UTF8
Write-Host ""
Write-Host "Wrote $OutFile - send that file back." -ForegroundColor Green
