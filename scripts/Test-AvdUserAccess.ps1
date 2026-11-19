<#
.SYNOPSIS
    Read-only check of why a user can't see (or can't open) the AVD desktop.

.DESCRIPTION
    Walks the chain a user needs, in order, and prints PASS / WARN / FAIL with the fix:

      1. The user exists, is enabled, and whether they are a Member or Guest
      2. The user is in a group (or directly) assigned "Desktop Virtualization User"
         on the desktop application group                     -> controls the FEED
      3. The application group is registered in a workspace   -> controls the FEED
      4. "Virtual Machine User Login" (or Admin Login) on the session hosts
                                                              -> controls SIGN-IN
      5. Session hosts are Available and accepting new sessions
      6. Host pool has the Entra SSO RDP property; for guests, the tenant-wide
         Entra RDP setting on the "Windows Cloud Login" service principal is checked
      7. Guest-specific requirements

    Makes no changes. Needs `az login` with read access to the subscription; the Entra
    checks need directory read permission (group membership, service principals).

.EXAMPLE
    .\scripts\Test-AvdUserAccess.ps1 -ParameterFile .\infra\params\prod.bicepparam -User alice@contoso.com

.EXAMPLE
    # Guest: pass their email address or their #EXT# UPN
    .\scripts\Test-AvdUserAccess.ps1 -ParameterFile .\infra\params\prod.bicepparam -User bob@fabrikam.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $User,
    [string] $ParameterFile,
    [string] $HostPoolName,
    [string] $HostsResourceGroup
)

$ErrorActionPreference = 'Stop'
$script:Fails = 0
$script:Warns = 0

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
    # Returns a flat array. Windows PowerShell 5.1 emits a JSON array as ONE pipeline object.
    if (-not $Text) { return @() }
    $parsed = $Text | ConvertFrom-Json
    return @(foreach ($p in $parsed) { $p })
}
function Write-Result([string] $State, [string] $Text, [string] $Fix) {
    $colour = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }[$State]
    Write-Host ('  [{0}] {1}' -f $State, $Text) -ForegroundColor $colour
    if ($Fix) { Write-Host "         -> $Fix" -ForegroundColor $colour }
    if ($State -eq 'FAIL') { $script:Fails++ }
    if ($State -eq 'WARN') { $script:Warns++ }
}
function Write-Section([string] $Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }

# ------------------------------------------------------------------ Resolve names
if ($ParameterFile) {
    $ParameterFile = (Resolve-Path -LiteralPath $ParameterFile).Path
    $paramText = Get-Content -Raw -LiteralPath $ParameterFile
    if ($paramText -match '(?m)^//\s*subscriptionId:\s*([0-9a-fA-F-]{36})') { $null = Test-Az account set --subscription $Matches[1] --only-show-errors }
    $outputsFile = Join-Path (Split-Path -Parent $ParameterFile) (([IO.Path]::GetFileNameWithoutExtension($ParameterFile)) + '.outputs.json')
    if (Test-Path -LiteralPath $outputsFile) {
        $o = Get-Content -Raw -LiteralPath $outputsFile | ConvertFrom-Json
        if (-not $HostPoolName) { $HostPoolName = $o.hostPoolName.value }
        if (-not $HostsResourceGroup) { $HostsResourceGroup = $o.sessionHostResourceGroup.value }
    }
}
if (-not $HostPoolName) {
    $pools = @(ConvertFrom-AzJson (Test-Az resource list --resource-type Microsoft.DesktopVirtualization/hostPools --query '[].name' -o json --only-show-errors).Output)
    if ($pools.Count -eq 1) { $HostPoolName = "$($pools[0])" }
    else { throw 'Could not work out the host pool - pass -HostPoolName (or -ParameterFile after a Deploy-Avd.ps1 run).' }
}

$hp = @(ConvertFrom-AzJson (Test-Az resource list --resource-type Microsoft.DesktopVirtualization/hostPools --name $HostPoolName --query '[].{id:id, rg:resourceGroup}' -o json --only-show-errors).Output)
if (-not $hp.Count) { throw "Host pool '$HostPoolName' not found in the current subscription." }
$hostPoolId = $hp[0].id
$serviceRg = $hp[0].rg

Write-Host ''
Write-Host "AVD access check for $User" -ForegroundColor White
Write-Host "  Host pool: $HostPoolName (resource group $serviceRg)"

# ------------------------------------------------------------------ 1. User
Write-Section '1. User account'
$u = $null
$r = Test-Az ad user show --id $User --query '{id:id, upn:userPrincipalName, type:userType, enabled:accountEnabled, mail:mail}' -o json --only-show-errors
if ($r.Ok -and $r.Output) { $u = $r.Output | ConvertFrom-Json }
else {
    # Guests are usually found by email rather than their #EXT# UPN.
    $r = Test-Az ad user list --filter "mail eq '$User'" --query '[].{id:id, upn:userPrincipalName, type:userType, enabled:accountEnabled, mail:mail}' -o json --only-show-errors
    $list = @(ConvertFrom-AzJson $r.Output)
    if ($list.Count) { $u = $list[0] }
}
if (-not $u) {
    Write-Result FAIL "No user '$User' found in this tenant." 'For a guest, check the invitation was sent and redeemed (Entra ID > Users > the guest > Invitation state).'
    Write-Host ''; exit 1
}
$isGuest = ("$($u.type)" -eq 'Guest')
Write-Result INFO ("{0} ({1}), object ID {2}" -f $u.upn, $(if ($isGuest) { 'Guest' } else { 'Member' }), $u.id)
if ($u.enabled -eq $false) { Write-Result FAIL 'Account is disabled.' 'Enable the account.' }

