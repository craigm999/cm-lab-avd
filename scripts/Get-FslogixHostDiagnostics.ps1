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
    [string] $ResourceGroup,
    [string] $StorageAccountName,
    [ValidateSet('privateEndpoint', 'serviceEndpoint')] [string] $NetworkAccess
)
$networkAccess = $NetworkAccess

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
        if (-not $StorageAccountName -and $outs.PSObject.Properties['fslogixStorageAccountName']) { $StorageAccountName = $outs.fslogixStorageAccountName.value }
        if ($outs.PSObject.Properties['fslogixNetworkAccess'] -and $outs.fslogixNetworkAccess.value) { $networkAccess = $outs.fslogixNetworkAccess.value }
    }
    if (-not $networkAccess -and $paramText -match "(?m)^param\s+fslogixNetworkAccess\s*=\s*'([^']+)'") { $networkAccess = $Matches[1] }
}
if (-not $networkAccess) { $networkAccess = 'privateEndpoint' }
if (-not $ResourceGroup) { throw 'Session host resource group unknown - pass -ResourceGroup (or -ParameterFile after a Deploy-Avd.ps1 run).' }

function Write-Check([string] $State, [string] $Text) {
    $colour = @{ OK = 'Green'; FAIL = 'Red'; WARN = 'Yellow'; INFO = 'Gray' }[$State]
    Write-Host ('[{0}] {1}' -f $State, $Text) -ForegroundColor $colour
}
function ConvertFrom-AzJson([string] $Text) {
    if (-not $Text) { return @() }
    $parsed = $Text | ConvertFrom-Json
    return @(foreach ($p in $parsed) { $p })
}

