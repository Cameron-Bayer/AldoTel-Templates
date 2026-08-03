<#
.SYNOPSIS
  Read-only discovery for the ClickStack alert pack. Answers every open question in one run.
.DESCRIPTION
  Makes NO changes to the cluster - only `get`, `describe`-style reads and SELECT queries.
  Writes everything to appliance-discovery.txt; send that file back.
.EXAMPLE
  ./appliance-discovery.ps1
  ./appliance-discovery.ps1 -Namespace myns -ClickHousePod my-ch-0
#>
[CmdletBinding()]
param(
  [string]$Namespace,
  [string]$ClickHousePod,
  [string]$ChUser = 'default',
  [string]$ChPassword,
  [string]$OutFile = "appliance-discovery.txt"
)

$ErrorActionPreference = 'Continue'
$out = New-Object System.Collections.Generic.List[string]
function W([string]$s = '') { $out.Add($s); Write-Host $s }
function Section([string]$s) { W ''; W ("=" * 70); W "== $s"; W ("=" * 70) }

W "ClickStack alert-pack discovery - $(Get-Date -Format o)"
W "context: $(kubectl config current-context 2>&1)"

# --- 1. Where is everything? -------------------------------------------------
Section "1. Grafana deployments (namespace + name the installer needs)"
W (kubectl get deploy -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers 2>&1 |
   Select-String -Pattern 'grafana' | Out-String).Trim()

Section "2. StatefulSets/Pods that look like ClickHouse"
W (kubectl get pods -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers 2>&1 |
   Select-String -Pattern 'clickhouse|chi-' | Out-String).Trim()

# Resolve namespace + clickhouse pod if not supplied
$chLine = kubectl get pods -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers 2>&1 |
          Select-String -Pattern 'clickhouse' | Where-Object { $_ -notmatch 'operator' } | Select-Object -First 1
if ($chLine) { $ChNs = (($chLine -split '\s+')[0]); if (-not $ClickHousePod) { $ClickHousePod = ($chLine -split '\s+')[1] } }

if (-not $Namespace) {
  $gAll = kubectl get deploy -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers 2>&1 |
          Select-String -Pattern 'grafana'
  # Prefer the Grafana that lives alongside ClickHouse (that's the ClickStack one)
  $g = $gAll | Where-Object { ($_ -split '\s+')[0] -eq $ChNs } | Select-Object -First 1
  if (-not $g) { $g = $gAll | Select-Object -First 1 }
  if ($g) { $Namespace = ($g -split '\s+')[0]; $GrafanaDeploy = ($g -split '\s+')[1] }
}
if (-not $ChNs) { $ChNs = $Namespace }
W ''
W "resolved: grafana namespace  = '$Namespace'   deployment = '$GrafanaDeploy'"
W "resolved: clickhouse pod     = '$ClickHousePod' (ns '$ChNs')"
W "  -> installer flags:  -Namespace $Namespace -Deployment $GrafanaDeploy"

Section "3. ConfigMaps in the Grafana namespace (installer targets these)"
W (kubectl get cm -n $Namespace --no-headers 2>&1 | Out-String).Trim()

Section "4. Existing ClickHouse datasource UID (alert rules must bind to this)"
foreach ($cm in (kubectl get cm -n $Namespace -o name 2>&1)) {
  if ($cm -match 'dashboard') { continue }   # dashboards are huge and irrelevant here
  $body = kubectl get $cm -n $Namespace -o yaml 2>&1 | Out-String
  if ($body -match 'clickhouse-datasource|grafana-clickhouse') {
    W "--- $cm ---"
    W (($body -split "`n" | Select-String -Pattern '^\s*(uid|name|type|url|jsonData|host|port|secure):' |
        Select-Object -First 20) -join "`n")
  }
}

# --- 5. ClickHouse queries ---------------------------------------------------
# Call clickhouse-client directly - NO `sh -c`. Windows PowerShell 5.1 mangles the quoting
# of a shell one-liner passed as a native-command argument, which silently corrupted every
# query. Two further traps this avoids:
#   * `clickhouse-client --password ""` means "prompt me", and the prompt then eats the
#     first line of the piped SQL, producing bogus syntax errors.
#   * a prompt with stdin attached hangs or consumes input, so --password is only ever
#     passed when a real password was supplied via -ChPassword.
function Invoke-Ch([string]$sql) {
  if ($ChPassword) {
    $r = $sql | kubectl exec -i -n $ChNs $ClickHousePod -- clickhouse-client --user $ChUser --password $ChPassword 2>&1
  } else {
    $r = $sql | kubectl exec -i -n $ChNs $ClickHousePod -- clickhouse-client --user $ChUser 2>&1
  }
  ($r | ForEach-Object { $_.ToString() }) -join "`n"
}

# Fail fast with a clear message if ClickHouse can't be queried at all.
$probe = Invoke-Ch "SELECT 1 FORMAT TSV"
if ($probe -notmatch '^\s*1\s*$') {
  W ''
  W "!! Could not query ClickHouse in pod '$ClickHousePod' (ns '$ChNs')."
  W "!! Response was: $probe"
  W "!! If it needs credentials, re-run with:  -ChUser <user> -ChPassword <pass>"
  W "!! Sections 5-14 below will be empty."
}

