<#
.SYNOPSIS
    Interactive questionnaire that produces a Bicep parameter file for the AVD deployment.

.DESCRIPTION
    Walks through docs/questionnaire.md: subscription, region, resource groups (new or
    existing), VNet (new or existing), identity, capacity, monitoring, FSLogix and scaling.

    When the Azure CLI is installed and signed in, answers are looked up and validated live:
      * subscriptions, VNets and subnets are offered as pick lists
      * the region is taken from an existing VNet
      * subnet free-IP capacity is checked against the number of session hosts
      * existing resource groups are detected (and marked create = false)
      * Entra ID groups can be given by name and resolved to object IDs
      * the Azure Virtual Desktop service principal object ID is looked up

    Output:
      infra/params/<env>.bicepparam      - parameter file for main.bicep
      infra/params/<env>.answers.json    - your answers; pass back with -AnswersFile to edit

    Works on PowerShell 7+ and Windows PowerShell 5.1. Secrets are NOT written: the local
    admin password is read from $env:AVD_LOCAL_ADMIN_PASSWORD at deploy time.

.EXAMPLE
    pwsh ./scripts/New-AvdParameterFile.ps1

.EXAMPLE
    # Re-run using previous answers as defaults (press Enter to keep each one)
    pwsh ./scripts/New-AvdParameterFile.ps1 -AnswersFile ./infra/params/prod.answers.json

.EXAMPLE
    # Offline - no Azure lookups
    pwsh ./scripts/New-AvdParameterFile.ps1 -SkipAzureLookups
#>
[CmdletBinding()]
param(
    [string] $AnswersFile,
    [string] $OutputDirectory,
    [switch] $SkipAzureLookups
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $OutputDirectory) {
    $OutputDirectory = [IO.Path]::Combine($PSScriptRoot, '..', 'infra', 'params')
}

# =====================================================================================
# Helpers - prompting
# =====================================================================================
$script:Previous = $null
if ($AnswersFile) {
    $script:Previous = Get-Content -Raw -Path $AnswersFile | ConvertFrom-Json
    Write-Host "Loaded previous answers from $AnswersFile" -ForegroundColor DarkGray
}
$script:Answers = [ordered]@{}

function Get-Default([string] $Key, $Fallback) {
    if ($null -ne $script:Previous -and $script:Previous.PSObject.Properties[$Key]) {
        return $script:Previous.$Key
    }
    return $Fallback
}

function Write-Section([string] $Title) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor Cyan
}

function Write-Note([string] $Text) { Write-Host "  $Text" -ForegroundColor DarkGray }
function Write-Warn([string] $Text) { Write-Host "  ! $Text" -ForegroundColor Yellow }
function Write-Ok([string] $Text) { Write-Host "  + $Text" -ForegroundColor Green }

# Free-text question. $Validate returns $null when OK, or an error message.
function Read-Answer {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Prompt,
        [string] $Default = '',
        [scriptblock] $Validate,
        [switch] $AllowEmpty
    )
    $Default = [string](Get-Default $Key $Default)
    while ($true) {
        $suffix = if ($Default -ne '') { " [$Default]" } else { '' }
        $value = Read-Host "  $Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        $value = $value.Trim()
        if ($value -eq '-' ) { $value = '' }   # '-' clears a default
        if ($value -eq '' -and -not $AllowEmpty) {
            Write-Warn 'A value is required.'
            continue
        }
        if ($Validate -and $value -ne '') {
            $err = & $Validate $value
            if ($err) { Write-Warn $err; continue }
        }
        $script:Answers[$Key] = $value
        return $value
    }
}

function Read-Choice {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Prompt,
        [Parameter(Mandatory)] [string[]] $Options,
        [string] $Default
    )
    $Default = [string](Get-Default $Key $Default)
    Write-Host "  $Prompt"
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($Options[$i] -eq $Default) { '*' } else { ' ' }
        Write-Host ("   {0}{1,2}) {2}" -f $marker, ($i + 1), $Options[$i])
    }
    while ($true) {
        $value = Read-Host '  Choice'
        if ([string]::IsNullOrWhiteSpace($value) -and $Default) { $value = $Default }
        $n = 0
        if ([int]::TryParse($value, [ref] $n) -and $n -ge 1 -and $n -le $Options.Count) {
            $value = $Options[$n - 1]
        }
        $match = $Options | Where-Object { $_ -eq $value }
        if ($match) {
            $script:Answers[$Key] = [string]$match
            return [string]$match
        }
        Write-Warn "Pick 1-$($Options.Count)."
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Prompt,
        [bool] $Default = $true
    )
    $prev = Get-Default $Key $null
    if ($null -ne $prev) { $Default = [System.Convert]::ToBoolean($prev) }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $value = Read-Host "  $Prompt [$hint]"
        if ([string]::IsNullOrWhiteSpace($value)) { $result = $Default }
        elseif ($value -match '^(y|yes)$') { $result = $true }
        elseif ($value -match '^(n|no)$') { $result = $false }
        else { Write-Warn 'Answer y or n.'; continue }
        $script:Answers[$Key] = $result
        return $result
    }
}

function Read-Int {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Prompt,
        [int] $Default,
        [int] $Min = 0,
        [int] $Max = [int]::MaxValue
    )
    $v = Read-Answer -Key $Key -Prompt $Prompt -Default ([string]$Default) -Validate {
        param($x)
        $n = 0
        if (-not [int]::TryParse($x, [ref] $n)) { return 'Enter a whole number.' }
        if ($n -lt $Min -or $n -gt $Max) { return "Must be between $Min and $Max." }
    }
    $script:Answers[$Key] = [int]$v
    return [int]$v
}

# Pick from a list of objects (from Azure), or type a value manually.
function Select-FromList {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Prompt,
        [object[]] $Items,
        [Parameter(Mandatory)] [scriptblock] $Label,
        [Parameter(Mandatory)] [scriptblock] $Value,
        [scriptblock] $Validate,
        [switch] $AllowEmpty
    )
    $default = [string](Get-Default $Key '')
    if ($Items -and $Items.Count -gt 0) {
        Write-Host "  $Prompt"
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $v = & $Value $Items[$i]
            $marker = if ($v -eq $default) { '*' } else { ' ' }
            Write-Host ("   {0}{1,2}) {2}" -f $marker, ($i + 1), (& $Label $Items[$i]))
        }
        Write-Note 'Enter a number, paste a value, or press Enter for the default (*).'
        while ($true) {
            $in = Read-Host '  Choice'
            if ([string]::IsNullOrWhiteSpace($in)) { $in = $default }
            $n = 0
            if ([int]::TryParse($in, [ref] $n) -and $n -ge 1 -and $n -le $Items.Count) {
                $in = [string](& $Value $Items[$n - 1])
            }
            if ($in -eq '' -and $AllowEmpty) { $script:Answers[$Key] = ''; return '' }
            if ($in -eq '') { Write-Warn 'A value is required.'; continue }
            if ($Validate) { $err = & $Validate $in; if ($err) { Write-Warn $err; continue } }
            $script:Answers[$Key] = $in
            return $in
        }
    }
    $params = @{ Key = $Key; Prompt = $Prompt; Validate = $Validate; AllowEmpty = $AllowEmpty }
    return Read-Answer @params
}

