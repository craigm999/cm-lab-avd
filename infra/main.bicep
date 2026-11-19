// =====================================================================================
// Azure Virtual Desktop - Entra ID joined (no Intune) pooled environment
//
// Sizing: capacity for `targetUserCount` concurrent users at `maxSessionsPerHost`
// users per session host  =>  ceil(1000 / 10) = 100 session hosts by default.
//
// Deploy at subscription scope:
//   az deployment sub create -l <region> -f infra/main.bicep -p infra/main.bicepparam
// =====================================================================================
targetScope = 'subscription'

// ----------------------------------------------------------------------------- General
@description('Azure region for all resources.')
param location string

@description('Short name used to build resource names (lowercase, no spaces).')
@minLength(2)
@maxLength(8)
param workloadName string = 'avd'

@description('Environment tag / name suffix, e.g. prod, dev.')
@maxLength(6)
param environmentName string = 'prod'

@description('Tags applied to every resource.')
param tags object = {}

// ----------------------------------------------------------------------------- Capacity
@description('Number of concurrent users the pool must support.')
@minValue(1)
param targetUserCount int = 1000

@description('Maximum number of user sessions per session host (host pool maxSessionLimit).')
@minValue(1)
@maxValue(999999)
param maxSessionsPerHost int = 10

@description('Optional override for the number of session hosts to deploy in THIS run. -1 = derive from targetUserCount / maxSessionsPerHost. Use with sessionHostStartIndex to deploy in stages.')
param sessionHostCountOverride int = -1

@description('Index of the first session host deployed in this run (used for staged / scale-out deployments).')
@minValue(0)
param sessionHostStartIndex int = 0

// ----------------------------------------------------------------------------- Session hosts
@description('Session host VM name prefix. Final name = <prefix>-<nnn> (max 15 chars).')
@maxLength(10)
param sessionHostNamePrefix string = 'avdsh'

@description('Session host VM size. D8s_v5 (8 vCPU / 32 GiB) comfortably hosts 10 medium knowledge-worker sessions.')
param vmSize string = 'Standard_D8s_v5'

@description('OS disk SKU.')
@allowed([
  'Premium_LRS'
  'StandardSSD_LRS'
  'Premium_ZRS'
  'StandardSSD_ZRS'
])
param osDiskType string = 'Premium_LRS'

@description('OS disk size in GiB.')
param osDiskSizeGB int = 128

@description('Marketplace image reference for the session hosts (must be a multi-session, Gen2 image).')
param imageReference object = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'office-365'
  sku: 'win11-24h2-avd-m365'
  version: 'latest'
}

@description('Availability zones to spread session hosts across. Empty array = no zones.')
param availabilityZones array = [
  '1'
  '2'
  '3'
]

@description('Enable encryption at host (requires the EncryptionAtHost feature registered on the subscription).')
param encryptionAtHost bool = false

@description('Local administrator user name for the session hosts (break-glass only; users sign in with Entra ID).')
param localAdminUsername string = 'avdadmin'

@description('Local administrator password.')
@secure()
param localAdminPassword string

@description('URL of the AVD agent DSC configuration package.')
param avdAgentDscPackageUrl string = 'https://wvdportalstorageblob.blob.${environment().suffixes.storage}/galleryartifacts/Configuration_1.0.02990.697.zip'

// ----------------------------------------------------------------------------- Network
@description('Address space of the AVD virtual network.')
param vnetAddressPrefix string = '10.50.0.0/16'

@description('Session host subnet. A /22 gives ~1,019 usable IPs - room for 100 hosts plus growth.')
param sessionHostSubnetPrefix string = '10.50.0.0/22'

@description('Private endpoint subnet (storage).')
param privateEndpointSubnetPrefix string = '10.50.4.0/27'

@description('Custom DNS servers for the VNet. Empty = Azure-provided DNS (fine for Entra-joined hosts).')
param dnsServers array = []

// ----------------------------------------------------------------------------- Host pool
@description('Load balancing algorithm. BreadthFirst spreads users for performance; DepthFirst packs hosts for cost.')
@allowed([
  'BreadthFirst'
  'DepthFirst'
])
param loadBalancerType string = 'BreadthFirst'

