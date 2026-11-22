<#
.SYNOPSIS
    Re-applies the session host configuration (FSLogix + Entra Kerberos) to EXISTING hosts.

.DESCRIPTION
    New hosts are configured by the deployment itself. Use this script when you change the
    configuration after hosts already exist - for example you enabled FSLogix storage with
    `Deploy-Avd.ps1 -InfraOnly`, or changed the profile size.

    There is no Intune or Group Policy in this design (Entra joined, no Intune), so the script
    pushes infra/scripts/Configure-SessionHost.ps1 to each VM as the same managed run command
    ("Configure-SessionHost") the template uses, then waits for the results.

    Settings come from the deployment outputs that Deploy-Avd.ps1 saves next to the parameter
    file (<name>.outputs.json): the FSLogix UNC path and the session host resource group.

    Stopped (deallocated) hosts cannot run commands. By default they are listed and skipped;
    -IncludeStopped starts them first (autoscale will power them down again later).

    Changes apply at each user's NEXT sign-in. Existing sessions are unaffected.

.EXAMPLE
    .\scripts\Update-SessionHostConfig.ps1 -ParameterFile .\infra\params\prod.bicepparam -IncludeStopped

.EXAMPLE
    # Only two hosts, explicit share path
    .\scripts\Update-SessionHostConfig.ps1 -ResourceGroup rg-avd-prod-uksouth-hosts `
        -VhdLocation '\\stfslogixabc.file.core.windows.net\profiles' -VmName avdsh-001, avdsh-002
#>
[CmdletBinding()]
param(
    [string] $ParameterFile,
    [string] $ResourceGroup,
    [string] $VhdLocation,
    [int] $ProfileSizeMB = 0,
    [string[]] $VmName,
    [switch] $IncludeStopped,
    [switch] $DisableFslogix,
    [switch] $Customize,
    [int] $TimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'
if ($Customize -and -not $PSBoundParameters.ContainsKey('TimeoutMinutes')) { $TimeoutMinutes = 90 }
$repoRoot = Split-Path -Parent $PSScriptRoot
$configScript = Join-Path (Join-Path (Join-Path $repoRoot 'infra') 'scripts') 'Configure-SessionHost.ps1'
$customizeScript = Join-Path (Join-Path (Join-Path $repoRoot 'infra') 'scripts') 'Customize-SessionHost.ps1'
$customizationsFile = Join-Path (Join-Path (Join-Path $repoRoot 'infra') 'customizations') 'customizations.json'

function Test-Az {
    $azArgs = $args
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & az @azArgs 2>$null
        return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = (($out | Out-String).Trim()) }
    }
    finally { $ErrorActionPreference = $eap }
}
function Write-Step([string] $Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

# ------------------------------------------------------------------ Resolve settings
if ($ParameterFile) {
    $ParameterFile = (Resolve-Path -LiteralPath $ParameterFile).Path
    $paramText = Get-Content -Raw -LiteralPath $ParameterFile
    $outputsFile = Join-Path (Split-Path -Parent $ParameterFile) (([IO.Path]::GetFileNameWithoutExtension($ParameterFile)) + '.outputs.json')
    if (Test-Path -LiteralPath $outputsFile) {
        $outputs = Get-Content -Raw -LiteralPath $outputsFile | ConvertFrom-Json
        if (-not $ResourceGroup) { $ResourceGroup = $outputs.sessionHostResourceGroup.value }
        if (-not $VhdLocation) { $VhdLocation = $outputs.fslogixUncPath.value }
    }
    else {
        Write-Host "No $outputsFile found - run Deploy-Avd.ps1 first, or pass -ResourceGroup and -VhdLocation." -ForegroundColor Yellow
    }
    if ($ProfileSizeMB -le 0 -and $paramText -match '(?m)^param\s+fslogixProfileSizeMB\s*=\s*(\d+)') { $ProfileSizeMB = [int]$Matches[1] }
    if ($paramText -match '(?m)^//\s*subscriptionId:\s*([0-9a-fA-F-]{36})') {
        $null = Test-Az account set --subscription $Matches[1] --only-show-errors
    }
}
if ($ProfileSizeMB -le 0) { $ProfileSizeMB = 30000 }
if (-not $ResourceGroup) { throw 'Session host resource group unknown - pass -ResourceGroup.' }
$fslogix = -not $DisableFslogix
if ($Customize) { $fslogix = $false }   # -Customize pushes only the customisation script
if ($fslogix -and -not $VhdLocation) {
    throw 'FSLogix share path unknown (deployment outputs have no fslogixUncPath). Deploy FSLogix storage first, pass -VhdLocation, or use -DisableFslogix.'
}

Write-Host ''
Write-Host "  Resource group : $ResourceGroup"
if ($Customize) { Write-Host "  Pushing        : customisation (optimisation, hardening, apps) from $customizationsFile" }
else { Write-Host ('  FSLogix        : {0}' -f $(if ($fslogix) { "$VhdLocation ($ProfileSizeMB MB max)" } else { 'not configured (Kerberos settings only)' })) }
Write-Host ''

# ------------------------------------------------------------------ Hosts
Write-Step 'Listing session hosts'
$list = Test-Az vm list --resource-group $ResourceGroup --show-details --query '[].{name:name, power:powerState}' -o json --only-show-errors
if (-not $list.Ok) { throw "Could not list VMs in $ResourceGroup (signed in? right subscription?)." }
# Assign first, then enumerate: Windows PowerShell 5.1 emits a JSON array as ONE pipeline object.
$parsed = $list.Output | ConvertFrom-Json
$vms = @(foreach ($v in $parsed) { $v })
if ($VmName) { $vms = @($vms | Where-Object { $VmName -contains $_.name }) }
if (-not $vms.Count) { throw 'No matching VMs found.' }

$running = @($vms | Where-Object { $_.power -eq 'VM running' } | ForEach-Object { $_.name })
$stopped = @($vms | Where-Object { $_.power -ne 'VM running' } | ForEach-Object { $_.name })
Write-Host ("  {0} running, {1} not running" -f $running.Count, $stopped.Count)

if ($stopped.Count) {
    if ($IncludeStopped) {
        Write-Step "Starting $($stopped.Count) stopped host(s)"
        foreach ($n in $stopped) { $null = Test-Az vm start --resource-group $ResourceGroup --name $n --no-wait --only-show-errors }
        foreach ($n in $stopped) {
            $w = Test-Az vm wait --resource-group $ResourceGroup --name $n --custom "instanceView.statuses[?code=='PowerState/running']" --timeout 900 --only-show-errors
            if ($w.Ok) { $running += $n } else { Write-Host "  could not start $n - skipped" -ForegroundColor Yellow }
        }
        $stopped = @($stopped | Where-Object { $running -notcontains $_ })
    }
    else {
        Write-Host ("  Skipping stopped hosts (re-run with -IncludeStopped): {0}" -f ($stopped -join ', ')) -ForegroundColor Yellow
    }
}
if (-not $running.Count) { throw 'No running hosts to configure.' }

# ------------------------------------------------------------------ Push run command
Write-Step "Applying configuration to $($running.Count) host(s)"
if ($Customize) {
    # Same JSON the template compiles in, so re-applying matches what new hosts get.
    $json = (Get-Content -Raw -LiteralPath $customizationsFile | ConvertFrom-Json | ConvertTo-Json -Depth 10 -Compress)
    $parameters = @("ConfigBase64=$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))")
    $commandName = 'Customize-SessionHost'; $scriptPath = $customizeScript; $timeout = 5400
}
else {
    $parameters = @("FslogixEnabled=$fslogix", "VhdLocation=$(if ($fslogix) { $VhdLocation } else { '' })", "ProfileSizeMB=$ProfileSizeMB")
    $commandName = 'Configure-SessionHost'; $scriptPath = $configScript; $timeout = 1800
}
$started = @()
foreach ($n in $running) {
    $r = Test-Az vm run-command create --resource-group $ResourceGroup --vm-name $n --name $commandName `
        --script "@$scriptPath" --parameters @parameters --timeout-in-seconds $timeout --no-wait --only-show-errors
    if ($r.Ok) { $started += $n; Write-Host "  queued $n" } else { Write-Host "  FAILED to queue $n" -ForegroundColor Red }
}

