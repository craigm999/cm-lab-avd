<#
.SYNOPSIS
    One-off tenant configuration for AVD single sign-on with Microsoft Entra ID.

.DESCRIPTION
    Enables the Microsoft Entra RDP protocol on the "Microsoft Remote Desktop" and
    "Windows Cloud Login" service principals, and (optionally) adds a device group of the
    session hosts to the trusted target device list so users aren't shown the
    "Allow remote desktop connection?" consent prompt.

    The device group: either pass an existing group's object ID (-TargetDeviceGroupId), or
    pass the session host name prefix(es) (-SessionHostPrefix) and the script creates - or
    reuses - a DYNAMIC device group whose rule picks up every host with that prefix,
    including hosts added later. Dynamic groups need Microsoft Entra ID P1.

    Requires the Microsoft.Graph PowerShell modules (Install-Module Microsoft.Graph) and an
    admin who can manage service principals (and create groups, for -SessionHostPrefix).

.EXAMPLE
    # Create/reuse a dynamic group for the avdpd-* personal desktops and use it
    .\scripts\Enable-EntraSSO.ps1 -SessionHostPrefix avdpd

.EXAMPLE
    # Pooled and personal hosts in one group
    .\scripts\Enable-EntraSSO.ps1 -SessionHostPrefix avdsh, avdpd

.EXAMPLE
    .\scripts\Enable-EntraSSO.ps1 -TargetDeviceGroupId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [string] $TargetDeviceGroupId,
    [string[]] $SessionHostPrefix,
    [string] $DeviceGroupName = 'AVD Session Hosts'
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Applications

$scopes = @('Application.Read.All', 'Application-RemoteDesktopConfig.ReadWrite.All')
if ($SessionHostPrefix -and -not $TargetDeviceGroupId) {
    Import-Module Microsoft.Graph.Groups
    $scopes += 'Group.ReadWrite.All'
}
Connect-MgGraph -Scopes $scopes -NoWelcome

# ------------------------------------------------------------------ Device group
if ($SessionHostPrefix -and -not $TargetDeviceGroupId) {
    # e.g. (device.displayName -startsWith "avdpd-") -or (device.displayName -startsWith "avdsh-")
    $rule = (@($SessionHostPrefix) | ForEach-Object { '(device.displayName -startsWith "{0}-")' -f $_.TrimEnd('-') }) -join ' -or '
    $existingGroup = @(Get-MgGroup -Filter "displayName eq '$($DeviceGroupName.Replace("'", "''"))'" -Property Id, DisplayName, MembershipRule)
    if ($existingGroup.Count -gt 1) { throw "Several groups are named '$DeviceGroupName' - pass -TargetDeviceGroupId instead." }
    if ($existingGroup.Count -eq 1) {
        $TargetDeviceGroupId = $existingGroup[0].Id
        Write-Output "Using existing group '$DeviceGroupName' ($TargetDeviceGroupId)"
        if ($existingGroup[0].MembershipRule -and $existingGroup[0].MembershipRule -ne $rule) {
            Write-Warning "Its membership rule is '$($existingGroup[0].MembershipRule)', not '$rule'. Check it covers all session hosts."
        }
    }
    else {
        try {
            $g = New-MgGroup -DisplayName $DeviceGroupName `
                -Description 'AVD session hosts (dynamic) - trusted for Entra SSO without the consent prompt' `
                -MailEnabled:$false -MailNickname ('avdsessionhosts' + (Get-Random -Maximum 99999)) -SecurityEnabled `
                -GroupTypes @('DynamicMembership') -MembershipRule $rule -MembershipRuleProcessingState 'On'
            $TargetDeviceGroupId = $g.Id
            Write-Output "Created dynamic device group '$DeviceGroupName' ($TargetDeviceGroupId) with rule: $rule"
            Write-Output 'Membership is evaluated by Entra ID in the background - devices appear within minutes (longer in large tenants).'
        }
        catch {
            Write-Warning "Could not create a dynamic group: $($_.Exception.Message)"
            Write-Warning 'Dynamic groups need Microsoft Entra ID P1. Without it, create a normal security group, add the session host devices to it, and re-run with -TargetDeviceGroupId <its object ID>.'
            throw
        }
    }
}

# ------------------------------------------------------------------ Service principals
$appIds = @(
    'a4a365df-50f1-4397-bc59-1a1564b8bb9c', # Microsoft Remote Desktop
    '270efc09-cd0d-444b-a71f-39af4910ec45'  # Windows Cloud Login
)

foreach ($appId in $appIds) {
    $sp = Get-MgServicePrincipal -Filter "appId eq '$appId'"
    if (-not $sp) { Write-Warning "Service principal $appId not found in tenant"; continue }

    $cfg = Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $sp.Id -ErrorAction SilentlyContinue
    if (-not $cfg -or -not $cfg.IsRemoteDesktopProtocolEnabled) {
        Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $sp.Id -IsRemoteDesktopProtocolEnabled
        Write-Output "Enabled Entra RDP protocol on $($sp.DisplayName)"
    }
    else { Write-Output "Entra RDP protocol already enabled on $($sp.DisplayName)" }

    if ($TargetDeviceGroupId) {
        $existing = @(Get-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -ServicePrincipalId $sp.Id)
        if (@($existing | ForEach-Object { $_.Id }) -notcontains $TargetDeviceGroupId) {
            New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -ServicePrincipalId $sp.Id -BodyParameter @{
                '@odata.type' = '#microsoft.graph.targetDeviceGroup'
                id            = $TargetDeviceGroupId
                displayName   = $DeviceGroupName
            } | Out-Null
            Write-Output "Added device group $TargetDeviceGroupId as trusted on $($sp.DisplayName)"
        }
        else { Write-Output "Device group already trusted on $($sp.DisplayName)" }
    }
}
