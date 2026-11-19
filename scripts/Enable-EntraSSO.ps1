<#
.SYNOPSIS
    One-off tenant configuration for AVD single sign-on with Microsoft Entra ID.

.DESCRIPTION
    Enables the Microsoft Entra RDP protocol on the "Microsoft Remote Desktop" and
    "Windows Cloud Login" service principals, and (optionally) adds the AVD device
    group to the trusted target device list so users aren't shown the consent prompt.
    Requires: Microsoft.Graph PowerShell modules, Application.ReadWrite.All.

.EXAMPLE
    ./Enable-EntraSSO.ps1 -TargetDeviceGroupId <dynamic group object id containing the session hosts>
#>
param(
    [string] $TargetDeviceGroupId
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Applications

Connect-MgGraph -Scopes 'Application.Read.All', 'Application-RemoteDesktopConfig.ReadWrite.All'

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

    if ($TargetDeviceGroupId) {
        $existing = Get-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -ServicePrincipalId $sp.Id
        if ($existing.Id -notcontains $TargetDeviceGroupId) {
            New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup -ServicePrincipalId $sp.Id -BodyParameter @{
                '@odata.type' = '#microsoft.graph.targetDeviceGroup'
                id            = $TargetDeviceGroupId
                displayName   = 'AVD Session Hosts'
            } | Out-Null
            Write-Output "Added target device group to $($sp.DisplayName)"
        }
    }
}