Write-Step 'Waiting for results'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$results = @{}
while ($started.Count -and (Get-Date) -lt $deadline) {
    foreach ($n in @($started)) {
        $s = Test-Az vm run-command show --resource-group $ResourceGroup --vm-name $n --name $commandName --instance-view --query 'instanceView.executionState' -o tsv --only-show-errors
        if ($s.Ok -and $s.Output -in @('Succeeded', 'Failed', 'TimedOut', 'Canceled')) {
            $results[$n] = $s.Output
            $started = @($started | Where-Object { $_ -ne $n })
        }
    }
    if ($started.Count) { Start-Sleep -Seconds 15 }
}
foreach ($n in $started) { $results[$n] = 'Unknown (still running at timeout)' }

# What the script itself reported. "Succeeded" only means the run command ran; the script's
# exit code and log say whether each step worked (a step that fails exits 1).
$outputs = @{}
foreach ($n in @($results.Keys)) {
    if ($results[$n] -notin @('Succeeded', 'Failed')) { continue }
    $iv = Test-Az vm run-command show --resource-group $ResourceGroup --vm-name $n --name $commandName --instance-view --query '{exit:instanceView.exitCode, output:instanceView.output, error:instanceView.error}' -o json --only-show-errors
    $ivObj = $null
    if ($iv.Ok -and $iv.Output) { try { $ivObj = $iv.Output | ConvertFrom-Json } catch { $ivObj = $null } }
    if (-not $ivObj) { continue }
    $outputs[$n] = "$($ivObj.output)`n$($ivObj.error)"
    if ($null -ne $ivObj.exit -and "$($ivObj.exit)" -ne '' -and [int]$ivObj.exit -ne 0) { $results[$n] = "Failed (script exit code $($ivObj.exit))" }
}

