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
    [int] $TimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$configScript = Join-Path (Join-Path (Join-Path $repoRoot 'infra') 'scripts') 'Configure-SessionHost.ps1'

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
if ($fslogix -and -not $VhdLocation) {
    throw 'FSLogix share path unknown (deployment outputs have no fslogixUncPath). Deploy FSLogix storage first, pass -VhdLocation, or use -DisableFslogix.'
}

Write-Host ''
Write-Host "  Resource group : $ResourceGroup"
Write-Host ('  FSLogix        : {0}' -f $(if ($fslogix) { "$VhdLocation ($ProfileSizeMB MB max)" } else { 'not configured (Kerberos settings only)' }))
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
$parameters = @("FslogixEnabled=$fslogix", "VhdLocation=$(if ($fslogix) { $VhdLocation } else { '' })", "ProfileSizeMB=$ProfileSizeMB")
$started = @()
foreach ($n in $running) {
    $r = Test-Az vm run-command create --resource-group $ResourceGroup --vm-name $n --name Configure-SessionHost `
        --script "@$configScript" --parameters @parameters --timeout-in-seconds 1800 --no-wait --only-show-errors
    if ($r.Ok) { $started += $n; Write-Host "  queued $n" } else { Write-Host "  FAILED to queue $n" -ForegroundColor Red }
}

Write-Step 'Waiting for results'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$results = @{}
while ($started.Count -and (Get-Date) -lt $deadline) {
    foreach ($n in @($started)) {
        $s = Test-Az vm run-command show --resource-group $ResourceGroup --vm-name $n --name Configure-SessionHost --instance-view --query 'instanceView.executionState' -o tsv --only-show-errors
        if ($s.Ok -and $s.Output -in @('Succeeded', 'Failed', 'TimedOut', 'Canceled')) {
            $results[$n] = $s.Output
            $started = @($started | Where-Object { $_ -ne $n })
        }
    }
    if ($started.Count) { Start-Sleep -Seconds 15 }
}
foreach ($n in $started) { $results[$n] = 'Unknown (still running at timeout)' }

Write-Host ''
$failed = 0
foreach ($k in ($results.Keys | Sort-Object)) {
    $colour = if ($results[$k] -eq 'Succeeded') { 'Green' } else { $failed++; 'Red' }
    Write-Host ('  {0,-20} {1}' -f $k, $results[$k]) -ForegroundColor $colour
}
foreach ($n in $stopped) { Write-Host ('  {0,-20} skipped (stopped)' -f $n) -ForegroundColor Yellow }
Write-Host ''
if ($failed) {
    Write-Host "$failed host(s) failed. Details: az vm run-command show -g $ResourceGroup --vm-name <vm> --name Configure-SessionHost --instance-view" -ForegroundColor Red
    exit 1
}
Write-Host 'Done. New settings apply at each user''s next sign-in.' -ForegroundColor Green
