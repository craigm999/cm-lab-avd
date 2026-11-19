<#
    Runs ON a session host (pushed by scripts/Get-FslogixHostDiagnostics.ps1 via Run Command).
    Read-only. Output is kept short because Run Command returns only ~4 KB.
#>
param([string] $NetworkAccess = 'privateEndpoint')   # or serviceEndpoint
$ErrorActionPreference = 'Continue'
function Line([string] $State, [string] $Text) { Write-Output ('[{0}] {1}' -f $State, $Text) }

# ---------------------------------------------------------------- Settings
$kerb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' -ErrorAction SilentlyContinue).CloudKerberosTicketRetrievalEnabled
$cred = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount' -ErrorAction SilentlyContinue).LoadCredKeyFromProfile
$fsl = Get-ItemProperty 'HKLM:\SOFTWARE\FSLogix\Profiles' -ErrorAction SilentlyContinue
if ($kerb -eq 1) { Line OK 'CloudKerberosTicketRetrievalEnabled = 1' } else { Line FAIL 'CloudKerberosTicketRetrievalEnabled not set - re-run Update-SessionHostConfig.ps1' }
if ($cred -eq 1) { Line OK 'LoadCredKeyFromProfile = 1' } else { Line WARN 'LoadCredKeyFromProfile not set' }
if ($fsl -and $fsl.Enabled -eq 1) { Line OK ('FSLogix enabled, VHDLocations = ' + (@($fsl.VHDLocations) -join ';')) } else { Line FAIL 'FSLogix not enabled in registry' }
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
Line INFO ('Last boot: {0:yyyy-MM-dd HH:mm} - Kerberos setting needs a restart after it is first applied' -f $boot)

foreach ($svc in 'iphlpsvc', 'WinHttpAutoProxySvc') {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { Line WARN "$svc not found" }
    elseif ($s.StartType -eq 'Disabled') { Line FAIL "$svc is Disabled (required by Entra Kerberos)" }
    else { Line OK "$svc $($s.Status) ($($s.StartType))" }
}
$join = (dsregcmd /status) -match 'AzureAdJoined\s*:\s*YES'
if ($join) { Line OK 'Device is Entra joined' } else { Line FAIL 'Device is NOT Entra joined (dsregcmd /status)' }

