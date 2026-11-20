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
    [string] $DryRun = 'False'
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
