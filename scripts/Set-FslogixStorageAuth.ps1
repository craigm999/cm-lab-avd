<#
.SYNOPSIS
    One-off Entra ID setup that FSLogix on Azure Files (Entra Kerberos, private endpoint) needs.

.DESCRIPTION
    Enabling Entra Kerberos on the storage account creates an Entra app registration named
    "[Storage Account] <account>.file.core.windows.net". This script configures it, following
    Microsoft Learn (Azure Files Entra Kerberos; SMB authentication troubleshooting):

      1. Private link names. The share is reached through a private endpoint, so DNS resolves
         the account to <account>.privatelink.file.core.windows.net. Without matching
         identifierUris the client can't get a Kerberos ticket, falls back to NTLM and fails
         with error 1326. Adds a privatelink entry for every file.core.windows.net entry.
      2. Cloud-only groups. Adds the 'kdc_enable_cloud_group_sids' tag so cloud-only Entra
         groups are included in the Kerberos ticket (needed for cloud-only identities).
         Skip with -SkipCloudGroupTag.
      3. Admin consent for the app's permissions (openid, profile, User.Read).
      4. Checks Conditional Access (read-only). Entra Kerberos doesn't support MFA for the
         share, so the app must be excluded from MFA policies that target all apps
         (otherwise error 1327). The script reports policies to fix; it doesn't edit them.

    Run as a Global Administrator, or an Application Administrator / Cloud Application
    Administrator plus Conditional Access read access. Supports -WhatIf. Safe to re-run.

.EXAMPLE
    .\scripts\Set-FslogixStorageAuth.ps1 -ParameterFile .\infra\params\prod.bicepparam -WhatIf
    .\scripts\Set-FslogixStorageAuth.ps1 -ParameterFile .\infra\params\prod.bicepparam
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ParameterFile,
    [string] $StorageAccountName,
    [switch] $SkipCloudGroupTag
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
function Write-Step([string] $Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }

# ------------------------------------------------------------------ Resolve the storage account
if ($ParameterFile) {
    $ParameterFile = (Resolve-Path -LiteralPath $ParameterFile).Path
    $paramText = Get-Content -Raw -LiteralPath $ParameterFile
    if ($paramText -match '(?m)^//\s*subscriptionId:\s*([0-9a-fA-F-]{36})') { $null = Test-Az account set --subscription $Matches[1] --only-show-errors }
    $outputsFile = Join-Path (Split-Path -Parent $ParameterFile) (([IO.Path]::GetFileNameWithoutExtension($ParameterFile)) + '.outputs.json')
    if (-not $StorageAccountName -and (Test-Path -LiteralPath $outputsFile)) {
        $StorageAccountName = (Get-Content -Raw -LiteralPath $outputsFile | ConvertFrom-Json).fslogixStorageAccountName.value
    }
}
if (-not $StorageAccountName) { throw 'Storage account unknown - pass -StorageAccountName (or -ParameterFile after a Deploy-Avd.ps1 run).' }

$tenantId = (Test-Az account show --query tenantId -o tsv --only-show-errors).Output
$displayName = "[Storage Account] $StorageAccountName.file.core.windows.net"
Write-Host ''
Write-Host "Storage account : $StorageAccountName"
Write-Host "Entra app       : $displayName"

$apps = @(ConvertFrom-AzJson (Test-Az ad app list --filter "displayName eq '$displayName'" --query '[].{id:id, appId:appId, uris:identifierUris, tags:tags}' -o json --only-show-errors).Output)
if (-not $apps.Count) {
    throw "No app registration '$displayName' found. Entra Kerberos creates it when the storage account is deployed with directoryServiceOptions AADKERB - check the FSLogix storage deployment finished, then re-run."
}
$app = $apps[0]
$uris = @(foreach ($u in $app.uris) { "$u" })
$tags = @(foreach ($t in $app.tags) { "$t" })

# ------------------------------------------------------------------ 1 + 2. Manifest changes
Write-Step 'Private link names and cloud-only group support'
$newUris = @($uris)
foreach ($u in $uris) {
    if ($u -match '\.file\.core\.windows\.net$' -and $u -notmatch '\.privatelink\.file\.') {
        $pl = $u -replace '\.file\.core\.windows\.net$', '.privatelink.file.core.windows.net'
        if ($newUris -notcontains $pl) { $newUris += $pl }
    }
}
$addedUris = @($newUris | Where-Object { $uris -notcontains $_ })
$newTags = @($tags)
if (-not $SkipCloudGroupTag -and $newTags -notcontains 'kdc_enable_cloud_group_sids') { $newTags += 'kdc_enable_cloud_group_sids' }
$addedTags = @($newTags | Where-Object { $tags -notcontains $_ })

