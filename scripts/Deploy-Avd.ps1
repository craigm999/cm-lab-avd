<#
.SYNOPSIS
    Deploys (or previews) the AVD environment from Windows using the Azure CLI.

.DESCRIPTION
    PowerShell equivalent of scripts/deploy.sh. Works in Windows PowerShell 5.1 and PowerShell 7.

    * Reads the target subscription from the "// subscriptionId: <id>" header that
      New-AvdParameterFile.ps1 writes (or use -SubscriptionId).
    * Reads the region from "param location = '<region>'" in the parameter file.
    * Prompts for the session host local admin password (hidden) unless
      $env:AVD_LOCAL_ADMIN_PASSWORD is already set. The password is only placed in this
      process's environment for the duration of the run and removed afterwards.
    * Registers the required resource providers if they are not registered.
    * Two stages:
        1. Shared resources (host pool, workspace, storage, network, RBAC...) in one
           subscription deployment, run with sessionHostCountOverride = 0.
        2. Session hosts: infra/modules/sessionhost.bicep is published as the template spec
           avd-sessionhost (1.0) and each host gets its own small deployment from it,
           -ThrottleLimit (default 20) at a time. Putting hundreds of hosts in one deployment
           fails with DeploymentSizeExceeded (4 MB), because ARM repeats the host template,
           scripts included, for every host. This way there is no batch limit.
    * -WhatIf runs `az deployment sub what-if` for the shared resources and lists the hosts
      it would add; otherwise you are asked to confirm first (skip with -Force).
    * Which hosts:
        (default)     every host the parameter file describes that doesn't exist yet.
                      Existing hosts are skipped, never redeployed.
        -AddHosts N   N new hosts after the highest existing number (avdsh-101...).
        -HostNames    exactly these hosts, e.g. ones that failed (avdsh-021,avdsh-030).
        -InfraOnly    shared resources only.
    * Saves the deployment outputs to <param file name>.outputs.json next to the parameter
      file (used by Update-SessionHostConfig.ps1).

    Requires the Azure CLI (winget install Microsoft.AzureCLI) and an `az login`.

.EXAMPLE
    .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -WhatIf

.EXAMPLE
    .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam

.EXAMPLE
    # Retry two hosts that failed
    .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -HostNames avdsh-021,avdsh-030

.EXAMPLE
    # Add 20 more session hosts after the existing ones
    .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -AddHosts 20 -WhatIf

.EXAMPLE
    # Apply a change to shared resources only (e.g. enable FSLogix storage, change scaling plan)
    .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -InfraOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ParameterFile,

    [string] $SubscriptionId,

    [string] $Location,

    [string] $DeploymentName = ('avd-' + (Get-Date -Format 'yyyyMMddHHmmss')),

    [ValidateRange(0, 5000)]
    [int] $AddHosts = 0,

    [string[]] $HostNames,

    [switch] $InfraOnly,

    [ValidateRange(1, 100)]
    [int] $ThrottleLimit = 20,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
if ((@(($AddHosts -gt 0), [bool]$InfraOnly, [bool]$HostNames) | Where-Object { $_ }).Count -gt 1) { throw 'Use only one of -AddHosts, -HostNames and -InfraOnly.' }
$preview = [bool]$WhatIfPreference
# Our own calls must not be suppressed by -WhatIf; we branch on $preview instead.
$WhatIfPreference = $false

$repoRoot = Split-Path -Parent $PSScriptRoot
$template = Join-Path (Join-Path $repoRoot 'infra') 'main.bicep'

function Invoke-Az {
    # Runs az with the given arguments, throws on failure, returns stdout text.
    $azArgs = $args
    $out = & az @azArgs
    if ($LASTEXITCODE -ne 0) { throw "az $($azArgs -join ' ') failed (exit code $LASTEXITCODE)." }
    return ($out -join "`n")
}

function Test-Az {
    # Runs az for a yes/no probe. Stderr is discarded; Windows PowerShell 5.1 would otherwise
    # turn redirected stderr into a terminating error under ErrorActionPreference = Stop.
    $azArgs = $args
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & az @azArgs 2>$null
        return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = (($out | Out-String).Trim()) }
    }
    finally { $ErrorActionPreference = $eap }
}

function Get-ParamValue([string] $Text, [string] $Name, [string] $Default) {
    # Reads `param <Name> = <value>` from a .bicepparam (simple scalars only).
    if ($Text -match "(?m)^param\s+$Name\s*=\s*'?([^'\r\n]*?)'?\s*(//.*)?$") { return $Matches[1].Trim() }
    return $Default
}

