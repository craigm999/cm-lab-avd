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
param location string
param vmName string
param vmSize string
param zone string = ''
param subnetId string
param imageReference object
param osDiskType string
param osDiskSizeGB int
param encryptionAtHost bool = false
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
    securityProfile: {
      securityType: 'TrustedLaunch'
      encryptionAtHost: encryptionAtHost
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
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
resource guestAttestation 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
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

output vmName string = vm.name
output vmId string = vm.id
