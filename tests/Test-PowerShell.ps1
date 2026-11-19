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

# ------------------------------------------------------------------- 4. Deploy-Avd.ps1 with a fake az
# A global function named az shadows the real CLI, records each call and returns canned output.
Write-Host "`n== Deploy-Avd.ps1 (az mocked)" -ForegroundColor Cyan
$global:AzCalls = [System.Collections.Generic.List[string]]::new()
$global:PasswordSeenByAz = $null
$global:DeployParamText = $null
$global:MockVmNames = '[]'
$global:MockVmPower = '[]'
$global:MockGraph = $false
$global:MockDnsLinks = '[]'
$global:MockZoneList = '[]'
$global:MockZoneLinks = '[]'
function global:az {
    $line = ($args | ForEach-Object { "$_" }) -join ' '
    $global:AzCalls.Add($line)
    $global:LASTEXITCODE = 0
    if ($line -like 'deployment sub*') {
        $global:PasswordSeenByAz = $env:AVD_LOCAL_ADMIN_PASSWORD
        $i = [array]::IndexOf([string[]]$args, '--parameters')
        if ($i -ge 0) { $global:DeployParamText = Get-Content -Raw -LiteralPath $args[$i + 1] }
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
        'deployment sub create*'  { return '{"hostPoolName":{"type":"String","value":"vdpool-avd-prod-uksouth"},"resourceGroupsCreated":{"type":"Array","value":["rg-a","rg-b"]}}' }
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
    Assert-Equal ($calls -match 'deployment sub what-if --name avd-\d+ --location uksouth --template-file \S+main\.bicep --parameters \S+main\.bicepparam') $true 'deploy: what-if command'
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
}
catch { $failures.Add("Deploy-Avd create threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
# -AddHosts: existing hosts 001, 002, 020 (plus an unrelated VM) -> new hosts start at 021
$global:MockVmNames = '["avdsh-001","avdsh-002","avdsh-020","jumpbox-01"]'
$global:AzCalls.Clear(); $global:DeployParamText = $null
try {
    & $deployScript -ParameterFile $exampleParams -AddHosts 5 -WhatIf
    Assert-Equal ($global:DeployParamText -match '(?m)^param sessionHostStartIndex = 20\s*$') $true 'deploy -AddHosts: start index after highest existing host'
    Assert-Equal ($global:DeployParamText -match '(?m)^param sessionHostCountOverride = 5\s*$') $true 'deploy -AddHosts: host count'
    Assert-Equal (($global:AzCalls -join "`n") -match 'main\.deploy-tmp\.bicepparam') $true 'deploy -AddHosts: uses temporary param file'
    Assert-Equal (Test-Path (Join-Path $repo 'infra/main.deploy-tmp.bicepparam')) $false 'deploy -AddHosts: temporary param file removed'
}
catch { $failures.Add("Deploy-Avd -AddHosts threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

# -InfraOnly -> zero hosts
$global:AzCalls.Clear(); $global:DeployParamText = $null
try {
    & $deployScript -ParameterFile $exampleParams -InfraOnly -WhatIf
    Assert-Equal ($global:DeployParamText -match '(?m)^param sessionHostCountOverride = 0\s*$') $true 'deploy -InfraOnly: no session hosts'
}
catch { $failures.Add("Deploy-Avd -InfraOnly threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }

# Plain run over existing hosts -> overlap warning; with -Force it proceeds and saves outputs
$global:HostBuffer.Clear()
$outputsPath = Join-Path $repo 'infra/main.outputs.json'
Remove-Item $outputsPath -ErrorAction SilentlyContinue
try {
    & $deployScript -ParameterFile $exampleParams -Force -DeploymentName 'avd-ci2'
    Assert-Equal ((($global:HostBuffer) -join "`n") -match 'would redeploy 3 host\(s\) that already exist') $true 'deploy: warns before redeploying existing hosts'
    Assert-Equal (Test-Path $outputsPath) $true 'deploy: outputs saved next to param file'
}
catch { $failures.Add("Deploy-Avd overlap run threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
Remove-Item $outputsPath -ErrorAction SilentlyContinue

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

Remove-Item Function:\az -ErrorAction SilentlyContinue

Remove-Item (Join-Path $paramsDir 'ci*') -ErrorAction SilentlyContinue

# ------------------------------------------------------------------- Result
Microsoft.PowerShell.Utility\Write-Host ''
if ($failures.Count) {
    Microsoft.PowerShell.Utility\Write-Host "$($failures.Count) failure(s):" -ForegroundColor Red
    $failures | ForEach-Object { Microsoft.PowerShell.Utility\Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Microsoft.PowerShell.Utility\Write-Host 'All PowerShell tests passed.' -ForegroundColor Green