function Set-ParamValue([string] $Text, [string] $Name, [string] $Value) {
    $pattern = "(?m)^param\s+$Name\s*=.*$"
    if ($Text -match $pattern) { return [regex]::Replace($Text, $pattern, "param $Name = $Value") }
    return $Text.TrimEnd() + "`nparam $Name = $Value`n"
}

function Write-Step([string] $Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

# ------------------------------------------------------------------ Checks
if (-not (Test-Path -LiteralPath $ParameterFile)) { throw "Parameter file not found: $ParameterFile" }
$ParameterFile = (Resolve-Path -LiteralPath $ParameterFile).Path
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI not found. Install it with: winget install -e --id Microsoft.AzureCLI  (then open a new terminal)'
}

$paramText = Get-Content -Raw -LiteralPath $ParameterFile
if (-not $SubscriptionId -and $paramText -match '(?m)^//\s*subscriptionId:\s*([0-9a-fA-F-]{36})') { $SubscriptionId = $Matches[1] }
if (-not $SubscriptionId -and $env:AVD_SUBSCRIPTION_ID) { $SubscriptionId = $env:AVD_SUBSCRIPTION_ID }
if (-not $Location -and $paramText -match "(?m)^param\s+location\s*=\s*'([^']+)'") { $Location = $Matches[1] }
if (-not $Location) { $Location = 'uksouth' }

Write-Step 'Checking Azure CLI sign-in and Bicep'
if (-not (Test-Az account show --only-show-errors).Ok) {
    Write-Host 'Not signed in - opening az login.' -ForegroundColor Yellow
    $null = Invoke-Az login --only-show-errors
}
if (-not (Test-Az bicep version --only-show-errors).Ok) { $null = Invoke-Az bicep install --only-show-errors }

if ($SubscriptionId) { $null = Invoke-Az account set --subscription $SubscriptionId --only-show-errors }
$account = Invoke-Az account show --query '{name:name,id:id}' -o json --only-show-errors | ConvertFrom-Json

Write-Host ''
Write-Host ('  Subscription : {0} ({1})' -f $account.name, $account.id)
Write-Host ('  Region       : {0}' -f $Location)
Write-Host ('  Parameters   : {0}' -f $ParameterFile)
Write-Host ('  Mode         : {0}' -f $(if ($preview) { 'what-if (preview, no changes)' } else { 'CREATE / UPDATE' }))
Write-Host ''

# ------------------------------------------------------------------ Session host plan
# Hosts are NOT part of the main (subscription) deployment. That deployment always runs
# with sessionHostCountOverride = 0, and each host is then deployed on its own from a template
# spec. A copy loop in one deployment repeats the whole session host template (scripts and
# customisation settings included) per host, which hits ARM's 4 MB DeploymentSizeExceeded
# limit at around 50-100 hosts, so per-host deployments have no batch size limit.
$paramDir = Split-Path -Parent $ParameterFile
$paramBase = [IO.Path]::GetFileNameWithoutExtension($ParameterFile)
$outputsFile = Join-Path $paramDir "$paramBase.outputs.json"

$prefix = Get-ParamValue $paramText 'sessionHostNamePrefix' 'avdsh'
$hostsRg = $null
if (Test-Path -LiteralPath $outputsFile) {
    try { $hostsRg = (Get-Content -Raw -LiteralPath $outputsFile | ConvertFrom-Json).sessionHostResourceGroup.value } catch { $hostsRg = $null }
}
if (-not $hostsRg -and $paramText -match "(?s)hosts:\s*\{\s*name:\s*'([^']*)'") { $hostsRg = $Matches[1] }
if (-not $hostsRg) {
    $hostsRg = 'rg-{0}-{1}-{2}-hosts' -f (Get-ParamValue $paramText 'workloadName' 'avd'), (Get-ParamValue $paramText 'environmentName' 'prod'), $Location
}

$existingNumbers = @()
$vmList = Test-Az vm list --resource-group $hostsRg --query '[].name' -o json --only-show-errors
if ($vmList.Ok -and $vmList.Output) {
    $pattern = '^' + [regex]::Escape($prefix) + '-(\d+)$'
    # Assign first, then loop: Windows PowerShell 5.1 sends a JSON array down the pipeline as ONE object.
    $vmNames = $vmList.Output | ConvertFrom-Json
    $existingNumbers = @(foreach ($n in $vmNames) { if ("$n" -match $pattern) { [int]$Matches[1] } }) | Sort-Object
    $existingNumbers = @($existingNumbers)
}
$highest = if ($existingNumbers.Count) { $existingNumbers[-1] } else { 0 }