Section "5. Do the 7 metrics the 8 rules need actually exist?"
W (Invoke-Ch @"
SELECT * FROM (
  SELECT 'gauge' AS tbl, MetricName, count() AS pts, max(TimeUnix) AS latest
  FROM default.otel_metrics_gauge
  WHERE TimeUnix > now() - INTERVAL 2 HOUR
    AND MetricName IN ('k8s.node.filesystem.available','k8s.node.filesystem.capacity',
                       'system.cpu.utilization','system.memory.utilization',
                       'k8s.pod.phase','k8s.container.restarts')
  GROUP BY MetricName
  UNION ALL
  SELECT 'sum' AS tbl, MetricName, count() AS pts, max(TimeUnix) AS latest
  FROM default.otel_metrics_sum
  WHERE TimeUnix > now() - INTERVAL 2 HOUR AND MetricName = 'k8s.node.uptime'
  GROUP BY MetricName
) ORDER BY tbl, MetricName FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "6. Node names (label the volume/uptime rules group by)"
W (Invoke-Ch @"
SELECT DISTINCT ResourceAttributes['k8s.node.name'] AS node
FROM default.otel_metrics_gauge
WHERE TimeUnix > now() - INTERVAL 2 HOUR AND MetricName='k8s.node.filesystem.capacity'
FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "7. FULL pod inventory seen in telemetry (I pick the Key Vault name from this)"
W (Invoke-Ch @"
SELECT DISTINCT replaceRegexpOne(ResourceAttributes['k8s.pod.name'], '-[a-z0-9]{6,10}-[a-z0-9]{5}$|-[0-9]+$', '') AS workload
FROM default.otel_metrics_gauge
WHERE TimeUnix > now() - INTERVAL 2 HOUR AND MetricName='k8s.pod.phase'
ORDER BY workload FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "8. FULL ServiceName inventory in logs (I pick the policy-engine name from this)"
W (Invoke-Ch @"
SELECT ServiceName, count() AS log_rows,
       countIf(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')) AS errors
FROM default.otel_logs
WHERE Timestamp > now() - INTERVAL 2 HOUR
GROUP BY ServiceName ORDER BY log_rows DESC LIMIT 60 FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "9. Anything vault/policy/cert/kv-ish anywhere in k8s (pods, svc, deploy)"
W (kubectl get pods,svc,deploy -A -o custom-columns='KIND:.kind,NS:.metadata.namespace,NAME:.metadata.name' --no-headers 2>&1 |
   Select-String -Pattern 'vault|policy|kv|cert|guestconfig|arc' | Out-String).Trim()

Section "10. Disk signal: is PER-VOLUME data available, or only per-node?"
W "-- (a) any hostmetrics filesystem metrics? (needed for 'per volume type' alerting) --"
W (Invoke-Ch @"
SELECT MetricName, count() AS pts, length(any(Attributes)) AS n_attr_keys,
       any(toString(Attributes)) AS sample_attrs
FROM default.otel_metrics_gauge
WHERE TimeUnix > now() - INTERVAL 2 HOUR AND MetricName LIKE 'system.filesystem%'
GROUP BY MetricName FORMAT PrettyCompact
"@ | Out-String).Trim()
W "   (no rows above = hostmetrics filesystem scraper is OFF => per-volume alerting impossible)"
W "-- (b) attributes on the kubeletstats node filesystem metric (empty map => no per-volume breakdown) --"
W (Invoke-Ch @"
SELECT MetricName, length(Attributes) AS n_attr_keys, count() AS pts,
       any(toString(Attributes)) AS sample_attrs
FROM default.otel_metrics_gauge
WHERE TimeUnix > now() - INTERVAL 2 HOUR AND MetricName LIKE 'k8s.node.filesystem%'
GROUP BY MetricName, n_attr_keys FORMAT PrettyCompact
"@ | Out-String).Trim()
W "-- (c) current node-level headroom --"
W (Invoke-Ch @"
SELECT node, round(free_pct, 1) AS free_pct, round(cap_gb, 1) AS cap_gb
FROM (
  SELECT ResourceAttributes['k8s.node.name'] AS node,
         argMaxIf(Value, TimeUnix, MetricName='k8s.node.filesystem.available') AS avail,
         argMaxIf(Value, TimeUnix, MetricName='k8s.node.filesystem.capacity')  AS cap,
         avail / nullIf(cap,0) * 100 AS free_pct,
         cap / 1024 / 1024 / 1024 AS cap_gb
  FROM default.otel_metrics_gauge
  WHERE TimeUnix > now() - INTERVAL 30 MINUTE
    AND MetricName IN ('k8s.node.filesystem.available','k8s.node.filesystem.capacity')
  GROUP BY node
) WHERE cap > 0 ORDER BY free_pct ASC FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "10b. OTel collector receivers actually enabled (what CAN be alerted on)"
foreach ($cm in (kubectl get cm -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers 2>&1 |
                 Select-String -Pattern 'collector|otel')) {
  $ns2, $n2 = ($cm -split '\s+')[0,1]
  $body = kubectl get cm $n2 -n $ns2 -o yaml 2>&1 | Out-String
  if ($body -match 'receivers:') {
    W "--- $ns2/$n2 ---"
    W (($body -split "`n" | Select-String -Pattern '^\s{2,10}(hostmetrics|kubeletstats|filelog|k8s_cluster|k8s_events|otlp|prometheus|windowsperfcounters|scrapers|filesystem|cpu|memory|network|paging|load|disk):' |
        Select-Object -First 30) -join "`n")
  }
}

Section "11. Current CPU / memory utilisation (are 90% / 85% sane here?)"
W (Invoke-Ch @"
SELECT 'cpu_pct_now' AS metric, round(avg(v) * 100, 1) AS pct FROM (
  SELECT sumIf(Value, Attributes['state'] != 'idle') AS v
  FROM default.otel_metrics_gauge
  WHERE MetricName='system.cpu.utilization' AND TimeUnix > now() - INTERVAL 15 MINUTE
  GROUP BY ResourceAttributes['host.name'], Attributes['cpu'], TimeUnix)
UNION ALL
SELECT 'mem_pct_now', round(avgIf(Value, Attributes['state']='used') * 100, 1)
FROM default.otel_metrics_gauge
WHERE MetricName='system.memory.utilization' AND TimeUnix > now() - INTERVAL 15 MINUTE
FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "12. Retention - how far back does data go? (affects 'growth trend' alerts)"
W (Invoke-Ch @"
SELECT 'otel_metrics_gauge' AS t, min(TimeUnix) AS oldest, max(TimeUnix) AS newest FROM default.otel_metrics_gauge
UNION ALL SELECT 'otel_logs', min(Timestamp), max(Timestamp) FROM default.otel_logs
FORMAT PrettyCompact
"@ | Out-String).Trim()

Section "13. Metric inventory by prefix (which of the other 35 alerts are reachable)"
W (Invoke-Ch @"
SELECT prefix, count() AS distinct_metrics
FROM (
  SELECT DISTINCT MetricName, splitByChar('.', MetricName)[1] AS prefix FROM default.otel_metrics_gauge
  WHERE TimeUnix > now() - INTERVAL 2 HOUR AND MetricName NOT LIKE 'ClickHouse%'
  UNION DISTINCT
  SELECT DISTINCT MetricName, splitByChar('.', MetricName)[1] AS prefix FROM default.otel_metrics_sum
  WHERE TimeUnix > now() - INTERVAL 2 HOUR AND MetricName NOT LIKE 'ClickHouse%'
) GROUP BY prefix ORDER BY distinct_metrics DESC LIMIT 40 FORMAT PrettyCompact
"@ | Out-String).Trim()

W ''
W "-- infrastructure-relevant metric names (system.* / k8s.node.* / k8s.pod.* / host.*) --"
W (Invoke-Ch @"
SELECT DISTINCT MetricName FROM (
  SELECT MetricName FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 2 HOUR
  UNION ALL
  SELECT MetricName FROM default.otel_metrics_sum   WHERE TimeUnix > now() - INTERVAL 2 HOUR
)
WHERE MetricName LIKE 'system.%' OR MetricName LIKE 'k8s.node.%'
   OR MetricName LIKE 'k8s.pod.%' OR MetricName LIKE 'host.%' OR MetricName LIKE 'process.%'
ORDER BY MetricName LIMIT 200 FORMAT TSV
"@ | Out-String).Trim()

Section "14. Any Windows / Hyper-V / cluster / cert host-side signal? (Tier B+C alerts)"
W (Invoke-Ch @"
SELECT DISTINCT MetricName FROM (
  SELECT MetricName FROM default.otel_metrics_gauge WHERE TimeUnix > now() - INTERVAL 2 HOUR
  UNION ALL
  SELECT MetricName FROM default.otel_metrics_sum   WHERE TimeUnix > now() - INTERVAL 2 HOUR
)
WHERE (MetricName ILIKE '%cert%' OR MetricName ILIKE '%cluster%' OR MetricName ILIKE '%hyperv%'
   OR MetricName ILIKE '%windows%' OR MetricName ILIKE '%smart%' OR MetricName ILIKE '%s2d%'
   OR MetricName ILIKE '%ntp%' OR MetricName ILIKE '%timesync%' OR MetricName ILIKE '%storage.pool%')
  AND MetricName NOT LIKE 'ClickHouse%'
ORDER BY MetricName LIMIT 100 FORMAT TSV
"@ | Out-String).Trim()
W "   (no rows above = no host-side signal yet => the 23 Tier-C alerts need the host emitter)"

$out -join "`r`n" | Set-Content -Path $OutFile -Encoding utf8
Write-Host ''
Write-Host "Wrote $OutFile - send that file back." -ForegroundColor Green
