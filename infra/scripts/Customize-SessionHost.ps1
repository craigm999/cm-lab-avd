<#
.SYNOPSIS
    Build-time customisation of an AVD session host: optimisation, security hardening, apps.

.DESCRIPTION
    Runs ON the session host as the "Customize-SessionHost" managed run command. The template
    runs it after the FSLogix/Kerberos configuration and BEFORE the AVD agent registers the
    host, so users never land on a half-built desktop. scripts/Update-SessionHostConfig.ps1
    -Customize pushes it again to existing hosts. It is safe to re-run.

    Settings come from infra/customizations/customizations.json (base64 JSON parameter):
      optimize : consumer features/tips off, first-logon animation off, listed built-in
                 Appx packages removed
      harden   : LLMNR off, AutoRun off, LSA protection, WDigest off, Defender PUA
                 protection (+ optional network protection), firewall on, logon auditing
      redirection : device redirection policy (drives, printers, USB/PnP, COM/LPT, smart
                 cards, cameras blocked; clipboard, audio, microphone allowed by default)
      dataProtection : block Microsoft (personal) accounts on Windows, OneDrive sync only
                 for your tenant (no personal OneDrive), Edge sign-in pattern and URL block
                 list, and optionally Entra Tenant Restrictions v2 (Windows policy)
      apps     : downloaded and installed silently - MSI or EXE, optional SHA-256 check,
                 optional detectPath to skip apps that are already installed,
                 fileName (URLs without a file name), files (inline config files written
                 next to the installer; reference the folder as {dir} in arguments) and
                 registry (settings applied after install, e.g. update policies)

    -DryRun prints what would be done without changing anything.
    Log: C:\ProgramData\AvdCustomization\customize.log
#>
param(
    [string] $ConfigBase64 = '',
    [string] $DryRun = 'False',
    [string] $PolicyDefinitionsPath = "$env:WINDIR\PolicyDefinitions",
    [string] $DefaultUserHive = 'C:\Users\Default\NTUSER.DAT'
)

$ErrorActionPreference = 'Stop'
$dry = [System.Convert]::ToBoolean($DryRun)
$logDir = 'C:\ProgramData\AvdCustomization'
if (-not $dry) { $null = New-Item -ItemType Directory -Force -Path $logDir }
$script:failures = 0

function Log([string] $Text) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Text
    Write-Output $line
    if (-not $dry) { Add-Content -Path (Join-Path $logDir 'customize.log') -Value $line }
}
function Set-Reg([string] $Path, [string] $Name, $Value, [string] $Type = 'DWord') {
    if ($dry) { Log "  [dry-run] $Path\$Name = $Value"; return }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Get-Prop($Object, [string] $Name, $Default) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { return $Object.$Name }
    return $Default
}

$config = $null
if ($ConfigBase64) { $config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ConfigBase64)) | ConvertFrom-Json }
if (-not $config) { Log 'No customisation config supplied - nothing to do.'; exit 0 }
Log ("Session host customisation starting{0}" -f $(if ($dry) { ' (DRY RUN - no changes)' } else { '' }))

