<#
.SYNOPSIS
    Daily maintenance for a PERSONAL (1:1) AVD host pool: keep N spare desktops and remove
    desktops that haven't been used for a long time.

.DESCRIPTION
    Runs as an Azure Automation runbook (PowerShell 5.1 runtime) using the Automation
    account's managed identity, or locally (report mode) using your `az login`. It only
    uses Azure REST APIs, so it needs no PowerShell modules.

    Every run:
      1. Usage: reads the last 2 days of AVD connections (WVDConnections in Log Analytics)
         and stamps each desktop VM with an 'avd-last-used' tag (yyyy-MM-dd). Usage is
         tracked on the VM itself, so the idle period doesn't depend on Log Analytics
         retention. Tags are written in Report mode too, so tracking starts on day one.
      2. Tidy-up: desktops idle for 'unusedDays' (last-used tag, or VM creation date if never
         used) are deleted - session host registration, then the VM (its NIC and OS disk are
         set to delete with it). Never touched: desktops with active sessions, desktops
         tagged avd-keep=true, and spare (unassigned) desktops needed to keep the spare
         target. At most 'maxDeletePerRun' per run.
      3. Spares: if fewer than 'spareTarget' desktops are unassigned (counting builds still in
         progress), deploys more from the session host template spec - the same template the
         main deployment uses. At most 'maxAddPerRun' per run.

    Mode 'Report' (default) only reports what it would do. 'Apply' acts.
    Entra ID device objects of deleted desktops are listed for clean-up but not deleted
    (deleting devices needs a directory role, not just a Graph permission).

    Configuration: the 'AvdPoolAutomationConfig' Automation variable (written by
    scripts/Publish-AvdPoolAutomation.ps1), or -ConfigPath for a local run.

.EXAMPLE
    # Local preview (report only) using your az login
    .\infra\automation\Invoke-AvdPoolMaintenance.ps1 -ConfigPath .\infra\params\prod.automation.json
#>
param(
    [string] $ConfigPath,
    [string] $Mode = '',
    [string] $NowUtc = ''
)

$ErrorActionPreference = 'Stop'
$now = if ($NowUtc) { ([datetime]$NowUtc).ToUniversalTime() } else { [datetime]::UtcNow }
function Say([string] $Text) { Write-Output $Text }

# ------------------------------------------------------------------ Config and auth
if ($ConfigPath) { $cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json }
else { $cfg = (Get-AutomationVariable -Name 'AvdPoolAutomationConfig') | ConvertFrom-Json }
if (-not $Mode) { $Mode = if ($cfg.mode) { "$($cfg.mode)" } else { 'Report' } }
$apply = $Mode -eq 'Apply'

$script:tokens = @{}
function Get-Token([string] $Resource) {
    if ($script:tokens.ContainsKey($Resource)) { return $script:tokens[$Resource] }
    if ($env:IDENTITY_ENDPOINT) {
        # Automation managed identity
        $r = Invoke-RestMethod -Method GET -Uri ('{0}?resource={1}&api-version=2019-08-01' -f $env:IDENTITY_ENDPOINT, [uri]::EscapeDataString($Resource)) -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'True' }
        $t = $r.access_token
    }
    else {
        $t = (& az account get-access-token --resource $Resource --query accessToken -o tsv)
        if (-not $t) { throw "Could not get a token for $Resource - run 'az login' first." }
    }
    $script:tokens[$Resource] = "$t".Trim()
    return $script:tokens[$Resource]
}
function Invoke-Arm([string] $Method, [string] $Path, $Body = $null) {
    $uri = if ($Path -like 'https://*') { $Path } else { 'https://management.azure.com' + $Path }
    $p = @{ Method = $Method; Uri = $uri; Headers = @{ Authorization = 'Bearer ' + (Get-Token 'https://management.azure.com/') } }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 30 -Compress); $p.ContentType = 'application/json' }
    return Invoke-RestMethod @p
}
function Get-ArmList([string] $Path) {
    $next = $Path
    while ($next) {
        $r = Invoke-Arm GET $next
        foreach ($i in @($r.value)) { if ($null -ne $i) { $i } }
        $next = if ($r.PSObject.Properties['nextLink']) { $r.nextLink } else { $null }
    }
}
function Get-Number([string] $Name) {
    if ($Name -match ('^' + [regex]::Escape("$($cfg.sessionHostPrefix)") + '-(\d+)$')) { return [int]$Matches[1] }
    return $null
}

Say ("AVD pool maintenance - {0:yyyy-MM-dd HH:mm} UTC - mode {1}" -f $now, $Mode)
Say ("Spare target {0}, delete after {1} days unused (max {2} adds / {3} deletes per run)" -f $cfg.spareTarget, $cfg.unusedDays, $cfg.maxAddPerRun, $cfg.maxDeletePerRun)

