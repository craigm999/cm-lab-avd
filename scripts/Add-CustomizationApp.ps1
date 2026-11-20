<#
.SYNOPSIS
    Adds (or updates) an app in infra/customizations/customizations.json, with its SHA-256.

.DESCRIPTION
    Downloads the installer once on THIS machine, computes its SHA-256 and writes the app
    entry, so session hosts only install a file that matches what you checked. Re-run with
    -Replace and a new -Url to move an app to a new version (keeps its 'files' and
    'registry' settings).

    Afterwards: new hosts get the app automatically; push it to existing hosts with
      .\scripts\Update-SessionHostConfig.ps1 -ParameterFile <file> -Customize -IncludeStopped

.EXAMPLE
    .\scripts\Add-CustomizationApp.ps1 -Name 'Git' `
        -Url 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe' `
        -Arguments '/VERYSILENT /NORESTART /NOCANCEL /SP-' -DetectPath 'C:\Program Files\Git\cmd\git.exe'

.EXAMPLE
    # New version of an existing entry
    .\scripts\Add-CustomizationApp.ps1 -Name 'Visual Studio Code' -Url 'https://update.code.visualstudio.com/<version>/win32-x64/stable' -Replace
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Url,
    [string] $Arguments,
    [string] $DetectPath,
    [string] $FileName,
    [switch] $Replace,
    [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = [IO.Path]::Combine($PSScriptRoot, '..', 'infra', 'customizations', 'customizations.json') }
$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json

$apps = @(foreach ($a in @($cfg.apps)) { if ($a) { $a } })
$existing = @($apps | Where-Object { $_.name -eq $Name })
if ($existing.Count -and -not $Replace) { throw "An app named '$Name' already exists - use -Replace to update it." }
$old = if ($existing.Count) { $existing[0] } else { $null }

if (-not $FileName -and $old -and $old.PSObject.Properties['fileName']) { $FileName = $old.fileName }
if (-not $FileName) { $FileName = [IO.Path]::GetFileName(([uri]$Url).AbsolutePath) }
if ($FileName -notmatch '\.(msi|exe)$') { throw "Can't tell the installer type from '$FileName' - pass -FileName (e.g. -FileName setup.exe)." }

Write-Host "Downloading $Url ..."
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("addapp-" + [guid]::NewGuid().ToString('N') + '-' + $FileName)
try {
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
    $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
    $size = (Get-Item -LiteralPath $tmp).Length
}
finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
Write-Host ("  {0:N1} MB, SHA-256 {1}" -f ($size / 1MB), $hash)

$entry = [ordered]@{ name = $Name; url = $Url }
if ($FileName -ne [IO.Path]::GetFileName(([uri]$Url).AbsolutePath)) { $entry.fileName = $FileName }
$entry.arguments = if ($PSBoundParameters.ContainsKey('Arguments')) { $Arguments } elseif ($old -and $old.PSObject.Properties['arguments']) { $old.arguments } else { '' }
$entry.sha256 = $hash
$det = if ($PSBoundParameters.ContainsKey('DetectPath')) { $DetectPath } elseif ($old -and $old.PSObject.Properties['detectPath']) { $old.detectPath } else { '' }
if ($det) { $entry.detectPath = $det }
foreach ($keep in 'files', 'registry') { if ($old -and $old.PSObject.Properties[$keep]) { $entry[$keep] = $old.$keep } }

$newApps = @()
$placed = $false
foreach ($a in $apps) {
    if ($a.name -eq $Name) { $newApps += [pscustomobject]$entry; $placed = $true } else { $newApps += $a }
}
if (-not $placed) { $newApps += [pscustomobject]$entry }
if ($cfg.PSObject.Properties['apps']) { $cfg.apps = $newApps } else { $cfg | Add-Member -NotePropertyName apps -NotePropertyValue $newApps }

$json = $cfg | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("{0} '{1}' in {2}" -f $(if ($placed) { 'Updated' } else { 'Added' }), $Name, $ConfigPath) -ForegroundColor Green
if (-not $det) { Write-Host '  Tip: add -DetectPath so re-runs skip hosts that already have it.' -ForegroundColor Yellow }
Write-Host '  New hosts get it automatically. Existing hosts: Update-SessionHostConfig.ps1 -Customize -IncludeStopped'
