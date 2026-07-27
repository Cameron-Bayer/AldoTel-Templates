<#
.SYNOPSIS
    Enable host CPU/memory *utilization* metrics on the appliance's kube-telemetry
    DaemonSet collector so the "Host / OS Metrics" dashboard fills in.

.DESCRIPTION
    The AzureLocal-Observability-Appliance ships its hostmetrics receiver with the
    cpu/memory scrapers enabled, but their *ratio* metrics --

        system.cpu.utilization
        system.memory.utilization

    -- left at the OpenTelemetry default of DISABLED (they are opt-in). The
    "Host / OS Metrics" board marks both as [required], so they show up as MISS in
    preflight even though the DaemonSet is healthy and emitting cpu.load_average,
    disk.io, network.io, etc.

    This patches the running DaemonSet release IN PLACE with:
        helm upgrade <release> --reuse-values -f <two-metric override>
    `--reuse-values` preserves everything the appliance's installer set (most
    importantly the injected mTLS OTLP endpoint env), and the installed chart
    version is auto-detected and pinned with `--version` so this never drifts the
    appliance's collector chart -- it only flips the two metrics on (or off).

    Idempotent. Re-run any time; pass -Disable to turn them back off.

.NOTES
    This patches an APPLIANCE release (default: clickstack-kube-daemonset), NOT the
    dashboards metrics scraper deployed by install-collector.ps1. If the appliance
    later re-runs its own install-kube-telemetry.ps1, the packaged DaemonSet values
    (which lack these two metrics) will revert this -- just re-run this script, or
    bake the same cpu/memory `metrics:` blocks into the appliance's
    configs/kube-otel-daemonset-values.yaml to make it permanent.

.PARAMETER Namespace
    Namespace where the appliance/kube-telemetry is installed (default: aldotel).

.PARAMETER DaemonsetRelease
    Helm release name of the kube-telemetry DaemonSet collector
    (default: clickstack-kube-daemonset).

.PARAMETER Disable
    Set the two utilization metrics back to disabled instead of enabling them.

.EXAMPLE
    ./enable-host-metrics.ps1
.EXAMPLE
    ./enable-host-metrics.ps1 -Namespace aldotel -Disable
#>
param(
    [string]$Namespace        = 'aldotel',
    [string]$DaemonsetRelease = 'clickstack-kube-daemonset',
    [switch]$Disable
)

$ErrorActionPreference = 'Stop'

$helmRepoName   = 'open-telemetry'
$helmRepoUrl    = 'https://open-telemetry.github.io/opentelemetry-helm-charts'
$collectorChart = "$helmRepoName/opentelemetry-collector"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Invoke-Native {
    param([string]$File, [string[]]$CmdArgs, [switch]$AllowFail)
    $out = & $File @CmdArgs 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
        throw "$File $($CmdArgs -join ' ') failed:`n$out"
    }
    return $out
}

$enabled = if ($Disable) { 'false' } else { 'true' }
$verb    = if ($Disable) { 'Disabling' } else { 'Enabling' }

# --- Locate the DaemonSet release and pin its current chart version -----------
Write-Step "Locating DaemonSet release '$DaemonsetRelease' in namespace '$Namespace'"
$listJson = Invoke-Native 'helm' @('list', '-n', $Namespace, '-o', 'json') | Out-String
$releases = @()
try { $releases = @($listJson | ConvertFrom-Json) } catch { }
$rel = $releases | Where-Object { $_.name -eq $DaemonsetRelease } | Select-Object -First 1
if (-not $rel) {
    throw "DaemonSet release '$DaemonsetRelease' not found in namespace '$Namespace'. Is the appliance's kube-telemetry installed?  (check: helm list -n $Namespace)"
}
if ($rel.chart -notmatch '^opentelemetry-collector-') {
    throw "Release '$DaemonsetRelease' is chart '$($rel.chart)', not opentelemetry-collector. Refusing to patch an unexpected chart."
}
$chartVersion = $rel.chart -replace '^opentelemetry-collector-', ''
Write-Host "    found (chart opentelemetry-collector-$chartVersion) - pinning that version"

# --- Stage the two-metric override -------------------------------------------
Write-Step "Staging Helm values override"
$values = @"
# Enable the two opt-in hostmetrics ratio metrics the Host / OS dashboard needs.
# Deep-merged onto the appliance's existing DaemonSet values via --reuse-values.
config:
  receivers:
    hostmetrics:
      scrapers:
        cpu:
          metrics:
            system.cpu.utilization:
              enabled: $enabled
        memory:
          metrics:
            system.memory.utilization:
              enabled: $enabled
"@
$staged = Join-Path ([System.IO.Path]::GetTempPath()) ("hostmetrics-util-" + [guid]::NewGuid().ToString('N') + '.yaml')
Set-Content -Path $staged -Value $values -Encoding utf8

# --- Apply --------------------------------------------------------------------
Write-Step "Adding/updating Helm repo '$helmRepoName'"
Invoke-Native 'helm' @('repo', 'add', $helmRepoName, $helmRepoUrl) -AllowFail | Out-Null
Invoke-Native 'helm' @('repo', 'update') -AllowFail | Out-Null

Write-Step "$verb system.cpu.utilization + system.memory.utilization on '$DaemonsetRelease'"
Invoke-Native 'helm' @(
    'upgrade', $DaemonsetRelease, $collectorChart,
    '--namespace', $Namespace,
    '--version', $chartVersion,
    '--reuse-values',
    '-f', $staged,
    '--wait', '--timeout', '5m'
) | Out-Null
Remove-Item $staged -ErrorAction SilentlyContinue

Write-Host ""
Write-Step "Done. DaemonSet rolling restart underway (~1-2 min)."
Write-Host @"
Then verify:
  ./hyperdx/preflight.ps1        # 'Host / OS Metrics' -> OK (system.cpu/memory.utilization PASS)

Revert:
  ./collector/enable-host-metrics.ps1 -Namespace $Namespace -Disable
"@