$users = [int](Get-ParamValue $paramText 'targetUserCount' '1000')
$perHost = [int](Get-ParamValue $paramText 'maxSessionsPerHost' '10')
$start = [int](Get-ParamValue $paramText 'sessionHostStartIndex' '0')
$override = [int](Get-ParamValue $paramText 'sessionHostCountOverride' '-1')
$personalPool = (Get-ParamValue $paramText 'hostPoolType' 'Pooled') -eq 'Personal'
$count = if ($override -ge 0) { $override } elseif ($personalPool) { $users } else { [int][math]::Ceiling($users / $perHost) }

$skipped = @()
if ($InfraOnly) { $planned = @() }
elseif ($HostNames) {
    $planned = @(foreach ($h in $HostNames) {
            if ("$h" -match ('^' + [regex]::Escape($prefix) + '-(\d+)$')) { [int]$Matches[1] }
            else { throw "Host name '$h' does not match the prefix in the parameter file ($prefix-nnn)." }
        })
}
elseif ($AddHosts -gt 0) { $planned = @(for ($i = 1; $i -le $AddHosts; $i++) { $highest + $i }) }
else {
    # Plain run: every host the parameter file describes that does not exist yet.
    $all = @(for ($i = $start; $i -lt $start + $count; $i++) { $i + 1 })
    $planned = @($all | Where-Object { $existingNumbers -notcontains $_ })
    $skipped = @($all | Where-Object { $existingNumbers -contains $_ })
}
$plannedNames = @($planned | ForEach-Object { '{0}-{1:D3}' -f $prefix, $_ })

# The main deployment never contains hosts. Must sit beside the original so its relative
# `using` path still resolves.
$tempParamFile = Join-Path $paramDir "$paramBase.deploy-tmp.bicepparam"
[IO.File]::WriteAllText($tempParamFile, (Set-ParamValue $paramText 'sessionHostCountOverride' 0), (New-Object System.Text.UTF8Encoding($false)))
$deployParamFile = $tempParamFile

Write-Host ('  Hosts RG     : {0} ({1} existing {2}-nnn host(s){3})' -f $hostsRg, $existingNumbers.Count, $prefix, $(if ($highest) { ", highest $prefix-{0:D3}" -f $highest } else { '' }))
if ($planned.Count -eq 1) { Write-Host ('  This run     : session host {0}' -f $plannedNames[0]) }
elseif ($planned.Count -gt 1) {
    Write-Host ('  This run     : {0} session hosts, {1} to {2}, {3} at a time' -f $planned.Count, $plannedNames[0], $plannedNames[-1], $ThrottleLimit)
}
else { Write-Host '  This run     : no new session hosts (shared resources only)' }
if ($skipped.Count) { Write-Host ('  Skipped      : {0} host(s) already exist - redeploy one with -HostNames {1}-nnn' -f $skipped.Count, $prefix) }
$redeploy = @($planned | Where-Object { $existingNumbers -contains $_ })
if ($redeploy.Count) {
    Write-Host ("  Redeploying  : {0} existing host(s). Start any stopped by autoscale first, or their extensions fail." -f $redeploy.Count) -ForegroundColor Yellow
}
Write-Host ''

# ------------------------------------------------------------------ Private DNS pre-flight
# A VNet can be linked to only ONE privatelink.file.* zone. With privateDnsZoneMode = 'new' the
# template creates a zone in the storage RG and links it, which fails ("overlapping namespaces")
# if the VNet is already linked to another privatelink.file zone - e.g. a central/hub zone, or a
# leftover from an earlier attempt that used a different storage RG. Catch that before deploying.
$dnsMode = Get-ParamValue $paramText 'privateDnsZoneMode' 'new'
$fslogixOn = (Get-ParamValue $paramText 'deployFslogixStorage' 'true') -ne 'false'
$fslogixAccess = Get-ParamValue $paramText 'fslogixNetworkAccess' 'privateEndpoint'