# ---------------------------------------------------------------- DNS + network
$unc = @($fsl.VHDLocations)[0]
if ($unc -match '^\\\\([^\\]+)\\') {
    $fqdn = $Matches[1]
    try {
        $res = Resolve-DnsName -Name $fqdn -ErrorAction Stop
        $cnames = @($res | Where-Object { $_.Type -eq 'CNAME' } | ForEach-Object { $_.NameHost })
        $ips = @($res | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
        $private = @($ips | Where-Object { $_ -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' })
        if ($private.Count) { Line OK "$fqdn -> $($ips -join ',') (private endpoint)" }
        elseif ($NetworkAccess -eq 'serviceEndpoint') { Line OK "$fqdn -> $($ips -join ',') (public endpoint, reached via the subnet's service endpoint - expected)" }
        else { Line FAIL "$fqdn -> $($ips -join ',') is PUBLIC - private DNS zone not linked/used by this VNet's DNS (or switch to fslogixNetworkAccess = serviceEndpoint)" }
        if ($NetworkAccess -eq 'privateEndpoint' -and -not ($cnames -match 'privatelink')) { Line WARN 'No privatelink CNAME in the answer' }
    }
    catch { Line FAIL "DNS lookup of $fqdn failed: $($_.Exception.Message)" }
    $tcp = Test-NetConnection -ComputerName $fqdn -Port 445 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($tcp) { Line OK 'TCP 445 reachable' }
    elseif ($NetworkAccess -eq 'serviceEndpoint') { Line FAIL 'TCP 445 NOT reachable - check an NSG outbound rule allows 445 to the Storage service tag' }
    else { Line FAIL 'TCP 445 NOT reachable - NSG/firewall between hosts and the private endpoint' }

    # SMB-level test. This runs as SYSTEM, which has no Entra Kerberos ticket, so an
    # authentication error is EXPECTED and proves SMB reached the share; 53/67 means it didn't.
    $share = ($unc -split '\\' | Where-Object { $_ })[1]
    # stdin from nul so net use can never sit waiting at a credential prompt
    $nu = (cmd.exe /c "net use \\$fqdn\$share /persistent:no < nul 2>&1") -join ' '
    $null = cmd.exe /c "net use \\$fqdn\$share /delete /y 2>&1"
    $smbCode = if ($nu -match 'System error (\d+)') { $Matches[1] } else { '0' }
    if ($smbCode -in @('53', '67')) { Line FAIL "SMB to \\$fqdn\$share failed with error $smbCode (network path/name not found) although TCP 445 is open - check the share name and that nothing inspects/blocks SMB" }
    elseif ($smbCode -eq '0') { Line OK "SMB to \\$fqdn\$share connected" }
    else { Line OK "SMB reaches \\$fqdn\$share (error $smbCode as SYSTEM is expected - SYSTEM has no user Kerberos ticket)" }
}

# ---------------------------------------------------------------- FSLogix log
$hints = @{
    '5'    = 'Access denied: storage firewall not allowing this subnet, share-level permission (up to 30 min to apply), or NTFS - see the Azure-side checks above'
    '53'   = 'Network path not found: DNS or port 445'
    '67'   = 'Network name not found: share name / DNS'
    '86'   = 'Invalid password: no Kerberos ticket - admin consent / privatelink names (Set-FslogixStorageAuth.ps1), restart'
    '1326' = 'Bad credentials: Kerberos fell back to NTLM - privatelink identifierUris missing (Set-FslogixStorageAuth.ps1), admin consent, or host not restarted'
    '1327' = 'Account restrictions: an MFA Conditional Access policy applies to the storage app - exclude it'
    '1311' = 'No logon servers: Entra Kerberos ticket retrieval not working - check the registry setting and restart'
}
$logDir = 'C:\ProgramData\FSLogix\Logs\Profile'
$log = Get-ChildItem -Path $logDir -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $log) { Line INFO 'No FSLogix profile log yet (nobody has signed in)' }
else {
    # Only the most recent sign-in attempt matters - earlier errors may predate a fix.
    $all = @(Get-Content -LiteralPath $log.FullName)
    $startIx = 0
    foreach ($marker in 'Begin Session', 'LoadProfile') {
        $hits = @(for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i] -match $marker) { $i } })
        if ($hits.Count) { $startIx = $hits[-1]; break }
    }
    $attemptTime = if ($all.Count -and $all[$startIx] -match '^\[(\d{2}:\d{2}:\d{2})') { $Matches[1] } else { '?' }
    $errs = @($all[$startIx..($all.Count - 1)] | Where-Object { $_ -match '\[ERROR' } | Select-Object -Last 6)
    $older = @($all[0..([math]::Max(0, $startIx - 1))] | Where-Object { $_ -match '\[ERROR' }).Count
    Line INFO ("Most recent sign-in attempt in {0}: {1} (log updated {2:HH:mm:ss})" -f $log.Name, $attemptTime, $log.LastWriteTime)
    if ($older -and $startIx -gt 0) { Line INFO "$older older error(s) earlier in the log ignored - they predate the latest attempt" }
    if (-not $errs.Count) { Line OK 'No errors in the most recent sign-in attempt' }
    else {
        Line INFO 'Errors in the most recent attempt:'
        $codes = @{}
        foreach ($e in $errs) {
            $t = "$e".Trim(); if ($t.Length -gt 170) { $t = $t.Substring(0, 170) + '...' }
            Write-Output "  $t"
            # FSLogix writes codes as 8-digit hex, e.g. [ERROR:0000052E] = 1326.
            foreach ($m in [regex]::Matches("$e", 'ERROR:([0-9A-Fa-f]{8})')) { $codes[[string][Convert]::ToInt32($m.Groups[1].Value, 16)] = $true }
            foreach ($m in [regex]::Matches("$e", '\((\d{1,4})\)')) { $codes[$m.Groups[1].Value] = $true }
        }
        foreach ($c in $codes.Keys) { if ($hints.ContainsKey($c)) { Line HINT "($c) $($hints[$c])" } }
    }
}