Write-Host ''
$failed = 0
foreach ($k in ($results.Keys | Sort-Object)) {
    $colour = if ($results[$k] -eq 'Succeeded') { 'Green' } else { $failed++; 'Red' }
    Write-Host ('  {0,-20} {1}' -f $k, $results[$k]) -ForegroundColor $colour
}
foreach ($n in $stopped) { Write-Host ('  {0,-20} skipped (stopped)' -f $n) -ForegroundColor Yellow }
# Host output: everything for a few hosts, otherwise just problems and status lines.
$showAll = $outputs.Count -le 3
foreach ($k in ($outputs.Keys | Sort-Object)) {
    $lines = @("$($outputs[$k])" -split "`r?`n" | Where-Object { $_.Trim() })
    if (-not $showAll) { $lines = @($lines | Where-Object { $_ -match 'FAILED|NOTE|not installed|still installed|exit [1-9]' }) }
    if (-not $lines.Count) { continue }
    Write-Host ''
    Write-Host "  --- $k ---"
    foreach ($l in $lines) { Write-Host "  $l" -ForegroundColor $(if ($l -match 'FAILED') { 'Red' } elseif ($l -match 'NOTE|WARNING') { 'Yellow' } else { 'Gray' }) }
}
Write-Host ''
if ($failed) {
    Write-Host "$failed host(s) failed. Details: az vm run-command show -g $ResourceGroup --vm-name <vm> --name $commandName --instance-view" -ForegroundColor Red
    exit 1
}
if ($Customize) { Write-Host 'Done. Restart hosts (out of hours) if an installer or the LSA protection setting needs it.' -ForegroundColor Green }
else { Write-Host 'Done. New settings apply at each user''s next sign-in.' -ForegroundColor Green }