# Service endpoint mode on an EXISTING VNet: the template doesn't modify subnets it doesn't
# own, and the storage firewall rule fails unless the subnet already has Microsoft.Storage.
if ($fslogixOn -and $fslogixAccess -eq 'serviceEndpoint' -and (Get-ParamValue $paramText 'networkMode' 'new') -eq 'existing') {
    $seSubnet = Get-ParamValue $paramText 'existingSessionHostSubnetId' ''
    Write-Step 'Checking the session host subnet has the Microsoft.Storage service endpoint'
    $sn = Test-Az network vnet subnet show --ids $seSubnet --query 'serviceEndpoints[].service' -o json --only-show-errors
    if (-not $sn.Ok) { throw "Could not read subnet $seSubnet - check the ID and your access." }
    $parsedSe = $sn.Output | ConvertFrom-Json
    $services = @(foreach ($x in $parsedSe) { "$x" })
    if ($services -notcontains 'Microsoft.Storage' -and $services -notcontains 'Microsoft.Storage.Global') {
        $all = @($services) + 'Microsoft.Storage'
        Write-Host ''
        Write-Host 'The session host subnet does not have the Microsoft.Storage service endpoint.' -ForegroundColor Red
        Write-Host 'Add it (keeps the endpoints it already has; no downtime for existing traffic):' -ForegroundColor Yellow
        Write-Host "  az network vnet subnet update --ids $seSubnet --service-endpoints $($all -join ' ')"
        if ($tempParamFile) { Remove-Item -LiteralPath $tempParamFile -ErrorAction SilentlyContinue }
        throw 'Service endpoint missing - see above. Nothing was deployed.'
    }
    Write-Host '  ok - Microsoft.Storage service endpoint present'
}

if ($fslogixOn -and $fslogixAccess -eq 'privateEndpoint' -and $dnsMode -eq 'new') {
    $workload = Get-ParamValue $paramText 'workloadName' 'avd'
    $envName = Get-ParamValue $paramText 'environmentName' 'prod'
    $suffix = "$workload-$envName-$Location"
    $subId = $account.id
    $vnetId = $null
    if ((Get-ParamValue $paramText 'networkMode' 'new') -eq 'existing') {
        $subnetId = Get-ParamValue $paramText 'existingSessionHostSubnetId' ''
        $ix = $subnetId.ToLowerInvariant().IndexOf('/subnets/')
        if ($ix -gt 0) { $vnetId = $subnetId.Substring(0, $ix) }
    }
    else {
        $netRg = if ($paramText -match "(?s)network:\s*\{\s*name:\s*'([^']+)'") { $Matches[1] } else { "rg-$suffix-network" }
        $vnetName = Get-ParamValue $paramText 'vnetName' ''
        if (-not $vnetName) { $vnetName = "vnet-$suffix" }
        $vnetId = "/subscriptions/$subId/resourceGroups/$netRg/providers/Microsoft.Network/virtualNetworks/$vnetName"
    }
    $storageRg = if ($paramText -match "(?s)storage:\s*\{\s*name:\s*'([^']+)'") { $Matches[1] } else { "rg-$suffix-storage" }
    $ourZone = "/subscriptions/$subId/resourceGroups/$storageRg/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net".ToLowerInvariant()

    if ($vnetId) {
        Write-Step 'Checking private DNS zone links on the VNet'
        $linkIds = @()
        if ((Test-Az extension show --name resource-graph --only-show-errors).Ok) {
            $kql = "resources | where type =~ 'microsoft.network/privatednszones/virtualnetworklinks' | where id contains '/privatednszones/privatelink.file.' | where tolower(tostring(properties.virtualNetwork.id)) == '$($vnetId.ToLowerInvariant())' | project id"
            $g = Test-Az graph query -q $kql --first 100 --query 'data[].id' -o json --only-show-errors
            if ($g.Ok -and $g.Output) { $parsedIds = $g.Output | ConvertFrom-Json; $linkIds = @(foreach ($x in $parsedIds) { "$x" }) }
        }
        else {
            # Without the resource-graph extension only this subscription can be searched.
            $z = Test-Az network private-dns zone list --query "[?starts_with(name, 'privatelink.file.')].{rg:resourceGroup, name:name}" -o json --only-show-errors
            if ($z.Ok -and $z.Output) {
                $zones = $z.Output | ConvertFrom-Json
                foreach ($zone in $zones) {
                    $l = Test-Az network private-dns link vnet list --resource-group $zone.rg --zone-name $zone.name --query '[].{id:id, vnet:virtualNetwork.id}' -o json --only-show-errors
                    if ($l.Ok -and $l.Output) {
                        $links = $l.Output | ConvertFrom-Json
                        foreach ($link in $links) { if ("$($link.vnet)" -ieq $vnetId) { $linkIds += "$($link.id)" } }
                    }
                }
            }
        }
        $conflicts = @(foreach ($id in $linkIds) {
            $zoneId = $id.Substring(0, $id.ToLowerInvariant().IndexOf('/virtualnetworklinks/'))
            if ($zoneId.ToLowerInvariant() -ne $ourZone) { $zoneId }
        }) | Select-Object -Unique
        $conflicts = @($conflicts)
        if ($conflicts.Count) {
            Write-Host ''
            Write-Host 'The VNet is already linked to a privatelink.file DNS zone:' -ForegroundColor Red
            foreach ($c in $conflicts) { Write-Host "  $c" -ForegroundColor Red }
            Write-Host ''
            Write-Host "privateDnsZoneMode = 'new' would create a second zone and Azure would reject the link" -ForegroundColor Yellow
            Write-Host '("overlapping namespaces"). Use the existing zone instead - set in the parameter file:' -ForegroundColor Yellow
            Write-Host "  param privateDnsZoneMode = 'existing'"
            Write-Host "  param existingFilePrivateDnsZoneId = '$($conflicts[0])'"
            Write-Host 'If that zone is a leftover from an earlier attempt, you can instead delete its VNet link.' -ForegroundColor Yellow
            if ($tempParamFile) { Remove-Item -LiteralPath $tempParamFile -ErrorAction SilentlyContinue }
            throw 'Private DNS zone conflict - see above. Nothing was deployed.'
        }
        Write-Host '  ok - no conflicting privatelink.file zone linked'
    }
}

