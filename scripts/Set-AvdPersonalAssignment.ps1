<#
.SYNOPSIS
    Assigns users to personal (1:1) desktops.

.DESCRIPTION
    For hostPoolType = 'Personal'. With personalAssignmentType = 'Automatic', a user gets a free
    desktop the first time they connect, so you only need this to pre-assign. With 'Direct',
    users see nothing until they are assigned.

    Three ways to use it:
      -User alice@contoso.com -SessionHost avdpd-001     one assignment
      -CsvPath .\assignments.csv                          columns: User,SessionHost
      -FromGroup <group object ID or name>                every member of the group who has no
                                                          desktop yet gets the next free one

    Supports -WhatIf. A user can only have one desktop per host pool, and an assigned desktop
    can't be given to someone else from here (unassign it in the portal first).

.EXAMPLE
    .\scripts\Set-AvdPersonalAssignment.ps1 -ParameterFile .\infra\params\prod.bicepparam -FromGroup 'AVD Users' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Single')]
param(
    [string] $ParameterFile,
    [string] $HostPoolName,

    [Parameter(Mandatory, ParameterSetName = 'Single')] [string] $User,
    [Parameter(Mandatory, ParameterSetName = 'Single')] [string] $SessionHost,
    [Parameter(Mandatory, ParameterSetName = 'Csv')] [string] $CsvPath,
    [Parameter(Mandatory, ParameterSetName = 'Group')] [string] $FromGroup
)

$ErrorActionPreference = 'Stop'

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
function ConvertFrom-AzJson([string] $Text) {
    if (-not $Text) { return @() }
    $parsed = $Text | ConvertFrom-Json
    return @(foreach ($p in $parsed) { $p })
}

# ------------------------------------------------------------------ Host pool
if ($ParameterFile) {
    $ParameterFile = (Resolve-Path -LiteralPath $ParameterFile).Path
    $paramText = Get-Content -Raw -LiteralPath $ParameterFile
    if ($paramText -match '(?m)^//\s*subscriptionId:\s*([0-9a-fA-F-]{36})') { $null = Test-Az account set --subscription $Matches[1] --only-show-errors }
    $outputsFile = Join-Path (Split-Path -Parent $ParameterFile) (([IO.Path]::GetFileNameWithoutExtension($ParameterFile)) + '.outputs.json')
    if (-not $HostPoolName -and (Test-Path -LiteralPath $outputsFile)) { $HostPoolName = (Get-Content -Raw -LiteralPath $outputsFile | ConvertFrom-Json).hostPoolName.value }
}
if (-not $HostPoolName) { throw 'Host pool unknown - pass -HostPoolName (or -ParameterFile after a Deploy-Avd.ps1 run).' }

$hp = @(ConvertFrom-AzJson (Test-Az resource list --resource-type Microsoft.DesktopVirtualization/hostPools --name $HostPoolName --query '[].id' -o json --only-show-errors).Output)
if (-not $hp.Count) { throw "Host pool '$HostPoolName' not found." }
$hostPoolId = "$($hp[0])"
$type = (Test-Az resource show --ids $hostPoolId --query 'properties.hostPoolType' -o tsv --only-show-errors).Output
if ($type -ne 'Personal') { throw "Host pool '$HostPoolName' is '$type' - assignments only apply to Personal host pools." }

$api = 'api-version=2024-04-03'
$hosts = @(ConvertFrom-AzJson (Test-Az rest --method get --url "https://management.azure.com$hostPoolId/sessionHosts?$api" --query 'value[].{name:name, user:properties.assignedUser}' -o json --only-show-errors).Output)
# Session host resource names look like '<hostpool>/<computer name>'.
$byShort = @{}
foreach ($h in $hosts) { $byShort[(("$($h.name)" -split '/')[-1] -split '\.')[0].ToLowerInvariant()] = $h }
Write-Host ("Host pool {0}: {1} desktop(s), {2} assigned" -f $HostPoolName, $hosts.Count, @($hosts | Where-Object { $_.user }).Count)

# ------------------------------------------------------------------ Build the list of assignments
$pairs = @()
switch ($PSCmdlet.ParameterSetName) {
    'Single' { $pairs += [pscustomobject]@{ User = $User; SessionHost = $SessionHost } }
    'Csv' { $pairs += @(Import-Csv -LiteralPath $CsvPath | ForEach-Object { [pscustomobject]@{ User = $_.User.Trim(); SessionHost = $_.SessionHost.Trim() } }) }
    'Group' {
        $gid = $FromGroup
        if ($gid -notmatch '^[0-9a-fA-F-]{36}$') {
            $g = @(ConvertFrom-AzJson (Test-Az ad group list --display-name $FromGroup --query '[].id' -o json --only-show-errors).Output)
            if ($g.Count -ne 1) { throw "Group '$FromGroup' not found or not unique - pass its object ID." }
            $gid = "$($g[0])"
        }
        $members = @(ConvertFrom-AzJson (Test-Az ad group member list --group $gid --query "[?userPrincipalName].userPrincipalName" -o json --only-show-errors).Output | ForEach-Object { "$_" })
        $assignedUsers = @($hosts | Where-Object { $_.user } | ForEach-Object { "$($_.user)".ToLowerInvariant() })
        $todo = @($members | Where-Object { $assignedUsers -notcontains $_.ToLowerInvariant() })
        $free = @($hosts | Where-Object { -not $_.user } | Sort-Object name)
        for ($i = 0; $i -lt [math]::Min($todo.Count, $free.Count); $i++) {
            $pairs += [pscustomobject]@{ User = $todo[$i]; SessionHost = (("$($free[$i].name)" -split '/')[-1]) }
        }
        Write-Host ("{0} group member(s) without a desktop, {1} free desktop(s)" -f $todo.Count, $free.Count)
        if ($todo.Count -gt $free.Count) { Write-Host ("{0} user(s) left without a desktop - add hosts with Deploy-Avd.ps1 -AddHosts {0}" -f ($todo.Count - $free.Count)) -ForegroundColor Yellow }
    }
}

# ------------------------------------------------------------------ Apply
$done = 0; $failed = 0
foreach ($p in $pairs) {
    $key = ("$($p.SessionHost)" -split '\.')[0].ToLowerInvariant()
    $h = $byShort[$key]
    if (-not $h) { Write-Host "  FAIL $($p.User): no desktop named $($p.SessionHost) in this host pool" -ForegroundColor Red; $failed++; continue }
    if ($h.user -and "$($h.user)" -ine $p.User) { Write-Host "  SKIP $($p.SessionHost) is already assigned to $($h.user)" -ForegroundColor Yellow; continue }
    if ($h.user) { Write-Host "  ok   $($p.SessionHost) already assigned to $($p.User)"; continue }
    if ($PSCmdlet.ShouldProcess("$($p.SessionHost)", "Assign to $($p.User)")) {
        $tmp = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($tmp, (@{ properties = @{ assignedUser = $p.User } } | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
            $r = Test-Az rest --method patch --url "https://management.azure.com$hostPoolId/sessionHosts/$((("$($h.name)" -split '/')[-1]))?$api" --headers 'Content-Type=application/json' --body "@$tmp" --only-show-errors
            if ($r.Ok) { Write-Host "  done $($p.SessionHost) -> $($p.User)" -ForegroundColor Green; $done++ }
            else { Write-Host "  FAIL $($p.SessionHost) -> $($p.User) (does the user already have a desktop in this pool?)" -ForegroundColor Red; $failed++ }
        }
        finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    }
}
Write-Host ''
Write-Host ("{0} assigned, {1} failed" -f $done, $failed)
if ($failed) { exit 1 }