# ---------------------------------------------------------------- Optimisation
$opt = Get-Prop $config 'optimize' $null
if (Get-Prop $opt 'enabled' $false) {
    Log 'Optimisation'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'EnableFirstLogonAnimation' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' 'DisablePrivacyExperience' 1
    foreach ($pkg in @(Get-Prop $opt 'removeAppxPackages' @())) {
        if ($dry) { Log "  [dry-run] remove Appx package $pkg"; continue }
        try {
            Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $pkg } | Remove-AppxProvisionedPackage -Online -AllUsers -ErrorAction SilentlyContinue | Out-Null
            Get-AppxPackage -AllUsers -Name $pkg -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            Log "  removed $pkg"
        }
        catch { Log "  could not remove $pkg - $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------- Hardening
$hard = Get-Prop $config 'harden' $null
if (Get-Prop $hard 'enabled' $false) {
    Log 'Security hardening'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0                         # LLMNR off
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255           # AutoRun off
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL' 1                                               # LSA protection
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential' 0               # no cleartext creds
    if ($dry) { Log '  [dry-run] firewall on for all profiles; Defender PUA protection on; audit logon events' }
    else {
        Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True
        try { Set-MpPreference -PUAProtection Enabled } catch { Log "  Defender PUA protection not set - $($_.Exception.Message)" }
        if (Get-Prop $hard 'defenderNetworkProtection' $false) {
            try { Set-MpPreference -EnableNetworkProtection Enabled; Log '  Defender network protection on' } catch { Log "  network protection not set - $($_.Exception.Message)" }
        }
        $null = auditpol.exe /set /subcategory:"Logon" /success:enable /failure:enable
        $null = auditpol.exe /set /subcategory:"Account Lockout" /failure:enable
    }
}

# ---------------------------------------------------------------- Device redirection
# Session host policy ("Remote Desktop Session Host > Device and Resource Redirection").
# The host pool's RDP properties are built from the same settings; the most restrictive
# of the two wins, so enforcing here means a client can't opt back in.
$redir = Get-Prop $config 'redirection' $null
if ($null -ne $redir) {
    Log 'Device redirection policy'
    $ts = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    # setting, registry value, data when BLOCKED, data when ALLOWED, default if not in config
    $policies = @(
        @('drives', 'fDisableCdm', 1, 0, $false),           # Do not allow drive redirection
        @('printers', 'fDisableCpm', 1, 0, $false),         # Do not allow client printer redirection
        @('comPorts', 'fDisableCcm', 1, 0, $false),         # Do not allow COM port redirection
        @('comPorts', 'fDisableLPT', 1, 0, $false),         # Do not allow LPT port redirection
        @('usbDevices', 'fDisablePNPRedir', 1, 0, $false),  # Do not allow supported Plug and Play device redirection
        @('smartCards', 'fEnableSmartCard', 0, 1, $false),  # Do not allow smart card device redirection
        @('cameras', 'fDisableCameraRedir', 1, 0, $false),  # Do not allow video capture redirection
        @('clipboard', 'fDisableClip', 1, 0, $true),        # Do not allow Clipboard redirection
        @('audioPlayback', 'fDisableCam', 1, 0, $true),     # Allow audio and video playback redirection
        @('microphone', 'fDisableAudioCapture', 1, 0, $true) # Allow audio recording redirection
    )
    foreach ($p in $policies) {
        $allowed = [bool](Get-Prop $redir $p[0] $p[4])
        Set-Reg $ts $p[1] $(if ($allowed) { $p[3] } else { $p[2] })
        if (-not $dry) { Log ("  {0}: {1}" -f $p[0], $(if ($allowed) { 'allowed' } else { 'blocked' })) }
    }
    Log '  Applies to new sessions (users sign out and back in).'
}

# ---------------------------------------------------------------- Data protection
function Set-DefaultUserReg([string] $SubKey, [string] $Name, $Value) {
    # Per-user policies go into the default profile, so every NEW profile gets them.
    if ($dry) { Log "  [dry-run] default user profile: $SubKey\$Name = $Value"; return }
    $null = reg.exe load 'HKU\AvdDefaultUser' $DefaultUserHive
    try {
        $path = "Registry::HKEY_USERS\AvdDefaultUser\$SubKey"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -Path $path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
    }
    finally { [gc]::Collect(); [gc]::WaitForPendingFinalizers(); $null = reg.exe unload 'HKU\AvdDefaultUser' }
}

function Set-TenantRestrictionsPolicy([string] $Tenant, [string] $PolicyId, [bool] $Firewall) {
    # Microsoft Learn documents this as a Group Policy ("Tenant Restrictions > Cloud Policy
    # Details": Microsoft Entra Directory ID, Policy GUID, Enable firewall protection of
    # Microsoft endpoints) but not its registry values. So read the policy definition that
    # ships with THIS Windows build and write exactly what it describes.
    $admxFile = Get-ChildItem -Path $PolicyDefinitionsPath -Filter *.admx -ErrorAction SilentlyContinue |
        Where-Object { (Get-Content -Raw $_.FullName) -match 'TenantRestrictions' } | Select-Object -First 1
    if (-not $admxFile) { Log '  Tenant restrictions: FAILED - no Tenant Restrictions policy definition on this Windows build'; $script:failures++; return }
    [xml]$admx = Get-Content -Raw $admxFile.FullName
    $pol = @($admx.policyDefinitions.policies.policy | Where-Object { $_.OuterXml -match 'TenantRestrictions' }) | Select-Object -First 1
    if (-not $pol) { $pol = @($admx.policyDefinitions.policies.policy) | Select-Object -First 1 }
    $labels = @{}
    $adml = Join-Path (Join-Path $PolicyDefinitionsPath 'en-US') ($admxFile.BaseName + '.adml')
    if (Test-Path $adml) {
        [xml]$admlXml = Get-Content -Raw $adml
        foreach ($pres in @($admlXml.policyDefinitionResources.resources.presentationTable.presentation)) {
            foreach ($c in @($pres.ChildNodes)) { if ($c.refId) { $labels[$c.refId] = (("$($c.label)", "$($c.InnerText)") | Where-Object { $_ } | Select-Object -First 1) } }
        }
    }
    $elements = @(foreach ($e in @($pol.elements.ChildNodes)) {
        if ($e.NodeType -ne 'Element') { continue }
        [pscustomobject]@{ Type = $e.LocalName; Id = "$($e.id)"; Label = "$($labels["$($e.id)"])"; Key = $(if ($e.key) { "$($e.key)" } else { "$($pol.key)" }); ValueName = "$($e.valueName)"; Node = $e }
    })
    foreach ($e in $elements) { Log ("  ADMX {0}: {1} '{2}' -> {3}\{4}" -f $e.Type, $e.Id, $e.Label, $e.Key, $e.ValueName) }
    $tenantEl = @($elements | Where-Object { $_.Type -eq 'text' -and ($_.Label -match 'Directory ID' -or $_.Id -match 'TenantId|DirectoryId') })
    $policyEl = @($elements | Where-Object { $_.Type -eq 'text' -and ($_.Label -match 'Policy GUID' -or $_.Id -match 'PolicyId|PolicyGuid') })
    $fwEl = @($elements | Where-Object { $_.Type -eq 'boolean' -and ($_.Label -match 'firewall' -or $_.Id -match 'Firewall') })
    if ($tenantEl.Count -ne 1 -or $policyEl.Count -ne 1) {
        Log "  Tenant restrictions: FAILED - couldn't identify the Directory ID / Policy GUID fields unambiguously (see ADMX lines above)"
        $script:failures++; return
    }
    if ($pol.valueName) {
        $on = if ($pol.enabledValue -and $pol.enabledValue.decimal) { [int]$pol.enabledValue.decimal.value } else { 1 }
        Set-Reg "HKLM:\$($pol.key)" "$($pol.valueName)" $on
    }
    Set-Reg "HKLM:\$($tenantEl[0].Key)" $tenantEl[0].ValueName $Tenant 'String'
    Set-Reg "HKLM:\$($policyEl[0].Key)" $policyEl[0].ValueName $PolicyId 'String'
    if ($fwEl.Count -eq 1) {
        $n = $fwEl[0].Node
        $data = if ($Firewall) { if ($n.trueValue -and $n.trueValue.decimal) { [int]$n.trueValue.decimal.value } else { 1 } } else { if ($n.falseValue -and $n.falseValue.decimal) { [int]$n.falseValue.decimal.value } else { 0 } }
        Set-Reg "HKLM:\$($fwEl[0].Key)" $fwEl[0].ValueName $data
    }
    Log "  Tenant restrictions v2: tenant $Tenant, policy $PolicyId$(if ($Firewall) { ', firewall protection on' })"
}

$dp = Get-Prop $config 'dataProtection' $null
if ($null -ne $dp) {
    Log 'Data protection'
    $tenant = [string](Get-Prop $dp 'tenantId' '')
    if (-not $tenant) {
        $line = @(dsregcmd.exe /status 2>$null) | Where-Object { $_ -match '^\s*TenantId\s*:' } | Select-Object -First 1
        if ("$line" -match '([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') { $tenant = $Matches[1] }
    }
    if (-not $tenant -and $dry) { $tenant = '<this host''s tenant>' }

    if (Get-Prop $dp 'blockMicrosoftAccounts' $false) {
        # Accounts: Block Microsoft accounts = "Users can't add or log on with Microsoft accounts" (3)
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'NoConnectedUser' 3
    }
    if (Get-Prop $dp 'oneDriveOnlyOwnTenant' $false) {
        if (-not $tenant) { Log '  OneDrive: FAILED - tenant ID unknown (set dataProtection.tenantId)'; $script:failures++ }
        else {
            Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive\AllowTenantList' $tenant $tenant 'String'   # sync only this organisation
            Set-DefaultUserReg 'SOFTWARE\Policies\Microsoft\OneDrive' 'DisablePersonalSync' 1                # no personal OneDrive sync
        }
    }
    $pattern = [string](Get-Prop $dp 'edgeSigninPattern' '')
    if ($pattern) { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'RestrictSigninToPattern' $pattern 'String' }
    $urls = @(Get-Prop $dp 'blockedUrls' @() | Where-Object { $_ })
    if ($urls.Count) {
        $blk = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist'
        if (-not $dry -and (Test-Path $blk)) { Remove-Item -Path $blk -Recurse -Force }   # the list is replaced, not appended
        for ($i = 0; $i -lt $urls.Count; $i++) { Set-Reg $blk ([string]($i + 1)) $urls[$i] 'String' }
    }
    $tr = Get-Prop $dp 'tenantRestrictions' $null
    if (Get-Prop $tr 'enabled' $false) {
        $trPolicy = [string](Get-Prop $tr 'policyId' '')
        if (-not $trPolicy -or -not $tenant) { Log '  Tenant restrictions: FAILED - set dataProtection.tenantRestrictions.policyId (Entra > External Identities > Cross-tenant access settings > Default settings > Tenant restrictions)'; $script:failures++ }
        else { Set-TenantRestrictionsPolicy $tenant $trPolicy ([bool](Get-Prop $tr 'firewallProtection' $false)) }
    }
}

# ---------------------------------------------------------------- Applications
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
foreach ($app in @(Get-Prop $config 'apps' @())) {
    $name = Get-Prop $app 'name' 'app'
    $url = Get-Prop $app 'url' ''
    $installArgs = [string](Get-Prop $app 'arguments' '')
    $sha = Get-Prop $app 'sha256' ''
    $detect = Get-Prop $app 'detectPath' ''
    if (-not $url) { Log "App '$name': no url - skipped"; continue }
    if ($detect -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($detect)))) { Log "App '$name': already installed ($detect) - skipped"; continue }
    # fileName: needed when the URL has no file name in it (e.g. VS Code's download link).
    $fileName = Get-Prop $app 'fileName' ''
    if (-not $fileName) { $fileName = [IO.Path]::GetFileName(([uri]$url).AbsolutePath) }
    if ($fileName -notmatch '\.(msi|exe)$') { Log "App '$name': can't tell the installer type from '$fileName' - set fileName (e.g. setup.exe) in the config"; $script:failures++; continue }
    $isMsi = $fileName -match '\.msi$'
    $work = Join-Path $env:TEMP ('avdapp-' + ($name -replace '[^A-Za-z0-9]', ''))
    $installArgs = $installArgs.Replace('{dir}', $work)           # {dir} = folder holding the installer and any 'files'
    $extraFiles = @(Get-Prop $app 'files' @())
    $regs = @(Get-Prop $app 'registry' @())
    if ($dry) {
        Log ("App '{0}': [dry-run] download {1} as {2}{3}, install {4} {5}" -f $name, $url, $fileName, $(if ($sha) { ' (SHA-256 checked)' } else { ' (NO hash check)' }), $(if ($isMsi) { 'msiexec /i /qn /norestart' } else { 'exe' }), $installArgs)
        foreach ($f in $extraFiles) { Log "  [dry-run] write $work\$($f.name)" }
        foreach ($r in $regs) { Set-Reg $r.path $r.name $r.value $(Get-Prop $r 'type' 'DWord') }
        continue
    }
    try {
        $null = New-Item -ItemType Directory -Force -Path $work
        $file = Join-Path $work $fileName
        foreach ($f in $extraFiles) { Set-Content -LiteralPath (Join-Path $work $f.name) -Value $f.content -Encoding ASCII }
        Log "App '$name': downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
        if ($sha) {
            $actual = (Get-FileHash -Path $file -Algorithm SHA256).Hash
            if ($actual -ne $sha.ToUpperInvariant()) { throw "SHA-256 mismatch (expected $sha, got $actual) - not installing" }
        }
        else { Log "App '$name': WARNING no sha256 in config - download not verified" }
        if ($isMsi) { $p = Start-Process msiexec.exe -ArgumentList ('/i "{0}" /qn /norestart {1}' -f $file, $installArgs) -Wait -PassThru }
        elseif ($installArgs) { $p = Start-Process -FilePath $file -ArgumentList $installArgs -Wait -PassThru }
        else { $p = Start-Process -FilePath $file -Wait -PassThru }
        if (@(0, 3010, 1641) -contains $p.ExitCode) { Log "App '$name': installed (exit $($p.ExitCode))" }
        else { throw "installer exit code $($p.ExitCode)" }
        # registry: settings applied after install, e.g. policies that turn off in-app updaters.
        foreach ($r in $regs) { Set-Reg $r.path $r.name $r.value $(Get-Prop $r 'type' 'DWord') }
    }
    catch { Log "App '$name': FAILED - $($_.Exception.Message)"; $script:failures++ }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures) { Log "$($script:failures) app(s) failed - see above."; exit 1 }
Log 'Session host customisation complete.'
