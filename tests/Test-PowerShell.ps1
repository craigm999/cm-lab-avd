<#
.SYNOPSIS
    CI tests for the PowerShell in this repo.

    1. Parses every .ps1 file (syntax errors fail the run).
    2. Runs PSScriptAnalyzer (Error severity fails the run; warnings are reported).
    3. Runs scripts/New-AvdParameterFile.ps1 end-to-end with scripted answers for two
       scenarios (existing landing zone / new hub-spoke VNet), with -SkipAzureLookups.
    4. Compiles each generated .bicepparam with `az bicep build-params` and asserts on
       the resulting parameter values.

    Requires: pwsh 7, Azure CLI with Bicep. Set AVD_LOCAL_ADMIN_PASSWORD (any value).
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Equal($Actual, $Expected, [string] $What) {
    if ("$Actual" -ne "$Expected") {
        $failures.Add("$What - expected '$Expected', got '$Actual'")
        Write-Host "  FAIL $What - expected '$Expected', got '$Actual'" -ForegroundColor Red
    }
    else {
        Write-Host "  ok   $What = $Actual" -ForegroundColor Green
    }
}

# ------------------------------------------------------------------- 1. Parse
Write-Host "`n== Parse all PowerShell files" -ForegroundColor Cyan
foreach ($file in Get-ChildItem -Path $repo -Recurse -Filter *.ps1) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors)
    if ($errors) {
        foreach ($e in $errors) { $failures.Add("$($file.Name):$($e.Extent.StartLineNumber) $($e.Message)") }
        Write-Host "  FAIL $($file.Name)" -ForegroundColor Red
    }
    else { Write-Host "  ok   $($file.Name)" -ForegroundColor Green }
}

# ------------------------------------------------------------------- 2. PSScriptAnalyzer
Write-Host "`n== PSScriptAnalyzer" -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck | Out-Null
}
$excluded = @(
    'PSAvoidUsingWriteHost',                       # interactive script - intentional
    'PSUseShouldProcessForStateChangingFunctions', # helpers, not cmdlets
    'PSAvoidUsingPlainTextForPassword'
)
$results = Invoke-ScriptAnalyzer -Path $repo -Recurse -ExcludeRule $excluded
foreach ($r in $results) {
    $line = "{0}:{1} [{2}] {3}: {4}" -f $r.ScriptName, $r.Line, $r.Severity, $r.RuleName, $r.Message
    if ($r.Severity -eq 'Error' -or $r.Severity -eq 'ParseError') { $failures.Add($line); Write-Host "  FAIL $line" -ForegroundColor Red }
    else { Write-Host "  warn $line" -ForegroundColor Yellow }
}
if (-not $results) { Write-Host '  ok   no findings' -ForegroundColor Green }

# ------------------------------------------------------------------- 3. Questionnaire E2E
# Read-Host / Write-Host are replaced with functions (functions win over cmdlets).
# Each answer is chosen by regex against the prompt, or - for "Choice" prompts - the
# question text written just before it.
$global:HostBuffer = [System.Collections.Generic.List[string]]::new()
$global:Answers = @()
$global:AskLog = [System.Collections.Generic.List[string]]::new()

function global:Write-Host {
    param([Parameter(Position = 0)] $Object = '', $ForegroundColor, [switch] $NoNewline)
    $global:HostBuffer.Add([string]$Object)
    Microsoft.PowerShell.Utility\Write-Host "    | $Object"
}

function global:Read-Host {
    param([Parameter(Position = 0)] [string] $Prompt)
    $context = $Prompt
    if ($Prompt -match 'Choice$') {
        # The question is the last non-option line written before the prompt.
        $q = $global:HostBuffer | Where-Object { $_ -notmatch '^\s+[ *]\s*\d+\)' -and $_ -notmatch '^\s+Enter a number' } | Select-Object -Last 1
        $context = "$q :: $Prompt"
    }
    $global:HostBuffer.Clear()
    $global:AskLog.Add($context)
    if ($global:AskLog.Count -gt 200) { throw 'Too many prompts - questionnaire is looping (a scripted answer was probably rejected).' }
    $last3 = $global:AskLog | Select-Object -Last 3
    if ($global:AskLog.Count -ge 3 -and @($last3 | Select-Object -Unique).Count -eq 1) {
        throw "Same prompt asked 3 times (answer rejected?): $context"
    }
    foreach ($pair in $global:Answers) {
        if ($context -match $pair[0]) {
            Microsoft.PowerShell.Utility\Write-Host "    > $($pair[1])" -ForegroundColor Magenta
            return $pair[1]
        }
    }
    Microsoft.PowerShell.Utility\Write-Host '    > (default)' -ForegroundColor DarkGray
    return ''
}