$groupIds = @()
$g = Test-Az ad user get-member-groups --id $u.id --query '[].id' -o json --only-show-errors
if ($g.Ok) { $groupIds = @(ConvertFrom-AzJson $g.Output | ForEach-Object { "$_" }) }
else { Write-Result WARN 'Could not read the user''s group memberships (directory permissions?).' 'Check membership in the portal instead.' }

# ------------------------------------------------------------------ 2 + 3. Feed
Write-Section '2. Desktop assignment (what makes it appear in Windows App)'
$appGroups = @(ConvertFrom-AzJson (Test-Az resource list --resource-group $serviceRg --resource-type Microsoft.DesktopVirtualization/applicationGroups --query '[].id' -o json --only-show-errors).Output)
$assignedVia = $null
$assignedAppGroupIds = @()
foreach ($agId in $appGroups) {
    $ras = @(ConvertFrom-AzJson (Test-Az role assignment list --scope "$agId" --include-inherited --query "[?roleDefinitionName=='Desktop Virtualization User'].{pid:principalId, type:principalType, name:principalName}" -o json --only-show-errors).Output)
    foreach ($ra in $ras) {
        if ("$($ra.pid)" -eq "$($u.id)") { $assignedVia = 'direct assignment'; $assignedAppGroupIds += "$agId" }
        elseif ($ra.type -eq 'Group' -and $groupIds -contains "$($ra.pid)") {
            $assignedVia = "group $($ra.name) ($($ra.pid))"; $assignedAppGroupIds += "$agId"
            $direct = Test-Az ad group member check --group "$($ra.pid)" --member-id $u.id --query value -o tsv --only-show-errors
            if ($direct.Ok -and $direct.Output -eq 'false') {
                Write-Result WARN "User is in $($ra.name) only through a NESTED group." 'If the desktop does not show, add the user (or their group) to the assigned group directly to rule out nesting.'
            }
        }
    }
}
if ($assignedVia) { Write-Result PASS "Assigned 'Desktop Virtualization User' via $assignedVia." }
else {
    Write-Result FAIL 'User has no Desktop Virtualization User assignment on any application group in this host pool.' 'Add the user to the AVD users group used in the deployment (avdUsersGroupObjectId), or check that group ID in the parameter file is the right one. Then sign out of Windows App and back in.'
}

Write-Section '3. Workspace'
$workspaces = @(ConvertFrom-AzJson (Test-Az resource list --resource-group $serviceRg --resource-type Microsoft.DesktopVirtualization/workspaces --query '[].id' -o json --only-show-errors).Output)
$registered = $false
foreach ($wsId in $workspaces) {
    $refs = @(ConvertFrom-AzJson (Test-Az resource show --ids "$wsId" --query 'properties.applicationGroupReferences' -o json --only-show-errors).Output)
    foreach ($agId in $assignedAppGroupIds) { if (@($refs | ForEach-Object { "$_".ToLowerInvariant() }) -contains $agId.ToLowerInvariant()) { $registered = $true } }
}
if (-not $workspaces.Count) { Write-Result FAIL 'No workspace found.' 'Re-run Deploy-Avd.ps1 -InfraOnly.' }
elseif ($assignedAppGroupIds.Count -and -not $registered) { Write-Result FAIL 'The assigned application group is not registered in a workspace.' 'Re-run Deploy-Avd.ps1 -InfraOnly (the template registers it).' }
elseif ($registered) { Write-Result PASS 'Application group is registered in the workspace.' }

# ------------------------------------------------------------------ 4. Sign-in RBAC
Write-Section '4. Sign-in permission on the session hosts'
if ($HostsResourceGroup) {
    $loginRas = @(ConvertFrom-AzJson (Test-Az role assignment list --resource-group $HostsResourceGroup --include-inherited --query "[?roleDefinitionName=='Virtual Machine User Login' || roleDefinitionName=='Virtual Machine Administrator Login'].{pid:principalId, role:roleDefinitionName, name:principalName}" -o json --only-show-errors).Output)
    $login = @($loginRas | Where-Object { "$($_.pid)" -eq "$($u.id)" -or $groupIds -contains "$($_.pid)" })
    if ($login.Count) { Write-Result PASS ("Has {0} via {1}." -f $login[0].role, $login[0].name) }
    else { Write-Result FAIL 'No Virtual Machine User Login on the session hosts - the desktop will show but sign-in will be refused.' "Assign 'Virtual Machine User Login' on $HostsResourceGroup to the users group (the template does this; check the group ID)." }
}
else { Write-Result WARN 'Session host resource group unknown - skipped.' 'Pass -HostsResourceGroup or -ParameterFile.' }

