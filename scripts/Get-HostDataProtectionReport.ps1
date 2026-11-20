<#
.SYNOPSIS
    Shows what data-protection settings are really in effect on a session host.

.DESCRIPTION
    Read-only. Pushes infra/scripts/Test-DataProtectionHost.ps1 with Run Command and prints:
      * when the customisation last ran, whether it included data protection, and any
        failures it logged (e.g. tenant restrictions fields not found)
      * whether a restart is still needed
      * Microsoft-account block, OneDrive allowed tenants, Edge URL block list
      * the Tenant Restrictions v2 values actually present (none = Entra's tenant
        restrictions policy has nothing on this device to enforce it)
      * for each signed-in user: personal OneDrive sync state and which tenant(s) their
        OneDrive app is syncing
    Run it while a test user is signed in to see their OneDrive state.

.EXAMPLE
    .\scripts\Get-HostDataProtectionReport.ps1 -ParameterFile .\infra\params\prod.bicepparam -VmName avdpd-005
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VmName,
    [string] $ParameterFile,
    [string] $ResourceGroup
)

$ErrorActionPreference = 'Stop'
$hostScript = Join-Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'infra') 'scripts') 'Test-DataProtectionHost.ps1'

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

if ($ParameterFile) {
    $ParameterFile = (Resolve-Path -LiteralPath $ParameterFile).Path
    $paramText = Get-Content -Raw -LiteralPath $ParameterFile
    if ($paramText -match '(?m)^//\s*subscriptionId:\s*([0-9a-fA-F-]{36})') { $null = Test-Az account set --subscription $Matches[1] --only-show-errors }
    $outputsFile = Join-Path (Split-Path -Parent $ParameterFile) (([IO.Path]::GetFileNameWithoutExtension($ParameterFile)) + '.outputs.json')
    if (-not $ResourceGroup -and (Test-Path -LiteralPath $outputsFile)) { $ResourceGroup = (Get-Content -Raw -LiteralPath $outputsFile | ConvertFrom-Json).sessionHostResourceGroup.value }
}
if (-not $ResourceGroup) { throw 'Session host resource group unknown - pass -ResourceGroup (or -ParameterFile after a Deploy-Avd.ps1 run).' }

Write-Host "Checking data protection on $VmName (about a minute)..." -ForegroundColor Cyan
$r = Test-Az vm run-command invoke --resource-group $ResourceGroup --name $VmName --command-id RunPowerShellScript --scripts "@$hostScript" --query 'value[0].message' -o tsv --only-show-errors
if (-not $r.Ok) { throw "Run Command failed on $VmName. Is the VM running?" }
Write-Host ''
foreach ($line in ($r.Output -split "`r?`n")) {
    if ($line -match '^\[stdout\]|^\[stderr\]' -or -not $line.Trim()) { continue }
    $colour = if ($line -match '^\[FAIL\]') { 'Red' } elseif ($line -match '^\[WARN\]') { 'Yellow' } elseif ($line -match '^\[OK\]') { 'Green' } else { 'Gray' }
    Write-Host $line -ForegroundColor $colour
}