# =====================================================================================
# Helpers - Azure CLI
# =====================================================================================
$script:AzOk = $false
$script:HasGraph = $false
$acct = $null

# Simple function (no param block) so az flags like --query are passed through untouched.
function Invoke-AzJson {
    if (-not $script:AzOk) { return $null }
    $azArgs = $args
    try {
        $out = & az @azArgs --only-show-errors -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        return (($out -join "`n") | ConvertFrom-Json)
    }
    catch { return $null }
}

function Test-ResourceId([string] $Id, [string] $Type) {
    $pattern = "^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/$([regex]::Escape($Type))/[^/]+"
    if ($Id -notmatch $pattern) { return "Expected a resource ID of type $Type (/subscriptions/<id>/resourceGroups/<rg>/providers/$Type/<name>...)." }
}

function Get-IdPart([string] $Id, [int] $Index) { return ($Id -split '/')[$Index] }

$guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

# =====================================================================================
# Helpers - Bicep output
# =====================================================================================
function ConvertTo-BicepString([string] $s) {
    return "'" + $s.Replace('\', '\\').Replace("'", "\'").Replace('${', '\${') + "'"
}

function ConvertTo-BicepArray([string[]] $Items, [int] $Indent = 0) {
    $Items = @($Items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Items.Count -eq 0) { return '[]' }
    $pad = '  ' * $Indent
    $lines = @('[')
    foreach ($i in $Items) { $lines += "$pad  $(ConvertTo-BicepString $i)" }
    $lines += "$pad]"
    return ($lines -join "`n")
}

function ConvertTo-BicepBool([bool] $b) { if ($b) { 'true' } else { 'false' } }

function Split-List([string] $s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return @() }
    return @($s -split '[,;\s]+' | Where-Object { $_ -ne '' })
}

# =====================================================================================
# Start
# =====================================================================================
Write-Host ''
Write-Host 'Azure Virtual Desktop - deployment questionnaire' -ForegroundColor White
Write-Note "Press Enter to accept [defaults]. Type '-' to clear a default."
Write-Note 'See docs/questionnaire.md for the meaning of each question.'

if (-not $SkipAzureLookups) {
    if (Get-Command az -ErrorAction SilentlyContinue) {
        $script:AzOk = $true
        $acct = Invoke-AzJson account show
        if ($acct) {
            Write-Ok "Azure CLI signed in as $($acct.user.name) (tenant $($acct.tenantId))."
            $script:HasGraph = [bool](Invoke-AzJson extension show --name resource-graph)
            if (-not $script:HasGraph) { Write-Note "Tip: 'az extension add --name resource-graph' enables cross-subscription pick lists." }
        }
        else {
            $script:AzOk = $false
            Write-Warn "Azure CLI is not signed in - continuing without live lookups. (Run 'az login' first to enable them.)"
        }
    }
    else {
        Write-Warn 'Azure CLI not found - continuing without live lookups.'
    }
}

# -------------------------------------------------------------------------------------
Write-Section '1. Tenant and subscription'
# -------------------------------------------------------------------------------------
$tenantDefault = ''
if ($script:AzOk -and $acct) { $tenantDefault = $acct.tenantId }
$tenantId = Read-Answer -Key 'tenantId' -Prompt 'Entra ID tenant ID' -Default $tenantDefault -Validate {
    param($x) if ($x -notmatch $guidPattern) { 'Must be a GUID.' }
}

Write-Note 'The workload subscription holds the session hosts, host pool and storage.'
Write-Note 'It MUST be the subscription that contains (or will contain) the session host VNet.'
$subs = Invoke-AzJson account list --query "[?tenantId=='$tenantId'].{name:name, id:id}"
$subscriptionId = Select-FromList -Key 'subscriptionId' -Prompt 'Workload subscription' -Items $subs `
    -Label { param($s) "$($s.name)  ($($s.id))" } -Value { param($s) $s.id } `
    -Validate { param($x) if ($x -notmatch $guidPattern) { 'Must be a subscription GUID.' } }

# -------------------------------------------------------------------------------------
Write-Section '2. Network'
# -------------------------------------------------------------------------------------
$networkMode = Read-Choice -Key 'networkMode' -Prompt 'Session host virtual network:' -Options @('existing', 'new') -Default 'existing'

$location = ''
$existingSessionHostSubnetId = ''
$existingPrivateEndpointSubnetId = ''
$outboundNote = ''

if ($networkMode -eq 'existing') {
    $vnets = Invoke-AzJson network vnet list --subscription $subscriptionId --query '[].{name:name, rg:resourceGroup, location:location, id:id, space:addressSpace.addressPrefixes}'
    $vnetId = Select-FromList -Key 'existingVnetId' -Prompt 'Existing VNet' -Items $vnets `
        -Label { param($v) "$($v.name)  rg=$($v.rg)  $($v.location)  $($v.space -join ',')" } -Value { param($v) $v.id } `
        -Validate {
        param($x)
        $e = Test-ResourceId $x 'Microsoft.Network/virtualNetworks'; if ($e) { return $e }
        if ((Get-IdPart $x 2) -ne $subscriptionId) { return 'The VNet must be in the workload subscription (NICs cannot use a VNet in another subscription).' }
    }

    $vnetObj = Invoke-AzJson network vnet show --ids $vnetId
    if ($vnetObj) {
        $location = $vnetObj.location
        Write-Ok "VNet region: $location (session hosts will be deployed there)."
        if ($vnetObj.PSObject.Properties['dhcpOptions'] -and $vnetObj.dhcpOptions -and $vnetObj.dhcpOptions.dnsServers) {
            Write-Note "VNet DNS servers: $($vnetObj.dhcpOptions.dnsServers -join ', ')"
        }
        else {
            Write-Note 'VNet uses Azure-provided DNS.'
        }
    }

    $subnets = Invoke-AzJson network vnet subnet list --ids $vnetId --query '[].{name:name, id:id, prefix:addressPrefix, used:length(ipConfigurations || `[]`)}'
    if (-not $subnets) {
        $subnets = Invoke-AzJson network vnet subnet list --resource-group (Get-IdPart $vnetId 4) --vnet-name (Get-IdPart $vnetId 8) --subscription $subscriptionId --query '[].{name:name, id:id, prefix:addressPrefix, used:length(ipConfigurations || `[]`)}'
    }
    $subnetLabel = {
        param($s)
        $free = ''
        if ($s.prefix -match '/(\d+)$') { $free = ([math]::Pow(2, 32 - [int]$Matches[1]) - 5 - [int]$s.used) }
        "$($s.name)  $($s.prefix)  ~$free free IPs"
    }
    $subnetValidate = {
        param($x)
        $e = Test-ResourceId $x 'Microsoft.Network/virtualNetworks'; if ($e) { return $e }
        if ($x -notmatch '/subnets/[^/]+$') { return 'Expected a subnet resource ID (.../virtualNetworks/<vnet>/subnets/<subnet>).' }
        if ((Get-IdPart $x 2) -ne $subscriptionId) { return 'Subnet must be in the workload subscription.' }
    }
    $existingSessionHostSubnetId = Select-FromList -Key 'existingSessionHostSubnetId' -Prompt 'Session host subnet' -Items $subnets `
        -Label $subnetLabel -Value { param($s) $s.id } -Validate $subnetValidate

    Write-Note 'The storage private endpoint can share the session host subnet. Press Enter with no value to share it.'
    $existingPrivateEndpointSubnetId = Select-FromList -Key 'existingPrivateEndpointSubnetId' -Prompt 'Private endpoint subnet (optional)' -Items $subnets `
        -Label $subnetLabel -Value { param($s) $s.id } -Validate $subnetValidate -AllowEmpty

    $outboundNote = Read-Answer -Key 'existingOutboundDescription' -Prompt 'How do hosts on this subnet reach the internet? (e.g. hub firewall / NAT gateway)' -AllowEmpty
    Write-Note 'Make sure the AVD required endpoints are allowed outbound (docs/questionnaire.md section 4.6).'
}
else {
    $locations = Invoke-AzJson account list-locations --query "[?metadata.regionType=='Physical'].{name:name, display:displayName}"
    $location = Read-Answer -Key 'location' -Prompt 'Azure region (e.g. uksouth, westeurope, eastus2)' -Default 'uksouth' -Validate {
        param($x)
        if ($x -notmatch '^[a-z][a-z0-9]{2,30}$') { return "Enter the region's short name, e.g. uksouth." }
        if ($locations -and -not ($locations | Where-Object { $_.name -eq $x })) { return "Unknown region '$x'." }
    }
}
if ($networkMode -eq 'existing' -and -not $location) {
    $location = Read-Answer -Key 'location' -Prompt 'Azure region of the existing VNet' -Default 'uksouth' -Validate {
        param($x) if ($x -notmatch '^[a-z][a-z0-9]{2,30}$') { "Enter the region's short name, e.g. uksouth." }
    }
}
$script:Answers['location'] = $location

# -------------------------------------------------------------------------------------
Write-Section '3. Naming'
# -------------------------------------------------------------------------------------
$workloadName = Read-Answer -Key 'workloadName' -Prompt 'Workload short name (2-8 chars, lowercase)' -Default 'avd' -Validate {
    param($x) if ($x -notmatch '^[a-z0-9]{2,8}$') { 'Use 2-8 lowercase letters/numbers.' }
}
$environmentName = Read-Answer -Key 'environmentName' -Prompt 'Environment name (max 6 chars, e.g. prod, dev)' -Default 'prod' -Validate {
    param($x) if ($x -notmatch '^[a-z0-9]{1,6}$') { 'Use 1-6 lowercase letters/numbers.' }
}
Write-Note 'Desktop type:'
Write-Note '  Pooled   - users share multi-session hosts (e.g. 10 per host)'
Write-Note '  Personal - 1:1, every user gets their own VM (one VM per user)'
$hostPoolType = Read-Choice -Key 'hostPoolType' -Prompt 'Desktop type:' -Options @('Pooled', 'Personal') -Default 'Pooled'
$isPersonal = $hostPoolType -eq 'Personal'
$prefixDefault = if ($isPersonal) { 'avdpd' } else { 'avdsh' }
$sessionHostNamePrefix = Read-Answer -Key 'sessionHostNamePrefix' -Prompt 'Session host name prefix (max 10 chars; hosts become <prefix>-001...)' -Default $prefixDefault -Validate {
    param($x) if ($x -notmatch '^[a-zA-Z][a-zA-Z0-9-]{0,9}$') { 'Up to 10 letters, numbers or hyphens, starting with a letter.' }
}
$tagsRaw = Read-Answer -Key 'tags' -Prompt 'Tags as key=value pairs separated by ; (e.g. owner=IT;costCentre=1234)' -AllowEmpty -Validate {
    param($x)
    foreach ($pair in ($x -split ';' | Where-Object { $_.Trim() })) {
        if ($pair -notmatch '^\s*[^=]+=.*$') { return "'$pair' is not key=value." }
    }
}
$nameSuffix = "$workloadName-$environmentName-$location"

# -------------------------------------------------------------------------------------
Write-Section '4. Capacity and session hosts'
# -------------------------------------------------------------------------------------
$personalAssignmentType = 'Automatic'
if ($isPersonal) {
    $targetUserCount = Read-Int -Key 'targetUserCount' -Prompt 'Number of users (each gets their own desktop VM)' -Default 1000 -Min 1
    $maxSessionsPerHost = 1
    $hostsNeeded = $targetUserCount
    Write-Note 'Assignment: Automatic - a user gets a free desktop on first connection;'
    Write-Note '            Direct    - you assign users to desktops (scripts\Set-AvdPersonalAssignment.ps1).'
    $personalAssignmentType = Read-Choice -Key 'personalAssignmentType' -Prompt 'Desktop assignment:' -Options @('Automatic', 'Direct') -Default 'Automatic'
    Write-Ok "$hostsNeeded desktop VMs required (1:1)."
    if ($hostsNeeded -gt 400) { Write-Note 'Large pools are deployed in batches of up to 400 (Deploy-Avd.ps1 -AddHosts 400, repeated).' }
}
else {
    $targetUserCount = Read-Int -Key 'targetUserCount' -Prompt 'Concurrent users to support' -Default 1000 -Min 1
    $maxSessionsPerHost = Read-Int -Key 'maxSessionsPerHost' -Prompt 'Users per session host' -Default 10 -Min 1
    $hostsNeeded = [int][math]::Ceiling($targetUserCount / $maxSessionsPerHost)
    Write-Ok "$hostsNeeded session hosts required."
}

$vmSizeDefault = if ($isPersonal) { 'Standard_D4s_v5' } else { 'Standard_D8s_v5' }
if ($isPersonal) { Write-Note 'Personal desktops host one user each: Standard_D4s_v5 (4 vCPU/16 GiB) for knowledge workers, D2s_v5 for light use.' }
$vmSize = Read-Answer -Key 'vmSize' -Prompt 'VM size' -Default $vmSizeDefault
$vcpu = $null
$sku = Invoke-AzJson vm list-sizes --location $location --subscription $subscriptionId --query "[?name=='$vmSize'] | [0]"
if ($sku) {
    $vcpu = [int]$sku.numberOfCores
    Write-Ok "$vmSize = $vcpu vCPU / $([math]::Round($sku.memoryInMB / 1024)) GiB. Total quota needed: $($vcpu * $hostsNeeded) vCPU."
    $usage = Invoke-AzJson vm list-usage --location $location --subscription $subscriptionId --query "[?name.value=='cores'] | [0]"
    if ($usage) {
        $free = [int]$usage.limit - [int]$usage.currentValue
        if ($free -lt ($vcpu * $hostsNeeded)) {
            Write-Warn "Regional vCPU quota has $free free cores - request an increase (also check the VM family quota)."
        }
        else { Write-Ok "Regional vCPU quota OK ($free free). Check the VM family quota too." }
    }
}
elseif ($script:AzOk) {
    Write-Warn "Could not find $vmSize in $location for this subscription - check the name/availability."
}

if ($networkMode -eq 'existing') {
    $sn = Invoke-AzJson network vnet subnet show --ids $existingSessionHostSubnetId --query '{prefix:addressPrefix, used:length(ipConfigurations || `[]`)}'
    if ($sn -and $sn.prefix -match '/(\d+)$') {
        $free = [math]::Pow(2, 32 - [int]$Matches[1]) - 5 - [int]$sn.used
        if ($free -lt $hostsNeeded + 1) { Write-Warn "Session host subnet has ~$free free IPs but $hostsNeeded hosts (+1 private endpoint) are needed." }
        else { Write-Ok "Session host subnet has ~$free free IPs." }
    }
}

$pilotDefault = [math]::Min($hostsNeeded, 400)
$pilot = Read-Int -Key 'initialHostCount' -Prompt "Hosts to deploy in the first run (pilot, max 400 per run), or $hostsNeeded for all" -Default $pilotDefault -Min 0 -Max $hostsNeeded
$imageChoice = Read-Choice -Key 'imageSource' -Prompt 'Session host image:' -Options @('marketplace', 'gallery') -Default 'marketplace'
$galleryImageId = ''
$vmSecurityType = 'TrustedLaunch'
$marketplaceSku = 'win11-24h2-avd-m365'
if ($imageChoice -eq 'gallery') {
    Write-Note 'Use the image DEFINITION ID to always deploy the latest version, or a /versions/<x.y.z> ID to pin one.'
    $galleryImageId = Read-Answer -Key 'galleryImageId' -Prompt 'Compute Gallery image definition or version resource ID' -Validate {
        param($x) Test-ResourceId $x 'Microsoft.Compute/galleries'
    }
    Write-Note 'Trusted Launch needs a Gen2 image whose definition security type is TrustedLaunchSupported or TrustedLaunch.'
    $tl = Read-YesNo -Key 'imageTrustedLaunch' -Prompt 'Does the image support Trusted Launch?' -Default $true
    $vmSecurityType = if ($tl) { 'TrustedLaunch' } else { 'Standard' }
}
else {
    $marketplaceSku = Read-Answer -Key 'marketplaceSku' -Prompt 'Marketplace SKU (office-365 offer)' -Default 'win11-24h2-avd-m365'
}
$zones = Read-Answer -Key 'availabilityZones' -Prompt "Availability zones (comma separated, '-' for none)" -Default '1,2,3' -AllowEmpty -Validate {
    param($x) foreach ($z in (Split-List $x)) { if ($z -notmatch '^[1-3]$') { return 'Zones must be 1, 2 and/or 3.' } }
}
$encryptionAtHost = Read-YesNo -Key 'encryptionAtHost' -Prompt 'Enable encryption at host? (feature must be registered on the subscription)' -Default $false
$localAdminUsername = Read-Answer -Key 'localAdminUsername' -Prompt 'Local break-glass admin username' -Default 'avdadmin' -Validate {
    param($x) if ($x -in @('admin', 'administrator', 'root', 'guest', 'user')) { 'That username is not allowed by Azure.' }
}

# -------------------------------------------------------------------------------------
Write-Section '5. Monitoring'
# -------------------------------------------------------------------------------------
$logAnalyticsMode = Read-Choice -Key 'logAnalyticsMode' -Prompt 'Log Analytics workspace:' -Options @('existing', 'new') -Default 'existing'
$existingLogAnalyticsWorkspaceId = ''
$logRetention = 30
if ($logAnalyticsMode -eq 'existing') {
    $laws = Invoke-AzJson monitor log-analytics workspace list --query '[].{name:name, rg:resourceGroup, location:location, id:id}'
    $existingLogAnalyticsWorkspaceId = Select-FromList -Key 'existingLogAnalyticsWorkspaceId' -Prompt 'Existing workspace (any subscription; paste the ID if it is not listed)' -Items $laws `
        -Label { param($w) "$($w.name)  rg=$($w.rg)  $($w.location)" } -Value { param($w) $w.id } `
        -Validate { param($x) Test-ResourceId $x 'Microsoft.OperationalInsights/workspaces' }
}
else {
    $logRetention = Read-Int -Key 'logAnalyticsRetentionDays' -Prompt 'Retention (days)' -Default 30 -Min 30 -Max 730
}

# -------------------------------------------------------------------------------------
Write-Section '6. User profiles (FSLogix)'
# -------------------------------------------------------------------------------------
if ($isPersonal) { Write-Note 'Personal desktops keep the profile on the user''s own VM, so FSLogix is optional (default: no).' }
$deployFslogix = Read-YesNo -Key 'deployFslogixStorage' -Prompt 'Deploy Azure Files Premium for FSLogix profiles (Entra Kerberos)?' -Default (-not $isPersonal)
$fslogixProfileSizeMB = 30000
$fslogixShareQuotaGiB = 10240
$fslogixStorageSku = 'Premium_ZRS'
$privateDnsZoneMode = 'new'
$existingFilePrivateDnsZoneId = ''
$fslogixNetworkAccess = 'privateEndpoint'
if ($deployFslogix) {
    $fslogixProfileSizeMB = Read-Int -Key 'fslogixProfileSizeMB' -Prompt 'Max profile size per user (MB)' -Default 30000 -Min 1000
    $suggested = [int][math]::Max(100, [math]::Ceiling($targetUserCount * 10))
    $fslogixShareQuotaGiB = Read-Int -Key 'fslogixShareQuotaGiB' -Prompt 'Share size (GiB) - ~10 GiB/user is a typical starting point' -Default $suggested -Min 100 -Max 102400
    $fslogixStorageSku = Read-Choice -Key 'fslogixStorageSku' -Prompt 'Storage redundancy:' -Options @('Premium_ZRS', 'Premium_LRS') -Default 'Premium_ZRS'

    Write-Note 'How session hosts reach the profile share:'
    Write-Note '  privateEndpoint - private endpoint + privatelink.file DNS zone; public access off'
    Write-Note '  serviceEndpoint - no private endpoint or private DNS needed; the public endpoint is'
    Write-Note '                    firewalled to the session host subnet (Microsoft backbone, not internet)'
    $fslogixNetworkAccess = Read-Choice -Key 'fslogixNetworkAccess' -Prompt 'Profile share network access:' -Options @('privateEndpoint', 'serviceEndpoint') -Default 'privateEndpoint'
    if ($fslogixNetworkAccess -eq 'privateEndpoint') {
        Write-Note 'privatelink.file.core.windows.net DNS zone for the storage private endpoint:'
        Write-Note '  new           - create a zone in the storage RG and link it to the VNet'
        Write-Note '  existing      - use a central zone (usually in the hub/connectivity subscription)'
        Write-Note '  policyManaged - Azure Policy creates the DNS record; the template creates none'
        $dnsDefault = if ($networkMode -eq 'existing') { 'existing' } else { 'new' }
        $privateDnsZoneMode = Read-Choice -Key 'privateDnsZoneMode' -Prompt 'DNS zone:' -Options @('new', 'existing', 'policyManaged') -Default $dnsDefault
        if ($privateDnsZoneMode -eq 'existing') {
            $zonesFound = $null
            if ($script:HasGraph) {
                $zonesFound = Invoke-AzJson graph query -q "resources | where type =~ 'microsoft.network/privatednszones' and name startswith 'privatelink.file.' | project name, resourceGroup, subscriptionId, id" --query 'data'
            }
            elseif ($script:AzOk) {
                $dnsSub = Read-Answer -Key 'dnsZoneSubscriptionId' -Prompt 'Subscription that holds the zone (hub/connectivity)' -Default $subscriptionId
                $zonesFound = Invoke-AzJson network private-dns zone list --subscription $dnsSub --query "[?starts_with(name, 'privatelink.file.')].{name:name, resourceGroup:resourceGroup, subscriptionId:'$dnsSub', id:id}"
            }
            $existingFilePrivateDnsZoneId = Select-FromList -Key 'existingFilePrivateDnsZoneId' -Prompt 'Existing privatelink.file zone' -Items $zonesFound `
                -Label { param($z) "$($z.name)  sub=$($z.subscriptionId)  rg=$($z.resourceGroup)" } -Value { param($z) $z.id } `
                -Validate {
                param($x)
                $e = Test-ResourceId $x 'Microsoft.Network/privateDnsZones'; if ($e) { return $e }
                if ($x -notmatch '/privateDnsZones/privatelink\.file\.') { return 'Must be the privatelink.file.<storage suffix> zone.' }
            }
            Write-Note 'The zone must already be linked to this VNet, or to the hub VNet whose DNS this VNet uses.'
        }
        elseif ($privateDnsZoneMode -eq 'new' -and $networkMode -eq 'existing') {
            Write-Warn 'Creating a new zone linked to an existing VNet: if a privatelink.file zone is already linked (e.g. via the hub DNS), this will conflict.'
        }
    }
    else {
        if ($networkMode -eq 'existing') {
            Write-Note 'The existing session host subnet needs the Microsoft.Storage service endpoint;'
            Write-Note 'Deploy-Avd.ps1 checks this and prints the az command if it is missing.'
        }
        else { Write-Note 'The new session host subnet will get the Microsoft.Storage service endpoint.' }
    }
}

# -------------------------------------------------------------------------------------
if ($networkMode -eq 'new') {
    Write-Section '7. New virtual network'
    $vnetName = Read-Answer -Key 'vnetName' -Prompt 'VNet name' -Default "vnet-$nameSuffix"
    $cidr = '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'
    $cidrCheck = { param($x) if ($x -notmatch $cidr) { 'Use CIDR notation, e.g. 10.50.0.0/16.' } }
    $vnetAddressPrefix = Read-Answer -Key 'vnetAddressPrefix' -Prompt 'VNet address space (must not overlap hub / on-prem / other spokes)' -Default '10.50.0.0/16' -Validate $cidrCheck
    $sessionHostSubnetPrefix = Read-Answer -Key 'sessionHostSubnetPrefix' -Prompt 'Session host subnet (/23 or larger recommended)' -Default '10.50.0.0/22' -Validate {
        param($x)
        if ($x -notmatch $cidr) { return 'Use CIDR notation.' }
        $bits = [int]($x -split '/')[1]
        $usable = [math]::Pow(2, 32 - $bits) - 5
        if ($usable -lt $hostsNeeded) { return "/$bits gives $usable usable IPs - fewer than the $hostsNeeded hosts needed." }
    }
    $privateEndpointSubnetPrefix = Read-Answer -Key 'privateEndpointSubnetPrefix' -Prompt 'Private endpoint subnet' -Default '10.50.4.0/27' -Validate $cidrCheck
    $dnsServers = Read-Answer -Key 'dnsServers' -Prompt "Custom DNS server IPs, comma separated ('-' for Azure DNS)" -AllowEmpty
    $outboundMethod = Read-Choice -Key 'outboundMethod' -Prompt 'Outbound internet for session hosts:' -Options @('NatGateway', 'FirewallUdr', 'None') -Default 'NatGateway'
    $firewallPrivateIp = ''
    if ($outboundMethod -eq 'FirewallUdr') {
        $firewallPrivateIp = Read-Answer -Key 'firewallPrivateIp' -Prompt 'Hub firewall / NVA private IP' -Validate {
            param($x) if ($x -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { 'Enter an IPv4 address.' }
        }
    }
    $hubVnetId = ''
    $hubUseRemoteGateways = $false
    if (Read-YesNo -Key 'peerToHub' -Prompt 'Peer the new VNet to a hub VNet?' -Default $false) {
        $hubVnets = $null
        if ($script:HasGraph) {
            $hubVnets = Invoke-AzJson graph query -q "resources | where type =~ 'microsoft.network/virtualnetworks' | project name, resourceGroup, subscriptionId, location, id" --first 200 --query 'data'
        }
        elseif ($script:AzOk) {
            $hubSub = Read-Answer -Key 'hubSubscriptionId' -Prompt 'Subscription that holds the hub VNet' -Default $subscriptionId
            $hubVnets = Invoke-AzJson network vnet list --subscription $hubSub --query "[].{name:name, resourceGroup:resourceGroup, subscriptionId:'$hubSub', location:location, id:id}"
        }
        $hubVnetId = Select-FromList -Key 'hubVnetId' -Prompt 'Hub VNet (any subscription)' -Items $hubVnets `
            -Label { param($v) "$($v.name)  sub=$($v.subscriptionId)  rg=$($v.resourceGroup)  $($v.location)" } -Value { param($v) $v.id } `
            -Validate { param($x) Test-ResourceId $x 'Microsoft.Network/virtualNetworks' }
        $hubUseRemoteGateways = Read-YesNo -Key 'hubUseRemoteGateways' -Prompt "Use the hub's VPN/ExpressRoute gateway?" -Default $false
        Write-Note 'The deploying identity needs Network Contributor on the hub VNet to create the hub-side peering.'
    }
}

# -------------------------------------------------------------------------------------
Write-Section '8. Resource groups'
# -------------------------------------------------------------------------------------
Write-Note 'For each component give a resource group name. Existing groups are detected (when signed in)'
Write-Note 'and left untouched; new ones are created. Components may share a resource group.'

function Read-ResourceGroup([string] $Role, [string] $Description) {
    $name = Read-Answer -Key "rg_$Role" -Prompt "$Description - resource group" -Default "rg-$nameSuffix-$Role" -Validate {
        param($x) if ($x -notmatch '^[-\w\._\(\)]{1,90}$' -or $x.EndsWith('.')) { 'Invalid resource group name.' }
    }
    $create = $true
    if ($script:AzOk) {
        $rg = Invoke-AzJson group show --name $name --subscription $subscriptionId
        if ($rg) {
            $create = $false
            Write-Ok "'$name' exists ($($rg.location)) - will be used as-is."
            if ($rg.location -ne $location) { Write-Note "Resource group is in $($rg.location); resources inside it will still be deployed to $location." }
        }
        else {
            Write-Ok "'$name' does not exist - will be created."
        }
    }
    else {
        $create = -not (Read-YesNo -Key "rg_${Role}_exists" -Prompt "Does '$name' already exist?" -Default $false)
    }
    $script:Answers["rg_${Role}_create"] = $create
    return @{ name = $name; create = $create }
}

$rgService = Read-ResourceGroup 'service' 'AVD host pool / app group / workspace'
$rgHosts = Read-ResourceGroup 'hosts' 'Session host VMs'
$rgStorage = if ($deployFslogix) { Read-ResourceGroup 'storage' 'FSLogix storage' } else { @{ name = ''; create = $false } }
$rgNetwork = if ($networkMode -eq 'new') { Read-ResourceGroup 'network' 'New VNet' } else { @{ name = ''; create = $false } }
$rgMonitor = if ($logAnalyticsMode -eq 'new') { Read-ResourceGroup 'monitor' 'New Log Analytics workspace' } else { @{ name = ''; create = $false } }

# -------------------------------------------------------------------------------------
Write-Section '9. Identity and access'
# -------------------------------------------------------------------------------------
function Resolve-Group([string] $Key, [string] $Prompt, [switch] $Optional) {
    while ($true) {
        $value = Read-Answer -Key $Key -Prompt $Prompt -AllowEmpty:$Optional
        if ($value -eq '') { return '' }
        if ($value -match $guidPattern) {
            $g = Invoke-AzJson ad group show --group $value --query '{name:displayName, id:id}'
            if ($g) { Write-Ok "Group: $($g.name)" }
            elseif ($script:AzOk) { Write-Warn 'Could not verify this group ID in Entra ID (may be a permissions issue).' }
            return $value
        }
        if (-not $script:AzOk) { Write-Warn 'Without Azure lookups, enter the group object ID (GUID).'; continue }
        $g = @(Invoke-AzJson ad group list --display-name $value --query '[].{name:displayName, id:id}' | Where-Object { $_ })
        if ($g.Count -eq 0) { Write-Warn "No group named '$value' found."; continue }
        if ($g.Count -gt 1) { Write-Warn "Several groups named '$value' - enter the object ID instead."; continue }
        Write-Ok "Resolved '$value' -> $($g[0].id)"
        $script:Answers[$Key] = $g[0].id
        return $g[0].id
    }
}
$avdUsersGroupObjectId = Resolve-Group 'avdUsersGroupObjectId' 'AVD users group (name or object ID)'
$avdAdminsGroupObjectId = Resolve-Group 'avdAdminsGroupObjectId' 'AVD admins group (name or object ID, optional)' -Optional

$avdSpId = ''
$sp = Invoke-AzJson ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query '{id:id}'
if ($sp) { $avdSpId = $sp.id; Write-Ok "Azure Virtual Desktop service principal: $avdSpId" }
$avdSpId = Read-Answer -Key 'avdServicePrincipalObjectId' -Prompt "'Azure Virtual Desktop' service principal object ID (for autoscale / Start VM on Connect; '-' to skip)" -Default $avdSpId -AllowEmpty -Validate {
    param($x) if ($x -notmatch $guidPattern) { 'Must be a GUID.' }
}
$identityType = Read-Choice -Key 'userIdentityType' -Prompt 'Are AVD users synced from on-premises AD or cloud-only?' -Options @('hybrid', 'cloud-only') -Default 'hybrid'
if ($identityType -eq 'cloud-only' -and $deployFslogix) {
    Write-Warn 'Cloud-only identities with Entra Kerberos for Azure Files: confirm current support status before go-live (see README).'
}
$enableSso = Read-YesNo -Key 'enableSingleSignOn' -Prompt 'Enable Entra ID single sign-on?' -Default $true

# -------------------------------------------------------------------------------------
Write-Section '10. Host pool and scaling'
# -------------------------------------------------------------------------------------
$desktopFriendlyName = Read-Answer -Key 'desktopFriendlyName' -Prompt 'Desktop name shown to users' -Default 'Corporate Desktop'
$loadBalancerType = 'BreadthFirst'
if (-not $isPersonal) {
    $loadBalancerType = Read-Choice -Key 'loadBalancerType' -Prompt 'Load balancing:' -Options @('BreadthFirst', 'DepthFirst') -Default 'BreadthFirst'
}
else { Write-Note 'Personal pools: autoscale starts each VM when its user connects and deallocates it after sign-out / long disconnects.' }
$deployScalingPlan = Read-YesNo -Key 'deployScalingPlan' -Prompt 'Deploy autoscale scaling plan?' -Default $true
$tz = 'GMT Standard Time'
if ($deployScalingPlan) {
    Write-Note "Windows time zone ID, e.g. 'GMT Standard Time', 'W. Europe Standard Time', 'Eastern Standard Time'."
    $tz = Read-Answer -Key 'scalingPlanTimeZone' -Prompt 'Scaling plan time zone' -Default 'GMT Standard Time'
    Write-Note 'Schedule (weekdays 07:00-20:00, reduced weekends) is in infra/modules/hostpool.bicep.'

    if (-not $avdSpId) { Write-Warn 'No AVD service principal ID: the scaling plan will not be able to power hosts on/off until the role is assigned.' }
}

# =====================================================================================
# Write output
# =====================================================================================
Write-Section 'Summary'
$summary = [ordered]@{
    'Subscription'      = $subscriptionId
    'Region'            = $location
    'Network'           = if ($networkMode -eq 'existing') { "existing: $existingSessionHostSubnetId" } else { "new: $vnetName $vnetAddressPrefix" }
    'Session hosts'     = if ($isPersonal) { "Personal 1:1 ($personalAssignmentType): $hostsNeeded x $vmSize ($pilot in first run)" } else { "Pooled: $hostsNeeded x $vmSize ($pilot in first run), $maxSessionsPerHost users each" }
    'Log Analytics'     = if ($logAnalyticsMode -eq 'existing') { $existingLogAnalyticsWorkspaceId } else { 'new' }
    'FSLogix'           = if (-not $deployFslogix) { 'not deployed' } elseif ($fslogixNetworkAccess -eq 'serviceEndpoint') { "$fslogixShareQuotaGiB GiB $fslogixStorageSku, service endpoint (no private DNS)" } else { "$fslogixShareQuotaGiB GiB $fslogixStorageSku, private endpoint, DNS zone: $privateDnsZoneMode" }
    'RG service'        = "$($rgService.name) (create=$($rgService.create))"
    'RG hosts'          = "$($rgHosts.name) (create=$($rgHosts.create))"
}
if ($deployFslogix) { $summary['RG storage'] = "$($rgStorage.name) (create=$($rgStorage.create))" }
if ($networkMode -eq 'new') { $summary['RG network'] = "$($rgNetwork.name) (create=$($rgNetwork.create))" }
if ($logAnalyticsMode -eq 'new') { $summary['RG monitor'] = "$($rgMonitor.name) (create=$($rgMonitor.create))" }
foreach ($k in $summary.Keys) { Write-Host ("  {0,-15} {1}" -f $k, $summary[$k]) }

if (-not (Read-YesNo -Key '_confirm' -Prompt 'Write parameter file?' -Default $true)) {
    Write-Warn 'Nothing written.'
    return
}
$script:Answers.Remove('_confirm')

# Tags
$tagLines = @()
foreach ($pair in ($tagsRaw -split ';' | Where-Object { $_.Trim() })) {
    $k, $v = $pair -split '=', 2
    $k = $k.Trim()
    $keyText = if ($k -match '^[A-Za-z_][A-Za-z0-9_]*$') { $k } else { ConvertTo-BicepString $k }
    $tagLines += "  ${keyText}: $(ConvertTo-BicepString $v.Trim())"
}
$tagsBicep = if ($tagLines.Count) { "{`n" + ($tagLines -join "`n") + "`n}" } else { '{}' }

function Format-Rg($rg) {
    return "{ name: $(ConvertTo-BicepString $rg.name), create: $(ConvertTo-BicepBool $rg.create) }"
}

if ($imageChoice -eq 'gallery') {
    $imageBicep = "{`n  id: $(ConvertTo-BicepString $galleryImageId)`n}"
}
else {
    $imageBicep = "{`n  publisher: 'MicrosoftWindowsDesktop'`n  offer: 'office-365'`n  sku: $(ConvertTo-BicepString $marketplaceSku)`n  version: 'latest'`n}"
}

$countOverride = if ($pilot -eq $hostsNeeded) { -1 } else { $pilot }
$generated = (Get-Date).ToString('yyyy-MM-dd HH:mm')

$lines = @(
    "// Generated by scripts/New-AvdParameterFile.ps1 on $generated"
    "// Re-run with -AnswersFile ./infra/params/$environmentName.answers.json to change answers."
    '//'
    "// tenantId: $tenantId"
    "// subscriptionId: $subscriptionId"
    '//'
    '// Deploy:'
    "//   export AVD_LOCAL_ADMIN_PASSWORD='<strong password>'"
    "//   Windows:     .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\$environmentName.bicepparam -WhatIf"
    "//                .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\$environmentName.bicepparam"
    "//   macOS/Linux: ./scripts/deploy.sh infra/params/$environmentName.bicepparam what-if"
    "using '../main.bicep'"
    ''
    '// ---------------------------------------------------------------- General'
    "param location = $(ConvertTo-BicepString $location)"
    "param workloadName = $(ConvertTo-BicepString $workloadName)"
    "param environmentName = $(ConvertTo-BicepString $environmentName)"
    "param tags = $tagsBicep"
    ''
    '// ---------------------------------------------------------------- Resource groups'
    'param resourceGroups = {'
    "  service: $(Format-Rg $rgService)"
    "  hosts: $(Format-Rg $rgHosts)"
    "  storage: $(Format-Rg $rgStorage)"
    "  network: $(Format-Rg $rgNetwork)"
    "  monitor: $(Format-Rg $rgMonitor)"
    '}'
    ''
    '// ---------------------------------------------------------------- Network'
    "param networkMode = $(ConvertTo-BicepString $networkMode)"
)
if ($networkMode -eq 'existing') {
    $lines += "param existingSessionHostSubnetId = $(ConvertTo-BicepString $existingSessionHostSubnetId)"
    $lines += "param existingPrivateEndpointSubnetId = $(ConvertTo-BicepString $existingPrivateEndpointSubnetId)"
    if ($outboundNote) { $lines += "// Outbound: $outboundNote" }
}
else {
    $lines += "param vnetName = $(ConvertTo-BicepString $vnetName)"
    $lines += "param vnetAddressPrefix = $(ConvertTo-BicepString $vnetAddressPrefix)"
    $lines += "param sessionHostSubnetPrefix = $(ConvertTo-BicepString $sessionHostSubnetPrefix)"
    $lines += "param privateEndpointSubnetPrefix = $(ConvertTo-BicepString $privateEndpointSubnetPrefix)"
    $lines += "param dnsServers = $(ConvertTo-BicepArray (Split-List $dnsServers))"
    $lines += "param outboundMethod = $(ConvertTo-BicepString $outboundMethod)"
    $lines += "param firewallPrivateIp = $(ConvertTo-BicepString $firewallPrivateIp)"
    $lines += "param hubVnetId = $(ConvertTo-BicepString $hubVnetId)"
    $lines += "param hubUseRemoteGateways = $(ConvertTo-BicepBool $hubUseRemoteGateways)"
}
$lines += @(
    ''
    '// ---------------------------------------------------------------- Capacity / session hosts'
    $(if ($isPersonal) { "// Personal (1:1): $targetUserCount users = $hostsNeeded desktop VMs" } else { "// $targetUserCount users / $maxSessionsPerHost per host = $hostsNeeded session hosts" })
    "param hostPoolType = $(ConvertTo-BicepString $hostPoolType)"
    "param personalAssignmentType = $(ConvertTo-BicepString $personalAssignmentType)"
    "param targetUserCount = $targetUserCount"
    "param maxSessionsPerHost = $maxSessionsPerHost"
    "param sessionHostCountOverride = $countOverride"
    'param sessionHostStartIndex = 0'
    "param sessionHostNamePrefix = $(ConvertTo-BicepString $sessionHostNamePrefix)"
    "param vmSize = $(ConvertTo-BicepString $vmSize)"
    "param imageReference = $imageBicep"
    "param availabilityZones = $(ConvertTo-BicepArray (Split-List $zones))"
    "param encryptionAtHost = $(ConvertTo-BicepBool $encryptionAtHost)"
    "param vmSecurityType = $(ConvertTo-BicepString $vmSecurityType)"
    "param localAdminUsername = $(ConvertTo-BicepString $localAdminUsername)"
    "param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')"
    ''
    '// ---------------------------------------------------------------- Identity'
    "param avdUsersGroupObjectId = $(ConvertTo-BicepString $avdUsersGroupObjectId)"
    "param avdAdminsGroupObjectId = $(ConvertTo-BicepString $avdAdminsGroupObjectId)"
    "param avdServicePrincipalObjectId = $(ConvertTo-BicepString $avdSpId)"
    "param enableSingleSignOn = $(ConvertTo-BicepBool $enableSso)"
    ''
    '// ---------------------------------------------------------------- Host pool / scaling'
    "param desktopFriendlyName = $(ConvertTo-BicepString $desktopFriendlyName)"
    "param loadBalancerType = $(ConvertTo-BicepString $loadBalancerType)"
    "param deployScalingPlan = $(ConvertTo-BicepBool $deployScalingPlan)"
    "param scalingPlanTimeZone = $(ConvertTo-BicepString $tz)"
    ''
    '// ---------------------------------------------------------------- Monitoring'
    "param logAnalyticsMode = $(ConvertTo-BicepString $logAnalyticsMode)"
    "param existingLogAnalyticsWorkspaceId = $(ConvertTo-BicepString $existingLogAnalyticsWorkspaceId)"
    "param logAnalyticsRetentionDays = $logRetention"
    ''
    '// ---------------------------------------------------------------- FSLogix'
    "param deployFslogixStorage = $(ConvertTo-BicepBool $deployFslogix)"
    "param fslogixProfileSizeMB = $fslogixProfileSizeMB"
    "param fslogixShareQuotaGiB = $fslogixShareQuotaGiB"
    "param fslogixStorageSku = $(ConvertTo-BicepString $fslogixStorageSku)"
    "param fslogixNetworkAccess = $(ConvertTo-BicepString $fslogixNetworkAccess)"
    "param privateDnsZoneMode = $(ConvertTo-BicepString $privateDnsZoneMode)"
    "param existingFilePrivateDnsZoneId = $(ConvertTo-BicepString $existingFilePrivateDnsZoneId)"
    ''
)

if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$paramPath = Join-Path $OutputDirectory "$environmentName.bicepparam"
$answersPath = Join-Path $OutputDirectory "$environmentName.answers.json"

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($paramPath, ($lines -join "`n"), $utf8NoBom)
[IO.File]::WriteAllText($answersPath, ($script:Answers | ConvertTo-Json -Depth 5), $utf8NoBom)

Write-Host ''
Write-Ok "Parameter file: $paramPath"
Write-Ok "Answers:        $answersPath"
Write-Host ''
Write-Host '  Next steps:' -ForegroundColor White
Write-Host "    1. .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\$environmentName.bicepparam -WhatIf"
Write-Host "    2. .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\$environmentName.bicepparam"
Write-Host '       (prompts for the session host local admin password; macOS/Linux: scripts/deploy.sh)'
if ($pilot -lt $hostsNeeded) {
    Write-Host "    4. Later, to add the remaining $($hostsNeeded - $pilot) hosts, edit $environmentName.bicepparam:"
    Write-Host '         param sessionHostCountOverride = -1'
    Write-Host '       then run Deploy-Avd.ps1 again (-WhatIf first). It adds only the hosts that do not exist yet.'
    if ($deployScalingPlan) { Write-Host "    Tip: tag pilot hosts 'ExcludeFromScaling' so autoscale doesn't power them off while you test." }
}