if (-not $addedUris.Count -and -not $addedTags.Count) {
    Write-Host '  Already configured - no manifest changes needed.' -ForegroundColor Green
}
else {
    foreach ($u in $addedUris) { Write-Host "  + identifierUri $u" }
    foreach ($t in $addedTags) { Write-Host "  + tag $t" }
    if ($PSCmdlet.ShouldProcess($displayName, 'Update identifierUris/tags')) {
        $body = @{ identifierUris = $newUris; tags = $newTags } | ConvertTo-Json -Depth 3
        $tmp = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($false)))
            $r = Test-Az rest --method patch --url "https://graph.microsoft.com/v1.0/applications/$($app.id)" --headers 'Content-Type=application/json' --body "@$tmp" --only-show-errors
            if (-not $r.Ok) { throw 'Updating the app registration failed - you need Application Administrator (or owner of the app).' }
            Write-Host '  Updated.' -ForegroundColor Green
        }
        finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    }
}

# ------------------------------------------------------------------ 3. Admin consent
Write-Step 'Admin consent (openid, profile, User.Read)'
if ($PSCmdlet.ShouldProcess($displayName, 'Grant tenant-wide admin consent')) {
    $c = Test-Az ad app permission admin-consent --id $app.appId --only-show-errors
    if ($c.Ok) { Write-Host '  Consent granted.' -ForegroundColor Green }
    else {
        Write-Host '  Could not grant consent from the CLI (needs Global Administrator or Privileged Role Administrator).' -ForegroundColor Yellow
        Write-Host "  Portal: Entra ID > App registrations > All applications > $displayName > API permissions > Grant admin consent." -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------ 4. Conditional Access (read-only)
Write-Step 'Conditional Access check (MFA must not apply to this app)'
$ca = Test-Az rest --method get --url 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies' --query "value[?state=='enabled'].{name:displayName, include:conditions.applications.includeApplications, exclude:conditions.applications.excludeApplications, controls:grantControls.builtInControls, strength:grantControls.authenticationStrength.id}" -o json --only-show-errors
if (-not $ca.Ok) {
    Write-Host '  Could not read Conditional Access policies (needs Policy.Read.All / Security Reader).' -ForegroundColor Yellow
    Write-Host "  Check manually: exclude the app '$displayName' (app ID $($app.appId)) from every policy that requires MFA for All cloud apps." -ForegroundColor Yellow
}
else {
    $blocking = @()
    foreach ($p in (ConvertFrom-AzJson $ca.Output)) {
        $inc = @(foreach ($x in $p.include) { "$x" }); $exc = @(foreach ($x in $p.exclude) { "$x" })
        $ctl = @(foreach ($x in $p.controls) { "$x" })
        $needsMfa = ($ctl -contains 'mfa') -or [bool]$p.strength
        $covers = ($inc -contains 'All' -or $inc -contains $app.appId) -and ($exc -notcontains $app.appId)
        if ($needsMfa -and $covers) { $blocking += $p.name }
    }
    if ($blocking.Count) {
        Write-Host '  These enabled policies require MFA and include this app:' -ForegroundColor Red
        foreach ($b in $blocking) { Write-Host "    - $b" -ForegroundColor Red }
        Write-Host "  Exclude '$displayName' (app ID $($app.appId)) under Target resources > Exclude in each policy." -ForegroundColor Red
        Write-Host '  Until then, profile mounts fail (error 1327).' -ForegroundColor Red
    }
    else { Write-Host '  No enabled MFA policy covers this app.' -ForegroundColor Green }
}

Write-Host ''
Write-Host 'Next:' -ForegroundColor White
Write-Host '  - Restart the session hosts (or sign users out); Kerberos changes apply at the next sign-in/boot.'
Write-Host '  - Share permission changes can take up to ~30 minutes to apply.'
Write-Host '  - Verify with: .\scripts\Get-FslogixHostDiagnostics.ps1 -ParameterFile <file> -VmName <host>'