$generator = Join-Path $repo 'scripts/New-AvdParameterFile.ps1'
$paramsDir = Join-Path $repo 'infra/params'

function Invoke-Scenario([string] $Name, [string] $Env, [object[]] $Answers) {
    Write-Host "`n== Questionnaire scenario: $Name" -ForegroundColor Cyan
    $global:Answers = $Answers
    $global:AskLog.Clear()
    try {
        & $generator -SkipAzureLookups -OutputDirectory $paramsDir
    }
    catch {
        $failures.Add("Scenario '$Name' threw: $_")
        Microsoft.PowerShell.Utility\Write-Host "  FAIL scenario threw: $_" -ForegroundColor Red
        return $null
    }
    $bicepparam = Join-Path $paramsDir "$Env.bicepparam"
    if (-not (Test-Path $bicepparam)) { $failures.Add("Scenario '$Name' wrote no $bicepparam"); return $null }
    Microsoft.PowerShell.Utility\Write-Host "`n--- generated $Env.bicepparam ---"
    Get-Content $bicepparam | ForEach-Object { Microsoft.PowerShell.Utility\Write-Host "    $_" }

    $json = Join-Path ([IO.Path]::GetTempPath()) "$Env.parameters.json"
    $out = & az bicep build-params --file $bicepparam --outfile $json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("Scenario '$Name': az bicep build-params failed: $out")
        Microsoft.PowerShell.Utility\Write-Host "  FAIL build-params: $out" -ForegroundColor Red
        return $null
    }
    if ($out) { Microsoft.PowerShell.Utility\Write-Host "    build-params output: $out" -ForegroundColor Yellow }
    Microsoft.PowerShell.Utility\Write-Host '  ok   generated file compiles against main.bicep' -ForegroundColor Green
    return (Get-Content -Raw $json | ConvertFrom-Json).parameters
}

$sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$tenant = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
$vnet = "/subscriptions/$sub/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke"

# --- Scenario A: existing landing zone ------------------------------------------
$p = Invoke-Scenario 'existing landing zone' 'ciexst' @(
    , @('tenant ID', $tenant)
    , @('Workload subscription', $sub)
    , @('Session host virtual network', 'existing')
    , @('^\s*Existing VNet', $vnet)
    , @('^\s*Session host subnet$', "$vnet/subnets/snet-avd")
    , @('Private endpoint subnet', "$vnet/subnets/snet-pe")
    , @('reach the internet', 'Hub Azure Firewall')
    , @('region of the existing VNet', 'uksouth')
    , @('Environment name', 'ciexst')
    , @('Tags', 'owner=IT;cost centre=1234;note=it''s ${x}')
    , @('Log Analytics workspace:', 'existing')
    , @('Existing workspace', '/subscriptions/cccccccc-cccc-cccc-cccc-cccccccccccc/resourceGroups/rg-mgmt/providers/Microsoft.OperationalInsights/workspaces/log-central')
    , @('DNS zone:', 'existing')
    , @('Existing privatelink.file zone', '/subscriptions/dddddddd-dddd-dddd-dddd-dddddddddddd/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net')
    , @("-service' already exist", 'y')
    , @('already exist', 'n')
    , @('AVD users group', '11111111-1111-1111-1111-111111111111')
)
if ($p) {
    Assert-Equal $p.location.value 'uksouth' 'A location'
    Assert-Equal $p.networkMode.value 'existing' 'A networkMode'
    Assert-Equal $p.existingSessionHostSubnetId.value "$vnet/subnets/snet-avd" 'A session host subnet'
    Assert-Equal $p.resourceGroups.value.service.create $false 'A service RG create (exists)'
    Assert-Equal $p.resourceGroups.value.hosts.create $true 'A hosts RG create'
    Assert-Equal $p.resourceGroups.value.hosts.name 'rg-avd-ciexst-uksouth-hosts' 'A hosts RG name'
    Assert-Equal $p.logAnalyticsMode.value 'existing' 'A logAnalyticsMode'
    Assert-Equal $p.privateDnsZoneMode.value 'existing' 'A privateDnsZoneMode'
    Assert-Equal $p.sessionHostCountOverride.value -1 'A sessionHostCountOverride (all hosts)'
    Assert-Equal $p.tags.value.'cost centre' '1234' 'A tag key with space'
    Assert-Equal $p.tags.value.note "it's `${x}" 'A tag value escaping'
    Assert-Equal ($p.availabilityZones.value -join ',') '1,2,3' 'A zones'
    Assert-Equal $p.imageReference.value.sku 'win11-24h2-avd-m365' 'A image sku'
}

