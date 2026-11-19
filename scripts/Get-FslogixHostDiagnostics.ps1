<#
.SYNOPSIS
    Runs the FSLogix / Entra Kerberos diagnostics on a session host and shows the result.

.DESCRIPTION
    Pushes infra/scripts/Test-FslogixHost.ps1 to the VM with Run Command (no RDP needed) and
    prints its report:
      * the Kerberos / FSLogix registry settings and last boot time
      * required services (IP Helper, WinHTTP auto-proxy) and Entra join state
      * DNS for the storage account: private endpoint IP or public IP, privatelink CNAME
      * TCP 445 to the share
      * the last errors from the FSLogix profile log, with the likely fix for each error code
    Read-only. The VM must be running.

.EXAMPLE
    .\scripts\Get-FslogixHostDiagnostics.ps1 -ParameterFile .\infra\params\prod.bicepparam -VmName avdsh-001
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VmName,
    [string] $ParameterFile,
    [string] $ResourceGroup
)
$networkAccess = $null

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$hostScript = Join-Path (Join-Path (Join-Path $repoRoot 'infra') 'scripts') 'Test-FslogixHost.ps1'

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
    if (Test-Path -LiteralPath $outputsFile) {
        $outs = Get-Content -Raw -LiteralPath $outputsFile | ConvertFrom-Json
        if (-not $ResourceGroup) { $ResourceGroup = $outs.sessionHostResourceGroup.value }
        if ($outs.PSObject.Properties['fslogixNetworkAccess'] -and $outs.fslogixNetworkAccess.value) { $networkAccess = $outs.fslogixNetworkAccess.value }
    }
    if (-not $networkAccess -and $paramText -match "(?m)^param\s+fslogixNetworkAccess\s*=\s*'([^']+)'") { $networkAccess = $Matches[1] }
}
if (-not $networkAccess) { $networkAccess = 'privateEndpoint' }
if (-not $ResourceGroup) { throw 'Session host resource group unknown - pass -ResourceGroup (or -ParameterFile after a Deploy-Avd.ps1 run).' }

Write-Host "Running diagnostics on $VmName (takes about a minute)..." -ForegroundColor Cyan
$r = Test-Az vm run-command invoke --resource-group $ResourceGroup --name $VmName --command-id RunPowerShellScript --scripts "@$hostScript" --parameters "NetworkAccess=$networkAccess" --query 'value[0].message' -o tsv --only-show-errors
if (-not $r.Ok) { throw "Run Command failed on $VmName. Is the VM running? (az vm start -g $ResourceGroup -n $VmName)" }

Write-Host ''
foreach ($line in ($r.Output -split "`r?`n")) {
    if ($line -match '^\[stdout\]|^\[stderr\]' -or -not $line.Trim()) { continue }
    $colour = if ($line -match '^\[FAIL\]') { 'Red' } elseif ($line -match '^\[(WARN|HINT)\]') { 'Yellow' } elseif ($line -match '^\[OK\]') { 'Green' } else { 'Gray' }
    Write-Host $line -ForegroundColor $colour
}