# ------------------------------------------------------------------ Inventory
$sessionHosts = @(Get-ArmList "$($cfg.hostPoolId)/sessionHosts?api-version=2024-04-03")
$byName = @{}
foreach ($sh in $sessionHosts) { $byName[((("$($sh.name)" -split '/')[-1]) -split '\.')[0].ToLowerInvariant()] = $sh }
$vms = @(Get-ArmList "/subscriptions/$($cfg.subscriptionId)/resourceGroups/$($cfg.hostsResourceGroup)/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01" |
    Where-Object { $null -ne (Get-Number $_.name) })

# ------------------------------------------------------------------ 1. Usage -> 'avd-last-used' tags
$recent = @{}
if ($cfg.workspaceResourceId) {
    try {
        $ws = Invoke-Arm GET "$($cfg.workspaceResourceId)?api-version=2023-09-01"
        $q = 'WVDConnections | where TimeGenerated > ago(2d) | where State in ("Connected", "Completed") | extend Host = tolower(tostring(split(SessionHostName, ".")[0])) | summarize LastUsed = max(TimeGenerated) by Host'
        $la = Invoke-RestMethod -Method POST -Uri "https://api.loganalytics.io/v1/workspaces/$($ws.properties.customerId)/query" `
            -Headers @{ Authorization = 'Bearer ' + (Get-Token 'https://api.loganalytics.io') } -ContentType 'application/json' -Body (@{ query = $q } | ConvertTo-Json -Compress)
        foreach ($row in @($la.tables[0].rows)) { $recent["$($row[0])"] = ([datetime]$row[1]).ToUniversalTime() }
    }
    catch { Say "WARNING: could not read connection history from Log Analytics - $($_.Exception.Message)" }
}

$info = @()
foreach ($vm in $vms) {
    $key = "$($vm.name)".ToLowerInvariant()
    $sh = $byName[$key]
    $tags = if ($vm.PSObject.Properties['tags'] -and $vm.tags) { $vm.tags } else { [pscustomobject]@{} }
    $tagged = $null
    if ($tags.PSObject.Properties['avd-last-used']) { try { $tagged = [datetime]::ParseExact("$($tags.'avd-last-used')", 'yyyy-MM-dd', $null) } catch { $tagged = $null } }
    $sessions = if ($sh) { [int]$sh.properties.sessions } else { 0 }
    $seen = $null
    if ($recent.ContainsKey($key)) { $seen = $recent[$key] }
    if ($sessions -gt 0) { $seen = $now }
    if ($seen -and (-not $tagged -or $seen.Date -gt $tagged.Date)) {
        $stamp = $seen.ToString('yyyy-MM-dd')
        try {
            $null = Invoke-Arm PATCH "$($vm.id)/providers/Microsoft.Resources/tags/default?api-version=2021-04-01" @{ operation = 'Merge'; properties = @{ tags = @{ 'avd-last-used' = $stamp } } }
            $tagged = $seen.Date
        }
        catch { Say "WARNING: could not tag $($vm.name) - $($_.Exception.Message)" }
    }
    $created = if ($vm.properties.PSObject.Properties['timeCreated']) { ([datetime]$vm.properties.timeCreated).ToUniversalTime() } else { $now }
    $lastUsed = if ($tagged) { $tagged } else { $null }
    $since = if ($lastUsed) { $lastUsed } else { $created }
    $info += [pscustomobject]@{
        Name     = "$($vm.name)"
        Id       = "$($vm.id)"
        Number   = Get-Number $vm.name
        InPool   = [bool]$sh
        Session  = if ($sh) { (("$($sh.name)" -split '/')[-1]) } else { $null }
        User     = if ($sh -and $sh.properties.assignedUser) { "$($sh.properties.assignedUser)" } else { $null }
        Sessions = $sessions
        Keep     = ($tags.PSObject.Properties['avd-keep'] -and "$($tags.'avd-keep')" -eq 'true')
        Created  = $created
        LastUsed = $lastUsed
        IdleDays = [int][math]::Floor(($now - $since).TotalDays)
    }
}

# Builds in progress: VMs not yet registered in the pool, created in the last 6 hours.
$pending = @($info | Where-Object { -not $_.InPool -and ($now - $_.Created).TotalHours -lt 6 })
$orphans = @($info | Where-Object { -not $_.InPool -and ($now - $_.Created).TotalHours -ge 6 })
$inPool = @($info | Where-Object { $_.InPool })
$free = @($inPool | Where-Object { -not $_.User })
Say ("Desktops: {0} in pool ({1} assigned, {2} free), {3} build(s) in progress" -f $inPool.Count, ($inPool.Count - $free.Count), $free.Count, $pending.Count)
foreach ($o in $orphans) { Say "WARNING: $($o.Name) exists but never registered with the host pool (created $($o.Created.ToString('yyyy-MM-dd HH:mm'))) - check its deployment; not touched." }

# ------------------------------------------------------------------ 2. Tidy-up
$unusedDays = [int]$cfg.unusedDays
$idle = @($inPool | Where-Object { $_.IdleDays -ge $unusedDays -and $_.Sessions -eq 0 -and -not $_.Keep } | Sort-Object IdleDays -Descending)
$freeAfter = $free.Count + $pending.Count
$toDelete = @()
foreach ($h in $idle) {
    if ($toDelete.Count -ge [int]$cfg.maxDeletePerRun) { break }
    if (-not $h.User) {
        # An unused spare is only surplus if we still meet the spare target without it.
        if ($freeAfter - 1 -lt [int]$cfg.spareTarget) { continue }
        $freeAfter--
    }
    $toDelete += $h
}
$skippedKeep = @($inPool | Where-Object { $_.IdleDays -ge $unusedDays -and $_.Keep })
Say ("Unused for {0}+ days: {1} desktop(s); deleting {2}{3}" -f $unusedDays, $idle.Count, $toDelete.Count, $(if ($skippedKeep.Count) { " ($($skippedKeep.Count) kept by avd-keep tag)" } else { '' }))
foreach ($d in $toDelete) {
    $who = if ($d.User) { "assigned to $($d.User)" } else { 'spare' }
    $last = if ($d.LastUsed) { "last used $($d.LastUsed.ToString('yyyy-MM-dd'))" } else { "never used (created $($d.Created.ToString('yyyy-MM-dd')))" }
    if (-not $apply) { Say "  would delete $($d.Name) - $who, $last, idle $($d.IdleDays) days"; continue }
    try {
        $null = Invoke-Arm DELETE "$($cfg.hostPoolId)/sessionHosts/$($d.Session)?api-version=2024-04-03&force=true"
        $null = Invoke-Arm DELETE "$($d.Id)?api-version=2024-07-01"
        Say "  deleted $($d.Name) - $who, $last. Remove its Entra ID device object (Entra ID > Devices) when convenient."
    }
    catch { Say "  FAILED to delete $($d.Name) - $($_.Exception.Message)" }
}

# ------------------------------------------------------------------ 3. Spares
$freeNow = $free.Count - @($toDelete | Where-Object { -not $_.User }).Count + $pending.Count
$need = [int]$cfg.spareTarget - $freeNow
$add = [math]::Max(0, [math]::Min($need, [int]$cfg.maxAddPerRun))
Say ("Spare desktops: {0} available or building, target {1} -> adding {2}" -f $freeNow, $cfg.spareTarget, $add)
if ($add -gt 0) {
    $numbers = @($info | ForEach-Object { $_.Number }) + @($sessionHosts | ForEach-Object { Get-Number (((("$($_.name)" -split '/')[-1]) -split '\.')[0]) } | Where-Object { $null -ne $_ })
    $next = if ($numbers.Count) { ([int](($numbers | Measure-Object -Maximum).Maximum)) + 1 } else { 1 }
    $zones = @($cfg.zones | Where-Object { $_ })
    $names = @(for ($i = 0; $i -lt $add; $i++) { '{0}-{1:D3}' -f $cfg.sessionHostPrefix, ($next + $i) })
    if (-not $apply) { Say "  would deploy: $($names -join ', ')" }
    else {
        $password = if ($ConfigPath) { $env:AVD_LOCAL_ADMIN_PASSWORD } else { Get-AutomationVariable -Name 'AvdLocalAdminPassword' }
        if (-not $password) { throw 'Local admin password not available (AvdLocalAdminPassword variable / AVD_LOCAL_ADMIN_PASSWORD).' }
        # A fresh registration token for the new hosts (the template reads it from the host pool).
        $null = Invoke-Arm PATCH "$($cfg.hostPoolId)?api-version=2024-04-03" @{ properties = @{ registrationInfo = @{ expirationTime = $now.AddHours(8).ToString('yyyy-MM-ddTHH:mm:ssZ'); registrationTokenOperation = 'Update' } } }
        foreach ($n in $names) {
            $num = Get-Number $n
            $params = @{}
            foreach ($p in $cfg.sessionHostParameters.PSObject.Properties) { $params[$p.Name] = @{ value = $p.Value } }
            $params['vmName'] = @{ value = $n }
            $params['zone'] = @{ value = $(if ($zones.Count) { "$($zones[($num - 1) % $zones.Count])" } else { '' }) }
            $params['adminPassword'] = @{ value = $password }
            try {
                $null = Invoke-Arm PUT "/subscriptions/$($cfg.subscriptionId)/resourceGroups/$($cfg.hostsResourceGroup)/providers/Microsoft.Resources/deployments/avd-auto-$($n)?api-version=2024-03-01" @{
                    properties = @{ mode = 'Incremental'; templateLink = @{ id = "$($cfg.templateSpecVersionId)" }; parameters = $params }
                }
                Say "  started deployment of $n (takes ~30-60 min; counted as 'building' until it registers)"
            }
            catch { Say "  FAILED to start deployment of $n - $($_.Exception.Message)" }
        }
    }
}
Say 'Done.'
