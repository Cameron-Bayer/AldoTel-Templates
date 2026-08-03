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

    When run interactively it first asks where alerts should be sent (Teams, Slack,
    email, PagerDuty, or a generic webhook), validates what you enter, and generates
    the matching contact point. It also offers to set the pod-name substring the
    Key Vault appliance rule matches on. Files in ../alerting/ are
    never modified — customisations are applied to temporary copies.

    Re-running the script is safe (idempotent): every step is a merge/strategic patch.

.EXAMPLE
    ./install-k8s.ps1
    Installs into the default aldotel namespace / clickstack-grafana* ConfigMaps,
    prompting for the alert destination.

.EXAMPLE
    ./install-k8s.ps1 -AlertDestination Teams -AlertUrl 'https://prod-12.westus.logic.azure.com:443/workflows/...'
    Unattended install that sends alerts to a Microsoft Teams channel. Legacy Office 365
    connector URLs (outlook.office.com/webhook/...) are rejected — Microsoft is retiring
    them; use a Power Automate Workflows URL.

.EXAMPLE
    ./install-k8s.ps1 -NonInteractive
    Never prompts; leaves contact-points.yaml exactly as it ships. Use in CI.

.EXAMPLE
    ./install-k8s.ps1 -Namespace obs -SkipAlerts
    Installs the data source + dashboards only, into namespace `obs`.

.EXAMPLE
    ./install-k8s.ps1 -Insecure -ChPort 9000
    Installs against a plaintext (non-TLS) ClickStack. By default the data source
    connects over the native-secure port (9440) with CA verification; -Insecure
    strips TLS and defaults the port to 9000.

.EXAMPLE
    ./install-k8s.ps1 -Advanced
    Installs onto the Observability Appliance. The appliance has no separate
    datasources ConfigMap and already ships an equivalent ClickHouse data source,
    so the script auto-detects that layout, skips provisioning a data source, and
    binds every dashboard + alert rule to the existing `clickhouse` UID. Pass
    -ReuseDatasource / -DatasourceUid explicitly to override the auto-detection.

.NOTES
    Requires: kubectl configured against the target cluster.
    The data source password comes from the CH_PASSWORD env var already injected into
    the ClickStack Grafana pod — you do not pass a password here.
    On a TLS-hardened ClickStack the CA certificate is read from -CaCertPath
    (default /etc/grafana/certs/ca.crt), a file already mounted into the Grafana pod.
