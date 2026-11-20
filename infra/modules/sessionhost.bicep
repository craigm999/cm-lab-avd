// One Entra ID joined (no Intune) AVD session host.
//
// Extension order:
//   1. AADLoginForWindows  - joins the VM to Microsoft Entra ID. No `mdmId` setting is
//                            passed, so the device is NOT enrolled in Intune.
//   2. Run command         - FSLogix + Entra Kerberos configuration. Runs BEFORE the
//                            agent registers, so no user can land on a half-configured
//                            host and autoscale can't stop it mid-build.
//   3. DSC (AVD agent)     - installs the AVD agent + boot loader and registers the VM
//                            to the host pool with aadJoin = true.
//   4. Restart             - delayed restart so the Entra Kerberos setting takes effect.
param location string
param vmName string
param vmSize string
param zone string = ''
param subnetId string
param imageReference object
param osDiskType string
param osDiskSizeGB int
param encryptionAtHost bool = false

@description('TrustedLaunch (Secure Boot + vTPM; needs a Gen2 image - marketplace or a Compute Gallery definition with security type TrustedLaunchSupported/TrustedLaunch) or Standard (for Gen1 images, managed images or gallery definitions without Trusted Launch support).')
@allowed([
  'TrustedLaunch'
  'Standard'
])
param securityType string = 'TrustedLaunch'
param adminUsername string
@secure()
param adminPassword string
param hostPoolResourceGroupName string
param hostPoolName string
param avdAgentDscPackageUrl string
param fslogixEnabled bool
param fslogixVhdLocation string
param fslogixProfileSizeMB int
param tags object = {}

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' existing = {
  scope: resourceGroup(hostPoolResourceGroupName)
  name: hostPoolName
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  zones: empty(zone) ? null : [
    zone
  ]
  identity: {
    // Required for Microsoft Entra ID join.
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    licenseType: 'Windows_Client'
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
        }
      }
    }
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        name: 'osdisk-${vmName}'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        diskSizeGB: osDiskSizeGB
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: osDiskType
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    securityProfile: securityType == 'TrustedLaunch'
      ? {
          securityType: 'TrustedLaunch'
          encryptionAtHost: encryptionAtHost
          uefiSettings: {
            secureBootEnabled: true
            vTpmEnabled: true
          }
        }
      : {
          encryptionAtHost: encryptionAtHost
        }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// 1. Microsoft Entra ID join - deliberately no mdmId => no Intune enrollment.
resource entraJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
  }
}

// Trusted Launch boot integrity monitoring.
resource guestAttestation 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = if (securityType == 'TrustedLaunch') {
  parent: vm
  name: 'GuestAttestation'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Security.WindowsAttestation'
    type: 'GuestAttestation'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    settings: {
      AttestationConfig: {
        MaaSettings: {
          maaEndpoint: ''
          maaTenantName: 'GuestAttestation'
        }
      }
    }
  }
  dependsOn: [
    entraJoin
  ]
}

// 2. FSLogix + Entra Kerberos session host configuration.
resource configure 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'Configure-SessionHost'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/Configure-SessionHost.ps1')
    }
    parameters: [
      {
        name: 'FslogixEnabled'
        value: string(fslogixEnabled)
      }
      {
        name: 'VhdLocation'
        value: fslogixVhdLocation
      }
      {
        name: 'ProfileSizeMB'
        value: string(fslogixProfileSizeMB)
      }
    ]
    asyncExecution: false
    treatFailureAsDeploymentFailure: true
    timeoutInSeconds: 1800
  }
  dependsOn: [
    guestAttestation
  ]
}

// 3. AVD agent install + host pool registration.
resource avdAgent 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'Microsoft.PowerShell.DSC'
  location: location
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.73'
    autoUpgradeMinorVersion: true
    settings: {
      modulesUrl: avdAgentDscPackageUrl
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        hostPoolName: hostPoolName
        registrationInfoTokenCredential: {
          UserName: 'PLACEHOLDER_DO_NOT_USE'
          Password: 'PrivateSettingsRef:RegistrationInfoToken'
        }
        aadJoin: true
        UseAgentDownloadEndpoint: true
        aadJoinPreview: false
        mdmId: ''
        sessionHostConfigurationLastUpdateTime: ''
      }
    }
    protectedSettings: {
      Items: {
        RegistrationInfoToken: hostPool.listRegistrationTokens().value[0].token
      }
    }
  }
  dependsOn: [
    configure
  ]
}

// 4. Restart once the build is complete. The Entra Kerberos setting
//    (CloudKerberosTicketRetrievalEnabled) only takes effect after a restart, and FSLogix
//    profiles on Azure Files depend on it. The restart is scheduled 2 minutes out so this
//    command (and the deployment) completes first.
resource restartAfterBuild 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'Restart-AfterBuild'
  location: location
  properties: {
    source: {
      script: 'shutdown.exe /r /t 120 /d p:4:1 /c "AVD session host build complete"'
    }
    asyncExecution: false
    treatFailureAsDeploymentFailure: false
    timeoutInSeconds: 300
  }
  dependsOn: [
    avdAgent
  ]
}

output vmName string = vm.name
output vmId string = vm.id