# ------------------------------------------------------------------ Custom image pre-flight
# imageReference = { id: '<Compute Gallery image definition or version ID>' }
if ($paramText -match "(?s)imageReference\s*=\s*\{\s*id:\s*'([^']+)'") {
    $imageId = $Matches[1]
    $secType = Get-ParamValue $paramText 'vmSecurityType' 'TrustedLaunch'
    Write-Step 'Checking the custom image'
    $imgProblems = @()
    if ($imageId -notmatch '/providers/Microsoft\.Compute/galleries/([^/]+)/images/([^/]+)(/versions/([^/]+))?$') {
        $imgProblems += 'imageReference.id is not a Compute Gallery image definition or version. Managed images do not support Trusted Launch - use a gallery, or set vmSecurityType = ''Standard''.'
    }
    else {
        $gallery = $Matches[1]; $definition = $Matches[2]; $version = $Matches[4]
        $imgRg = ($imageId -split '/')[4]; $imgSub = ($imageId -split '/')[2]
        $defId = ($imageId -split '/versions/')[0]
        $def = $null
        $d = Test-Az sig image-definition show --ids $defId --query '{gen:hyperVGeneration, state:osState, features:features}' -o json --only-show-errors
        if ($d.Ok -and $d.Output) { $def = $d.Output | ConvertFrom-Json }
        if (-not $def) { $imgProblems += "Image definition not found or not readable: $defId (the deploying identity needs Reader on the gallery)." }
        else {
            $feat = @(foreach ($f in $def.features) { $f })
            $st = "$((@($feat | Where-Object { $_.name -eq 'SecurityType' }) | Select-Object -First 1).value)"
            Write-Host ("  definition: {0}, {1}, security type {2}" -f $def.gen, $def.state, $(if ($st) { $st } else { 'Standard' }))
            if ("$($def.state)" -ne 'Generalized') { $imgProblems += 'The image definition is Specialized - session hosts need a Generalized (sysprepped) image.' }
            if ($secType -eq 'TrustedLaunch') {
                if ("$($def.gen)" -ne 'V2') { $imgProblems += 'Trusted Launch needs a Gen2 image - set vmSecurityType = ''Standard'' for this Gen1 image.' }
                elseif ($st -notmatch '^TrustedLaunch') { $imgProblems += "The definition's security type is '$(if ($st) { $st } else { 'Standard' })' - Trusted Launch needs TrustedLaunchSupported or TrustedLaunch. Recreate the definition, or set vmSecurityType = 'Standard'." }
            }
            elseif ($st -eq 'TrustedLaunch') { $imgProblems += 'The definition is TrustedLaunch-only - set vmSecurityType = ''TrustedLaunch''.' }
        }
        $vq = '[].{name:name, regions:publishingProfile.targetRegions[].name, exclude:publishingProfile.excludeFromLatest, state:provisioningState}'
        $vl = Test-Az sig image-version list --subscription $imgSub --resource-group $imgRg --gallery-name $gallery --gallery-image-definition $definition --query $vq -o json --only-show-errors
        if ($vl.Ok -and $vl.Output) {
            $parsedVersions = $vl.Output | ConvertFrom-Json
            $versions = @(foreach ($v in $parsedVersions) { $v })
            # Wrap the whole if in @(): a single PSCustomObject has no .Count in Windows PowerShell 5.1.
            $pick = @(if ($version) { $versions | Where-Object { $_.name -eq $version } } else { $versions | Where-Object { -not $_.exclude -and $_.state -eq 'Succeeded' } | Sort-Object { [version]("$($_.name)") } | Select-Object -Last 1 })
            if (-not $pick.Count) { $imgProblems += $(if ($version) { "Image version $version not found." } else { 'No usable image version (all excluded from latest or not Succeeded).' }) }
            else {
                $regions = @(foreach ($r in $pick[0].regions) { ("$r" -replace '\s', '').ToLowerInvariant() })
                Write-Host ("  version: {0} (replicated to {1})" -f $pick[0].name, ($regions -join ', '))
                if ($regions -notcontains $Location.ToLowerInvariant()) { $imgProblems += "Image version $($pick[0].name) is not replicated to $Location - add it as a target region in the gallery." }
            }
        }
        else { $imgProblems += 'Could not list image versions (permissions?).' }
    }
    if ($imgProblems.Count) {
        foreach ($pmsg in $imgProblems) { Write-Host "  ! $pmsg" -ForegroundColor Red }
        if ($tempParamFile) { Remove-Item -LiteralPath $tempParamFile -ErrorAction SilentlyContinue }
        throw 'Custom image problem - see above. Nothing was deployed.'
    }
    Write-Host '  ok - image is usable'
}