# ------------------------------------------------------------------ 5. Hosts
Write-Section '5. Session hosts'
$sh = @(ConvertFrom-AzJson (Test-Az rest --method get --url "https://management.azure.com$hostPoolId/sessionHosts?api-version=2024-04-03" --query 'value[].{name:name, status:properties.status, allow:properties.allowNewSession, sessions:properties.sessions}' -o json --only-show-errors).Output)
if (-not $sh.Count) { Write-Result FAIL 'No session hosts registered in the host pool.' 'Check the host deployment (Deploy-Avd.ps1) and the AVD agent on the VM.' }
foreach ($h in $sh) {
    $name = ("$($h.name)" -split '/')[-1]
    if ($h.status -eq 'Available' -and $h.allow -ne $false) { Write-Result PASS "$name is Available ($($h.sessions) session(s))." }
    elseif ($h.allow -eq $false) { Write-Result WARN "$name is in drain mode (not accepting new sessions)." 'Host pool > Session hosts > Turn on new sessions.' }
    else { Write-Result WARN "$name status: $($h.status)." "'Unavailable' with Start VM on Connect is normal for a stopped host; 'NeedsAssistance'/'Upgrading' needs a look." }
}

# ------------------------------------------------------------------ 6. SSO
Write-Section '6. Single sign-on'
$rdp = (Test-Az resource show --ids $hostPoolId --query 'properties.customRdpProperty' -o tsv --only-show-errors).Output
if ($rdp -match 'enablerdsaadauth:i:1') { Write-Result PASS 'Host pool has enablerdsaadauth:i:1 (Entra SSO).' }
elseif ($isGuest) { Write-Result FAIL 'SSO is not enabled on the host pool - required for guest accounts.' 'Set enableSingleSignOn = true and run Deploy-Avd.ps1 -InfraOnly.' }
else { Write-Result INFO 'SSO is off on the host pool (users get a second sign-in prompt).' }

$spCfg = Test-Az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals(appId='270efc09-cd0d-444b-a71f-39af4910ec45')/remoteDesktopSecurityConfiguration" --query isRemoteDesktopProtocolEnabled -o tsv --only-show-errors
if ($spCfg.Ok -and $spCfg.Output -eq 'true') { Write-Result PASS 'Entra RDP protocol enabled on the Windows Cloud Login service principal.' }
elseif ($spCfg.Ok) {
    $state = if ($isGuest) { 'FAIL' } else { 'WARN' }
    Write-Result $state 'Entra RDP protocol is NOT enabled tenant-wide (Windows Cloud Login service principal).' 'Run scripts\Enable-EntraSSO.ps1 (needs a Graph admin). Required for guests; for members SSO falls back to a prompt.'
}
else { Write-Result WARN 'Could not read the tenant SSO setting (needs Graph Application.Read.All).' 'Run scripts\Enable-EntraSSO.ps1 as an admin if not done yet - it is safe to re-run.' }

# ------------------------------------------------------------------ 7. Guests
if ($isGuest) {
    Write-Section '7. Guest account requirements (Microsoft Learn: AVD authentication > External identity)'
    Write-Result INFO 'Supported on Entra-joined hosts running Windows 11 24H2+ with the 2025-09 cumulative update or later, using Windows App (Windows, macOS, iOS, Android or web).'
    Write-Result INFO 'Email one-time passcode guests are NOT supported. The guest must use an Entra (work/school) account or a Microsoft account.'
    Write-Result INFO 'Licensing: the guest needs an eligible licence (e.g. Microsoft 365 E3) assigned to their guest object in THIS tenant - their home-tenant licence does not count.'
    Write-Result WARN 'FSLogix: guests may not be able to get an Entra Kerberos ticket for the Azure Files share. With PreventLoginWithFailure=1, a failed profile mount blocks sign-in.' 'If a guest sees the desktop but sign-in fails with a profile error, tell your AVD admin - guests may need excluding from FSLogix.'
}

# ------------------------------------------------------------------ Client
Write-Section 'Client-side checks (manual)'
Write-Host '  - Quickest test: open https://windows.cloud.microsoft in a private browser window and sign in as the user.'
Write-Host '    If the desktop shows there but not in Windows App, the app is signed in with a different account.'
Write-Host '  - Windows App on Windows uses the account signed in to Windows. Add the right work account, or sign out and back in.'
Write-Host '  - After any group or assignment change: sign out of Windows App and back in (or Refresh). New memberships can take a few minutes, longer for dynamic groups.'
Write-Host '  - Still nothing: Entra ID > Sign-in logs for the user, filtered to "Azure Virtual Desktop" / "Windows Cloud Login", for Conditional Access blocks.'

Write-Host ''
if ($script:Fails) { Write-Host "$($script:Fails) problem(s) found - fix the FAIL items above first." -ForegroundColor Red; exit 1 }
elseif ($script:Warns) { Write-Host "No blocking problems found; $($script:Warns) warning(s) to review." -ForegroundColor Yellow }
else { Write-Host 'Everything checked looks right - work through the client-side checks.' -ForegroundColor Green }
