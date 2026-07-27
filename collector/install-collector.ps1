<#
.SYNOPSIS
  Deploy the ClickHouse + collector self-metrics scraper into a ClickStack /
  AzureLocal-Observability-Appliance cluster, so the ADVANCED dashboards that need
  ClickHouse (:9363) and OTel Collector (:8888) metrics light up.

.DESCRIPTION
  The appliance's central collector is OTLP-only and nothing scrapes ClickHouse's
  Prometheus endpoint or the collector's self-telemetry. This installs a small
  opentelemetry-collector (contrib) Helm release that scrapes both and forwards
  them via OTLP/gRPC mTLS to the ClickStack central collector — the same ingest
  path the appliance's kube-telemetry collectors use — which persists them to the
  same default.otel_metrics_* tables the dashboards read.

  Run this AFTER the appliance is fully deployed and BEFORE (or any time before)
  running the HyperDX preflight/importer and the Grafana advanced install:

      ./collector/install-collector.ps1 -Namespace <appliance-ns>
      # wait ~1-2 min for metrics to flow, then:
      ./hyperdx/preflight.ps1
      ./hyperdx/import.ps1 -Advanced
      ./grafana/kubernetes/install-k8s.ps1 -Advanced

  Re-running is safe (helm upgrade --install).

.PARAMETER Namespace
  Namespace where ClickStack / the appliance is installed. Match your deploy
  (the ALDOTel appliance deploys into 'aldotel'; a bare open-source ClickStack
  tier is often 'clickstack'). Default: aldotel.

.PARAMETER Release
  Helm release name for this scraper. Default: clickstack-metrics-collector.

.PARAMETER CollectorService
  Name of the ClickStack central OTel Collector Service (stable literal contract).
  Default: clickstack-otel-collector.

.PARAMETER ChService
  ClickHouse headless Service that fronts the :9363 Prometheus endpoint.
  Default: clickstack-clickhouse-clickhouse-headless.

.PARAMETER ChMetricsPort
  ClickHouse Prometheus port. Default: 9363.

.PARAMETER ChScheme
  Scheme for the ClickHouse metrics endpoint (http or https). ClickHouse's
  <prometheus> port is plaintext by default even on a TLS-hardened install.
  Default: http.

.PARAMETER EmitterSecret
  Existing enrolled internal-emitter TLS secret to present to the central
  collector's mTLS receiver. Any secret labeled aldotel.io/internal-emitter=true
  is accepted. Default: clickstack-emitter-app-secret. Ignored when
  -CreateDedicatedCert is used.

.PARAMETER CreateDedicatedCert
  Instead of reusing an existing emitter secret, apply collector/emitter-cert.yaml
  to mint a dedicated cert-manager identity (clickstack-emitter-dashboards-scraper),
  wait for its secret, then use it. Requires cert-manager + trust-manager (present
  on the appliance). Allow ~60s extra for allow-list propagation.

.PARAMETER SkipCollectorMetrics
  Do not scrape the collector :8888 self-telemetry (only ClickHouse :9363). Use if
  the central collector Service does not expose 8888 in your deploy.

.PARAMETER Uninstall
  Remove the scraper release (helm uninstall) and the dedicated cert if present.

.EXAMPLE
  ./install-collector.ps1

.EXAMPLE
  ./install-collector.ps1 -Namespace clickstack -CreateDedicatedCert

.NOTES
  Requires: kubectl + helm configured against the target cluster.