# ------------------------------------------------------------------ Password
$setPassword = $false
if (-not $env:AVD_LOCAL_ADMIN_PASSWORD) {
    $secure = Read-Host -AsSecureString 'Session host local admin password (12+ chars, 3 of: upper, lower, digit, symbol)'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $env:AVD_LOCAL_ADMIN_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $setPassword = $true
    if ($env:AVD_LOCAL_ADMIN_PASSWORD.Length -lt 12) {
        if ($tempParamFile) { Remove-Item -LiteralPath $tempParamFile -ErrorAction SilentlyContinue }
        Remove-Item Env:\AVD_LOCAL_ADMIN_PASSWORD
        throw 'Password must be at least 12 characters (Azure requirement).'
    }
}

try {
    # -------------------------------------------------------------- Providers
    Write-Step 'Checking resource providers'
    foreach ($rp in 'Microsoft.DesktopVirtualization', 'Microsoft.Compute', 'Microsoft.Network',
        'Microsoft.Storage', 'Microsoft.OperationalInsights', 'Microsoft.Insights') {
        $state = (Test-Az provider show --namespace $rp --query registrationState -o tsv --only-show-errors).Output
        if ($state -ne 'Registered') {
            Write-Host "  registering $rp"
            $null = Invoke-Az provider register --namespace $rp --only-show-errors
        }
    }

    $common = @('--name', $DeploymentName, '--location', $Location,
        '--template-file', $template, '--parameters', $deployParamFile, '--only-show-errors')

    if ($preview) {
        Write-Step 'Running what-if for the shared resources (no changes will be made)'
        & az deployment sub what-if @common
        if ($LASTEXITCODE -ne 0) { throw 'what-if failed - see the error above.' }
        Write-Host ''
        if ($planned.Count) {
            Write-Host ("Then {0} session host(s) would be deployed, one deployment each: {1}" -f $planned.Count, $(if ($planned.Count -le 6) { $plannedNames -join ', ' } else { "$($plannedNames[0]) ... $($plannedNames[-1])" }))
        }
        Write-Host 'Preview complete. Run again without -WhatIf to deploy.' -ForegroundColor Green
        return
    }

    if (-not $Force) {
        $answer = Read-Host "Deploy to '$($account.name)'? Type yes to continue"
        if ($answer -ne 'yes') { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
    }

    Write-Step "Deploying shared resources ($DeploymentName) - usually 5-15 minutes"
    $result = & az deployment sub create @common --query 'properties.outputs' -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Deployment failed. Details: az deployment sub show --name $DeploymentName  (or the subscription's Deployments blade in the portal)."
    }

    $outputsJson = ($result -join "`n")
    $outputs = $outputsJson | ConvertFrom-Json
    [IO.File]::WriteAllText($outputsFile, $outputsJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ''
    Write-Host 'Shared resources deployed.' -ForegroundColor Green
    foreach ($p in $outputs.PSObject.Properties) {
        $v = $p.Value.value
        if ($v -is [array]) { $v = $v -join ', ' }
        if ($v -is [System.Management.Automation.PSCustomObject]) { continue }
        Write-Host ('  {0,-28} {1}' -f $p.Name, $v)
    }
    Write-Host ''
    Write-Host "Outputs saved to $outputsFile"

    # Personal-pool automation (deployPoolAutomation = true): publish runbook, config, schedule.
    if ($outputs.PSObject.Properties['automationAccountName'] -and "$($outputs.automationAccountName.value)") {
        & (Join-Path $PSScriptRoot 'Publish-AvdPoolAutomation.ps1') -ParameterFile $ParameterFile
    }

    # The name users see in Windows App is the friendlyName of the desktop resource inside
    # the app group ("SessionDesktop"). That resource is read-only in ARM templates, so set
    # it here - the documented route is an update (PATCH), e.g. Update-AzWvdDesktop.
    $agId = if ($outputs.PSObject.Properties['desktopAppGroupId']) { "$($outputs.desktopAppGroupId.value)" } else { '' }
    $friendly = if ($outputs.PSObject.Properties['desktopFriendlyName']) { "$($outputs.desktopFriendlyName.value)" } else { '' }
    if ($agId -and $friendly) {
        $desk = Test-Az rest --method get --url "https://management.azure.com$agId/desktops?api-version=2024-04-03" --query 'value[0].name' -o tsv --only-show-errors
        $deskName = if ($desk.Ok -and $desk.Output) { ($desk.Output -split '/')[-1] } else { 'SessionDesktop' }
        $tmpBody = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($tmpBody, (@{ properties = @{ friendlyName = $friendly } } | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
            $pr = Test-Az rest --method patch --url "https://management.azure.com$agId/desktops/$($deskName)?api-version=2024-04-03" --headers 'Content-Type=application/json' --body "@$tmpBody" --only-show-errors
            if ($pr.Ok) { Write-Host "Desktop name in Windows App set to '$friendly' (users see it after their feed refreshes)." -ForegroundColor Green }
            else { Write-Host "Could not set the desktop name - set it with: Update-AzWvdDesktop -ResourceGroupName <rg> -ApplicationGroupName <app group> -Name $deskName -FriendlyName '$friendly'" -ForegroundColor Yellow }
        }
        finally { Remove-Item -LiteralPath $tmpBody -ErrorAction SilentlyContinue }
    }

    # -------------------------------------------------------------- Session hosts
    if ($planned.Count) {
        $shd = if ($outputs.PSObject.Properties['sessionHostDeployment']) { $outputs.sessionHostDeployment.value } else { $null }
        if (-not $shd) { throw 'The deployment returned no sessionHostDeployment output - is infra/main.bicep up to date?' }
        $hostsRg = "$($shd.hostsResourceGroup)"
        $zones = @($shd.zones | Where-Object { $_ })

        Write-Step "Publishing the session host template spec (avd-sessionhost 1.0 in $($shd.serviceResourceGroup))"
        $shTemplate = Join-Path (Join-Path (Join-Path $repoRoot 'infra') 'modules') 'sessionhost.bicep'
        $null = Invoke-Az ts create --name avd-sessionhost --version '1.0' --resource-group "$($shd.serviceResourceGroup)" --location "$($shd.location)" --template-file $shTemplate --description 'AVD session host (Deploy-Avd.ps1 and the pool maintenance runbook)' --yes --only-show-errors
        $tsId = (Invoke-Az ts show --name avd-sessionhost --version '1.0' --resource-group "$($shd.serviceResourceGroup)" --query id -o tsv --only-show-errors).Trim()

        # One registration token for the whole run, valid long enough for every wave
        # (about 90 minutes per wave of $ThrottleLimit hosts, plus margin; Azure allows up to 30 days).
        # Each host reads the token when its deployment starts, so it is set once, before any host.
        $waves = [math]::Ceiling($planned.Count / $ThrottleLimit)
        $tokenHours = [math]::Min(27 * 24, [math]::Max(8, $waves * 1.5 + 2))
        $expiry = (Get-Date).ToUniversalTime().AddHours($tokenHours).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $tokenBody = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($tokenBody, (@{ properties = @{ registrationInfo = @{ expirationTime = $expiry; registrationTokenOperation = 'Update' } } } | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
            $null = Invoke-Az rest --method patch --url "https://management.azure.com$($shd.hostPoolId)?api-version=2024-04-03" --headers 'Content-Type=application/json' --body "@$tokenBody" --only-show-errors
        }
        finally { Remove-Item -LiteralPath $tokenBody -ErrorAction SilentlyContinue }
        Write-Host "  registration token valid until $expiry"

        Write-Step ("Deploying {0} session host(s), {1} at a time - each takes about 30-60 minutes" -f $planned.Count, $ThrottleLimit)
        Write-Host '  Closing this window does not stop deployments already started; re-run to pick up the rest.'
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmm')
        $queue = New-Object System.Collections.Generic.Queue[int]
        foreach ($n in $planned) { $queue.Enqueue($n) }
        $running = @{}    # deployment name -> vm name
        $succeeded = New-Object System.Collections.Generic.List[string]
        $failed = New-Object System.Collections.Generic.List[string]
        $pollSeconds = if ($env:AVD_DEPLOY_POLL_SECONDS) { [int]$env:AVD_DEPLOY_POLL_SECONDS } else { 60 }

        while ($queue.Count -or $running.Count) {
            while ($queue.Count -and $running.Count -lt $ThrottleLimit) {
                $num = $queue.Dequeue()
                $vm = '{0}-{1:D3}' -f $prefix, $num
                $depName = "avd-host-$vm-$stamp"
                $hp = [ordered]@{}
                foreach ($p in $shd.sessionHostParameters.PSObject.Properties) { $hp[$p.Name] = @{ value = $p.Value } }
                $hp['vmName'] = @{ value = $vm }
                $hp['zone'] = @{ value = $(if ($zones.Count) { "$($zones[($num - 1) % $zones.Count])" } else { '' }) }
                $hp['adminPassword'] = @{ value = $env:AVD_LOCAL_ADMIN_PASSWORD }
                # Holds the password: written, handed to az, deleted straight away.
                $hpFile = [IO.Path]::GetTempFileName()
                try {
                    [IO.File]::WriteAllText($hpFile, (@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $hp } | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
                    $began = Test-Az deployment group create --resource-group $hostsRg --name $depName --template-spec $tsId --parameters "@$hpFile" --no-wait --only-show-errors
                }
                finally { Remove-Item -LiteralPath $hpFile -ErrorAction SilentlyContinue }
                if ($began.Ok) { $running[$depName] = $vm; Write-Host "  started $vm" }
                else { $failed.Add($vm); Write-Host "  FAILED to start $vm (az deployment group create refused it - check quota and the hosts resource group)" -ForegroundColor Red }
            }
            if (-not $running.Count) { break }
            if ($pollSeconds) { Start-Sleep -Seconds $pollSeconds }
            $st = Test-Az deployment group list --resource-group $hostsRg --query "[?starts_with(name, 'avd-host-')].{n:name, s:properties.provisioningState}" -o json --only-show-errors
            if (-not $st.Ok -or -not $st.Output) { continue }
            $states = $st.Output | ConvertFrom-Json
            foreach ($d in $states) {
                if (-not $running.ContainsKey("$($d.n)")) { continue }
                $vm = $running["$($d.n)"]
                if ($d.s -eq 'Succeeded') { $succeeded.Add($vm); $running.Remove("$($d.n)"); Write-Host "  done    $vm" -ForegroundColor Green }
                elseif ($d.s -in 'Failed', 'Canceled') {
                    $failed.Add($vm); $running.Remove("$($d.n)")
                    Write-Host "  FAILED  $vm - details: az deployment group show -g $hostsRg -n $($d.n) --query properties.error" -ForegroundColor Red
                }
            }
            Write-Host ("  {0:HH:mm}  {1} done, {2} failed, {3} running, {4} queued" -f (Get-Date), $succeeded.Count, $failed.Count, $running.Count, $queue.Count)
        }

        Write-Host ''
        Write-Host ("Session hosts: {0} deployed, {1} failed." -f $succeeded.Count, $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Yellow' } else { 'Green' })
        if ($failed.Count) {
            $failedNames = @($failed | Sort-Object)
            Write-Host 'Fix the cause (quota, subnet IPs, image), then retry just those hosts:' -ForegroundColor Yellow
            Write-Host ("  .\scripts\Deploy-Avd.ps1 -ParameterFile $ParameterFile -HostNames {0}" -f ($failedNames -join ','))
            throw "$($failed.Count) session host(s) failed."
        }
    }
    Write-Host 'Next: the post-deployment steps in README.md (storage admin consent, CA exclusion, NTFS permissions).'
}
finally {
    if ($setPassword) { Remove-Item Env:\AVD_LOCAL_ADMIN_PASSWORD -ErrorAction SilentlyContinue }
    if ($tempParamFile) { Remove-Item -LiteralPath $tempParamFile -ErrorAction SilentlyContinue }
}