# --- Scenario B: new spoke VNet, hub peering, firewall, shared RG ----------------
$p = Invoke-Scenario 'new hub-spoke VNet' 'cinew' @(
    , @('tenant ID', $tenant)
    , @('Workload subscription', $sub)
    , @('Session host virtual network', 'new')
    , @('Azure region', 'westeurope')
    , @('Environment name', 'cinew')
    , @('Hosts to deploy in the first run', '20')
    , @('Session host image', 'gallery')
    , @('Compute Gallery image', '/subscriptions/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee/resourceGroups/rg-img/providers/Microsoft.Compute/galleries/gal/images/win11')
    , @('Availability zones', '-')
    , @('Log Analytics workspace:', 'new')
    , @('Retention', '60')
    , @('DNS zone:', 'policyManaged')
    , @('Custom DNS server', '10.0.0.4, 10.0.0.5')
    , @('Outbound internet', 'FirewallUdr')
    , @('firewall / NVA private IP', '10.0.1.4')
    , @('Peer the new VNet', 'y')
    , @('Hub VNet', '/subscriptions/ffffffff-ffff-ffff-ffff-ffffffffffff/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub')
    , @('gateway', 'y')
    , @(' - resource group', 'rg-avd-cinew-all')
    , @('already exist', 'n')
    , @('AVD users group', '11111111-1111-1111-1111-111111111111')
    , @('AVD admins group', '99999999-9999-9999-9999-999999999999')
    , @('service principal', '22222222-2222-2222-2222-222222222222')
    , @('Deploy autoscale', 'n')
    , @('Load balancing', 'DepthFirst')
)
if ($p) {
    Assert-Equal $p.location.value 'westeurope' 'B location'
    Assert-Equal $p.networkMode.value 'new' 'B networkMode'
    Assert-Equal $p.outboundMethod.value 'FirewallUdr' 'B outboundMethod'
    Assert-Equal $p.firewallPrivateIp.value '10.0.1.4' 'B firewall IP'
    Assert-Equal ($p.dnsServers.value -join ',') '10.0.0.4,10.0.0.5' 'B dnsServers'
    Assert-Equal $p.hubUseRemoteGateways.value $true 'B hubUseRemoteGateways'
    Assert-Equal $p.resourceGroups.value.service.name $p.resourceGroups.value.network.name 'B shared RG'
    Assert-Equal $p.sessionHostCountOverride.value 20 'B pilot host count'
    Assert-Equal @($p.availabilityZones.value).Count 0 'B no zones'
    Assert-Equal ([bool]$p.imageReference.value.id) $true 'B gallery image id'
    Assert-Equal $p.logAnalyticsRetentionDays.value 60 'B retention'
    Assert-Equal $p.deployScalingPlan.value $false 'B scaling plan off'
    Assert-Equal $p.loadBalancerType.value 'DepthFirst' 'B load balancer'
    Assert-Equal $p.privateDnsZoneMode.value 'policyManaged' 'B DNS mode'
}

Remove-Item (Join-Path $paramsDir 'ci*') -ErrorAction SilentlyContinue

# ------------------------------------------------------------------- Result
Microsoft.PowerShell.Utility\Write-Host ''
if ($failures.Count) {
    Microsoft.PowerShell.Utility\Write-Host "$($failures.Count) failure(s):" -ForegroundColor Red
    $failures | ForEach-Object { Microsoft.PowerShell.Utility\Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Microsoft.PowerShell.Utility\Write-Host 'All PowerShell tests passed.' -ForegroundColor Green
