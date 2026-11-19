// Azure Files Premium share for FSLogix profile containers.
// Identity-based access uses Microsoft Entra Kerberos (no AD DS / domain controllers),
// reached privately via a private endpoint. Shared-key access is disabled.
param location string
param storageSku string
param shareQuotaGiB int
param privateEndpointSubnetId string
param vnetId string
@allowed([
  'new'
  'existing'
  'policyManaged'
])
param privateDnsZoneMode string = 'new'
param existingFilePrivateDnsZoneId string = ''
param avdUsersGroupObjectId string
param avdAdminsGroupObjectId string = ''
param logAnalyticsWorkspaceId string
param tags object = {}

var storageAccountName = take('stfslogix${uniqueString(resourceGroup().id)}', 24)
var shareName = 'profiles'

// Built-in roles
var smbShareContributorRoleId = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb' // Storage File Data SMB Share Contributor
var smbShareElevatedContributorRoleId = 'a7264617-510b-434b-a828-9731dc254ea7' // Storage File Data SMB Share Elevated Contributor

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'FileStorage'
  sku: {
    name: storageSku
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    protocolSettings: {
      smb: {
        versions: 'SMB3.1.1'
        authenticationMethods: 'Kerberos'
        kerberosTicketEncryption: 'AES-256'
        channelEncryption: 'AES-256-GCM'
        multichannel: {
          enabled: true
        }
      }
    }
  }
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: shareName
  properties: {
    shareQuota: shareQuotaGiB
    enabledProtocols: 'SMB'
  }
}

// ----------------------------------------------------------------------------- Private endpoint
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (privateDnsZoneMode == 'new') {
  name: 'privatelink.file.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (privateDnsZoneMode == 'new') {
  parent: privateDnsZone
  name: 'link-avd-vnet'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${storageAccount.name}-file'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'file'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

// With an existing zone (typically in a hub / connectivity subscription) the zone must
// already be linked to the VNet (or to the hub VNet whose DNS the spoke uses).
// policyManaged: Azure Policy (DeployIfNotExists) creates the zone group, so none here.
resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (privateDnsZoneMode != 'policyManaged') {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'file'
        properties: {
          privateDnsZoneId: privateDnsZoneMode == 'new' ? privateDnsZone.id : existingFilePrivateDnsZoneId
        }
      }
    ]
  }
}

// ----------------------------------------------------------------------------- Share-level RBAC
resource usersShareRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, avdUsersGroupObjectId, smbShareContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: avdUsersGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', smbShareContributorRoleId)
  }
}

resource adminsShareRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdAdminsGroupObjectId)) {
  name: guid(storageAccount.id, avdAdminsGroupObjectId, smbShareElevatedContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: avdAdminsGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', smbShareElevatedContributorRoleId)
  }
}

// ----------------------------------------------------------------------------- Diagnostics
resource fileDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: fileService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output storageAccountName string = storageAccount.name
output shareName string = share.name
output fslogixUncPath string = '\\\\${storageAccount.name}.file.${environment().suffixes.storage}\\${shareName}'