#>
[CmdletBinding()]
param(
    [string]$Namespace = 'aldotel',
    [string]$Deployment = 'clickstack-grafana',
    [string]$DatasourcesConfigMap = 'clickstack-grafana-datasources',
    [string]$DashboardsConfigMap = 'clickstack-grafana-dashboards',
    [string]$AlertingConfigMap = 'clickstack-grafana-alerting',
    [string]$ChServer = 'clickstack-clickhouse-clickhouse-headless',
    [int]$ChPort = 9440,
    [string]$CaCertPath = '/etc/grafana/certs/ca.crt',
    [string]$DatasourceUid = 'clickstack-ch',
    [switch]$ReuseDatasource,
    [switch]$Insecure,
    [switch]$Advanced,
    [switch]$SkipAlerts,
    [switch]$NoRestart,

    # --- Notification channel (interactive wizard when omitted) ---------------
    [ValidateSet('Teams', 'Slack', 'Email', 'PagerDuty', 'Webhook', 'Keep')]
    [string]$AlertDestination,
    [string]$AlertUrl,
    [string[]]$AlertEmail,
    [string]$PagerDutyKey,

    # --- Appliance rule workload name (interactive wizard when omitted) -------
    [string]$KeyVaultWorkload,

    # Never prompt. Use for CI / unattended installs.
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
# Data source UID that dashboards + provisioned alert rules bind to. Provisioned alert
# rules can't prompt for a data source, so they reference this UID directly. Defaults to
# the `clickstack-ch` data source this script provisions. On the Observability Appliance,
# whose Grafana already ships an identical ClickHouse data source (uid `clickhouse`), pass
# -ReuseDatasource -DatasourceUid clickhouse to bind to it instead of provisioning a new one.
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

# --- Notification channel wizard ---------------------------------------------
# Quote a value for YAML as a single-quoted scalar. URLs carry ':', '?', '&' and
# '@' which are unsafe as plain scalars; in single-quoted YAML the only escape
# needed is doubling an embedded single quote.
function ConvertTo-YamlString([string]$v) { "'" + ($v -replace "'", "''") + "'" }

function Test-AlertUrl {
    param([string]$Url, [string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Url)) { return "A URL is required." }
    if ($Url -notmatch '^https?://') { return "Must start with http:// or https://" }
    switch ($Kind) {
        'Teams' {
            if ($Url -match 'outlook\.office(365)?\.com') {
                return "That is a legacy Office 365 connector URL. Microsoft blocked new ones in 2024 and is retiring existing ones in 2026. Create a Power Automate Workflows URL instead: right-click the channel -> Workflows -> 'Post to a channel when a webhook request is received'."
            }
            if ($Url -notmatch 'logic\.azure\.com|powerplatform\.com|azure-api\.net') {
                return "That does not look like a Power Automate Workflows URL (expected a logic.azure.com host)."
            }
        }
        'Slack' {
            if ($Url -notmatch '^https://hooks\.slack\.com/') { return "Expected a Slack incoming webhook (https://hooks.slack.com/services/...)." }
        }
    }
    return $null
}

function Read-Validated {
    param([string]$Prompt, [scriptblock]$Validator)
    while ($true) {
        $v = (Read-Host $Prompt).Trim()
        $err = & $Validator $v
        if (-not $err) { return $v }
        Write-Host "    ! $err" -ForegroundColor Yellow
    }
}

# Emits a complete contact-points.yaml. The receiver is always named
# "ClickStack Alerts" so notification-policy.yaml keeps routing to it unchanged.
function New-ContactPointYaml {
    param([string]$Kind, [string]$Url, [string[]]$Addresses, [string]$RoutingKey)
    $header = @"
# ClickStack Grafana alerts — contact points
# GENERATED by install-k8s.ps1. Re-run the installer to change the destination.
apiVersion: 1

contactPoints:
  - orgId: 1
    name: ClickStack Alerts
    receivers:
      - uid: clickstack-alerts
        disableResolveMessage: false
"@
    switch ($Kind) {
        'Teams' { $body = @"
        type: teams
        settings:
          url: $(ConvertTo-YamlString $Url)
          title: '{{ template "default.title" . }}'
          sectiontitle: ''
          message: '{{ template "default.message" . }}'
"@ }
        'Slack' { $body = @"
        type: slack
        settings:
          url: $(ConvertTo-YamlString $Url)
"@ }
        'Email' { $body = @"
        type: email
        settings:
          addresses: $(ConvertTo-YamlString ($Addresses -join ';'))
"@ }
        'PagerDuty' { $body = @"
        type: pagerduty
        settings:
          integrationKey: $(ConvertTo-YamlString $RoutingKey)
"@ }
        'Webhook' { $body = @"
        type: webhook
        settings:
          url: $(ConvertTo-YamlString $Url)
"@ }
    }
    return ($header + "`n" + $body + "`n")
}

function Invoke-AlertWizard {
    Write-Host ""
    Write-Host "  Where should alerts be sent?" -ForegroundColor White
    Write-Host "    1) Microsoft Teams  (Power Automate Workflows URL)"
    Write-Host "    2) Slack            (incoming webhook)"
    Write-Host "    3) Email"
    Write-Host "    4) PagerDuty        (Events v2 integration key)"
    Write-Host "    5) Generic webhook  (any endpoint that accepts a POST)"
    Write-Host "    6) Leave contact-points.yaml as-is"
    $choice = Read-Validated "  Choose 1-6" {
        param($v) if ($v -notmatch '^[1-6]$') { "Enter a number from 1 to 6." } else { $null }
    }
    switch ($choice) {
        '1' {
            Write-Host ""
            Write-Host "  Get the URL in Teams: right-click the target channel -> Workflows ->" -ForegroundColor DarkGray
            Write-Host "  'Post to a channel when a webhook request is received' -> Add workflow." -ForegroundColor DarkGray
            $u = Read-Validated "  Teams Workflows URL" { param($v) Test-AlertUrl -Url $v -Kind 'Teams' }
            return @{ Kind = 'Teams'; Url = $u }
        }
        '2' {
            $u = Read-Validated "  Slack webhook URL" { param($v) Test-AlertUrl -Url $v -Kind 'Slack' }
            return @{ Kind = 'Slack'; Url = $u }
        }
        '3' {
            $a = Read-Validated "  Email address(es), comma-separated" {
                param($v)
                if ([string]::IsNullOrWhiteSpace($v)) { return "At least one address is required." }
                foreach ($one in ($v -split ',')) {
                    if ($one.Trim() -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { return "'$($one.Trim())' is not a valid email address." }
                }
                return $null
            }
            return @{ Kind = 'Email'; Addresses = ($a -split ',' | ForEach-Object { $_.Trim() }) }
        }
        '4' {
            $k = Read-Validated "  PagerDuty Events v2 integration key" {
                param($v) if ($v -notmatch '^[A-Za-z0-9]{20,}$') { "Expected a PagerDuty integration key (20+ alphanumeric characters)." } else { $null }
            }
            return @{ Kind = 'PagerDuty'; RoutingKey = $k }
        }
        '5' {
            $u = Read-Validated "  Webhook URL" { param($v) Test-AlertUrl -Url $v -Kind 'Webhook' }
            return @{ Kind = 'Webhook'; Url = $u }
        }
        '6' { return @{ Kind = 'Keep' } }
    }
}

Write-Step "Checking Grafana deployment '$Deployment' in namespace '$Namespace'"
Invoke-Kubectl @('get', 'deployment', $Deployment, '-n', $Namespace, '-o', 'name') | Out-Null

# --- 0a. Notification channel + appliance workload names -----------------------
# Resolved up front so the install runs unattended once answered, and so a typo
# fails before anything in the cluster has been touched.
$alertChoice = $null
if (-not $SkipAlerts) {
    $interactive = -not $NonInteractive -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    if ($AlertDestination) {
        switch ($AlertDestination) {
            'Email' {
                if (-not $AlertEmail) { throw "-AlertDestination Email requires -AlertEmail." }
                $alertChoice = @{ Kind = 'Email'; Addresses = $AlertEmail }
            }
            'PagerDuty' {
                if (-not $PagerDutyKey) { throw "-AlertDestination PagerDuty requires -PagerDutyKey." }
                $alertChoice = @{ Kind = 'PagerDuty'; RoutingKey = $PagerDutyKey }
            }
            'Keep' { $alertChoice = @{ Kind = 'Keep' } }
            default {
                if (-not $AlertUrl) { throw "-AlertDestination $AlertDestination requires -AlertUrl." }
                $err = Test-AlertUrl -Url $AlertUrl -Kind $AlertDestination
                if ($err) { throw "-AlertUrl rejected: $err" }
                $alertChoice = @{ Kind = $AlertDestination; Url = $AlertUrl }
            }
        }
    }
    elseif ($interactive) {
        Write-Step "Configuring the alert notification channel"
        $alertChoice = Invoke-AlertWizard
    }
    else {
        Write-Host "    no -AlertDestination and not interactive; leaving contact-points.yaml as-is" -ForegroundColor DarkGray
        $alertChoice = @{ Kind = 'Keep' }
    }

    # The Key Vault rule locates its workload by pod-name substring. The default
    # matches the Azure Local appliance; a stock cluster needs a different one.
    if (-not $KeyVaultWorkload -and $interactive -and -not $PSBoundParameters.ContainsKey('KeyVaultWorkload')) {
        Write-Host ""
        Write-Host "  The Key Vault alert rule finds its workload by pod-name substring." -ForegroundColor White
        Write-Host "  The default matches the Azure Local appliance. Press Enter to keep it." -ForegroundColor DarkGray
        $kv = (Read-Host "  Key Vault / KMS pod name contains [moc-kms]").Trim()
        if ($kv) { $KeyVaultWorkload = $kv }
    }
}

# --- 0. Auto-detect layout ----------------------------------------------------
# Stock ClickStack ships a separate datasources ConfigMap that this script provisions
# `clickstack-ch` into. The Observability Appliance instead keeps datasources.yaml as a
# subPath key of the single grafana config ConfigMap (no separate datasources CM) and
# already ships an equivalent ClickHouse data source. When that CM is absent and the user
# didn't ask to provision, fall back to reusing Grafana's existing data source.
$dsUidExplicit = $PSBoundParameters.ContainsKey('DatasourceUid')
if (-not $ReuseDatasource) {
    # --ignore-not-found makes kubectl exit 0 with no stderr when the CM is absent, so this
    # probe stays silent under $ErrorActionPreference='Stop' (Windows PowerShell turns a
    # native command's stderr into a terminating NativeCommandError even when redirected).
    $dsCm = & kubectl get configmap $DatasourcesConfigMap -n $Namespace --ignore-not-found -o name 2>$null
    if (-not $dsCm) {
        $ReuseDatasource = $true
        Write-Step "No '$DatasourcesConfigMap' ConfigMap found - appliance layout detected; reusing Grafana's existing data source"
    }
}
if ($ReuseDatasource -and -not $dsUidExplicit) {
    # Detect the existing data source UID from Grafana's config ConfigMap (falls back to
    # `clickhouse`, the appliance's built-in ClickHouse data source).
    $cfg = & kubectl get configmap $Deployment -n $Namespace --ignore-not-found -o 'jsonpath={.data.datasources\.yaml}' 2>$null
    $detected = $null
    if ($cfg) {
        $m = [regex]::Match($cfg, '(?m)^\s*uid:\s*(\S+)')
        if ($m.Success) { $detected = $m.Groups[1].Value }
    }
    $DatasourceUid = if ($detected) { $detected } else { 'clickhouse' }
    Write-Host "    binding dashboards + alert rules to existing uid '$DatasourceUid'"
}

# --- 1. Data source -----------------------------------------------------------
if ($ReuseDatasource) {
    Write-Step "Reusing existing data source '$DatasourceUid' (skipping datasource provisioning)"
    Write-Host "    dashboards + alert rules will bind to uid '$DatasourceUid'"
}
else {
    Write-Step "Provisioning data source '$DatasourceUid' into ConfigMap '$DatasourcesConfigMap'"
    $dsYaml = (Get-Content $dsFile -Raw)
    if ($Insecure) {
        # Plaintext ClickStack: strip TLS and default the port to 9000 unless overridden.
        if ($ChPort -eq 9440) { $ChPort = 9000 }
        $dsYaml = $dsYaml -replace 'secure: true', 'secure: false'
        $dsYaml = $dsYaml -replace 'tlsAuthWithCACert: true', 'tlsAuthWithCACert: false'
        $dsYaml = $dsYaml -replace '(?m)^\s*tlsCACert: .*\r?\n', ''
    } else {
        $dsYaml = $dsYaml -replace '\$__file\{[^}]*\}', ('$__file{' + $CaCertPath + '}')
    }
    $dsYaml = $dsYaml -replace 'server: .*', "server: $ChServer"
    $dsYaml = $dsYaml -replace 'port: \d+', "port: $ChPort"
    $dsYaml = $dsYaml -replace 'uid: clickstack-ch', "uid: $DatasourceUid"
    $dsPatch = @{ data = @{ "$DatasourceUid.yaml" = $dsYaml } } | ConvertTo-Json -Depth 6
    $dsPatchFile = Join-Path $tmp 'ds-patch.json'
    Set-Content -Path $dsPatchFile -Value $dsPatch -Encoding utf8
    Invoke-Kubectl @('patch', 'configmap', $DatasourcesConfigMap, '-n', $Namespace, '--type', 'merge', '--patch-file', $dsPatchFile) | Out-Null
    Write-Host "    added key $DatasourceUid.yaml"
}

# --- 2. Dashboards ------------------------------------------------------------
Write-Step "Provisioning dashboards into ConfigMap '$DashboardsConfigMap'"
$dashData = @{}
# Default: only the always-populated top-level dashboards. -Advanced also provisions
# dashboards/advanced/, which need optional data sources (OTLP histograms).
$dashFiles = @(Get-ChildItem (Join-Path $dashboardsDir '*.json'))
if ($Advanced) {
    $advDir = Join-Path $dashboardsDir 'advanced'
    if (Test-Path $advDir) { $dashFiles += @(Get-ChildItem (Join-Path $advDir '*.json')) }
}
foreach ($f in $dashFiles) {
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
    # Provisioned alert rules bind to the data source by UID. If a non-default UID is in
    # use (e.g. -DatasourceUid clickhouse to reuse the appliance's data source), rewrite
    # the rules' UID onto substituted copies. The `__expr__` expression UID is untouched.
    # The wizard's contact point and the workload-name substitutions are applied to the
    # same staged copies, so the files in the repo are never modified.
    $needsStaging = ($DatasourceUid -ne 'clickstack-ch') -or
                    ($alertChoice -and $alertChoice.Kind -ne 'Keep') -or
                    $KeyVaultWorkload
    $alertSrcDir = $alertingDir
    if ($needsStaging) {
        $alertSrcDir = Join-Path $tmp 'alerting'
        New-Item -ItemType Directory -Force -Path $alertSrcDir | Out-Null
        foreach ($y in Get-ChildItem (Join-Path $alertingDir '*.yaml')) {
            $text = Get-Content $y.FullName -Raw
            if ($DatasourceUid -ne 'clickstack-ch') { $text = $text -replace 'clickstack-ch', $DatasourceUid }
            if ($y.Name -eq 'appliance-alert-rules.yaml') {
                # Only the quoted substring inside positionCaseInsensitive(...) is replaced,
                # so rule titles and comments mentioning the word are left alone.
                if ($KeyVaultWorkload) {
                    $text = $text -replace "(?<=\['k8s\.pod\.name'\], ')moc-kms(?=')", $KeyVaultWorkload
                }
            }
            Set-Content -Path (Join-Path $alertSrcDir $y.Name) -Value $text -Encoding utf8 -NoNewline
        }
        if ($alertChoice -and $alertChoice.Kind -ne 'Keep') {
            $cpYaml = New-ContactPointYaml -Kind $alertChoice.Kind -Url $alertChoice.Url `
                -Addresses $alertChoice.Addresses -RoutingKey $alertChoice.RoutingKey
            Set-Content -Path (Join-Path $alertSrcDir 'contact-points.yaml') -Value $cpYaml -Encoding utf8 -NoNewline
            Write-Host "    notification channel: $($alertChoice.Kind)"
            if ($alertChoice.Url -or $alertChoice.RoutingKey) {
                Write-Host "    note: this credential is stored in ConfigMap '$AlertingConfigMap' (not a Secret)," -ForegroundColor Yellow
                Write-Host "          so anyone with read access to the namespace can see it." -ForegroundColor Yellow
            }
        }
        if ($KeyVaultWorkload) { Write-Host "    Key Vault rule matches pods containing '$KeyVaultWorkload'" }
    }
    $alertArgs = @('create', 'configmap', $AlertingConfigMap, '-n', $Namespace)
    foreach ($y in Get-ChildItem (Join-Path $alertSrcDir '*.yaml')) { $alertArgs += "--from-file=$($y.FullName)" }
    $alertArgs += @('--dry-run=client', '-o', 'yaml')
    $cmYaml = & kubectl @alertArgs
    if ($LASTEXITCODE -ne 0) { throw "building alerting ConfigMap failed:`n$cmYaml" }
    $cmFile = Join-Path $tmp 'alerting-cm.yaml'
    Set-Content -Path $cmFile -Value $cmYaml -Encoding utf8
    Invoke-Kubectl @('apply', '-f', $cmFile) | Out-Null
    Write-Host "    loaded $((Get-ChildItem (Join-Path $alertSrcDir '*.yaml')).Count) YAML file(s)"

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
Verify (port-forward Grafana, then hit the API from PowerShell):
    kubectl port-forward -n $Namespace svc/$Deployment 3010:3000
    `$cred = Get-Credential   # Grafana admin user + password
    `$g = 'http://localhost:3010'
    # data sources — expect 'clickhouse' and '$DatasourceUid'
    Invoke-RestMethod -Credential `$cred "`$g/api/datasources" | Select-Object name, type
    # dashboards
    Invoke-RestMethod -Credential `$cred "`$g/api/search?type=dash-db" | Select-Object title, uid
    # alert-rule health — expect health=ok for all rules
    Invoke-RestMethod -Credential `$cred "`$g/api/prometheus/grafana/api/v1/rules"

Notification channel: re-run this script and pick a destination at the prompt, or pass
    ./install-k8s.ps1 -AlertDestination Teams -AlertUrl '<workflows-url>'
Unattended installs that pass neither keep ../alerting/contact-points.yaml as shipped.
"@
