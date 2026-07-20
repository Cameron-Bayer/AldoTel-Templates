<#
.SYNOPSIS
    Durably install the ClickStack Grafana dashboards, ClickHouse data source, and
    alert rules into an existing ClickStack-on-Kubernetes Grafana.

.DESCRIPTION
    ClickStack's bundled Grafana stores everything in an *ephemeral* SQLite DB
    (there is no PersistentVolume on /var/lib/grafana), so anything created through
    the Grafana HTTP API — data sources, imported dashboards — is wiped the next
    time the pod restarts. The only durable install path is Grafana's file-based
    provisioning, which on this chart is fed by ConfigMaps.

    This script patches those ConfigMaps so the install survives pod restarts:
      1. Adds the `clickstack-ch` ClickHouse data source (datasource-clickstack-ch.yaml)
         to the datasources provisioning ConfigMap. The alert rules reference this UID.
      2. Adds every dashboard in ../dashboards/ to the dashboards provisioning
         ConfigMap, pinning each dashboard's datasource variable (clickhouseDatasource) to
         `clickstack-ch` so panels resolve without prompting.
      3. Loads ../alerting/*.yaml into an alerting ConfigMap and makes sure the Grafana
         Deployment mounts it at /etc/grafana/provisioning/alerting.
      4. Restarts Grafana so provisioning re-runs, then prints verification hints.

    Re-running the script is safe (idempotent): every step is a merge/strategic patch.

.EXAMPLE
    ./install-k8s.ps1
    Installs into the default clickstack namespace / clickstack-grafana* ConfigMaps.

.EXAMPLE
    ./install-k8s.ps1 -Namespace obs -SkipAlerts
    Installs the data source + dashboards only, into namespace `obs`.

.NOTES
    Requires: kubectl configured against the target cluster.
    The data source password comes from the CH_PASSWORD env var already injected into
    the ClickStack Grafana pod — you do not pass a password here.
#>
[CmdletBinding()]
param(
    [string]$Namespace = 'clickstack',
    [string]$Deployment = 'clickstack-grafana',
    [string]$DatasourcesConfigMap = 'clickstack-grafana-datasources',
    [string]$DashboardsConfigMap = 'clickstack-grafana-dashboards',
    [string]$AlertingConfigMap = 'clickstack-grafana-alerting',
    [string]$DatasourceUid = 'clickstack-ch',
    [string]$ChServer = 'clickstack-clickhouse-clickhouse-headless',
    [int]$ChPort = 9000,
    [switch]$SkipAlerts,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$grafanaDir = Split-Path -Parent $scriptDir
$dashboardsDir = Join-Path $grafanaDir 'dashboards'
$alertingDir = Join-Path $grafanaDir 'alerting'
$dsFile = Join-Path $scriptDir 'datasource-clickstack-ch.yaml'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("clickstack-graf-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Invoke-Kubectl {
    param([string[]]$KArgs)
    $out = & kubectl @KArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kubectl $($KArgs -join ' ') failed:`n$out" }
    return $out
}

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

Write-Step "Checking Grafana deployment '$Deployment' in namespace '$Namespace'"
Invoke-Kubectl @('get', 'deployment', $Deployment, '-n', $Namespace, '-o', 'name') | Out-Null

# --- 1. Data source -----------------------------------------------------------
Write-Step "Provisioning data source '$DatasourceUid' into ConfigMap '$DatasourcesConfigMap'"
$dsYaml = (Get-Content $dsFile -Raw)
$dsYaml = $dsYaml -replace 'server: .*', "server: $ChServer"
$dsYaml = $dsYaml -replace 'port: \d+', "port: $ChPort"
$dsPatch = @{ data = @{ "$DatasourceUid.yaml" = $dsYaml } } | ConvertTo-Json -Depth 6
$dsPatchFile = Join-Path $tmp 'ds-patch.json'
Set-Content -Path $dsPatchFile -Value $dsPatch -Encoding utf8
Invoke-Kubectl @('patch', 'configmap', $DatasourcesConfigMap, '-n', $Namespace, '--type', 'merge', '--patch-file', $dsPatchFile) | Out-Null
Write-Host "    added key $DatasourceUid.yaml"

# --- 2. Dashboards ------------------------------------------------------------
Write-Step "Provisioning dashboards into ConfigMap '$DashboardsConfigMap'"
$dashData = @{}
foreach ($f in Get-ChildItem (Join-Path $dashboardsDir '*.json')) {
    $model = Get-Content $f.FullName -Raw | ConvertFrom-Json
    if ($model.templating -and $model.templating.list) {
        foreach ($v in $model.templating.list) {
            if ($v.type -eq 'datasource') {
                $opt = [ordered]@{ selected = $true; text = $DatasourceUid; value = $DatasourceUid }
                $v.current = $opt
                $v.options = @($opt)
            }
        }
    }
    if ($model.PSObject.Properties.Name -contains '__inputs') { $model.PSObject.Properties.Remove('__inputs') }
    if ($model.PSObject.Properties.Name -contains 'id') { $model.PSObject.Properties.Remove('id') }
    $dashData[$f.Name] = ($model | ConvertTo-Json -Depth 100 -Compress)
    Write-Host "    baked $($f.Name) (ds -> $DatasourceUid)"
}
$dashPatch = @{ data = $dashData } | ConvertTo-Json -Depth 6
$dashPatchFile = Join-Path $tmp 'dash-patch.json'
Set-Content -Path $dashPatchFile -Value $dashPatch -Encoding utf8
Invoke-Kubectl @('patch', 'configmap', $DashboardsConfigMap, '-n', $Namespace, '--type', 'merge', '--patch-file', $dashPatchFile) | Out-Null

# --- 3. Alerts ----------------------------------------------------------------
if (-not $SkipAlerts) {
    Write-Step "Loading alert rules into ConfigMap '$AlertingConfigMap'"
    $alertArgs = @('create', 'configmap', $AlertingConfigMap, '-n', $Namespace)
    foreach ($y in Get-ChildItem (Join-Path $alertingDir '*.yaml')) { $alertArgs += "--from-file=$($y.FullName)" }
    $alertArgs += @('--dry-run=client', '-o', 'yaml')
    $cmYaml = & kubectl @alertArgs
    if ($LASTEXITCODE -ne 0) { throw "building alerting ConfigMap failed:`n$cmYaml" }
    $cmFile = Join-Path $tmp 'alerting-cm.yaml'
    Set-Content -Path $cmFile -Value $cmYaml -Encoding utf8
    Invoke-Kubectl @('apply', '-f', $cmFile) | Out-Null
    Write-Host "    loaded $((Get-ChildItem (Join-Path $alertingDir '*.yaml')).Count) YAML file(s)"

    Write-Step "Ensuring Grafana mounts the alerting provisioning folder"
    $container = (Invoke-Kubectl @('get', 'deployment', $Deployment, '-n', $Namespace, '-o', 'jsonpath={.spec.template.spec.containers[0].name}'))
    $mountPatch = @{
        spec = @{ template = @{ spec = @{
            volumes    = @(@{ name = 'alerting'; configMap = @{ name = $AlertingConfigMap } })
            containers = @(@{ name = $container; volumeMounts = @(@{ name = 'alerting'; mountPath = '/etc/grafana/provisioning/alerting'; readOnly = $true }) })
        } } }
    } | ConvertTo-Json -Depth 10
    $mountFile = Join-Path $tmp 'mount-patch.json'
    Set-Content -Path $mountFile -Value $mountPatch -Encoding utf8
    Invoke-Kubectl @('patch', 'deployment', $Deployment, '-n', $Namespace, '--type', 'strategic', '--patch-file', $mountFile) | Out-Null
    Write-Host "    mounted $AlertingConfigMap at /etc/grafana/provisioning/alerting"
}
else {
    Write-Step "Skipping alerts (-SkipAlerts)"
}

# --- 4. Restart + verify ------------------------------------------------------
if ($NoRestart) {
    Write-Step "Skipping restart (-NoRestart). Roll Grafana yourself to apply provisioning:"
    Write-Host "    kubectl rollout restart deployment $Deployment -n $Namespace"
}
else {
    Write-Step "Restarting Grafana to apply provisioning"
    Invoke-Kubectl @('rollout', 'restart', 'deployment', $Deployment, '-n', $Namespace) | Out-Null
    Invoke-Kubectl @('rollout', 'status', 'deployment', $Deployment, '-n', $Namespace, '--timeout=180s')
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Write-Host ""
Write-Step "Done."
Write-Host @"
Verify (port-forward Grafana, then hit the API):
    kubectl port-forward -n $Namespace svc/$Deployment 3010:3000
    # data sources — expect 'clickhouse' and '$DatasourceUid'
    curl -s -u <admin>:<pass> http://localhost:3010/api/datasources
    # dashboards
    curl -s -u <admin>:<pass> http://localhost:3010/api/search?type=dash-db
    # alert-rule health — expect health=ok for all rules
    curl -s -u <admin>:<pass> http://localhost:3010/api/prometheus/grafana/api/v1/rules

Notification channel: edit the webhook URL in ../alerting/contact-points.yaml, re-run
this script (or kubectl apply the alerting ConfigMap), and restart Grafana.
"@
