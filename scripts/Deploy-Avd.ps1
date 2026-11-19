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
    * -WhatIf runs `az deployment sub what-if`; otherwise you are asked to confirm before
      `az deployment sub create` (skip with -Force).
    * Updating an existing deployment:
        -AddHosts N   finds the highest existing host number (e.g. avdsh-100) and deploys
                      N new hosts after it (avdsh-101...). Existing hosts are not touched.
        -InfraOnly    deploys everything except session hosts (host pool settings, scaling
                      plan, FSLogix storage, network, RBAC). Existing hosts are not touched.
      Without either, the script warns if the run would redeploy hosts that already exist
      (which re-runs their extensions and fails on hosts autoscale has stopped).
    * Saves the deployment outputs to <param file name>.outputs.json next to the parameter
      file (used by Update-SessionHostConfig.ps1).

    Requires the Azure CLI (winget install Microsoft.AzureCLI) and an `az login`.

.EXAMPLE
    .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -WhatIf

.EXAMPLE
    .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam

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

    [ValidateRange(0, 1000)]
    [int] $AddHosts = 0,

    [switch] $InfraOnly,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
if ($AddHosts -gt 0 -and $InfraOnly) { throw 'Use either -AddHosts or -InfraOnly, not both.' }
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

$deployParamFile = $ParameterFile
$tempParamFile = $null
if ($InfraOnly -or $AddHosts -gt 0) {
    if ($InfraOnly) { $start = 0; $count = 0 } else { $start = $highest; $count = $AddHosts }
    $newText = Set-ParamValue $paramText 'sessionHostStartIndex' $start
    $newText = Set-ParamValue $newText 'sessionHostCountOverride' $count
    # Must sit beside the original so its relative `using` path still resolves.
    $tempParamFile = Join-Path $paramDir "$paramBase.deploy-tmp.bicepparam"
    [IO.File]::WriteAllText($tempParamFile, $newText, (New-Object System.Text.UTF8Encoding($false)))
    $deployParamFile = $tempParamFile
}

$planned = @(); for ($i = $start; $i -lt $start + $count; $i++) { $planned += ($i + 1) }
$overlap = @($planned | Where-Object { $existingNumbers -contains $_ })
Write-Host ('  Hosts RG     : {0} ({1} existing {2}-nnn host(s){3})' -f $hostsRg, $existingNumbers.Count, $prefix, $(if ($highest) { ", highest $prefix-{0:D3}" -f $highest } else { '' }))
if ($count -gt 0) {
    Write-Host ('  This run     : session hosts {0}-{1:D3} to {0}-{2:D3} ({3})' -f $prefix, $planned[0], $planned[-1], $count)
}
else {
    Write-Host '  This run     : no session hosts (shared resources only)'
}
Write-Host ''

# ARM allows at most 800 resources per deployment; each host is one nested deployment.
$maxHostsPerRun = 400
if ($count -gt $maxHostsPerRun) {
    Write-Host ("This run would deploy {0} hosts. One deployment can create at most about {1} reliably" -f $count, $maxHostsPerRun) -ForegroundColor Yellow
    Write-Host '(ARM limit: 800 resources per deployment). Deploy in batches instead, e.g.:' -ForegroundColor Yellow
    Write-Host "  .\scripts\Deploy-Avd.ps1 -ParameterFile $ParameterFile -AddHosts $maxHostsPerRun    (repeat until done)"
    if ($tempParamFile) { Remove-Item -LiteralPath $tempParamFile -ErrorAction SilentlyContinue }
    throw "Too many hosts for one run ($count)."
}

if ($overlap.Count) {
    Write-Host ("WARNING: this run would redeploy {0} host(s) that already exist ({1}-{2:D3} to {1}-{3:D3})." -f $overlap.Count, $prefix, $overlap[0], $overlap[-1]) -ForegroundColor Yellow
    Write-Host '  Their extensions would re-run with a new registration token, and the run fails on any host' -ForegroundColor Yellow
    Write-Host '  autoscale has stopped. To add hosts use -AddHosts <n>; to change shared settings use -InfraOnly.' -ForegroundColor Yellow
    Write-Host ''
    if (-not $preview -and -not $Force) {
        $answer = Read-Host 'Type redeploy to continue anyway'
        if ($answer -ne 'redeploy') {
            if ($tempParamFile) { Remove-Item -LiteralPath $tempParamFile -ErrorAction SilentlyContinue }
            Write-Host 'Cancelled.' -ForegroundColor Yellow
            return
        }
    }
}

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
        Write-Step 'Running what-if (no changes will be made)'
        & az deployment sub what-if @common
        if ($LASTEXITCODE -ne 0) { throw 'what-if failed - see the error above.' }
        Write-Host ''
        Write-Host 'Preview complete. Run again without -WhatIf to deploy.' -ForegroundColor Green
        return
    }

    if (-not $Force) {
        $answer = Read-Host "Deploy to '$($account.name)'? Type yes to continue"
        if ($answer -ne 'yes') { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
    }

    Write-Step "Deploying ($DeploymentName) - a full 100-host run takes roughly 45-90 minutes"
    $result = & az deployment sub create @common --query 'properties.outputs' -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Deployment failed. Details: az deployment sub show --name $DeploymentName  (or the subscription's Deployments blade in the portal)."
    }

    $outputsJson = ($result -join "`n")
    $outputs = $outputsJson | ConvertFrom-Json
    [IO.File]::WriteAllText($outputsFile, $outputsJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ''
    Write-Host 'Deployment succeeded.' -ForegroundColor Green
    foreach ($p in $outputs.PSObject.Properties) {
        $v = $p.Value.value
        if ($v -is [array]) { $v = $v -join ', ' }
        Write-Host ('  {0,-28} {1}' -f $p.Name, $v)
    }
    Write-Host ''
    Write-Host "Outputs saved to $outputsFile"
    Write-Host 'Next: the post-deployment steps in README.md (storage admin consent, CA exclusion, NTFS permissions).'
}
finally {
    if ($setPassword) { Remove-Item Env:\AVD_LOCAL_ADMIN_PASSWORD -ErrorAction SilentlyContinue }
    if ($tempParamFile) { Remove-Item -LiteralPath $tempParamFile -ErrorAction SilentlyContinue }
}
