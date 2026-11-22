<#
.SYNOPSIS
    Post-provisioning configuration for an Entra ID joined AVD session host.

.DESCRIPTION
    Executed by the Microsoft.Compute/virtualMachines/runCommands resource in
    sessionhost.bicep. Configures:
      * Microsoft Entra Kerberos ticket retrieval (needed for Azure Files with Entra Kerberos)
      * FSLogix profile containers pointing at the Azure Files share
      * Exclusion of the local admin from FSLogix
    The FSLogix agent ships in the Windows 11 multi-session + M365 marketplace images.
#>
param(
    [string] $FslogixEnabled = 'True',
    [string] $VhdLocation = '',
    [string] $ProfileSizeMB = '30000'
)

$ErrorActionPreference = 'Stop'

function Set-RegValue {
    param([string] $Path, [string] $Name, $Value, [string] $Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# ---------------------------------------------------------------- Entra Kerberos
# Lets Entra-joined hosts retrieve Kerberos tickets from Entra ID for Azure Files.
Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' -Name 'CloudKerberosTicketRetrievalEnabled' -Value 1
# Load credential key from the user profile (required when profiles roam via FSLogix).
Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount' -Name 'LoadCredKeyFromProfile' -Value 1

# ---------------------------------------------------------------- FSLogix
if ([System.Convert]::ToBoolean($FslogixEnabled) -and -not [string]::IsNullOrWhiteSpace($VhdLocation)) {
    $fsl = 'HKLM:\SOFTWARE\FSLogix\Profiles'
    Set-RegValue -Path $fsl -Name 'Enabled' -Value 1
    Set-RegValue -Path $fsl -Name 'VHDLocations' -Value @($VhdLocation) -Type 'MultiString'
    Set-RegValue -Path $fsl -Name 'VolumeType' -Value 'VHDX' -Type 'String'
    Set-RegValue -Path $fsl -Name 'SizeInMBs' -Value ([int]$ProfileSizeMB)
    Set-RegValue -Path $fsl -Name 'IsDynamic' -Value 1
    Set-RegValue -Path $fsl -Name 'FlipFlopProfileDirectoryName' -Value 1
    Set-RegValue -Path $fsl -Name 'DeleteLocalProfileWhenVHDShouldApply' -Value 1
    Set-RegValue -Path $fsl -Name 'PreventLoginWithFailure' -Value 1
    Set-RegValue -Path $fsl -Name 'PreventLoginWithTempProfile' -Value 1
    Set-RegValue -Path $fsl -Name 'LockedRetryCount' -Value 3
    Set-RegValue -Path $fsl -Name 'LockedRetryInterval' -Value 15
    Set-RegValue -Path $fsl -Name 'ReAttachRetryCount' -Value 3
    Set-RegValue -Path $fsl -Name 'ReAttachIntervalSeconds' -Value 15

    # Keep the local break-glass admin out of FSLogix.
    $localAdmin = (Get-LocalUser | Where-Object { $_.SID -like 'S-1-5-21-*-500' }).Name
    foreach ($group in 'FSLogix Profile Exclude List', 'FSLogix ODFC Exclude List') {
        if ($localAdmin -and (Get-LocalGroup -Name $group -ErrorAction SilentlyContinue)) {
            Add-LocalGroupMember -Group $group -Member $localAdmin -ErrorAction SilentlyContinue
        }
    }
    # Microsoft Defender exclusions recommended for FSLogix: scanning the container files
    # themselves slows sign-in and can lock them (content inside is still scanned in-session).
    $share = $VhdLocation.TrimEnd('\')
    $exclusions = @('%ProgramFiles%\FSLogix\Apps\frxdrv.sys', '%ProgramFiles%\FSLogix\Apps\frxdrvvt.sys', '%ProgramFiles%\FSLogix\Apps\frxccd.sys')
    foreach ($ext in 'VHD', 'VHDX') {
        $exclusions += "%TEMP%\*\*.$ext", "%Windir%\TEMP\*\*.$ext"
        foreach ($suffix in '', '.lock', '.meta', '.metadata') { $exclusions += "$share\*\*.$ext$suffix" }
    }
    try { Add-MpPreference -ExclusionPath $exclusions -ErrorAction Stop; Write-Output 'Defender exclusions for FSLogix added.' }
    catch { Write-Output "Defender exclusions for FSLogix not added: $($_.Exception.Message)" }
    Write-Output "FSLogix configured: $VhdLocation"
}
else {
    Write-Output 'FSLogix not configured (disabled or no VHD location supplied).'
}

# ---------------------------------------------------------------- Misc session host hygiene
# Time zone redirection so users see their local time.
Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fEnableTimeZoneRedirection' -Value 1
# Disable Storage Sense (it can delete data inside FSLogix containers).
Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' -Name 'AllowStorageSenseGlobal' -Value 0

Write-Output 'Session host configuration complete.'
