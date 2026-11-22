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
if ($env:SKIP_ANALYZER) { Write-Host '  skipped (SKIP_ANALYZER set)' }
elseif (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck | Out-Null
}
$excluded = @(
    'PSAvoidUsingWriteHost',                       # interactive script - intentional
    'PSUseShouldProcessForStateChangingFunctions', # helpers, not cmdlets
    'PSAvoidUsingPlainTextForPassword',
    'PSAvoidUsingConvertToSecureStringWithPlainText' # test fixtures only
)
$results = if ($env:SKIP_ANALYZER) { @() } else { Invoke-ScriptAnalyzer -Path $repo -Recurse -ExcludeRule $excluded }
foreach ($r in $results) {
    $line = "{0}:{1} [{2}] {3}: {4}" -f $r.ScriptName, $r.Line, $r.Severity, $r.RuleName, $r.Message
    if ($r.Severity -eq 'Error' -or $r.Severity -eq 'ParseError') { $failures.Add($line); Write-Host "  FAIL $line" -ForegroundColor Red }
    else { Write-Host "  warn $line" -ForegroundColor Yellow }
}
if (-not $results -and -not $env:SKIP_ANALYZER) { Write-Host '  ok   no findings' -ForegroundColor Green }

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
    param([Parameter(Position = 0)] [string] $Prompt, [switch] $AsSecureString)
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
            if ($AsSecureString) {
                Microsoft.PowerShell.Utility\Write-Host '    > (secure input)' -ForegroundColor Magenta
                return (ConvertTo-SecureString $pair[1] -AsPlainText -Force)
            }
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
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # 5.1: redirected stderr + Stop would throw
    $out = & az bicep build-params --file $bicepparam --outfile $json 2>&1 | Out-String
    $ErrorActionPreference = $eap
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
    Assert-Equal $p.fslogixNetworkAccess.value 'privateEndpoint' 'A FSLogix via private endpoint (default)'
    Assert-Equal $p.sessionHostCountOverride.value -1 'A sessionHostCountOverride (all hosts)'
    Assert-Equal $p.tags.value.'cost centre' '1234' 'A tag key with space'
    Assert-Equal $p.tags.value.note "it's `${x}" 'A tag value escaping'
    Assert-Equal ($p.availabilityZones.value -join ',') '1,2,3' 'A zones'
    Assert-Equal $p.imageReference.value.sku 'win11-24h2-avd-m365' 'A image sku'
    Assert-Equal $p.imageReference.value.offer 'office-365' 'A image with Microsoft 365 Apps (default)'
    Assert-Equal $p.defenderForServersPlan.value 'None' 'A Defender for Servers left alone (default)'
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
    , @('Profile share network access', 'serviceEndpoint')
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
    Assert-Equal $p.fslogixNetworkAccess.value 'serviceEndpoint' 'B FSLogix via service endpoint (no DNS question)'
}

# ------------------------------------------------------------------- 4. Deploy-Avd.ps1 with a fake az
# A global function named az shadows the real CLI, records each call and returns canned output.
Write-Host "`n== Deploy-Avd.ps1 (az mocked)" -ForegroundColor Cyan
$global:AzCalls = [System.Collections.Generic.List[string]]::new()
$global:PasswordSeenByAz = $null
$global:DeployParamText = $null
$global:MockVmNames = '[]'
$global:MockVmPower = '[]'
$global:AzResponses = $null
$global:MockGraph = $false
$global:MockDnsLinks = '[]'
$global:MockZoneList = '[]'
$global:MockZoneLinks = '[]'
$global:HostDeploys = [System.Collections.Generic.List[object]]::new()
$global:FailHosts = @()
$env:AVD_DEPLOY_POLL_SECONDS = '0'
$hostPoolIdT = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-svc/providers/Microsoft.DesktopVirtualization/hostPools/vdpool-x'
$global:MockSubCreate = '{"hostPoolName":{"type":"String","value":"vdpool-avd-prod-uksouth"},"resourceGroupsCreated":{"type":"Array","value":["rg-a","rg-b"]},' +
    '"sessionHostDeployment":{"type":"Object","value":{"hostPoolId":"' + $hostPoolIdT + '","hostsResourceGroup":"rg-hosts","serviceResourceGroup":"rg-svc","location":"uksouth","sessionHostPrefix":"avdsh","zones":["1","2","3"],' +
    '"sessionHostParameters":{"location":"uksouth","vmSize":"Standard_D4s_v5","imageReference":{"publisher":"MicrosoftWindowsDesktop"},"customizationConfig":{"apps":[],"dataProtection":{"blockedUrls":["onedrive.live.com"]}}}}}}'
function global:az {
    $line = ($args | ForEach-Object { "$_" }) -join ' '
    $global:AzCalls.Add($line)
    $global:LASTEXITCODE = 0
    if ($line -like 'deployment sub*') {
        $global:PasswordSeenByAz = $env:AVD_LOCAL_ADMIN_PASSWORD
        $i = [array]::IndexOf([string[]]$args, '--parameters')
        if ($i -ge 0) { $global:DeployParamText = Get-Content -Raw -LiteralPath $args[$i + 1] }
    }
    if ($line -like 'deployment group create*') {
        $ni = [array]::IndexOf([string[]]$args, '--name'); $pi = [array]::IndexOf([string[]]$args, '--parameters')
        $global:HostDeploys.Add([pscustomobject]@{ Name = "$($args[$ni + 1])"; File = "$($args[$pi + 1])".TrimStart('@'); Params = (Get-Content -Raw -LiteralPath ("$($args[$pi + 1])".TrimStart('@')) | ConvertFrom-Json).parameters })
    }
    if ($line -like 'deployment group list*') {
        return (ConvertTo-Json -Depth 3 @($global:HostDeploys | ForEach-Object { @{ n = $_.Name; s = $(if ($global:FailHosts -contains $_.Params.vmName.value) { 'Failed' } else { 'Succeeded' }) } }))
    }
    $bi2 = [array]::IndexOf([string[]]$args, '--body')
    $ui2 = [array]::IndexOf([string[]]$args, '--url')
    if ($bi2 -ge 0 -and $ui2 -ge 0 -and $null -ne $global:BodyLog) {   # an empty list is falsy
        $global:BodyLog.Add([pscustomobject]@{ Line = $line; Url = "$($args[$ui2 + 1])"; Body = (Get-Content -Raw -LiteralPath ("$($args[$bi2 + 1])".TrimStart('@'))) })
    }
    if ($line -like 'rest --method patch*') {
        $bi = [array]::IndexOf([string[]]$args, '--body')
        if ($bi -ge 0) { $global:PatchBody = Get-Content -Raw -LiteralPath ("$($args[$bi + 1])".TrimStart('@')) }
    }
    if ($global:AzResponses) {
        foreach ($k in $global:AzResponses.Keys) {
            if ($line -like $k) {
                $v = $global:AzResponses[$k]
                if ($v -is [int]) { $global:LASTEXITCODE = $v; return '' }
                return $v
            }
        }
    }
    switch -Wildcard ($line) {
        'vm list --resource-group * --show-details*' { return $global:MockVmPower }
        'vm list --resource-group *' { return $global:MockVmNames }
        'vm run-command show*' { return 'Succeeded' }
        'extension show --name resource-graph*' { if ($global:MockGraph) { return '{}' } else { $global:LASTEXITCODE = 1; return '' } }
        'graph query*' { return $global:MockDnsLinks }
        'network private-dns zone list*' { return $global:MockZoneList }
        'network private-dns link vnet list*' { return $global:MockZoneLinks }
        'account show --query*' { return '{"name":"Test Sub","id":"00000000-0000-0000-0000-000000000000"}' }
        'account show*'         { return '{}' }
        'bicep version*'        { return 'Bicep CLI version 0.49.2' }
        'provider show*'        { return 'Registered' }
        'deployment sub what-if*' { return 'Resource changes: 120 to create.' }
        'deployment sub create*'  { return $global:MockSubCreate }
        'ts show*'                { return '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-svc/providers/Microsoft.Resources/templateSpecs/avd-sessionhost/versions/1.0' }
        default { return '' }
    }
}
$deployScript = Join-Path $repo 'scripts/Deploy-Avd.ps1'
$exampleParams = Join-Path $repo 'infra/main.bicepparam'
Remove-Item Env:\AVD_LOCAL_ADMIN_PASSWORD -ErrorAction SilentlyContinue