@description('Enable single sign-on with Entra ID (RDP property enablerdsaadauth). See README post-deployment steps.')
param enableSingleSignOn bool = true

@description('Registration token lifetime (ISO 8601 duration, max 27 days).')
param registrationTokenValidity string = 'PT8H'

@description('Friendly name shown to users in the client for the desktop.')
param desktopFriendlyName string = 'Corporate Desktop'

// ----------------------------------------------------------------------------- Identity / RBAC
@description('Object ID of the Entra ID group whose members may use AVD (assigned to the app group + Virtual Machine User Login).')
param avdUsersGroupObjectId string

@description('Optional object ID of an Entra ID group granted Virtual Machine Administrator Login on the session hosts.')
param avdAdminsGroupObjectId string = ''

@description('Object ID of the "Azure Virtual Desktop" service principal (appId 9cdead84-a844-4324-93f2-b2e6bb768d07) in your tenant. Required for the scaling plan and Start VM on Connect. Empty = skip that role assignment.')
param avdServicePrincipalObjectId string = ''

// ----------------------------------------------------------------------------- Scaling
@description('Deploy an autoscale scaling plan for the host pool.')
param deployScalingPlan bool = true

@description('Windows time zone ID used by the scaling plan schedules.')
param scalingPlanTimeZone string = 'GMT Standard Time'

// ----------------------------------------------------------------------------- FSLogix
@description('Deploy an Azure Files Premium share for FSLogix profile containers using Entra Kerberos.')
param deployFslogixStorage bool = true

@description('FSLogix share quota in GiB. Premium Files IOPS scale with provisioned size.')
@minValue(100)
param fslogixShareQuotaGiB int = 10240

@description('Storage redundancy for the FSLogix storage account.')
@allowed([
  'Premium_LRS'
  'Premium_ZRS'
])
param fslogixStorageSku string = 'Premium_ZRS'

@description('Maximum FSLogix profile VHDX size in MB.')
param fslogixProfileSizeMB int = 30000

// ----------------------------------------------------------------------------- Monitoring
@description('Log Analytics retention in days.')
param logAnalyticsRetentionDays int = 30

// =====================================================================================
// Variables
// =====================================================================================
var nameSuffix = '${workloadName}-${environmentName}-${locationShort}'
var locationShort = replace(location, ' ', '')
var allTags = union(tags, {
  workload: 'AzureVirtualDesktop'
  environment: environmentName
})

// Integer ceiling division: hosts needed to serve targetUserCount at maxSessionsPerHost.
var requiredSessionHosts = (targetUserCount + maxSessionsPerHost - 1) / maxSessionsPerHost
var sessionHostCount = sessionHostCountOverride >= 0 ? sessionHostCountOverride : requiredSessionHosts

var serviceRgName = 'rg-${nameSuffix}-service'
var hostsRgName = 'rg-${nameSuffix}-hosts'
var networkRgName = 'rg-${nameSuffix}-network'
var storageRgName = 'rg-${nameSuffix}-storage'
var monitorRgName = 'rg-${nameSuffix}-monitor'

var hostPoolName = 'vdpool-${nameSuffix}'

// =====================================================================================
// Resource groups
// =====================================================================================
resource rgService 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: serviceRgName
  location: location
  tags: allTags
}

resource rgHosts 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: hostsRgName
  location: location
  tags: allTags
}

resource rgNetwork 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: networkRgName
  location: location
  tags: allTags
}

resource rgStorage 'Microsoft.Resources/resourceGroups@2024-03-01' = if (deployFslogixStorage) {
  name: storageRgName
  location: location
  tags: allTags
}

resource rgMonitor 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: monitorRgName
  location: location
  tags: allTags
}

// =====================================================================================
// Modules
// =====================================================================================
module monitoring 'modules/monitoring.bicep' = {
  name: 'avd-monitoring'
  scope: rgMonitor
  params: {
    location: location
    name: 'log-${nameSuffix}'
    retentionInDays: logAnalyticsRetentionDays
    tags: allTags
  }
}

