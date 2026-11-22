<#
    Runs ON a session host (pushed by scripts/Get-HostDataProtectionReport.ps1 via Run Command).
    Read-only report of what the dataProtection customisation actually left on this host.
    Output kept short: Run Command returns only ~4 KB.
#>
$ErrorActionPreference = 'Continue'
function Line([string] $State, [string] $Text) { Write-Output ('[{0}] {1}' -f $State, $Text) }
function Get-Val([string] $Path, [string] $Name) { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name }

$tenantLine = @(dsregcmd.exe /status 2>$null) | Where-Object { $_ -match '^\s*TenantId\s*:' } | Select-Object -First 1
$hostTenant = if ("$tenantLine" -match '([0-9a-fA-F-]{36})') { $Matches[1] } else { '' }
Line INFO "Host joined to tenant: $(if ($hostTenant) { $hostTenant } else { 'unknown' })"

# ---------------------------------------------------------------- Was the customisation applied?
$log = 'C:\ProgramData\AvdCustomization\customize.log'
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
if (-not (Test-Path $log)) { Line FAIL 'No customisation log - Customize-SessionHost has never run here (Update-SessionHostConfig.ps1 -Customize)' }
else {
    $logLines = @(Get-Content $log)
    $lastRun = $logLines | Where-Object { $_ -match 'customisation starting' } | Select-Object -Last 1
    Line INFO "Last customisation: $("$lastRun".Substring(0, [math]::Min(19, "$lastRun".Length)))  (last boot $($boot.ToString('yyyy-MM-dd HH:mm:ss')))"
    $idx = [array]::LastIndexOf([string[]]$logLines, "$lastRun")
    $recent = if ($idx -ge 0) { $logLines[$idx..($logLines.Count - 1)] } else { $logLines }
    if (-not ($recent -match 'Data protection')) { Line FAIL 'Last customisation run had NO data protection section - push the current customizations.json (-Customize)' }
    foreach ($l in ($recent -match 'Tenant restrictions|FAILED')) { Line $(if ($l -match 'FAILED') { 'FAIL' } else { 'INFO' }) ("log: " + ($l -replace '^\S+ \S+\s+', '')) }
    if ("$lastRun" -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})' -and [datetime]$Matches[1] -gt $boot) {
        Line WARN 'Customisation ran AFTER the last restart - restart the host so tenant restrictions and policies take full effect'
    }
}

# ---------------------------------------------------------------- Machine policies
$ncu = Get-Val 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'NoConnectedUser'
if ($ncu -eq 3) { Line OK 'Personal Microsoft accounts blocked in Windows (NoConnectedUser=3)' } else { Line WARN "NoConnectedUser = '$ncu' (not blocked)" }

$allowKey = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive\AllowTenantList'
$allowed = @()
if (Test-Path $allowKey) { $allowed = @((Get-Item $allowKey).Property) }
if ($allowed.Count) { Line OK "OneDrive may sync only tenant(s): $($allowed -join ', ')" } else { Line FAIL 'OneDrive AllowTenantList NOT set - any organisation (e.g. Contoso) can sync' }

$blk = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist'
if (Test-Path $blk) {
    $u = Get-ItemProperty $blk
    $list = @((Get-Item $blk).Property | ForEach-Object { $u.$_ }) -join ', '
    Line OK "Edge blocked URLs: $list"
}
else { Line WARN 'No Edge URL block list' }

$trRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TenantRestrictions'
if (-not (Test-Path $trRoot)) { Line FAIL 'Tenant restrictions v2 NOT configured on this host - Fabrikam''s Entra policy has nothing to enforce it (enable dataProtection.tenantRestrictions and push)' }
else {
    foreach ($k in @(Get-Item $trRoot) + @(Get-ChildItem $trRoot -Recurse)) {
        foreach ($p in $k.Property) { Line INFO ("TRv2 " + ($k.Name -replace '^HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows\\', '') + "\$p = " + $k.GetValue($p)) }
    }
}

# ---------------------------------------------------------------- Microsoft 365 apps
$teams = try { @(Get-AppxPackage -AllUsers -Name 'MSTeams' -ErrorAction Stop).Count -gt 0 } catch { $false }
$oneDrive = (Test-Path "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe") -or (Test-Path "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe")
$oneDriveBlocked = (Get-Val 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC') -eq 1
$office = Test-Path "$env:ProgramFiles\Microsoft Office\root\Office16\WINWORD.EXE"
Line INFO ("Installed: Teams {0}, OneDrive {1}{2}, Microsoft 365 Apps {3}" -f $(if ($teams) { 'yes' } else { 'no' }), $(if ($oneDrive) { 'yes' } else { 'no' }), $(if ($oneDriveBlocked) { ' (blocked by policy)' } else { '' }), $(if ($office) { 'yes' } else { 'no' }))

# ---------------------------------------------------------------- Microsoft Defender
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $avOk = $mp.AMServiceEnabled -and $mp.RealTimeProtectionEnabled -and $mp.AMRunningMode -eq 'Normal'
    Line $(if ($avOk) { 'OK' } else { 'FAIL' }) ("Defender Antivirus: mode {0}, real-time {1}, signatures {2} day(s) old, tamper protection {3}" -f $mp.AMRunningMode, $mp.RealTimeProtectionEnabled, $mp.AntivirusSignatureAge, $mp.IsTamperProtected)
    if ($mp.AntivirusSignatureAge -gt 3) { Line WARN 'Defender signatures are more than 3 days old - check outbound access to Microsoft update endpoints' }
}
catch { Line FAIL "Defender Antivirus status unavailable - $($_.Exception.Message)" }
$mde = Get-Val 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' 'OnboardingState'
if ($mde -eq 1) { Line OK 'Defender for Endpoint: onboarded' }
else { Line INFO 'Defender for Endpoint: not onboarded (defenderForServersPlan = P1/P2 onboards it via Defender for Cloud; allow a few hours after enabling)' }

# ---------------------------------------------------------------- Signed-in users (loaded profiles)
$sids = @(Get-ChildItem 'Registry::HKEY_USERS' | Where-Object { $_.PSChildName -match '^S-1-12-1-[\d-]+$' } | ForEach-Object { $_.PSChildName })
if (-not $sids.Count) { Line INFO 'No Entra users signed in right now - sign a test user in and re-run to see their OneDrive state' }
foreach ($sid in $sids) {
    $hk = "Registry::HKEY_USERS\$sid"
    $dps = Get-Val "$hk\SOFTWARE\Policies\Microsoft\OneDrive" 'DisablePersonalSync'
    $who = Get-Val "$hk\Volatile Environment" 'USERNAME'
    Line INFO ("User {0}: personal OneDrive sync {1}" -f $(if ($who) { $who } else { $sid }), $(if ($dps -eq 1) { 'blocked' } else { 'NOT blocked (profile existed before the policy)' }))
    foreach ($acct in @(Get-ChildItem "$hk\Software\Microsoft\OneDrive\Accounts" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Business*' })) {
        $t = $acct.GetValue('ConfiguredTenantId'); $m = $acct.GetValue('UserEmail')
        $state = if ($allowed -contains $t) { 'OK' } else { 'FAIL' }
        Line $state ("  OneDrive {0} signed in as {1}, tenant {2}{3}" -f $acct.PSChildName, $m, $t, $(if ($state -eq 'FAIL') { ' - NOT an allowed tenant; restart OneDrive / sign out once the policy is in place' } else { '' }))
    }
}