# what-if, password entered at the prompt
$global:Answers = @( , @('local admin password', 'Pilot-Passw0rd!x') )
$global:AskLog.Clear()
try {
    & $deployScript -ParameterFile $exampleParams -WhatIf
    $calls = $global:AzCalls -join "`n"
    Assert-Equal ($calls -match 'account set --subscription 00000000-0000-0000-0000-000000000000') $true 'deploy: subscription taken from param file header'
    Assert-Equal ($calls -match 'deployment sub what-if --name avd-\d+ --location uksouth --template-file \S+main\.bicep --parameters \S+main\.deploy-tmp\.bicepparam') $true 'deploy: what-if command'
    Assert-Equal ($global:DeployParamText -match '(?m)^param sessionHostCountOverride = 0\s*$') $true 'deploy: main deployment carries no hosts'
    Assert-Equal ((($global:HostBuffer) -join "`n") -match 'Then 100 session host\(s\) would be deployed') $true 'deploy -WhatIf: lists the hosts it would add'
    Assert-Equal $global:HostDeploys.Count 0 'deploy -WhatIf: no host deployments'
    Assert-Equal ($calls -match 'deployment sub create') $false 'deploy: -WhatIf does not create'
    Assert-Equal $global:PasswordSeenByAz 'Pilot-Passw0rd!x' 'deploy: prompted password passed to az'
    Assert-Equal ([bool]$env:AVD_LOCAL_ADMIN_PASSWORD) $false 'deploy: password cleared afterwards'
}
catch { $failures.Add("Deploy-Avd -WhatIf threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

# create with -Force, password from environment
$global:AzCalls.Clear()
$env:AVD_LOCAL_ADMIN_PASSWORD = 'From-Env-Passw0rd!'
try {
    & $deployScript -ParameterFile $exampleParams -Force -DeploymentName 'avd-ci'
    $calls = $global:AzCalls -join "`n"
    Assert-Equal ($calls -match 'deployment sub create --name avd-ci --location uksouth') $true 'deploy: create command'
    Assert-Equal ($calls -match 'deployment sub what-if') $false 'deploy: create does not run what-if'
    Assert-Equal $env:AVD_LOCAL_ADMIN_PASSWORD 'From-Env-Passw0rd!' 'deploy: existing env password left in place'
    Assert-Equal ($calls -match "ts create --name avd-sessionhost --version 1\.0 --resource-group rg-svc --location uksouth --template-file \S+sessionhost\.bicep") $true 'deploy: session host template spec published'
    Assert-Equal ($calls -match ('rest --method patch --url https://management\.azure\.com' + [regex]::Escape($hostPoolIdT) + '\?api-version')) $true 'deploy: registration token refreshed'
    Assert-Equal $global:HostDeploys.Count 100 'deploy: one deployment per host (100)'
    $h7 = $global:HostDeploys | Where-Object { $_.Params.vmName.value -eq 'avdsh-007' }
    Assert-Equal "$($h7.Params.zone.value)" '1' 'deploy: zone round-robin (host 7 -> zone 1)'
    Assert-Equal "$($h7.Params.adminPassword.value)" 'From-Env-Passw0rd!' 'deploy: password passed to the host deployment'
    Assert-Equal "$($h7.Params.vmSize.value)" 'Standard_D4s_v5' 'deploy: shared host parameters passed'
    Assert-Equal (@($h7.Params.customizationConfig.value.dataProtection.blockedUrls).Count) 1 'deploy: single-item arrays survive'
    Assert-Equal (@($global:HostDeploys | Where-Object { Test-Path -LiteralPath $_.File }).Count) 0 'deploy: host parameter files (password) deleted'
    Assert-Equal ($calls -match 'deployment group create --resource-group rg-hosts --name avd-host-avdsh-001-\d{12} --template-spec /subscriptions/\S+/templateSpecs/avd-sessionhost/versions/1\.0 --parameters @\S+ --no-wait') $true 'deploy: host deployment uses the template spec'
}
catch { $failures.Add("Deploy-Avd create threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
# -AddHosts: existing hosts 001, 002, 020 (plus an unrelated VM) -> new hosts start at 021
$global:MockVmNames = '["avdsh-001","avdsh-002","avdsh-020","jumpbox-01"]'
$global:AzCalls.Clear(); $global:DeployParamText = $null; $global:HostBuffer.Clear(); $global:HostDeploys.Clear()
try {
    & $deployScript -ParameterFile $exampleParams -AddHosts 5 -Force -DeploymentName 'avd-ci-add'
    $names = @($global:HostDeploys | ForEach-Object { $_.Params.vmName.value })
    Assert-Equal ($names -join ',') 'avdsh-021,avdsh-022,avdsh-023,avdsh-024,avdsh-025' 'deploy -AddHosts: next five numbers after the highest'
    Assert-Equal ($global:DeployParamText -match '(?m)^param sessionHostCountOverride = 0\s*$') $true 'deploy -AddHosts: main deployment carries no hosts'
    Assert-Equal (Test-Path (Join-Path $repo 'infra/main.deploy-tmp.bicepparam')) $false 'deploy -AddHosts: temporary param file removed'
}
catch { $failures.Add("Deploy-Avd -AddHosts threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

# -InfraOnly -> zero hosts
$global:AzCalls.Clear(); $global:DeployParamText = $null; $global:HostDeploys.Clear()
try {
    & $deployScript -ParameterFile $exampleParams -InfraOnly -Force -DeploymentName 'avd-ci-infra'
    Assert-Equal ($global:DeployParamText -match '(?m)^param sessionHostCountOverride = 0\s*$') $true 'deploy -InfraOnly: no session hosts'
    Assert-Equal $global:HostDeploys.Count 0 'deploy -InfraOnly: no host deployments'
    Assert-Equal (($global:AzCalls -join "`n") -match 'ts create') $false 'deploy -InfraOnly: no template spec needed'
}
catch { $failures.Add("Deploy-Avd -InfraOnly threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

# Plain run over existing hosts -> existing ones skipped, the rest deployed, outputs saved
$global:HostBuffer.Clear(); $global:HostDeploys.Clear()
$outputsPath = Join-Path $repo 'infra/main.outputs.json'
Remove-Item $outputsPath -ErrorAction SilentlyContinue
try {
    & $deployScript -ParameterFile $exampleParams -Force -DeploymentName 'avd-ci2'
    Assert-Equal ((($global:HostBuffer) -join "`n") -match 'Skipped\s+: 3 host\(s\) already exist') $true 'deploy: existing hosts reported as skipped'
    $names = @($global:HostDeploys | ForEach-Object { $_.Params.vmName.value })
    Assert-Equal $names.Count 97 'deploy: only missing hosts deployed'
    Assert-Equal (($names -contains 'avdsh-020') -or ($names -contains 'avdsh-001')) $false 'deploy: existing hosts never redeployed'
    Assert-Equal (Test-Path $outputsPath) $true 'deploy: outputs saved next to param file'
}
catch { $failures.Add("Deploy-Avd skip-existing run threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
Remove-Item $outputsPath -ErrorAction SilentlyContinue

# A host that fails -> run reports it and prints a -HostNames retry; -HostNames redeploys just those
$global:HostBuffer.Clear(); $global:HostDeploys.Clear(); $global:FailHosts = @('avdsh-023')
$threw = $null
try { & $deployScript -ParameterFile $exampleParams -AddHosts 5 -Force -DeploymentName 'avd-ci-fail' } catch { $threw = "$_" }
Assert-Equal ($threw -match '1 session host\(s\) failed') $true 'deploy: failed host makes the run fail'
Assert-Equal ((($global:HostBuffer) -join "`n") -match '-HostNames avdsh-023') $true 'deploy: retry command names the failed host'
$global:FailHosts = @(); $global:HostDeploys.Clear()
try {
    & $deployScript -ParameterFile $exampleParams -HostNames 'avdsh-023', 'avdsh-002' -Force -DeploymentName 'avd-ci-retry'
    Assert-Equal ((@($global:HostDeploys | ForEach-Object { $_.Params.vmName.value }) | Sort-Object) -join ',') 'avdsh-002,avdsh-023' 'deploy -HostNames: exactly the named hosts'
}
catch { $failures.Add("Deploy-Avd -HostNames threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
Remove-Item $outputsPath -ErrorAction SilentlyContinue
$global:HostDeploys.Clear()

# Private DNS pre-flight: privateDnsZoneMode = 'new' on a VNet already linked to another privatelink.file zone
Write-Host "`n== Deploy-Avd.ps1 private DNS pre-flight (az mocked)" -ForegroundColor Cyan
$global:MockVmNames = '[]'
$dnsParams = Join-Path $repo 'infra/params/cidns.bicepparam'
$null = New-Item -ItemType Directory -Force -Path (Split-Path $dnsParams)
$dnsText = (Get-Content -Raw $exampleParams) -replace "using 'main.bicep'", "using '../main.bicep'" -replace "(?m)^param privateDnsZoneMode = .*$", "param privateDnsZoneMode = 'new'"
[IO.File]::WriteAllText($dnsParams, $dnsText)
$hubZone = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net'
$ownZone = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-avd-prod-uksouth-storage/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net'
$spokeVnet = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-spoke-avd'

# 1. Resource Graph finds the hub zone linked to the VNet -> stop before deploying
$global:MockGraph = $true
$global:MockDnsLinks = '["' + $hubZone + '/virtualNetworkLinks/spoke-link"]'
$global:AzCalls.Clear(); $global:HostBuffer.Clear()
$threw = $null
try { & $deployScript -ParameterFile $dnsParams -WhatIf } catch { $threw = "$_" }
Assert-Equal ($threw -match 'Private DNS zone conflict') $true 'dns pre-flight: conflict stops the run'
Assert-Equal ((($global:HostBuffer) -join "`n").Contains("existingFilePrivateDnsZoneId = '$hubZone'")) $true 'dns pre-flight: suggests the existing zone ID'
Assert-Equal (($global:AzCalls -join "`n") -match 'deployment sub') $false 'dns pre-flight: nothing deployed'

# 2. Only our own zone is linked (re-run of the same deployment) -> no conflict
$global:MockDnsLinks = '["' + $ownZone + '/virtualNetworkLinks/link-avd-vnet"]'
$threw = $null
try { & $deployScript -ParameterFile $dnsParams -WhatIf } catch { $threw = "$_" }
Assert-Equal ([bool]$threw) $false 'dns pre-flight: own zone from an earlier run is fine'

# 3. No resource-graph extension -> falls back to searching this subscription
$global:MockGraph = $false
$global:MockZoneList = '[{"rg":"rg-dns-local","name":"privatelink.file.core.windows.net"}]'
$global:MockZoneLinks = '[{"id":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dns-local/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net/virtualNetworkLinks/x","vnet":"' + $spokeVnet + '"}]'
$threw = $null
try { & $deployScript -ParameterFile $dnsParams -WhatIf } catch { $threw = "$_" }
Assert-Equal ($threw -match 'Private DNS zone conflict') $true 'dns pre-flight (no resource-graph): conflict found in subscription'
Remove-Item $dnsParams -ErrorAction SilentlyContinue
$global:MockGraph = $false; $global:MockDnsLinks = '[]'; $global:MockZoneList = '[]'; $global:MockZoneLinks = '[]'

# Diagnostics, Azure side: storage firewall missing the host subnet -> the Access Denied (error 5) cause
Write-Host "`n== Get-FslogixHostDiagnostics.ps1 storage checks (az mocked)" -ForegroundColor Cyan
$diagScript = Join-Path $repo 'scripts/Get-FslogixHostDiagnostics.ps1'
$hostSubnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-avd'
$saJson = '{"id":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-st/providers/Microsoft.Storage/storageAccounts/sa1","location":"uksouth","public":"Enabled","default":"Deny","rules":RULES,"pe":1,"dirsvc":"AADKERB","sharePerm":"StorageFileDataSmbShareContributor"}'
$global:AzResponses = [ordered]@{
    'storage account show --name*' = $saJson.Replace('RULES', '[]')
    'vm show --resource-group*'    = '{"location":"uksouth","nic":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hosts/providers/Microsoft.Network/networkInterfaces/nic-avdsh-001"}'
    'network nic show --ids*'      = $hostSubnetId
    'network vnet subnet show --ids*' = '[{"service":"Microsoft.Storage","state":"Succeeded"}]'
    'role assignment list --scope*'   = '[{"role":"Storage File Data SMB Share Contributor","name":"AVD Users"}]'
    'vm run-command invoke*'          = "[stdout]`n[OK] TCP 445 reachable"
}
$global:HostBuffer.Clear()
try {
    & $diagScript -VmName 'avdsh-001' -ResourceGroup 'rg-hosts' -StorageAccountName 'sa1' -NetworkAccess serviceEndpoint
    $out = ($global:HostBuffer) -join "`n"
    Assert-Equal ($out -match '\[FAIL\] Storage firewall does NOT allow the host subnet') $true 'diag storage: missing firewall rule reported'
    Assert-Equal ($out.Contains("network-rule add --resource-group rg-st --account-name sa1 --subnet $hostSubnetId")) $true 'diag storage: fix command printed'
    Assert-Equal ($out -match '\[OK\] Host subnet has the Microsoft.Storage service endpoint') $true 'diag storage: subnet service endpoint checked'
    Assert-Equal ($out -match '\[WARN\] The account still has 1 private endpoint') $true 'diag storage: leftover private endpoint flagged'
    Assert-Equal ($out -match '\[OK\] Default share-level permission') $true 'diag storage: default share permission checked'
}
catch { $failures.Add("Diagnostics storage checks threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
$global:AzResponses['storage account show --name*'] = $saJson.Replace('RULES', '[{"id":"' + $hostSubnetId.ToUpper() + '","state":"Succeeded"}]')
$global:HostBuffer.Clear()
try {
    & $diagScript -VmName 'avdsh-001' -ResourceGroup 'rg-hosts' -StorageAccountName 'sa1' -NetworkAccess serviceEndpoint
    Assert-Equal ((($global:HostBuffer) -join "`n") -match '\[OK\] Storage firewall allows the host subnet') $true 'diag storage: rule found (case-insensitive ID match)'
}
catch { $failures.Add("Diagnostics storage checks (ok) threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
$global:AzResponses = $null

# Service endpoint pre-flight: existing subnet without Microsoft.Storage -> stop and print the command
Write-Host "`n== Deploy-Avd.ps1 service endpoint pre-flight (az mocked)" -ForegroundColor Cyan
$seParams = Join-Path $repo 'infra/params/cise.bicepparam'
$seText = ((Get-Content -Raw $exampleParams) -replace "using 'main.bicep'", "using '../main.bicep'").TrimEnd() + "`nparam fslogixNetworkAccess = 'serviceEndpoint'`n"
[IO.File]::WriteAllText($seParams, $seText)
$hostSubnet = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-spoke-avd/subnets/snet-avd-hosts'
$global:AzResponses = [ordered]@{ 'network vnet subnet show --ids*' = '["Microsoft.KeyVault"]' }
$global:AzCalls.Clear(); $global:HostBuffer.Clear()
$threw = $null
try { & $deployScript -ParameterFile $seParams -WhatIf } catch { $threw = "$_" }
Assert-Equal ($threw -match 'Service endpoint missing') $true 'se pre-flight: missing endpoint stops the run'
Assert-Equal ((($global:HostBuffer) -join "`n").Contains("az network vnet subnet update --ids $hostSubnet --service-endpoints Microsoft.KeyVault Microsoft.Storage")) $true 'se pre-flight: prints command keeping existing endpoints'
Assert-Equal (($global:AzCalls -join "`n") -match 'deployment sub') $false 'se pre-flight: nothing deployed'
$global:AzResponses = [ordered]@{ 'network vnet subnet show --ids*' = '["Microsoft.Storage"]' }
$threw = $null
try { & $deployScript -ParameterFile $seParams -WhatIf } catch { $threw = "$_" }
Assert-Equal ([bool]$threw) $false 'se pre-flight: passes when the endpoint exists'
Assert-Equal (($global:AzCalls -join "`n") -match 'graph query|private-dns') $false 'se pre-flight: private DNS check skipped in serviceEndpoint mode'
Remove-Item $seParams -ErrorAction SilentlyContinue
$global:AzResponses = $null

# Deploy-Avd: personal pool of 1000 -> one host per user. No batch limit any more: hosts are
# separate deployments, so the main deployment stays small (no DeploymentSizeExceeded).
Write-Host "`n== Deploy-Avd.ps1 large personal pool (az mocked)" -ForegroundColor Cyan
$pdParams = Join-Path $repo 'infra/params/cipdbig.bicepparam'
$pdText = ((Get-Content -Raw $exampleParams) -replace "using 'main.bicep'", "using '../main.bicep'").TrimEnd() + "`nparam hostPoolType = 'Personal'`n"
[IO.File]::WriteAllText($pdParams, $pdText)
$global:AzResponses = $null; $global:MockVmNames = '[]'; $global:AzCalls.Clear(); $global:HostBuffer.Clear(); $global:HostDeploys.Clear()
$threw = $null
try { & $deployScript -ParameterFile $pdParams -Force -ThrottleLimit 50 -DeploymentName 'avd-ci-big' } catch { $threw = "$_" }
Assert-Equal $threw $null 'deploy: personal 1000 users = 1000 hosts in one run'
Assert-Equal $global:HostDeploys.Count 1000 'deploy: 1000 host deployments'
Assert-Equal ((($global:HostBuffer) -join "`n") -match '1000 session hosts, avdsh-001 to avdsh-1000, 50 at a time') $true 'deploy: plan shows throttle'
Remove-Item $pdParams -ErrorAction SilentlyContinue
Remove-Item (Join-Path $repo 'infra/params/cipdbig.outputs.json') -ErrorAction SilentlyContinue
$global:HostDeploys.Clear()

# Deploy-Avd: pilot cap left in the file -> plain run adds nothing, and says why
Write-Host "`n== Deploy-Avd.ps1 pilot cap hint (az mocked)" -ForegroundColor Cyan
$pilotParams = Join-Path $repo 'infra/params/cipilot.bicepparam'
$pilotText = ((Get-Content -Raw $exampleParams) -replace "using 'main.bicep'", "using '../main.bicep'") -replace '(?m)^param sessionHostCountOverride = .*$', 'param sessionHostCountOverride = 1'
[IO.File]::WriteAllText($pilotParams, $pilotText)
$global:AzResponses = $null; $global:MockVmNames = '["avdsh-001"]'; $global:HostBuffer.Clear(); $global:HostDeploys.Clear()
try {
    & $deployScript -ParameterFile $pilotParams -WhatIf
    $out = ($global:HostBuffer) -join "`n"
    Assert-Equal ($out -match 'no new session hosts') $true 'pilot cap: nothing to add'
    Assert-Equal ($out -match "file says 100 host\(s\).*caps this at 1") $true 'pilot cap: explains the cap'
    Assert-Equal ($out -match "set it to -1") $true 'pilot cap: says how to lift it'
}
catch { $failures.Add("Deploy-Avd pilot cap threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
$global:HostBuffer.Clear()
try {
    & $deployScript -ParameterFile $pilotParams -InfraOnly -WhatIf
    Assert-Equal ((($global:HostBuffer) -join "`n") -match 'caps this') $false 'pilot cap: no hint with -InfraOnly'
}
catch { $failures.Add("Deploy-Avd pilot cap -InfraOnly threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
Remove-Item $pilotParams -ErrorAction SilentlyContinue
$global:MockVmNames = '[]'

# Set-AvdPersonalAssignment: -FromGroup fills free desktops, skips users who already have one
Write-Host "`n== Set-AvdPersonalAssignment.ps1 (az mocked)" -ForegroundColor Cyan
$assignScript = Join-Path $repo 'scripts/Set-AvdPersonalAssignment.ps1'
$pdPool = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-svc/providers/Microsoft.DesktopVirtualization/hostPools/vdpool-x-personal'
$global:AzResponses = [ordered]@{
    'resource list --resource-type Microsoft.DesktopVirtualization/hostPools --name*' = '["' + $pdPool + '"]'
    'resource show --ids */hostPools/*' = 'Personal'
    'rest --method get --url https://management.azure.com*' = '[{"name":"vdpool-x-personal/avdpd-001","user":"alice@contoso.com"},{"name":"vdpool-x-personal/avdpd-002","user":null},{"name":"vdpool-x-personal/avdpd-003","user":null}]'
    'ad group list --display-name*' = '["g-1"]'
    'ad group member list*' = '["alice@contoso.com","bob@contoso.com","carol@contoso.com","dave@contoso.com"]'
    'rest --method patch*' = ''
}
$global:AzCalls.Clear(); $global:HostBuffer.Clear()
try {
    & $assignScript -HostPoolName 'vdpool-x-personal' -FromGroup 'AVD Users'
    $patches = @($global:AzCalls | Where-Object { $_ -like 'rest --method patch*' })
    Assert-Equal $patches.Count 2 'assign: two free desktops filled'
    Assert-Equal ($patches[0] -match 'sessionHosts/avdpd-002\?api-version') $true 'assign: first free desktop used'
    $out = ($global:HostBuffer) -join "`n"
    Assert-Equal ($out -match '3 group member\(s\) without a desktop, 2 free desktop\(s\)') $true 'assign: alice (already assigned) skipped'
    Assert-Equal ($out -match '1 user\(s\) left without a desktop') $true 'assign: shortfall reported'
}
catch { $failures.Add("Set-AvdPersonalAssignment threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
$global:AzResponses['resource show --ids */hostPools/*'] = 'Pooled'
$threw = $null
try { & $assignScript -HostPoolName 'vdpool-x-personal' -User 'x@contoso.com' -SessionHost 'avdpd-002' } catch { $threw = "$_" }
Assert-Equal ($threw -match 'only apply to Personal host pools') $true 'assign: refuses a pooled host pool'
$global:AzResponses = $null

# Deploy-Avd: after a create, the desktop display name is set on the SessionDesktop resource
Write-Host "`n== Deploy-Avd.ps1 desktop display name (az mocked)" -ForegroundColor Cyan
$agIdT = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-svc/providers/Microsoft.DesktopVirtualization/applicationGroups/vdag-x-desktop'
$global:AzResponses = [ordered]@{
    'deployment sub create*' = '{"desktopAppGroupId":{"type":"String","value":"' + $agIdT + '"},"desktopFriendlyName":{"type":"String","value":"Contoso Desktop"},"sessionHostResourceGroup":{"type":"String","value":"rg-hosts"}}'
    'rest --method get --url https://management.azure.com*/desktops*' = 'vdag-x-desktop/SessionDesktop'
    'rest --method patch*' = ''
}
$global:MockVmNames = '[]'; $global:AzCalls.Clear(); $global:HostBuffer.Clear(); $global:PatchBody = $null
$outputsPath = Join-Path $repo 'infra/main.outputs.json'
try {
    & $deployScript -ParameterFile $exampleParams -InfraOnly -Force -DeploymentName 'avd-ci-name'
    $patch = @($global:AzCalls | Where-Object { $_ -like 'rest --method patch*' })
    Assert-Equal ($patch.Count -eq 1 -and $patch[0] -match [regex]::Escape("$agIdT/desktops/SessionDesktop?api-version=")) $true 'desktop name: PATCH on the SessionDesktop resource'
    Assert-Equal ("$global:PatchBody" -match '"friendlyName":\s*"Contoso Desktop"') $true 'desktop name: friendly name sent'
}
catch { $failures.Add("Deploy-Avd desktop name threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
Remove-Item $outputsPath -ErrorAction SilentlyContinue

# Deploy-Avd: custom (Compute Gallery) image pre-flight
Write-Host "`n== Deploy-Avd.ps1 custom image pre-flight (az mocked)" -ForegroundColor Cyan
$imgDef = '/subscriptions/55555555-5555-5555-5555-555555555555/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/gal_avd/images/win11-avd'
$imgParams = Join-Path $repo 'infra/params/ciimg.bicepparam'
$imgText = ((Get-Content -Raw $exampleParams) -replace "using 'main.bicep'", "using '../main.bicep'") -replace "(?s)param imageReference = \{.*?\n\}", "param imageReference = {`n  id: '$imgDef'`n}"
[IO.File]::WriteAllText($imgParams, $imgText)
$tlDef = '{"gen":"V2","state":"Generalized","features":[{"name":"SecurityType","value":"TrustedLaunchSupported"}]}'
function Invoke-ImageCheck([string] $Def, [string] $Versions) {
    $global:AzResponses = [ordered]@{ 'sig image-definition show*' = $Def; 'sig image-version list*' = $Versions }
    $global:HostBuffer.Clear()
    try { $null = & $deployScript -ParameterFile $imgParams -WhatIf; return '' } catch { return "$_" }
}
$r1 = Invoke-ImageCheck $tlDef '[{"name":"1.0.0","regions":["UK South"],"exclude":false,"state":"Succeeded"},{"name":"1.1.0","regions":["West Europe"],"exclude":false,"state":"Succeeded"}]'
Assert-Equal ($r1 -match 'Custom image problem') $true 'image: latest version not replicated to the region is caught'
Assert-Equal ((($global:HostBuffer) -join "`n") -match 'Image version 1\.1\.0 is not replicated to uksouth') $true 'image: names the version and region'
$r2 = Invoke-ImageCheck $tlDef '[{"name":"1.0.0","regions":["UK South"],"exclude":false,"state":"Succeeded"},{"name":"1.1.0","regions":["UK South","West Europe"],"exclude":false,"state":"Succeeded"}]'
Assert-Equal $r2 '' 'image: replicated Trusted Launch image passes'
$r3 = Invoke-ImageCheck '{"gen":"V2","state":"Generalized","features":[]}' '[{"name":"1.0.0","regions":["UK South"],"exclude":false,"state":"Succeeded"}]'
Assert-Equal ((($global:HostBuffer) -join "`n") -match 'Trusted Launch needs TrustedLaunchSupported') $true 'image: definition without Trusted Launch support is caught'
Remove-Item $imgParams -ErrorAction SilentlyContinue
$global:AzResponses = $null

# Update-SessionHostConfig -Customize: pushes the customisation script with the shared JSON config
Write-Host "`n== Update-SessionHostConfig.ps1 -Customize (az mocked)" -ForegroundColor Cyan
$global:AzResponses = $null
$global:MockVmPower = '[{"name":"avdpd-001","power":"VM running"}]'
$global:AzCalls.Clear()
try {
    & (Join-Path $repo 'scripts/Update-SessionHostConfig.ps1') -ResourceGroup 'rg-hosts' -Customize
    $create = @($global:AzCalls | Where-Object { $_ -like 'vm run-command create*' })
    Assert-Equal ($create.Count -eq 1 -and $create[0] -match '--name Customize-SessionHost --script @\S+Customize-SessionHost\.ps1 --parameters ConfigBase64=') $true 'customize: customisation run command pushed'
    $b64 = [regex]::Match($create[0], 'ConfigBase64=(\S+)').Groups[1].Value
    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    Assert-Equal ($decoded -match 'removeAppxPackages') $true 'customize: shared customizations.json sent'
    Assert-Equal ($create[0] -match '--timeout-in-seconds 5400') $true 'customize: longer timeout for app installs'
}
catch { $failures.Add("Update-SessionHostConfig -Customize threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

# -Customize where the script ran but a step failed: exit code and the host's own log lines shown
$global:AzResponses = [ordered]@{
    'vm run-command show * --query {exit*' = '{"exit":1,"output":"2026-11-22 10:00:00 Microsoft 365 apps\n2026-11-22 10:00:05   MSTeams not removed for all users - Deployment failed with HRESULT: 0x80073D02\n2026-11-22 10:00:06   Teams: FAILED - still installed after removal (see the lines above)","error":""}'
    'vm run-command show*' = 'Succeeded'
}
$global:AzCalls.Clear(); $global:HostBuffer.Clear()
try {
    & (Join-Path $repo 'scripts/Update-SessionHostConfig.ps1') -ResourceGroup 'rg-hosts' -Customize
    $out = ($global:HostBuffer) -join "`n"
    Assert-Equal ($out -match 'avdpd-001\s+Failed \(script exit code 1\)') $true 'customize: script exit code turns Succeeded into Failed'
    Assert-Equal ($out -match 'Teams: FAILED - still installed') $true 'customize: host log lines shown'
    Assert-Equal ($out -match '0x80073D02') $true 'customize: the underlying error is shown'
}
catch { $failures.Add("Update-SessionHostConfig -Customize (failed step) threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
$global:AzResponses = $null

# Update-SessionHostConfig: one running, one deallocated host
Write-Host "`n== Update-SessionHostConfig.ps1 (az mocked)" -ForegroundColor Cyan
$updateScript = Join-Path $repo 'scripts/Update-SessionHostConfig.ps1'
$global:MockVmPower = '[{"name":"avdsh-001","power":"VM running"},{"name":"avdsh-002","power":"VM deallocated"}]'
$unc = '\\stfslogixtest.file.core.windows.net\profiles'
$global:AzCalls.Clear()
try {
    & $updateScript -ResourceGroup 'rg-hosts' -VhdLocation $unc
    $calls = $global:AzCalls -join "`n"
    Assert-Equal ($calls -match 'vm run-command create --resource-group rg-hosts --vm-name avdsh-001 --name Configure-SessionHost --script @\S+Configure-SessionHost\.ps1 --parameters FslogixEnabled=True VhdLocation=\\\\stfslogixtest\.file\.core\.windows\.net\\profiles ProfileSizeMB=30000') $true 'update: run command pushed to running host'
    Assert-Equal ($calls -match 'vm-name avdsh-002') $false 'update: stopped host skipped by default'
    Assert-Equal ($calls -match 'vm start') $false 'update: does not start hosts by default'
}
catch { $failures.Add("Update-SessionHostConfig threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
$global:AzCalls.Clear()
try {
    & $updateScript -ResourceGroup 'rg-hosts' -VhdLocation $unc -IncludeStopped
    $calls = $global:AzCalls -join "`n"
    Assert-Equal ($calls -match 'vm start --resource-group rg-hosts --name avdsh-002') $true 'update -IncludeStopped: starts stopped host'
    Assert-Equal ($calls -match 'run-command create --resource-group rg-hosts --vm-name avdsh-002') $true 'update -IncludeStopped: configures it'
}
catch { $failures.Add("Update-SessionHostConfig -IncludeStopped threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

# Update-SessionHostDisk: type + size change, a busy host, a host that already matches
Write-Host "`n== Update-SessionHostDisk.ps1 (az mocked)" -ForegroundColor Cyan
$diskScript = Join-Path $repo 'scripts/Update-SessionHostDisk.ps1'
$poolT = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-svc/providers/Microsoft.DesktopVirtualization/hostPools/vdpool-x-personal'
$dPre = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hosts/providers/Microsoft.Compute/disks/'
function Reset-DiskMock([string] $ExtendOutput) {
    $global:AzResponses = [ordered]@{
        'vm list --resource-group rg-hosts --show-details*' = '[{"name":"avdpd-001","power":"VM running","diskId":"' + $dPre.ToUpper() + 'AVDPD-001-OSDISK"},{"name":"avdpd-002","power":"VM deallocated","diskId":"' + $dPre + 'avdpd-002-osdisk"},{"name":"avdpd-003","power":"VM running","diskId":"' + $dPre + 'avdpd-003-osdisk"},{"name":"avdpd-004","power":"VM running","diskId":"' + $dPre + 'avdpd-004-osdisk"},{"name":"jumpbox","power":"VM running","diskId":"' + $dPre + 'jumpbox-osdisk"}]'
        'disk list*' = '[{"id":"' + $dPre + 'avdpd-001-osdisk","sku":"Premium_LRS","size":128},{"id":"' + $dPre + 'avdpd-002-osdisk","sku":"Premium_LRS","size":128},{"id":"' + $dPre + 'avdpd-003-osdisk","sku":"Premium_LRS","size":128},{"id":"' + $dPre + 'avdpd-004-osdisk","sku":"StandardSSD_LRS","size":512},{"id":"' + $dPre + 'jumpbox-osdisk","sku":"Premium_LRS","size":128}]'
        'rest --method get --url *sessionHosts*' = '{"value":[{"name":"vdpool-x-personal/avdpd-001","properties":{"sessions":0,"allowNewSession":true}},{"name":"vdpool-x-personal/avdpd-002","properties":{"sessions":0,"allowNewSession":true}},{"name":"vdpool-x-personal/avdpd-003","properties":{"sessions":1,"allowNewSession":true}},{"name":"vdpool-x-personal/avdpd-004","properties":{"sessions":0,"allowNewSession":true}}]}'
        'rest --method patch*' = ''
        'vm run-command invoke*' = $ExtendOutput
    }
    $global:AzCalls.Clear(); $global:HostBuffer.Clear(); $global:BodyLog = [System.Collections.Generic.List[object]]::new()
}
$diskArgs = @{ ResourceGroup = 'rg-hosts'; HostPoolId = $poolT; DiskType = 'StandardSSD_LRS'; SizeGB = 256 }
Reset-DiskMock 'C: extended to 256 GB'
try {
    & $diskScript @diskArgs -WhatIf
    $out = ($global:HostBuffer) -join "`n"
    Assert-Equal ($out -match '2 to change, 1 skipped \(signed in\), 1 already match') $true 'disk -WhatIf: plan (busy host skipped, bigger disk kept, jump box ignored)'
    Assert-Equal ($out -match 'avdpd-001\s+VM running\s+Premium_LRS -> StandardSSD_LRS, 128 -> 256 GiB') $true 'disk -WhatIf: shows the change per host'
    Assert-Equal (@($global:AzCalls | Where-Object { $_ -match '^disk update|^vm deallocate|^rest --method patch' }).Count) 0 'disk -WhatIf: changes nothing'
}
catch { $failures.Add("Update-SessionHostDisk -WhatIf threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

Reset-DiskMock 'C: extended to 256 GB'
try {
    & $diskScript @diskArgs -Force
    $c = @($global:AzCalls)
    $upd = @($c | Where-Object { $_ -like 'disk update*' })
    Assert-Equal $upd.Count 2 'disk: two disks updated'
    Assert-Equal ($upd[0] -match 'AVDPD-001-OSDISK.*--sku StandardSSD_LRS --size-gb 256') $true 'disk: sku and size passed'
    Assert-Equal (@($c | Where-Object { $_ -match 'avdpd-00[34]' -and $_ -notlike 'vm list*' -and $_ -notlike 'disk list*' }).Count) 0 'disk: busy and matching hosts untouched'
    $iDrain = [array]::IndexOf([string[]]$c, @($c | Where-Object { $_ -like 'rest --method patch*avdpd-001*' })[0])
    $iDealloc = [array]::IndexOf([string[]]$c, @($c | Where-Object { $_ -like 'vm deallocate --resource-group rg-hosts --name avdpd-001*' })[0])
    $iUpd = [array]::IndexOf([string[]]$c, $upd[0])
    Assert-Equal ($iDrain -ge 0 -and $iDrain -lt $iDealloc -and $iDealloc -lt $iUpd) $true 'disk: drain, then deallocate, then update'
    $drainBodies = @($global:BodyLog | Where-Object { $_.Url -match 'avdpd-001' } | ForEach-Object { "$($_.Body)" -replace '\s', '' })
    Assert-Equal (($drainBodies -join '|') -match '"allowNewSession":false.*\|.*"allowNewSession":true') $true 'disk: drain mode on, then restored'
    Assert-Equal (@($c | Where-Object { $_ -like 'vm start --resource-group rg-hosts --name avdpd-00[12]*' }).Count) 2 'disk: both started (running host; stopped host to extend C:)'
    Assert-Equal (@($c | Where-Object { $_ -match '^vm run-command invoke .*--scripts @\S+avd-extend-c-\w+\.ps1' }).Count) 2 'disk: C: extended on both'
    Assert-Equal (@($c | Where-Object { $_ -like 'vm deallocate --resource-group rg-hosts --name avdpd-002*' }).Count) 1 'disk: stopped host deallocated again afterwards (only once)'
    Assert-Equal (@($c | Where-Object { $_ -like 'vm deallocate --resource-group rg-hosts --name avdpd-001*' }).Count) 1 'disk: running host left running'
    Assert-Equal ((($global:HostBuffer) -join "`n") -match 'Done: 2 changed, 0 failed') $true 'disk: summary'
}
catch { $failures.Add("Update-SessionHostDisk threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

Reset-DiskMock 'Resize-Partition : Size Not Supported'
$threw = $null
try { & $diskScript @diskArgs -Force -VmName avdpd-001 } catch { $threw = "$_" }
Assert-Equal ($threw -match '1 host\(s\) need attention') $true 'disk: failed C: extension reported'
Assert-Equal ((($global:HostBuffer) -join "`n") -match 'C: NOT extended - a recovery partition') $true 'disk: recovery partition hint'
$global:AzResponses = $null; $global:BodyLog = $null

# Test-AvdUserAccess: healthy member, then an unassigned guest
Write-Host "`n== Test-AvdUserAccess.ps1 (az mocked)" -ForegroundColor Cyan
$accessScript = Join-Path $repo 'scripts/Test-AvdUserAccess.ps1'
$svc = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-svc/providers/Microsoft.DesktopVirtualization'
function New-AccessMock([hashtable] $Overrides) {
    $m = [ordered]@{}
    foreach ($k in $Overrides.Keys) { $m[$k] = $Overrides[$k] }
    $defaults = [ordered]@{
        'resource list --resource-type Microsoft.DesktopVirtualization/hostPools --name*' = '[{"id":"' + $svc + '/hostPools/vdpool-x","rg":"rg-svc"}]'
        'ad user show*'                 = '{"id":"u-1","upn":"alice@contoso.com","type":"Member","enabled":true,"mail":"alice@contoso.com"}'
        'ad user get-member-groups*'    = '["g-users"]'
        'resource list --resource-group rg-svc --resource-type Microsoft.DesktopVirtualization/applicationGroups*' = '["' + $svc + '/applicationGroups/ag1"]'
        'role assignment list --scope*' = '[{"pid":"g-users","type":"Group","name":"AVD Users"}]'
        'ad group member check*'        = 'true'
        'resource list --resource-group rg-svc --resource-type Microsoft.DesktopVirtualization/workspaces*' = '["' + $svc + '/workspaces/ws1"]'
        'resource show --ids */workspaces/*'  = '["' + $svc + '/applicationGroups/ag1"]'
        'role assignment list --resource-group*' = '[{"pid":"g-users","role":"Virtual Machine User Login","name":"AVD Users"}]'
        'rest --method get --url https://management.azure.com*' = '[{"name":"vdpool-x/avdsh-001","status":"Available","allow":true,"sessions":0}]'
        'resource show --ids */hostPools/* --query {type*' = '{"type":"Pooled","assign":null}'
        'resource show --ids */hostPools/*' = 'targetisaadjoined:i:1;enablerdsaadauth:i:1;'
        'rest --method get --url https://graph.microsoft.com*' = 'true'
    }
    foreach ($k in $defaults.Keys) { if (-not $m.Contains($k)) { $m[$k] = $defaults[$k] } }
    return $m
}

$global:AzResponses = New-AccessMock @{}
$global:HostBuffer.Clear()
try {
    & $accessScript -User 'alice@contoso.com' -HostPoolName 'vdpool-x' -HostsResourceGroup 'rg-hosts'
    $out = ($global:HostBuffer) -join "`n"
    Assert-Equal ($out -match '\[PASS\] Assigned .Desktop Virtualization User. via group AVD Users') $true 'access: member assignment found via group'
    Assert-Equal ($out -match '\[PASS\] Application group is registered') $true 'access: workspace registration'
    Assert-Equal ($out -match '\[PASS\] Has Virtual Machine User Login') $true 'access: sign-in role'
    Assert-Equal ($out -match '\[PASS\] avdsh-001 is Available') $true 'access: host available'
    Assert-Equal ($out -match '\[FAIL\]') $false 'access: no failures for a healthy member'
}
catch { $failures.Add("Test-AvdUserAccess (member) threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

$global:AzResponses = New-AccessMock ([ordered]@{
    'ad user show*' = 1
    'ad user list --filter*' = '[{"id":"u-2","upn":"bob_fabrikam.com#EXT#@contoso.onmicrosoft.com","type":"Guest","enabled":true,"mail":"bob@fabrikam.com"}]'
    'ad user get-member-groups*' = '[]'
    'role assignment list --scope*' = '[{"pid":"g-users","type":"Group","name":"AVD Users"}]'
    'rest --method get --url https://graph.microsoft.com*' = 'false'
})
$global:HostBuffer.Clear()
try {
    & $accessScript -User 'bob@fabrikam.com' -HostPoolName 'vdpool-x' -HostsResourceGroup 'rg-hosts'
    $out = ($global:HostBuffer) -join "`n"
    Assert-Equal ($out -match 'bob_fabrikam\.com#EXT#.*\(Guest\)') $true 'access: guest found by email'
    Assert-Equal ($out -match '\[FAIL\] User has no Desktop Virtualization User assignment') $true 'access: missing assignment reported'
    Assert-Equal ($out -match '\[FAIL\] Entra RDP protocol is NOT enabled') $true 'access: tenant SSO setting is a failure for guests'
    Assert-Equal ($out -match 'one-time passcode guests are NOT supported') $true 'access: guest requirements listed'
}
catch { $failures.Add("Test-AvdUserAccess (guest) threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
$global:AzResponses = $null

# Get-HostDataProtectionReport: pushes the host script and colours the report
Write-Host "`n== Get-HostDataProtectionReport.ps1 (az mocked)" -ForegroundColor Cyan
$global:AzResponses = [ordered]@{ 'vm run-command invoke*' = "[stdout]`n[OK] Personal Microsoft accounts blocked`n[FAIL] Tenant restrictions v2 NOT configured on this host" }
$global:AzCalls.Clear(); $global:HostBuffer.Clear()
try {
    & (Join-Path $repo 'scripts/Get-HostDataProtectionReport.ps1') -VmName 'avdpd-005' -ResourceGroup 'rg-hosts'
    Assert-Equal (($global:AzCalls -join "`n") -match 'vm run-command invoke --resource-group rg-hosts --name avdpd-005 --command-id RunPowerShellScript --scripts @\S+Test-DataProtectionHost\.ps1') $true 'dp report: host script pushed'
    Assert-Equal ((($global:HostBuffer) -join "`n") -match '\[FAIL\] Tenant restrictions v2 NOT configured') $true 'dp report: findings shown'
}
catch { $failures.Add("Get-HostDataProtectionReport threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
$global:AzResponses = $null

# Set-FslogixStorageAuth: adds privatelink identifierUris + cloud-group tag, consents, reports MFA policy
Write-Host "`n== Set-FslogixStorageAuth.ps1 (az mocked)" -ForegroundColor Cyan
$authScript = Join-Path $repo 'scripts/Set-FslogixStorageAuth.ps1'
$caPolicies = '[{"name":"Require MFA all users","include":["All"],"exclude":[],"controls":["mfa"],"strength":null},{"name":"Already excluded","include":["All"],"exclude":["app-1"],"controls":["mfa"],"strength":null}]'
$global:AzResponses = [ordered]@{
    'account show --query tenantId*' = 'tenant-1'
    'ad app list --filter*' = '[{"id":"obj-1","appId":"app-1","uris":["api://tenant-1/CIFS/sa1.file.core.windows.net","api://tenant-1/HOST/sa1.file.core.windows.net","CIFS/sa1.file.core.windows.net"],"tags":[]}]'
    'rest --method patch*' = ''
    'ad app permission admin-consent*' = ''
    'rest --method get --url https://graph.microsoft.com/v1.0/identity/conditionalAccess*' = $caPolicies
}
$global:AzCalls.Clear(); $global:HostBuffer.Clear(); $global:PatchBody = $null
try {
    & $authScript -StorageAccountName 'sa1'
    $calls = $global:AzCalls -join "`n"
    $body = "$global:PatchBody"
    Assert-Equal ($body.Contains('api://tenant-1/CIFS/sa1.privatelink.file.core.windows.net')) $true 'storage auth: privatelink api:// URI added'
    Assert-Equal ($body.Contains('"CIFS/sa1.privatelink.file.core.windows.net"')) $true 'storage auth: privatelink SPN-form URI added'
    Assert-Equal ($body.Contains('api://tenant-1/CIFS/sa1.file.core.windows.net')) $true 'storage auth: existing URIs kept'
    Assert-Equal ($body.Contains('kdc_enable_cloud_group_sids')) $true 'storage auth: cloud-only groups tag added'
    Assert-Equal ($calls -match 'ad app permission admin-consent --id app-1') $true 'storage auth: admin consent granted'
    $out = ($global:HostBuffer) -join "`n"
    Assert-Equal ($out -match 'Require MFA all users') $true 'storage auth: blocking MFA policy reported'
    Assert-Equal ($out -match 'Already excluded') $false 'storage auth: excluded policy not reported'
}
catch { $failures.Add("Set-FslogixStorageAuth threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

# already configured -> no PATCH; -WhatIf -> no consent either
$global:AzResponses['ad app list --filter*'] = '[{"id":"obj-1","appId":"app-1","uris":["CIFS/sa1.file.core.windows.net","CIFS/sa1.privatelink.file.core.windows.net"],"tags":["kdc_enable_cloud_group_sids"]}]'
$global:AzCalls.Clear()
try {
    & $authScript -StorageAccountName 'sa1' -WhatIf
    $calls = $global:AzCalls -join "`n"
    Assert-Equal ($calls -match 'rest --method patch') $false 'storage auth: nothing to patch when already configured'
    Assert-Equal ($calls -match 'admin-consent') $false 'storage auth: -WhatIf makes no changes'
}
catch { $failures.Add("Set-FslogixStorageAuth -WhatIf threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

# Get-FslogixHostDiagnostics: pushes the host script and colours the report
Write-Host "`n== Get-FslogixHostDiagnostics.ps1 (az mocked)" -ForegroundColor Cyan
$diagScript = Join-Path $repo 'scripts/Get-FslogixHostDiagnostics.ps1'
$global:AzResponses = [ordered]@{
    'vm run-command invoke*' = "Enable succeeded:`n[stdout]`n[OK] TCP 445 reachable`n[FAIL] sa1.file.core.windows.net -> 20.1.2.3 is PUBLIC`n[HINT] (1326) Bad credentials"
}
$global:AzCalls.Clear(); $global:HostBuffer.Clear()
try {
    & $diagScript -VmName 'avdsh-001' -ResourceGroup 'rg-hosts'
    Assert-Equal (($global:AzCalls -join "`n") -match 'vm run-command invoke --resource-group rg-hosts --name avdsh-001 --command-id RunPowerShellScript --scripts @\S+Test-FslogixHost\.ps1') $true 'diagnostics: host script pushed via Run Command'
    $out = ($global:HostBuffer) -join "`n"
    Assert-Equal ($out -match '\[FAIL\] sa1\.file\.core\.windows\.net -> 20\.1\.2\.3 is PUBLIC') $true 'diagnostics: report shown'
    Assert-Equal ($out -match '\[stdout\]') $false 'diagnostics: Run Command noise stripped'
    Assert-Equal (($global:AzCalls -join "`n") -match '--parameters NetworkAccess=privateEndpoint') $true 'diagnostics: network access mode passed to host'
}
catch { $failures.Add("Get-FslogixHostDiagnostics threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
$global:AzResponses = $null

# Test-FslogixHost (runs on the session host): real run on Windows with a planted FSLogix log
if ($env:OS -eq 'Windows_NT') {
    Write-Host "`n== Test-FslogixHost.ps1 (Windows, fake FSLogix log)" -ForegroundColor Cyan
    $logDir = 'C:\ProgramData\FSLogix\Logs\Profile'
    $created = -not (Test-Path $logDir)
    $null = New-Item -ItemType Directory -Force -Path $logDir
    $fakeLog = Join-Path $logDir 'Profile-ci-test.log'
    Set-Content -Path $fakeLog -Value @(
        '[09:00:00.001][tid:00000a1c.00000b2d][INFO]           ===== Begin Session: Logon'
        '[09:00:01.002][tid:00000a1c.00000b2d][ERROR:00000035] Failed to open virtual disk (The network path was not found.)'
        '[10:00:00.001][tid:00000a1c.00000b2d][INFO]           ===== Begin Session: Logon'
        '[10:00:00.500][tid:00000a1c.00000b2d][INFO]           Starting LoadProfile'
        '[10:00:01.002][tid:00000a1c.00000b2d][ERROR:0000052E] Failed to open virtual disk (The user name or password is incorrect.)'
    )
    try {
        $hostOut = (& (Join-Path $repo 'infra/scripts/Test-FslogixHost.ps1') 2>&1 | Out-String)
        Microsoft.PowerShell.Utility\Write-Host $hostOut
        Assert-Equal ($hostOut -match '\[HINT\] \(1326\) Bad credentials') $true 'host diag: FSLogix hex code 0000052E decoded to 1326 with hint'
        Assert-Equal ($hostOut -match '\[(OK|FAIL|WARN)\] CloudKerberosTicketRetrievalEnabled') $true 'host diag: registry checks ran'
        Assert-Equal ($hostOut -match 'Most recent sign-in attempt in Profile-ci-test\.log: 10:00:00') $true 'host diag: latest attempt identified'
        Assert-Equal ($hostOut -match '\(53\)') $false 'host diag: error from an earlier attempt not reported'
        Assert-Equal ($hostOut -match '1 older error\(s\) earlier in the log ignored') $true 'host diag: older errors counted, not shown'
    }
    catch { $failures.Add("Test-FslogixHost threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
    finally {
        Remove-Item $fakeLog -ErrorAction SilentlyContinue
        if ($created) { Remove-Item 'C:\ProgramData\FSLogix' -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Customize-SessionHost: dry run on Windows (no changes) with the real config plus a sample app
if ($env:OS -eq 'Windows_NT') {
    Write-Host "`n== Customize-SessionHost.ps1 (Windows, dry run)" -ForegroundColor Cyan
    $cfg = Get-Content -Raw (Join-Path $repo 'infra/customizations/customizations.json') | ConvertFrom-Json
    $cfg.apps = @([pscustomobject]@{ name = '7-Zip'; url = 'https://example.invalid/7z.msi'; arguments = ''; sha256 = 'ABC'; detectPath = 'C:\definitely-not-installed\7z.exe' })
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($cfg | ConvertTo-Json -Depth 10)))
    try {
        $dryOut = (& (Join-Path $repo 'infra/scripts/Customize-SessionHost.ps1') -ConfigBase64 $b64 -DryRun 'True' | Out-String)
        Microsoft.PowerShell.Utility\Write-Host $dryOut
        Assert-Equal ($dryOut -match 'DRY RUN') $true 'customize dry run: announced'
        Assert-Equal ($dryOut -match 'remove Appx package Microsoft\.BingNews') $true 'customize dry run: appx removal planned'
        Assert-Equal ($dryOut -match 'EnableMulticast = 0') $true 'customize dry run: hardening planned'
        Assert-Equal ($dryOut -match 'remove Teams: stop it, remove MSTeams for every user') $true 'customize dry run: Teams removal planned'
        Assert-Equal ($dryOut -match 'officeupdate\\PreventTeamsInstall = 1') $true 'customize dry run: Office updates stopped from reinstalling Teams'
        Assert-Equal ($dryOut -match 'OneDrive\\DisableFileSyncNGSC = 1') $true 'customize dry run: OneDrive blocked by policy'
        Assert-Equal ($dryOut -match 'uninstall OneDrive') $true 'customize dry run: OneDrive uninstall planned'
        Assert-Equal ($dryOut -match 'Microsoft 365 Apps not installed|\[dry-run\] uninstall Microsoft 365') $false 'customize dry run: Office kept (removeOffice false)'
        Assert-Equal ($dryOut -match 'Real-Time Protection\\DisableRealtimeMonitoring = 0') $true 'customize dry run: Defender real-time enforced'
        Assert-Equal ($dryOut -match "App '7-Zip': \[dry-run\] download .*SHA-256 checked.*msiexec") $true 'customize dry run: app install planned with hash check'
        Assert-Equal (Test-Path 'C:\ProgramData\AvdCustomization\customize.log') $false 'customize dry run: nothing written'
    }
    catch { $failures.Add("Customize-SessionHost dry run threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
}

# Data protection (Windows): dry run of the shipped settings, Microsoft-account value checked
# against Windows' own security settings definitions, Tenant Restrictions reader against a
# sample policy definition shaped like the documented one.
if ($env:OS -eq 'Windows_NT') {
    Write-Host "`n== Data protection (Windows)" -ForegroundColor Cyan
    $custScript = Join-Path $repo 'infra/scripts/Customize-SessionHost.ps1'
    $dpCfg = Get-Content -Raw (Join-Path $repo 'infra/customizations/customizations.json') | ConvertFrom-Json
    $dpCfg.dataProtection.tenantId = '11111111-2222-3333-4444-555555555555'
    $dpCfg.dataProtection.edgeSigninPattern = '.*@contoso\.com'
    $b64dp = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($dpCfg | ConvertTo-Json -Depth 10)))
    $dpOut = (& $custScript -ConfigBase64 $b64dp -DryRun 'True' | Out-String)
    Assert-Equal ($dpOut -match 'Policies\\System\\NoConnectedUser = 3') $true 'dlp: Microsoft accounts blocked on Windows'
    Assert-Equal ($dpOut -match 'OneDrive\\AllowTenantList\\11111111-2222-3333-4444-555555555555 = 11111111-2222-3333-4444-555555555555') $true 'dlp: OneDrive syncs only this tenant'
    Assert-Equal ($dpOut -match 'default user profile: SOFTWARE\\Policies\\Microsoft\\OneDrive\\DisablePersonalSync = 1') $true 'dlp: personal OneDrive sync blocked for new profiles'
    Assert-Equal ($dpOut -match 'Edge\\URLBlocklist\\1 = onedrive\.live\.com') $true 'dlp: consumer OneDrive web blocked in Edge'
    Assert-Equal ($dpOut -match 'Edge\\RestrictSigninToPattern = \.\*@contoso') $true 'dlp: Edge sign-in restricted'
    Assert-Equal ($dpOut -match 'Tenant restrictions') $false 'dlp: tenant restrictions off by default'

    # NoConnectedUser = 3 means "Users can't add or log on with Microsoft accounts" (sceregvl.inf)
    $inf = Join-Path $env:WINDIR 'inf\sceregvl.inf'
    if (Test-Path $inf) {
        $infText = Get-Content -Raw $inf
        $line = ($infText -split "`r?`n") | Where-Object { $_ -match 'Policies\\System\\NoConnectedUser,' } | Select-Object -First 1
        $tok = if ("$line" -match '\|3\|%([^%]+)%') { $Matches[1] } elseif ("$line" -match ',3\|%([^%]+)%') { $Matches[1] } else { $null }
        $meaning = if ($tok -and ($infText -match "(?m)^\s*$([regex]::Escape($tok))\s*=\s*""?([^""\r\n]+)")) { $Matches[1] } else { "(not found: $line)" }
        if ($meaning -like '@*') {
            # Newer builds store a resource reference (e.g. @wsecedit.dll,-59153) - resolve it with Windows' own API.
            if (-not ('AvdTest.Indirect' -as [type])) {
                Add-Type -Namespace AvdTest -Name Indirect -MemberDefinition '[DllImport("shlwapi.dll", CharSet = CharSet.Unicode)] public static extern int SHLoadIndirectString(string src, System.Text.StringBuilder buf, int size, System.IntPtr reserved);'
            }
            $sb = New-Object System.Text.StringBuilder 1024
            if ([AvdTest.Indirect]::SHLoadIndirectString($meaning, $sb, $sb.Capacity, [IntPtr]::Zero) -eq 0) { $meaning = $sb.ToString() }
        }
        Assert-Equal ($meaning -match "can.t add or log on with Microsoft accounts") $true "dlp: NoConnectedUser=3 means '$meaning'"
    }

    # Tenant Restrictions v2: reader picks fields by their documented labels
    $pd = Join-Path ([IO.Path]::GetTempPath()) ('pd-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path (Join-Path $pd 'en-US') -Force
    Set-Content -Path (Join-Path $pd 'TenantRestrictions.admx') -Value @'
<?xml version="1.0" encoding="utf-8"?>
<policyDefinitions xmlns="http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions" revision="1.0" schemaVersion="1.0">
  <policies>
    <policy name="TrV2" class="Machine" displayName="$(string.TrV2)" key="SOFTWARE\Policies\Microsoft\Windows\TenantRestrictions\Payload" presentation="$(presentation.TrV2)">
      <elements>
        <text id="Elem1" valueName="Cloud" />
        <text id="Elem2" valueName="TenantId" />
        <text id="Elem3" valueName="PolicyId" />
        <boolean id="Elem4" valueName="EnforceFw"><trueValue><decimal value="1" /></trueValue><falseValue><decimal value="0" /></falseValue></boolean>
      </elements>
    </policy>
  </policies>
</policyDefinitions>
'@
    Set-Content -Path (Join-Path $pd 'en-US\TenantRestrictions.adml') -Value @'
<?xml version="1.0" encoding="utf-8"?>
<policyDefinitionResources xmlns="http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions" revision="1.0" schemaVersion="1.0">
  <resources>
    <stringTable><string id="TrV2">Cloud Policy Details</string></stringTable>
    <presentationTable>
      <presentation id="TrV2">
        <textBox refId="Elem1"><label>Microsoft Entra cloud</label></textBox>
        <textBox refId="Elem2"><label>Microsoft Entra Directory ID</label></textBox>
        <textBox refId="Elem3"><label>Policy GUID</label></textBox>
        <checkBox refId="Elem4">Enable firewall protection of Microsoft endpoints</checkBox>
      </presentation>
    </presentationTable>
  </resources>
</policyDefinitionResources>
'@
    $trCfg = '{"dataProtection":{"tenantId":"11111111-2222-3333-4444-555555555555","tenantRestrictions":{"enabled":true,"policyId":"99999999-8888-7777-6666-555555555555","firewallProtection":true}}}'
    $trOut = (& $custScript -ConfigBase64 ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($trCfg))) -DryRun 'True' -PolicyDefinitionsPath $pd | Out-String)
    Microsoft.PowerShell.Utility\Write-Host $trOut
    Assert-Equal ($trOut -match 'TenantRestrictions\\Payload\\TenantId = 11111111-2222-3333-4444-555555555555') $true 'dlp TRv2: tenant ID written to the Directory ID field'
    Assert-Equal ($trOut -match 'TenantRestrictions\\Payload\\PolicyId = 99999999-8888-7777-6666-555555555555') $true 'dlp TRv2: policy ID written to the Policy GUID field'
    Assert-Equal ($trOut -match 'TenantRestrictions\\Payload\\EnforceFw = 1') $true 'dlp TRv2: firewall protection checkbox'
    Assert-Equal ($trOut -match 'Payload\\Cloud =') $false 'dlp TRv2: unrelated fields left alone'
    # labels missing -> refuses to guess
    Set-Content -Path (Join-Path $pd 'en-US\TenantRestrictions.adml') -Value '<?xml version="1.0"?><policyDefinitionResources xmlns="http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions"><resources><presentationTable/></resources></policyDefinitionResources>'
    $trBad = (& $custScript -ConfigBase64 ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($trCfg))) -DryRun 'True' -PolicyDefinitionsPath $pd | Out-String)
    Assert-Equal ($trBad -match "couldn't identify the Directory ID / Policy GUID fields") $true 'dlp TRv2: refuses to guess when fields are ambiguous'
    Remove-Item $pd -Recurse -Force -ErrorAction SilentlyContinue
}

# Data protection host report: real run on Windows (nothing configured -> each gap flagged)
if ($env:OS -eq 'Windows_NT') {
    Write-Host "`n== Test-DataProtectionHost.ps1 (Windows, unconfigured machine)" -ForegroundColor Cyan
    $dpReport = (& (Join-Path $repo 'infra/scripts/Test-DataProtectionHost.ps1') 2>&1 | Out-String)
    Microsoft.PowerShell.Utility\Write-Host $dpReport
    Assert-Equal ($dpReport -match '\[FAIL\] No customisation log') $true 'dp report: missing customisation flagged'
    Assert-Equal ($dpReport -match '\[FAIL\] OneDrive AllowTenantList NOT set') $true 'dp report: missing OneDrive tenant restriction flagged'
    Assert-Equal ($dpReport -match '\[FAIL\] Tenant restrictions v2 NOT configured') $true 'dp report: missing tenant restrictions flagged'
}

# Device redirection policy: every registry value the script writes is checked against
# Windows' own TerminalServer.admx on this machine - policy name and resulting state.
if ($env:OS -eq 'Windows_NT') {
    Write-Host "`n== Device redirection policy vs TerminalServer.admx (Windows)" -ForegroundColor Cyan
    $admxPath = Join-Path $env:WINDIR 'PolicyDefinitions\TerminalServer.admx'
    $admlPath = Join-Path $env:WINDIR 'PolicyDefinitions\en-US\TerminalServer.adml'
    if (-not ((Test-Path $admxPath) -and (Test-Path $admlPath))) { $failures.Add('TerminalServer.admx/adml not found on the runner') }
    else {
        [xml]$admx = Get-Content -Raw $admxPath
        [xml]$adml = Get-Content -Raw $admlPath
        $strings = @{}
        foreach ($st in $adml.policyDefinitionResources.resources.stringTable.string) { $strings[$st.id] = $st.'#text' }
        $redCfg = Get-Content -Raw (Join-Path $repo 'infra/customizations/customizations.json')
        $b64r = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($redCfg))
        $rOut = (& (Join-Path $repo 'infra/scripts/Customize-SessionHost.ps1') -ConfigBase64 $b64r -DryRun 'True' | Out-String)
        $written = @{}
        foreach ($m in [regex]::Matches($rOut, 'Terminal Services\\(\w+) = (\d+)')) { $written[$m.Groups[1].Value] = [int]$m.Groups[2].Value }
        # value name -> expected policy (as named in the Microsoft Learn redirection pages) and state
        $expected = [ordered]@{
            fDisableCdm          = @('Do not allow drive redirection', 'Enabled')
            fDisableCpm          = @('Do not allow client printer redirection', 'Enabled')
            fDisableCcm          = @('Do not allow COM port redirection', 'Enabled')
            fDisableLPT          = @('Do not allow LPT port redirection', 'Enabled')
            fDisablePNPRedir     = @('Do not allow supported Plug and Play device redirection', 'Enabled')
            fEnableSmartCard     = @('Do not allow smart card device redirection', 'Enabled')
            fDisableCameraRedir  = @('Do not allow video capture redirection', 'Enabled')
            fDisableClip         = @('Do not allow Clipboard redirection', 'Disabled')
            fDisableCam          = @('Allow audio and video playback redirection', 'Enabled')
            fDisableAudioCapture = @('Allow audio recording redirection', 'Enabled')
        }
        foreach ($vn in $expected.Keys) {
            if (-not $written.ContainsKey($vn)) { $failures.Add("redirection: $vn not written"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $vn not written" -ForegroundColor Red; continue }
            $pol = @($admx.policyDefinitions.policies.policy | Where-Object { $_.valueName -eq $vn -and $_.key -eq 'SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' }) | Select-Object -First 1
            if (-not $pol) { $failures.Add("redirection: $vn is not a value in TerminalServer.admx"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $vn not in ADMX" -ForegroundColor Red; continue }
            $enabledVal = if ($pol.enabledValue -and $pol.enabledValue.decimal) { [int]$pol.enabledValue.decimal.value } else { 1 }
            $disabledVal = if ($pol.disabledValue -and $pol.disabledValue.decimal) { [int]$pol.disabledValue.decimal.value } else { 0 }
            $state = if ($written[$vn] -eq $enabledVal) { 'Enabled' } elseif ($written[$vn] -eq $disabledVal) { 'Disabled' } else { "unknown($($written[$vn]))" }
            $name = $strings[($pol.displayName -replace '^\$\(string\.(.+)\)$', '$1')]
            Assert-Equal "$name = $state" "$($expected[$vn][0]) = $($expected[$vn][1])" "redirection: $vn"
        }
    }
}

# Defender and OneDrive policy: every value the script writes is checked against Windows' own
# policy definitions on this machine (key + value name, and an allowed value for enums).
if ($env:OS -eq 'Windows_NT') {
    Write-Host "`n== Defender / OneDrive policy vs Windows ADMX (Windows)" -ForegroundColor Cyan
    function Find-AdmxValue([xml] $Admx, [string] $Key, [string] $ValueName) {
        foreach ($node in $Admx.SelectNodes('//*[@valueName]')) {
            if ($node.GetAttribute('valueName') -ne $ValueName) { continue }
            $k = $node.GetAttribute('key'); $n = $node
            while (-not $k -and $n.ParentNode -is [System.Xml.XmlElement]) { $n = $n.ParentNode; $k = $n.GetAttribute('key') }
            if ($k -eq $Key) { return $node }
        }
        return $null
    }
    $cfgText = Get-Content -Raw (Join-Path $repo 'infra/customizations/customizations.json')
    $dOut = (& (Join-Path $repo 'infra/scripts/Customize-SessionHost.ps1') -ConfigBase64 ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cfgText))) -DryRun 'True' | Out-String)
    $checks = @(
        @('WindowsDefender.admx', 'SOFTWARE\\Policies\\Microsoft\\Windows Defender[^=\r\n]*'),
        @('SkyDrive.admx', 'SOFTWARE\\Policies\\Microsoft\\Windows\\OneDrive')
    )
    foreach ($c in $checks) {
        $admxFile = Join-Path $env:WINDIR "PolicyDefinitions\$($c[0])"
        $found = [regex]::Matches($dOut, '\[dry-run\] HKLM:\\(' + $c[1] + ')\\(\w+) = (\d+)')
        if (-not (Test-Path $admxFile)) {
            if ($c[0] -eq 'WindowsDefender.admx') { $failures.Add('WindowsDefender.admx not found on the runner') }
            else { Microsoft.PowerShell.Utility\Write-Host "  skip $($c[0]) not on this Windows edition" -ForegroundColor DarkGray }
            continue
        }
        [xml]$ax = Get-Content -Raw $admxFile
        if (-not $found.Count) { $failures.Add("no values written for $($c[0])") }
        foreach ($m in $found) {
            $key = $m.Groups[1].Value; $vn = $m.Groups[2].Value; $val = [int]$m.Groups[3].Value
            $node = Find-AdmxValue $ax $key $vn
            $ok = [bool]$node
            if ($ok -and $node.LocalName -eq 'enum') { $ok = @($node.SelectNodes('*[local-name()="item"]/*[local-name()="value"]/*[local-name()="decimal"]') | ForEach-Object { [int]$_.GetAttribute('value') }) -contains $val }
            Assert-Equal $ok $true "policy: $key\$vn = $val defined in $($c[0])"
        }
    }
}

# Developer-apps example: dry run of the shipped example file on Windows
if ($env:OS -eq 'Windows_NT') {
    Write-Host "`n== Customize-SessionHost.ps1 developer-apps example (Windows, dry run)" -ForegroundColor Cyan
    $exJson = Get-Content -Raw (Join-Path $repo 'infra/customizations/examples/developer-apps.json')
    $b64ex = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($exJson))
    try {
        $exOut = (& (Join-Path $repo 'infra/scripts/Customize-SessionHost.ps1') -ConfigBase64 $b64ex -DryRun 'True' | Out-String)
        Microsoft.PowerShell.Utility\Write-Host $exOut
        Assert-Equal ($exOut -match "App 'Visual Studio Code': \[dry-run\] download \S+ as VSCodeSetup-x64\.exe") $true 'dev apps: VS Code fileName override used'
        Assert-Equal ($exOut -match 'VSCode\\UpdateMode = none') $true 'dev apps: VS Code update policy planned'
        Assert-Equal ($exOut -match "write \S*avdapp-IntelliJIDEACommunity\\silent\.config") $true 'dev apps: JetBrains silent.config written next to installer'
        Assert-Equal ($exOut -match '/CONFIG=\S*avdapp-IntelliJIDEACommunity\\silent\.config') $true 'dev apps: {dir} replaced in arguments'
        Assert-Equal ($exOut -match '\{dir\}') $false 'dev apps: no unreplaced {dir}'
        # The Windows runner already has Git at the example's detectPath, so it may be skipped.
        Assert-Equal ($exOut -match "App 'Git': (\[dry-run\]|already installed)") $true 'dev apps: Git planned (or skipped via detectPath)'
    }
    catch { $failures.Add("Developer apps dry run threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

    # URL with no file name and no fileName -> refused, counted as a failure
    $bad = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"apps":[{"name":"NoName","url":"https://example.invalid/download?id=1"}]}'))
    $badOut = (& (Join-Path $repo 'infra/scripts/Customize-SessionHost.ps1') -ConfigBase64 $bad -DryRun 'True' | Out-String)
    Assert-Equal ($badOut -match "can't tell the installer type") $true 'dev apps: URL without a file name needs fileName'
}

# Add-CustomizationApp: hash computed from the download; -Replace keeps files/registry
Write-Host "`n== Add-CustomizationApp.ps1 (download mocked)" -ForegroundColor Cyan
function global:Invoke-WebRequest {
    param($Uri, $OutFile, [switch] $UseBasicParsing)
    [IO.File]::WriteAllText($OutFile, "fake installer from $Uri")
}
$addScript = Join-Path $repo 'scripts/Add-CustomizationApp.ps1'
$tmpCfg = Join-Path ([IO.Path]::GetTempPath()) ('cust-' + [guid]::NewGuid().ToString('N') + '.json')
Copy-Item (Join-Path $repo 'infra/customizations/customizations.json') $tmpCfg
function Get-ExpectedHash([string] $u) {
    $f = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($f, "fake installer from $u")
    $h = (Get-FileHash $f -Algorithm SHA256).Hash; Remove-Item $f; return $h
}
try {
    $u1 = 'https://update.code.visualstudio.com/1.95.3/win32-x64/stable'
    & $addScript -Name 'Visual Studio Code' -Url $u1 -FileName 'VSCodeSetup-x64.exe' -Arguments '/VERYSILENT' -DetectPath 'C:\Program Files\Microsoft VS Code\Code.exe' -ConfigPath $tmpCfg
    $c1 = Get-Content -Raw $tmpCfg | ConvertFrom-Json
    $vs = @($c1.apps | Where-Object { $_.name -eq 'Visual Studio Code' })
    Assert-Equal $vs.Count 1 'add app: entry added'
    Assert-Equal $vs[0].sha256 (Get-ExpectedHash $u1) 'add app: SHA-256 of the downloaded file recorded'
    Assert-Equal $vs[0].fileName 'VSCodeSetup-x64.exe' 'add app: fileName kept for extension-less URL'
    Assert-Equal (@($c1.optimize.removeAppxPackages).Count -gt 5) $true 'add app: rest of the config preserved'

    # hand-add a registry setting, then bump the version with -Replace
    $c1.apps[0] | Add-Member -NotePropertyName registry -NotePropertyValue @([pscustomobject]@{ path = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'; name = 'UpdateMode'; value = 'none'; type = 'String' })
    [IO.File]::WriteAllText($tmpCfg, ($c1 | ConvertTo-Json -Depth 10))
    $u2 = 'https://update.code.visualstudio.com/1.96.0/win32-x64/stable'
    & $addScript -Name 'Visual Studio Code' -Url $u2 -Replace -ConfigPath $tmpCfg
    $c2 = Get-Content -Raw $tmpCfg | ConvertFrom-Json
    $vs2 = @($c2.apps | Where-Object { $_.name -eq 'Visual Studio Code' })
    Assert-Equal $vs2.Count 1 'add app -Replace: still one entry'
    Assert-Equal $vs2[0].url $u2 'add app -Replace: new URL'
    Assert-Equal $vs2[0].sha256 (Get-ExpectedHash $u2) 'add app -Replace: new hash'
    Assert-Equal "$(@($vs2[0].registry)[0].value)" 'none' 'add app -Replace: registry settings kept'
    Assert-Equal $vs2[0].arguments '/VERYSILENT' 'add app -Replace: arguments kept'

    $threw = $null
    try { & $addScript -Name 'Visual Studio Code' -Url $u2 -ConfigPath $tmpCfg } catch { $threw = "$_" }
    Assert-Equal ($threw -match 'already exists') $true 'add app: duplicate needs -Replace'
}
catch { $failures.Add("Add-CustomizationApp threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
finally { Remove-Item $tmpCfg -ErrorAction SilentlyContinue; Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue }

# ------------------------------------------------------------------- Pool maintenance runbook (REST mocked)
Write-Host "`n== Invoke-AvdPoolMaintenance.ps1 (REST mocked)" -ForegroundColor Cyan
$runbook = Join-Path $repo 'infra/automation/Invoke-AvdPoolMaintenance.ps1'
$pool = '/subscriptions/sub/resourceGroups/rg-svc/providers/Microsoft.DesktopVirtualization/hostPools/pool'
$vmBase = '/subscriptions/sub/resourceGroups/rg-hosts/providers/Microsoft.Compute/virtualMachines'
$cfgFile = Join-Path ([IO.Path]::GetTempPath()) ('aacfg-' + [guid]::NewGuid().ToString('N') + '.json')
[IO.File]::WriteAllText($cfgFile, (@{
    subscriptionId = 'sub'; hostPoolId = $pool; hostsResourceGroup = 'rg-hosts'; sessionHostPrefix = 'avdpd'
    spareTarget = 5; unusedDays = 90; maxAddPerRun = 10; maxDeletePerRun = 5; mode = 'Report'
    workspaceResourceId = '/subscriptions/sub/resourceGroups/rg-mon/providers/Microsoft.OperationalInsights/workspaces/law'
    zones = @('1', '2', '3'); templateSpecVersionId = 'ts-id'
    sessionHostParameters = @{ vmSize = 'Standard_D4s_v5'; location = 'uksouth' }
} | ConvertTo-Json -Depth 10))
$shJson = '{"value":[' +
    '{"name":"pool/avdpd-001","properties":{"assignedUser":"alice@contoso.com","sessions":0}},' +
    '{"name":"pool/avdpd-002","properties":{"assignedUser":"bob@contoso.com","sessions":0}},' +
    '{"name":"pool/avdpd-003","properties":{"assignedUser":null,"sessions":0}},' +
    '{"name":"pool/avdpd-004","properties":{"assignedUser":"carol@contoso.com","sessions":1}},' +
    '{"name":"pool/avdpd-005","properties":{"assignedUser":null,"sessions":0}},' +
    '{"name":"pool/avdpd-007","properties":{"assignedUser":"dave@contoso.com","sessions":0}}]}'
$vmJson = '{"value":[' +
    '{"name":"avdpd-001","id":"' + $vmBase + '/avdpd-001","tags":{"avd-last-used":"2026-11-01"},"properties":{"timeCreated":"2026-01-01T00:00:00Z"}},' +
    '{"name":"avdpd-002","id":"' + $vmBase + '/avdpd-002","tags":{"avd-last-used":"2026-07-01"},"properties":{"timeCreated":"2026-01-01T00:00:00Z"}},' +
    '{"name":"avdpd-003","id":"' + $vmBase + '/avdpd-003","properties":{"timeCreated":"2026-01-01T00:00:00Z"}},' +
    '{"name":"avdpd-004","id":"' + $vmBase + '/avdpd-004","tags":{"avd-last-used":"2026-06-01"},"properties":{"timeCreated":"2026-01-01T00:00:00Z"}},' +
    '{"name":"avdpd-005","id":"' + $vmBase + '/avdpd-005","properties":{"timeCreated":"2026-11-19T00:00:00Z"}},' +
    '{"name":"avdpd-006","id":"' + $vmBase + '/avdpd-006","properties":{"timeCreated":"2026-11-20T10:00:00Z"}},' +
    '{"name":"avdpd-007","id":"' + $vmBase + '/avdpd-007","tags":{"avd-last-used":"2026-01-01","avd-keep":"true"},"properties":{"timeCreated":"2026-01-01T00:00:00Z"}},' +
    '{"name":"jumpbox-01","id":"' + $vmBase + '/jumpbox-01","properties":{"timeCreated":"2020-01-01T00:00:00Z"}}]}'
$global:RestCalls = [System.Collections.Generic.List[object]]::new()
function global:Invoke-RestMethod {
    param($Method = 'GET', $Uri, $Headers, $Body, $ContentType)
    $global:RestCalls.Add([pscustomobject]@{ Method = "$Method".ToUpper(); Uri = "$Uri"; Body = $Body })
    if ($Method -eq 'GET' -and $Uri -like '*/sessionHosts?*') { return ($shJson | ConvertFrom-Json) }
    if ($Method -eq 'GET' -and $Uri -like '*/virtualMachines?*') { return ($vmJson | ConvertFrom-Json) }
    if ($Method -eq 'GET' -and $Uri -like '*/workspaces/law?*') { return ('{"properties":{"customerId":"cid"}}' | ConvertFrom-Json) }
    if ($Uri -like 'https://api.loganalytics.io/*') { return ('{"tables":[{"rows":[["avdpd-001","2026-11-19T09:00:00Z"]]}]}' | ConvertFrom-Json) }
    return $null
}
$global:AzResponses = [ordered]@{ 'account get-access-token*' = 'tok' }
try {
    $global:RestCalls.Clear()
    $rep = (& $runbook -ConfigPath $cfgFile -NowUtc '2026-11-20T12:00:00Z' | Out-String)
    Microsoft.PowerShell.Utility\Write-Host $rep
    Assert-Equal ($rep -match '6 in pool \(4 assigned, 2 free\), 1 build\(s\) in progress') $true 'pool: inventory (jumpbox ignored, avdpd-006 building)'
    Assert-Equal ($rep -match 'would delete avdpd-002 - assigned to bob@contoso\.com, last used 2026-07-01') $true 'pool: long-unused assigned desktop deleted'
    Assert-Equal ($rep -match 'would delete avdpd-003') $false 'pool: unused spare kept (needed for the spare target)'
    Assert-Equal ($rep -match 'would delete avdpd-007') $false 'pool: avd-keep tag respected'
    Assert-Equal ($rep -match '1 kept by avd-keep tag') $true 'pool: kept desktops reported'
    Assert-Equal ($rep -match 'would delete avdpd-004') $false 'pool: desktop with an active session never deleted'
    Assert-Equal ($rep -match 'would deploy: avdpd-008, avdpd-009') $true 'pool: tops up spares after the highest number'
    $tagged = @($global:RestCalls | Where-Object { $_.Method -eq 'PATCH' -and $_.Uri -like '*/tags/default*' })
    Assert-Equal (@($tagged | ForEach-Object { ($_.Uri -split '/virtualMachines/')[1].Split('/')[0] }) -join ',') 'avdpd-001,avdpd-004' 'pool: last-used tags stamped from connections and active sessions'
    Assert-Equal @($global:RestCalls | Where-Object { $_.Method -in @('DELETE', 'PUT') }).Count 0 'pool: Report mode deletes and deploys nothing'

    $global:RestCalls.Clear()
    $env:AVD_LOCAL_ADMIN_PASSWORD = 'Auto-Passw0rd!x'
    $app = (& $runbook -ConfigPath $cfgFile -Mode Apply -NowUtc '2026-11-20T12:00:00Z' | Out-String)
    $dels = @($global:RestCalls | Where-Object { $_.Method -eq 'DELETE' } | ForEach-Object { $_.Uri })
    Assert-Equal ($dels.Count -eq 2 -and $dels[0] -like "*$($pool)/sessionHosts/avdpd-002``?*force=true" -and $dels[1] -like "*$($vmBase)/avdpd-002``?*") $true 'pool apply: session host then VM deleted'
    Assert-Equal (@($global:RestCalls | Where-Object { $_.Method -eq 'PATCH' -and $_.Uri -like "*$($pool)``?api-version*" -and "$($_.Body)" -match 'registrationTokenOperation' }).Count) 1 'pool apply: registration token refreshed'
    $deps = @($global:RestCalls | Where-Object { $_.Method -eq 'PUT' -and $_.Uri -like '*/deployments/avd-auto-*' })
    Assert-Equal $deps.Count 2 'pool apply: two desktops deployed'
    Assert-Equal ("$($deps[0].Body)" -match '"vmName":\{"value":"avdpd-008"\}' -and "$($deps[0].Body)" -match '"zone":\{"value":"2"\}' -and "$($deps[0].Body)" -match '"id":"ts-id"' -and "$($deps[0].Body)" -match '"adminPassword":\{"value":"Auto-Passw0rd!x"\}') $true 'pool apply: deployment uses the template spec, name, zone and password'
}
catch { $failures.Add("Pool maintenance runbook threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
finally { Remove-Item $cfgFile -ErrorAction SilentlyContinue; Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue; $global:AzResponses = $null }

# ------------------------------------------------------------------- Publish-AvdPoolAutomation (az mocked)
Write-Host "`n== Publish-AvdPoolAutomation.ps1 (az mocked)" -ForegroundColor Cyan
$pubParams = Join-Path $repo 'infra/params/cipub.bicepparam'
$pubOutputs = Join-Path $repo 'infra/params/cipub.outputs.json'
[IO.File]::WriteAllText($pubParams, "// subscriptionId: 00000000-0000-0000-0000-000000000000`nusing '../main.bicep'`n")
[IO.File]::WriteAllText($pubOutputs, (@{
    automationAccountName = @{ value = 'aa-avd' }; automationResourceGroup = @{ value = 'rg-svc' }
    automationConfig = @{ value = @{ subscriptionId = '00000000-0000-0000-0000-000000000000'; mode = 'Report'; sessionHostPrefix = 'avdpd'; sessionHostParameters = @{ vmSize = 'Standard_D4s_v5' } } }
} | ConvertTo-Json -Depth 10))
$global:BodyLog = [System.Collections.Generic.List[object]]::new()
$global:AzResponses = [ordered]@{
    'resource show --ids*' = 'uksouth'
    'ts create*' = '{}'
    'ts show*' = 'ts-version-id'
    'rest --method get --url *runbooks/AvdPoolMaintenance?*' = 'Published'
    'rest --method get --url *schedules/AvdPoolMaintenance-daily?*' = 1
    'rest --method get --url *jobSchedules?*' = '0'
    'rest --method *' = '{}'
}
$global:AzCalls.Clear()
try {
    & (Join-Path $repo 'scripts/Publish-AvdPoolAutomation.ps1') -ParameterFile $pubParams
    $calls = $global:AzCalls -join "`n"
    Assert-Equal ($calls -match 'ts create --name avd-sessionhost --version 1\.0 --resource-group rg-svc --location uksouth --template-file \S+sessionhost\.bicep') $true 'publish: session host template spec'
    $rb = @($global:BodyLog | Where-Object { $_.Url -match '/runbooks/AvdPoolMaintenance\?api-version' })   # -like '?' would also match '/draft'
    Assert-Equal ($rb.Count -eq 1 -and $rb[0].Body -match '"runbookType":\s*"PowerShell"') $true 'publish: runbook created (PowerShell 5.1 runtime)'
    $content = @($global:BodyLog | Where-Object { $_.Url -like '*/draft/content?*' })
    Assert-Equal ($content.Count -eq 1 -and $content[0].Line -match 'Content-Type=text/powershell' -and $content[0].Body -match 'AVD pool maintenance') $true 'publish: runbook content uploaded'
    Assert-Equal ($calls -match 'rest --method POST --url \S+/runbooks/AvdPoolMaintenance/publish') $true 'publish: runbook published'
    $cfgVar = @($global:BodyLog | Where-Object { $_.Url -like '*/variables/AvdPoolAutomationConfig?*' })
    Assert-Equal ($cfgVar.Count -eq 1 -and $cfgVar[0].Body -match 'ts-version-id' -and $cfgVar[0].Body -match '"isEncrypted":\s*false') $true 'publish: config variable includes the template spec ID'
    $pwVar = @($global:BodyLog | Where-Object { $_.Url -like '*/variables/AvdLocalAdminPassword?*' })
    Assert-Equal ($pwVar.Count -eq 1 -and $pwVar[0].Body -match '"isEncrypted":\s*true') $true 'publish: password variable encrypted'
    Assert-Equal (@($global:BodyLog | Where-Object { $_.Url -like '*/schedules/AvdPoolMaintenance-daily?*' -and $_.Body -match '"frequency":\s*"Day"' }).Count) 1 'publish: daily schedule created'
    Assert-Equal (@($global:BodyLog | Where-Object { $_.Url -like '*/jobSchedules/*' -and $_.Body -match 'AvdPoolMaintenance' }).Count) 1 'publish: schedule linked to runbook'
    $localCfg = Join-Path $repo 'infra/params/cipub.automation.json'
    Assert-Equal ((Test-Path $localCfg) -and ((Get-Content -Raw $localCfg) -match 'ts-version-id')) $true 'publish: local preview config written'
}
catch { $failures.Add("Publish-AvdPoolAutomation threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
finally {
    Remove-Item $pubParams, $pubOutputs, (Join-Path $repo 'infra/params/cipub.automation.json') -ErrorAction SilentlyContinue
    $global:AzResponses = $null; $global:BodyLog = $null
}

Remove-Item Function:\az -ErrorAction SilentlyContinue

# --- Scenario C: personal (1:1) desktops, direct assignment ------------------------
$p = Invoke-Scenario 'personal 1:1 desktops' 'cipd' @(
    , @('tenant ID', $tenant)
    , @('Workload subscription', $sub)
    , @('Session host virtual network', 'new')
    , @('Azure region', 'uksouth')
    , @('Environment name', 'cipd')
    , @('Desktop type', 'Personal')
    , @('Number of users', '50')
    , @('Desktop assignment', 'Direct')
    , @('Include Microsoft 365 Apps', 'n')
    , @('Defender for Servers plan', 'P1')
    , @('Log Analytics workspace:', 'new')
    , @('already exist', 'n')
    , @('AVD users group', '11111111-1111-1111-1111-111111111111')
)
if ($p) {
    Assert-Equal $p.hostPoolType.value 'Personal' 'C host pool type'
    Assert-Equal $p.personalAssignmentType.value 'Direct' 'C assignment type'
    Assert-Equal $p.targetUserCount.value 50 'C users'
    Assert-Equal $p.sessionHostNamePrefix.value 'avdpd' 'C personal name prefix default'
    Assert-Equal $p.vmSize.value 'Standard_D4s_v5' 'C personal VM size default'
    Assert-Equal $p.deployFslogixStorage.value $false 'C FSLogix off by default for personal'
    Assert-Equal $p.sessionHostCountOverride.value -1 'C all 50 desktops in first run'
    Assert-Equal "$($p.imageReference.value.offer)/$($p.imageReference.value.sku)" 'windows-11/win11-24h2-avd' 'C plain Windows image (no Microsoft 365 Apps)'
    Assert-Equal $p.defenderForServersPlan.value 'P1' 'C Defender for Servers P1'
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
exit 0   # scripts under test may legitimately leave a non-zero LASTEXITCODE