module network 'modules/network.bicep' = {
  name: 'avd-network'
  scope: rgNetwork
  params: {
    location: location
    nameSuffix: nameSuffix
    vnetAddressPrefix: vnetAddressPrefix
    sessionHostSubnetPrefix: sessionHostSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    dnsServers: dnsServers
    tags: allTags
  }
}

module hostPool 'modules/hostpool.bicep' = {
  name: 'avd-hostpool'
  scope: rgService
  params: {
    location: location
    nameSuffix: nameSuffix
    hostPoolName: hostPoolName
    maxSessionsPerHost: maxSessionsPerHost
    loadBalancerType: loadBalancerType
    enableSingleSignOn: enableSingleSignOn
    registrationTokenValidity: registrationTokenValidity
    desktopFriendlyName: desktopFriendlyName
    avdUsersGroupObjectId: avdUsersGroupObjectId
    deployScalingPlan: deployScalingPlan
    scalingPlanTimeZone: scalingPlanTimeZone
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    tags: allTags
  }
}

module fslogixStorage 'modules/storage.bicep' = if (deployFslogixStorage) {
  name: 'avd-fslogix-storage'
  scope: rgStorage
  params: {
    location: location
    storageSku: fslogixStorageSku
    shareQuotaGiB: fslogixShareQuotaGiB
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    vnetId: network.outputs.vnetId
    avdUsersGroupObjectId: avdUsersGroupObjectId
    avdAdminsGroupObjectId: avdAdminsGroupObjectId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    tags: allTags
  }
}

// Sign-in + power management RBAC on the session host resource group.
module hostsRbac 'modules/hosts-rbac.bicep' = {
  name: 'avd-hosts-rbac'
  scope: rgHosts
  params: {
    avdUsersGroupObjectId: avdUsersGroupObjectId
    avdAdminsGroupObjectId: avdAdminsGroupObjectId
    avdServicePrincipalObjectId: avdServicePrincipalObjectId
  }
}

// The AVD service principal also needs power on/off rights where the host pool lives.
module serviceRbac 'modules/hosts-rbac.bicep' = if (!empty(avdServicePrincipalObjectId)) {
  name: 'avd-service-rbac'
  scope: rgService
  params: {
    avdServicePrincipalObjectId: avdServicePrincipalObjectId
  }
}

// Deploy hosts 20 at a time to stay well inside ARM / Compute API throttling limits.
@batchSize(20)
module sessionHosts 'modules/sessionhost.bicep' = [
  for i in range(sessionHostStartIndex, sessionHostCount): {
    name: 'avd-sh-${padLeft(i + 1, 3, '0')}'
    scope: rgHosts
    params: {
      location: location
      vmName: '${sessionHostNamePrefix}-${padLeft(i + 1, 3, '0')}'
      vmSize: vmSize
      zone: empty(availabilityZones) ? '' : availabilityZones[i % length(availabilityZones)]
      subnetId: network.outputs.sessionHostSubnetId
      imageReference: imageReference
      osDiskType: osDiskType
      osDiskSizeGB: osDiskSizeGB
      encryptionAtHost: encryptionAtHost
      adminUsername: localAdminUsername
      adminPassword: localAdminPassword
      hostPoolResourceGroupName: rgService.name
      hostPoolName: hostPool.outputs.hostPoolName
      avdAgentDscPackageUrl: avdAgentDscPackageUrl
      fslogixEnabled: deployFslogixStorage
      fslogixVhdLocation: deployFslogixStorage ? fslogixStorage!.outputs.fslogixUncPath : ''
      fslogixProfileSizeMB: fslogixProfileSizeMB
      tags: allTags
    }
  }
]

// =====================================================================================
// Outputs
// =====================================================================================
output hostPoolName string = hostPool.outputs.hostPoolName
output workspaceName string = hostPool.outputs.workspaceName
output sessionHostsRequired int = requiredSessionHosts
output sessionHostsDeployedThisRun int = sessionHostCount
output totalSessionCapacity int = requiredSessionHosts * maxSessionsPerHost
output fslogixStorageAccountName string = deployFslogixStorage ? fslogixStorage!.outputs.storageAccountName : ''
output fslogixUncPath string = deployFslogixStorage ? fslogixStorage!.outputs.fslogixUncPath : ''
output sessionHostResourceGroup string = rgHosts.name