# ------------------------------------------------------------------ Azure side: the causes of
# "Access is denied" (error 5) that the host can't see - storage firewall / VNet rules and
# share-level permissions (Microsoft Learn: Azure Files SMB connectivity troubleshooting).
if ($StorageAccountName) {
    Write-Host "Storage account $StorageAccountName (Azure side)" -ForegroundColor Cyan
    $sa = $null
    $q = '{id:id, location:location, public:publicNetworkAccess, default:networkRuleSet.defaultAction, rules:networkRuleSet.virtualNetworkRules[].{id:virtualNetworkResourceId, state:state}, pe:length(privateEndpointConnections || `[]`), dirsvc:azureFilesIdentityBasedAuthentication.directoryServiceOptions, sharePerm:azureFilesIdentityBasedAuthentication.defaultSharePermission}'
    $r0 = Test-Az storage account show --name $StorageAccountName --query $q -o json --only-show-errors
    if ($r0.Ok -and $r0.Output) { $sa = $r0.Output | ConvertFrom-Json }
    $vm = $null
    $r1 = Test-Az vm show --resource-group $ResourceGroup --name $VmName --query '{location:location, nic:networkProfile.networkInterfaces[0].id}' -o json --only-show-errors
    if ($r1.Ok -and $r1.Output) { $vm = $r1.Output | ConvertFrom-Json }
    $subnetId = $null
    if ($vm) { $subnetId = (Test-Az network nic show --ids $vm.nic --query 'ipConfigurations[0].subnet.id' -o tsv --only-show-errors).Output }

    if (-not $sa) { Write-Check WARN "Could not read storage account $StorageAccountName" }
    else {
        if ("$($sa.dirsvc)" -eq 'AADKERB') { Write-Check OK 'Identity source: Microsoft Entra Kerberos' } else { Write-Check FAIL "Identity source is '$($sa.dirsvc)', expected AADKERB" }
        if ($vm -and "$($vm.location)" -ne "$($sa.location)") { Write-Check WARN "Storage account is in $($sa.location) but the host is in $($vm.location)" }

        if ($networkAccess -eq 'serviceEndpoint') {
            if ("$($sa.public)" -eq 'Enabled') { Write-Check OK 'Public network access: Enabled (firewalled)' }
            else { Write-Check FAIL "Public network access is '$($sa.public)' - service endpoint mode needs it Enabled. Re-run Deploy-Avd.ps1 -InfraOnly with fslogixNetworkAccess = 'serviceEndpoint'." }
            if ("$($sa.default)" -ne 'Deny') { Write-Check WARN "Firewall default action is '$($sa.default)' (expected Deny)" }
            $rules = @(foreach ($x in $sa.rules) { $x })
            $match = @($rules | Where-Object { $subnetId -and "$($_.id)" -ieq "$subnetId" })
            if ($match.Count -and "$($match[0].state)" -eq 'Succeeded') { Write-Check OK 'Storage firewall allows the host subnet' }
            elseif ($match.Count) { Write-Check FAIL "Storage firewall rule for the host subnet is '$($match[0].state)' (not Succeeded)" }
            else {
                Write-Check FAIL 'Storage firewall does NOT allow the host subnet - this alone gives Access is denied (error 5).'
                if ($subnetId) { Write-Host "       Host subnet: $subnetId" -ForegroundColor Red }
                Write-Host '       Fix: re-run Deploy-Avd.ps1 -InfraOnly (adds the rule), or:' -ForegroundColor Red
                Write-Host ("       az storage account network-rule add --resource-group {0} --account-name {1} --subnet {2}" -f ("$($sa.id)" -split '/')[4], $StorageAccountName, $subnetId) -ForegroundColor Red
            }
            if ($subnetId) {
                $se = @(ConvertFrom-AzJson (Test-Az network vnet subnet show --ids $subnetId --query 'serviceEndpoints[].{service:service, state:provisioningState}' -o json --only-show-errors).Output)
                $st = @($se | Where-Object { "$($_.service)" -like 'Microsoft.Storage*' })
                if ($st.Count -and "$($st[0].state)" -eq 'Succeeded') { Write-Check OK "Host subnet has the $($st[0].service) service endpoint" }
                else { Write-Check FAIL 'Host subnet has no (working) Microsoft.Storage service endpoint - traffic arrives from a public IP and the firewall denies it.' }
            }
            if ([int]$sa.pe -gt 0) { Write-Check WARN "The account still has $($sa.pe) private endpoint connection(s). Delete the old private endpoint (pe-$StorageAccountName-file) so DNS stops pointing at privatelink." }
        }
        else {
            if ("$($sa.public)" -eq 'Disabled') { Write-Check OK 'Public network access: Disabled (private endpoint mode)' } else { Write-Check INFO "Public network access: $($sa.public)" }
            if ([int]$sa.pe -lt 1) { Write-Check FAIL 'No private endpoint connection on the account' } else { Write-Check OK "$($sa.pe) private endpoint connection(s)" }
        }

        $perm = "$($sa.sharePerm)"
        if ($perm -and $perm -ne 'None') { Write-Check OK "Default share-level permission for all authenticated identities: $perm" }
        else { Write-Check WARN 'No default share-level permission - access depends on the group role assignment (and, for cloud-only groups, the kdc_enable_cloud_group_sids tag). Changes take up to ~30 minutes.' }
        $ras = @(ConvertFrom-AzJson (Test-Az role assignment list --scope $sa.id --query "[?starts_with(roleDefinitionName, 'Storage File Data')].{role:roleDefinitionName, name:principalName}" -o json --only-show-errors).Output)
        foreach ($ra in $ras) { Write-Check INFO "Share role: $($ra.role) -> $($ra.name)" }
    }
    Write-Host ''
}

Write-Host "Running diagnostics on $VmName (takes about a minute)..." -ForegroundColor Cyan
$r = Test-Az vm run-command invoke --resource-group $ResourceGroup --name $VmName --command-id RunPowerShellScript --scripts "@$hostScript" --parameters "NetworkAccess=$networkAccess" --query 'value[0].message' -o tsv --only-show-errors
if (-not $r.Ok) { throw "Run Command failed on $VmName. Is the VM running? (az vm start -g $ResourceGroup -n $VmName)" }

Write-Host ''
foreach ($line in ($r.Output -split "`r?`n")) {
    if ($line -match '^\[stdout\]|^\[stderr\]' -or -not $line.Trim()) { continue }
    $colour = if ($line -match '^\[FAIL\]') { 'Red' } elseif ($line -match '^\[(WARN|HINT)\]') { 'Yellow' } elseif ($line -match '^\[OK\]') { 'Green' } else { 'Gray' }
    Write-Host $line -ForegroundColor $colour
}
