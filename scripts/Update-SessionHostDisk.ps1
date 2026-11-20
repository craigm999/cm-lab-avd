<#
.SYNOPSIS
    Changes the OS disk type and/or size of EXISTING session hosts.

.DESCRIPTION
    New hosts take osDiskType / osDiskSizeGB from the parameter file. Existing hosts keep the
    disk they were built with: Azure only changes an OS disk while the VM is deallocated, so
    a redeploy can't do it. This script does it host by host, a few at a time:

      1. Drain mode on (no new sign-ins; also stops Start VM on Connect starting it mid-change)
      2. Skip it if anyone has a session (re-checked after draining)
      3. Deallocate
      4. az disk update --sku / --size-gb
      5. If the disk grew: start the VM and extend C: into the new space
      6. Put it back as it was: running hosts stay running, stopped hosts are deallocated again
      7. Drain mode back to what it was

    The target type and size default to osDiskType / osDiskSizeGB in the parameter file, so
    edit the file first (that also covers new hosts), then run this. Or pass -DiskType / -SizeGB.

    Disks can only grow. A host whose disk is already bigger than -SizeGB keeps its size (its
    type can still change). Hosts that already match are left alone, so the script is safe to
    re-run - e.g. later, for hosts skipped because someone was signed in.

    -WhatIf lists what would change without touching anything.

.EXAMPLE
    .\scripts\Update-SessionHostDisk.ps1 -ParameterFile .\infra\params\prod.bicepparam -WhatIf

.EXAMPLE
    .\scripts\Update-SessionHostDisk.ps1 -ParameterFile .\infra\params\prod.bicepparam -ThrottleLimit 10

.EXAMPLE
    # Two hosts only, explicit target
    .\scripts\Update-SessionHostDisk.ps1 -ParameterFile .\infra\params\prod.bicepparam -VmName avdpd-001, avdpd-002 -DiskType StandardSSD_LRS -SizeGB 256
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ParameterFile,
    [string] $ResourceGroup,
    [string] $HostPoolId,
    [string[]] $VmName,

    [ValidateSet('Premium_LRS', 'StandardSSD_LRS', 'Premium_ZRS', 'StandardSSD_ZRS')]
    [string] $DiskType,

    [ValidateRange(32, 4095)]
    [int] $SizeGB = 0,

    [ValidateRange(1, 50)]
    [int] $ThrottleLimit = 5,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$preview = [bool]$WhatIfPreference
$WhatIfPreference = $false

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
function Get-ShortName([string] $Name) { return ((($Name -split '/')[-1]) -split '\.')[0].ToLowerInvariant() }