#>
[CmdletBinding()]
param(
    [string]$Namespace = 'aldotel',
    [string]$Release = 'clickstack-metrics-collector',
    [string]$CollectorService = 'clickstack-otel-collector',
    [string]$ChService = 'clickstack-clickhouse-clickhouse-headless',
    [int]$ChMetricsPort = 9363,
    [ValidateSet('http', 'https')][string]$ChScheme = 'http',
    [string]$EmitterSecret = 'clickstack-emitter-app-secret',
    [switch]$CreateDedicatedCert,
    [switch]$SkipCollectorMetrics,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$valuesTemplate = Join-Path $scriptDir 'otel-metrics-collector-values.yaml'
$certTemplate = Join-Path $scriptDir 'emitter-cert.yaml'
$dedicatedCertName = 'clickstack-emitter-dashboards-scraper'
$dedicatedSecret = 'clickstack-emitter-dashboards-scraper-secret'

$helmRepoName = 'open-telemetry'
$helmRepoUrl = 'https://open-telemetry.github.io/opentelemetry-helm-charts'
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

# --- Uninstall ---------------------------------------------------------------
if ($Uninstall) {
    Write-Step "Uninstalling release '$Release' from namespace '$Namespace'"
    Invoke-Native 'helm' @('uninstall', $Release, '-n', $Namespace) -AllowFail | Out-Null
    Write-Step "Removing dedicated emitter cert (if present)"
    Invoke-Native 'kubectl' @('delete', 'certificate', $dedicatedCertName, '-n', $Namespace, '--ignore-not-found') -AllowFail | Out-Null
    Invoke-Native 'kubectl' @('delete', 'secret', $dedicatedSecret, '-n', $Namespace, '--ignore-not-found') -AllowFail | Out-Null
    Write-Host "Done." -ForegroundColor Green
    return
}

# --- Preconditions -----------------------------------------------------------
Write-Step "Checking namespace '$Namespace' and central collector '$CollectorService'"
Invoke-Native 'kubectl' @('get', 'namespace', $Namespace, '-o', 'name') | Out-Null
Invoke-Native 'kubectl' @('get', 'service', $CollectorService, '-n', $Namespace, '-o', 'name') | Out-Null

# --- Emitter identity --------------------------------------------------------
if ($CreateDedicatedCert) {
    Write-Step "Minting dedicated emitter cert '$dedicatedCertName'"
    $certYaml = (Get-Content $certTemplate -Raw) -replace '__NAMESPACE__', $Namespace
    $certFile = Join-Path ([System.IO.Path]::GetTempPath()) ("emitter-cert-" + [guid]::NewGuid().ToString('N') + '.yaml')
    Set-Content -Path $certFile -Value $certYaml -Encoding utf8
    Invoke-Native 'kubectl' @('apply', '-f', $certFile) | Out-Null
    Remove-Item $certFile -ErrorAction SilentlyContinue

    Write-Host "    waiting for secret '$dedicatedSecret' to be issued..."
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $found = Invoke-Native 'kubectl' @('get', 'secret', $dedicatedSecret, '-n', $Namespace, '-o', 'name') -AllowFail
        if ($LASTEXITCODE -eq 0 -and $found) { break }
        Start-Sleep -Seconds 3
    }
    if ($LASTEXITCODE -ne 0) { throw "Timed out waiting for cert-manager to issue $dedicatedSecret" }
    $EmitterSecret = $dedicatedSecret
    Write-Host "    issued. Allowing ~60s for trust-manager allow-list propagation..."
    Start-Sleep -Seconds 60
}
else {
    Write-Step "Verifying emitter secret '$EmitterSecret' exists"
    Invoke-Native 'kubectl' @('get', 'secret', $EmitterSecret, '-n', $Namespace, '-o', 'name') | Out-Null
}

# --- Stage values ------------------------------------------------------------
Write-Step "Staging Helm values"
$otlpEndpoint = "https://$CollectorService.$Namespace.svc.cluster.local:4317"
$chTarget = "$ChService.$Namespace.svc.cluster.local"
$collectorMetricsTarget = "$CollectorService.$Namespace.svc.cluster.local:8888"

$values = Get-Content $valuesTemplate -Raw
if ($SkipCollectorMetrics) {
    # Strip the otelcol scrape job (between the >>> / <<< markers).
    $values = [regex]::Replace($values, '(?s)\s*# >>> otelcol job.*?# <<< otelcol job', '')
    Write-Host "    collector :8888 scrape disabled (-SkipCollectorMetrics)"
}
$values = $values -replace '__EMITTER_SECRET__', $EmitterSecret
$values = $values -replace '__CH_SCHEME__', $ChScheme
$values = $values -replace '__CH_TARGET__', $chTarget
$values = $values -replace '__CH_METRICS_PORT__', "$ChMetricsPort"
$values = $values -replace '__COLLECTOR_METRICS_TARGET__', $collectorMetricsTarget
$values = $values -replace '__OTLP_ENDPOINT__', $otlpEndpoint

$staged = Join-Path ([System.IO.Path]::GetTempPath()) ("metrics-collector-values-" + [guid]::NewGuid().ToString('N') + '.yaml')
Set-Content -Path $staged -Value $values -Encoding utf8

# --- Helm install ------------------------------------------------------------
Write-Step "Adding/updating Helm repo '$helmRepoName'"
Invoke-Native 'helm' @('repo', 'add', $helmRepoName, $helmRepoUrl) -AllowFail | Out-Null
Invoke-Native 'helm' @('repo', 'update') -AllowFail | Out-Null

Write-Step "Deploying '$Release' (helm upgrade --install)"
Invoke-Native 'helm' @(
    'upgrade', '--install', $Release, $collectorChart,
    '--namespace', $Namespace,
    '-f', $staged,
    '--wait', '--timeout', '5m'
) | Out-Null
Remove-Item $staged -ErrorAction SilentlyContinue

$pods = Invoke-Native 'kubectl' @('get', 'pods', '-n', $Namespace, '-l', "app.kubernetes.io/instance=$Release", '--no-headers') -AllowFail
Write-Host ""
Write-Step "Done. Scraper deployed."
Write-Host @"
Metrics take ~1-2 minutes to appear in ClickHouse. Then verify + import:

  # 1. Confirm the advanced-tier metrics are now present (preflight checks every tier)
  ./hyperdx/preflight.ps1

  # 2. Import the advanced dashboards
  ./hyperdx/import.ps1 -Advanced
  ./grafana/kubernetes/install-k8s.ps1 -Namespace $Namespace -Advanced

Troubleshoot the scraper:
  kubectl logs -n $Namespace -l app.kubernetes.io/instance=$Release --tail=50
  # confirm scrape targets are UP (port-forward the scraper's :8888 if you enable it)

Remove it:
  ./collector/install-collector.ps1 -Namespace $Namespace -Uninstall
"@
