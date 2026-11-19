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
function global:az {
    $line = ($args | ForEach-Object { "$_" }) -join ' '
    $global:AzCalls.Add($line)
    $global:LASTEXITCODE = 0
    if ($line -like 'deployment sub*') {
        $global:PasswordSeenByAz = $env:AVD_LOCAL_ADMIN_PASSWORD
        $i = [array]::IndexOf([string[]]$args, '--parameters')
        if ($i -ge 0) { $global:DeployParamText = Get-Content -Raw -LiteralPath $args[$i + 1] }
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
        '[10:00:00.001][tid:00000a1c.00000b2d][INFO]           Starting LoadProfile'
        '[10:00:01.002][tid:00000a1c.00000b2d][ERROR:0000052E] Failed to open virtual disk (The user name or password is incorrect.)'
    )
    try {
        $hostOut = (& (Join-Path $repo 'infra/scripts/Test-FslogixHost.ps1') 2>&1 | Out-String)
        Microsoft.PowerShell.Utility\Write-Host $hostOut
        Assert-Equal ($hostOut -match '\[HINT\] \(1326\) Bad credentials') $true 'host diag: FSLogix hex code 0000052E decoded to 1326 with hint'
        Assert-Equal ($hostOut -match '\[(OK|FAIL|WARN)\] CloudKerberosTicketRetrievalEnabled') $true 'host diag: registry checks ran'
    }
    catch { $failures.Add("Test-FslogixHost threw: $_"); Microsoft.PowerShell.Utility\Write-Host "  FAIL $_" -ForegroundColor Red }
    finally {
        Remove-Item $fakeLog -ErrorAction SilentlyContinue
        if ($created) { Remove-Item 'C:\ProgramData\FSLogix' -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

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
exit 0   # scripts under test may legitimately leave a non-zero LASTEXITCODE