function Set-Drain([string] $SessionHost, [bool] $AllowNewSession) {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, (@{ properties = @{ allowNewSession = $AllowNewSession } } | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
        return (Test-Az rest --method patch --url "https://management.azure.com$HostPoolId/sessionHosts/$($SessionHost)?api-version=2024-04-03" --headers 'Content-Type=application/json' --body "@$tmp" --only-show-errors).Ok
    }
    finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

function Get-PoolSessionHost {
    # Host pool session hosts, following nextLink (az rest doesn't page).
    $url = "https://management.azure.com$HostPoolId/sessionHosts?api-version=2024-04-03"
    $all = @()
    while ($url) {
        $r = Test-Az rest --method get --url $url --only-show-errors
        if (-not $r.Ok) { throw "Could not read the session hosts of $HostPoolId." }
        $page = $r.Output | ConvertFrom-Json
        $all += @(foreach ($v in $page.value) { $v })
        $url = if ($page.PSObject.Properties['nextLink']) { "$($page.nextLink)" } else { '' }
    }
    $map = @{}
    foreach ($sh in $all) {
        $map[(Get-ShortName "$($sh.name)")] = [pscustomobject]@{
            Name     = ("$($sh.name)" -split '/')[-1]
            Sessions = [int]$sh.properties.sessions
            Allow    = [bool]$sh.properties.allowNewSession
        }
    }
    return $map
}

function Wait-Power([string] $Vm, [string] $State) {
    return (Test-Az vm wait --resource-group $ResourceGroup --name $Vm --custom "instanceView.statuses[?code=='PowerState/$State']" --timeout 1200 --only-show-errors).Ok
}

# ------------------------------------------------------------------ Resolve settings
if ($ParameterFile) {
    $ParameterFile = (Resolve-Path -LiteralPath $ParameterFile).Path
    $paramText = Get-Content -Raw -LiteralPath $ParameterFile
    if ($paramText -match '(?m)^//\s*subscriptionId:\s*([0-9a-fA-F-]{36})') { $null = Test-Az account set --subscription $Matches[1] --only-show-errors }
    if (-not $DiskType -and $paramText -match "(?m)^param\s+osDiskType\s*=\s*'([^']+)'") { $DiskType = $Matches[1] }
    if ($SizeGB -le 0 -and $paramText -match '(?m)^param\s+osDiskSizeGB\s*=\s*(\d+)') { $SizeGB = [int]$Matches[1] }
    $outputsFile = Join-Path (Split-Path -Parent $ParameterFile) (([IO.Path]::GetFileNameWithoutExtension($ParameterFile)) + '.outputs.json')
    if (Test-Path -LiteralPath $outputsFile) {
        $outputs = Get-Content -Raw -LiteralPath $outputsFile | ConvertFrom-Json
        if (-not $ResourceGroup) { $ResourceGroup = "$($outputs.sessionHostResourceGroup.value)" }
        if (-not $HostPoolId -and $outputs.PSObject.Properties['sessionHostDeployment']) { $HostPoolId = "$($outputs.sessionHostDeployment.value.hostPoolId)" }
    }
}
if (-not $ResourceGroup) { throw 'Session host resource group unknown - pass -ResourceGroup (or -ParameterFile after a Deploy-Avd.ps1 run).' }
if (-not $HostPoolId) { throw 'Host pool unknown - pass -HostPoolId (or -ParameterFile after a Deploy-Avd.ps1 run). It is needed to check for signed-in users.' }
if (-not $DiskType -and $SizeGB -le 0) { throw 'Nothing to change - set osDiskType / osDiskSizeGB in the parameter file, or pass -DiskType / -SizeGB.' }

Write-Host ''
Write-Host "  Resource group : $ResourceGroup"
Write-Host ('  Target disk    : {0}{1}' -f $(if ($DiskType) { $DiskType } else { '(type unchanged)' }), $(if ($SizeGB -gt 0) { ", $SizeGB GiB" } else { ', (size unchanged)' }))
Write-Host ''

# ------------------------------------------------------------------ Plan
Write-Step 'Reading hosts, disks and sessions'
$vmOut = Test-Az vm list --resource-group $ResourceGroup --show-details --query '[].{name:name, power:powerState, diskId:storageProfile.osDisk.managedDisk.id}' -o json --only-show-errors
if (-not $vmOut.Ok) { throw "Could not list VMs in $ResourceGroup (signed in? right subscription?)." }
$diskOut = Test-Az disk list --resource-group $ResourceGroup --query '[].{id:id, sku:sku.name, size:diskSizeGB}' -o json --only-show-errors
if (-not $diskOut.Ok) { throw "Could not list disks in $ResourceGroup." }
# Assign first, then enumerate: Windows PowerShell 5.1 emits a JSON array as ONE pipeline object.
$vmParsed = $vmOut.Output | ConvertFrom-Json
$diskParsed = $diskOut.Output | ConvertFrom-Json
$disks = @{}
foreach ($d in $diskParsed) { $disks["$($d.id)".ToLowerInvariant()] = $d }
$sessionHosts = Get-PoolSessionHost

$plan = @()
foreach ($v in $vmParsed) {
    if ($VmName -and $VmName -notcontains $v.name) { continue }
    $sh = $sessionHosts[(Get-ShortName "$($v.name)")]
    if (-not $sh) { continue }   # not a session host of this pool (jump box etc.)
    $disk = $disks["$($v.diskId)".ToLowerInvariant()]
    if (-not $disk) { Write-Host "  $($v.name): OS disk not found in $ResourceGroup - skipped" -ForegroundColor Yellow; continue }
    $newSku = if ($DiskType -and $disk.sku -ne $DiskType) { $DiskType } else { '' }
    $grow = ($SizeGB -gt 0 -and [int]$disk.size -lt $SizeGB)
    $note = ''
    if ($SizeGB -gt 0 -and [int]$disk.size -gt $SizeGB) { $note = " (already $($disk.size) GiB - disks can't shrink, size kept)" }
    $plan += [pscustomobject]@{
        Vm = "$($v.name)"; Power = "$($v.power)"; DiskId = "$($v.diskId)"; Sku = "$($disk.sku)"; Size = [int]$disk.size
        NewSku = $newSku; Grow = $grow; SessionHost = $sh.Name; Sessions = $sh.Sessions; Allow = $sh.Allow; Note = $note
        Change = ([bool]$newSku -or $grow)
    }
}
if ($VmName) {
    $missing = @($VmName | Where-Object { @($plan | ForEach-Object { $_.Vm }) -notcontains $_ })
    if ($missing.Count) { Write-Host ("  Not found as session hosts: {0}" -f ($missing -join ', ')) -ForegroundColor Yellow }
}

$done = @($plan | Where-Object { -not $_.Change })
$busy = @($plan | Where-Object { $_.Change -and $_.Sessions -gt 0 })
$todo = @($plan | Where-Object { $_.Change -and $_.Sessions -eq 0 })
foreach ($p in $todo) {
    $what = @()
    if ($p.NewSku) { $what += "$($p.Sku) -> $($p.NewSku)" }
    if ($p.Grow) { $what += "$($p.Size) -> $SizeGB GiB" }
    Write-Host ("  {0,-14} {1,-16} {2}{3}" -f $p.Vm, $p.Power, ($what -join ', '), $p.Note)
}
foreach ($p in $busy) { Write-Host ("  {0,-14} skipped - {1} session(s) signed in; re-run later" -f $p.Vm, $p.Sessions) -ForegroundColor Yellow }
Write-Host ("  {0} to change, {1} skipped (signed in), {2} already match" -f $todo.Count, $busy.Count, $done.Count)
Write-Host ''

if (-not $todo.Count) { Write-Host 'Nothing to do.' -ForegroundColor Green; return }
if ($preview) {
    Write-Host 'Preview only. Each host is offline for roughly 5-10 minutes while it changes. Run again without -WhatIf to apply.' -ForegroundColor Green
    return
}
if (-not $Force) {
    $answer = Read-Host "Change the OS disk on $($todo.Count) host(s)? Each is offline for ~5-10 minutes. Type yes to continue"
    if ($answer -ne 'yes') { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
}

# ------------------------------------------------------------------ Apply, a wave at a time
# Pushed as a file (--scripts @file): inline quotes don't survive az.cmd on Windows PowerShell.
$extendFile = Join-Path ([IO.Path]::GetTempPath()) ('avd-extend-c-{0}.ps1' -f [guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($extendFile, @'
$p = Get-Partition -DriveLetter C
$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
if ($max -gt $p.Size + 1MB) { Resize-Partition -DriveLetter C -Size $max; 'C: extended to {0:N0} GB' -f ($max / 1GB) }
else { 'C: already full size ({0:N0} GB of a {1:N0} GB disk)' -f ($p.Size / 1GB), ((Get-Disk -Number $p.DiskNumber).Size / 1GB) }
'@, (New-Object System.Text.UTF8Encoding($false)))
$results = New-Object System.Collections.Generic.List[object]
$waves = [math]::Ceiling($todo.Count / $ThrottleLimit)
for ($w = 0; $w -lt $waves; $w++) {
    $wave = @($todo | Select-Object -Skip ($w * $ThrottleLimit) -First $ThrottleLimit)
    Write-Step ("Wave {0} of {1}: {2}" -f ($w + 1), $waves, (@($wave | ForEach-Object { $_.Vm }) -join ', '))

    # 1-2. Drain, then re-check nobody signed in meanwhile.
    foreach ($p in $wave) { if (-not (Set-Drain $p.SessionHost $false)) { $p | Add-Member -NotePropertyName Result -NotePropertyValue 'FAILED: could not set drain mode' -Force } }
    $current = Get-PoolSessionHost
    foreach ($p in $wave) {
        if ($p.PSObject.Properties['Result']) { continue }
        $now = $current[(Get-ShortName $p.Vm)]
        if ($now -and $now.Sessions -gt 0) { $p | Add-Member -NotePropertyName Result -NotePropertyValue 'skipped: someone signed in' -Force }
    }
    $active = @($wave | Where-Object { -not $_.PSObject.Properties['Result'] })

    # 3. Deallocate (all in the wave together).
    foreach ($p in $active) { if ($p.Power -ne 'VM deallocated') { $null = Test-Az vm deallocate --resource-group $ResourceGroup --name $p.Vm --no-wait --only-show-errors } }
    foreach ($p in $active) {
        if ($p.Power -ne 'VM deallocated' -and -not (Wait-Power $p.Vm 'deallocated')) { $p | Add-Member -NotePropertyName Result -NotePropertyValue 'FAILED: did not deallocate' -Force }
    }

    # 4. Change the disk.
    foreach ($p in $active) {
        if ($p.PSObject.Properties['Result']) { continue }
        $diskArgs = @('disk', 'update', '--ids', $p.DiskId, '--only-show-errors', '-o', 'none')
        if ($p.NewSku) { $diskArgs += @('--sku', $p.NewSku) }
        if ($p.Grow) { $diskArgs += @('--size-gb', "$SizeGB") }
        $u = Test-Az @diskArgs
        if (-not $u.Ok) { $p | Add-Member -NotePropertyName Result -NotePropertyValue 'FAILED: az disk update refused the change (az disk update --ids <disk> shows why)' -Force }
    }

    # 5. Start hosts that were running, and any whose disk grew (to extend C:).
    $toStart = @($active | Where-Object { $_.Power -eq 'VM running' -or ($_.Grow -and -not $_.PSObject.Properties['Result']) })
    foreach ($p in $toStart) { $null = Test-Az vm start --resource-group $ResourceGroup --name $p.Vm --no-wait --only-show-errors }
    foreach ($p in $toStart) {
        if (-not (Wait-Power $p.Vm 'running')) {
            $msg = 'FAILED: did not start again - start it in the portal'
            $prev = if ($p.PSObject.Properties['Result']) { "$($p.Result); " } else { '' }
            $p | Add-Member -NotePropertyName Result -NotePropertyValue ($prev + $msg) -Force
        }
    }
    foreach ($p in $active) {
        if ($p.PSObject.Properties['Result'] -or -not $p.Grow) { continue }
        $x = Test-Az vm run-command invoke --resource-group $ResourceGroup --name $p.Vm --command-id RunPowerShellScript --scripts "@$extendFile" --query 'value[0].message' -o tsv --only-show-errors
        if ($x.Ok -and $x.Output -match 'C: (extended|already full size)') { $p | Add-Member -NotePropertyName Extend -NotePropertyValue ([regex]::Match($x.Output, 'C: [^\r\n]*').Value) -Force }
        else { $p | Add-Member -NotePropertyName Extend -NotePropertyValue 'C: NOT extended - a recovery partition after C: may block it (Disk Management on the host)' -Force }
    }

    # 6. Hosts that were stopped go back to stopped (deallocated = no compute cost).
    foreach ($p in $active) {
        if ($p.Power -ne 'VM running' -and @($toStart | ForEach-Object { $_.Vm }) -contains $p.Vm) {
            $null = Test-Az vm deallocate --resource-group $ResourceGroup --name $p.Vm --no-wait --only-show-errors
        }
    }

    # 7. Drain mode back to what it was.
    foreach ($p in $wave) {
        if ($p.Allow -and -not (Set-Drain $p.SessionHost $true)) {
            Write-Host "  $($p.Vm): could not turn drain mode off - do it in the portal (Host pool > Session hosts)" -ForegroundColor Yellow
        }
    }

    foreach ($p in $wave) {
        $res = if ($p.PSObject.Properties['Result']) { $p.Result } else { 'done' }
        if ($p.PSObject.Properties['Extend']) { $res += "; $($p.Extend)" }
        $results.Add([pscustomobject]@{ Vm = $p.Vm; Result = $res })
        $colour = if ($res -match 'FAILED|NOT extended') { 'Red' } elseif ($res -match '^skipped') { 'Yellow' } else { 'Green' }
        Write-Host ("  {0,-14} {1}" -f $p.Vm, $res) -ForegroundColor $colour
    }
}

Remove-Item -LiteralPath $extendFile -ErrorAction SilentlyContinue
$failed = @($results | Where-Object { $_.Result -match 'FAILED|NOT extended' })
$skippedNow = @($results | Where-Object { $_.Result -match '^skipped' })
Write-Host ''
Write-Host ("Done: {0} changed, {1} failed, {2} skipped (signed in) this run, {3} skipped earlier (signed in)." -f ($results.Count - $failed.Count - $skippedNow.Count), $failed.Count, $skippedNow.Count, $busy.Count) -ForegroundColor $(if ($failed.Count) { 'Yellow' } else { 'Green' })
if ($skippedNow.Count + $busy.Count) { Write-Host 'Re-run the same command later to pick up hosts that were in use.' }
if ($failed.Count) { throw "$($failed.Count) host(s) need attention - see above." }
