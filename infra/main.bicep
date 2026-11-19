// =====================================================================================
// Azure Virtual Desktop - Entra ID joined (no Intune) pooled environment
//
// Sizing: capacity for `targetUserCount` concurrent users at `maxSessionsPerHost`
// users per session host  =>  ceil(1000 / 10) = 100 session hosts by default.
//
// Works with NEW or EXISTING resource groups, virtual network, Log Analytics workspace
// and private DNS zone. Run scripts/New-AvdParameterFile.ps1 (or fill in
// docs/questionnaire.md) to produce a parameter file for your environment.
//
// Deploy at subscription scope (the subscription that holds / will hold the VNet):
//   az deployment sub create -l <region> -f infra/main.bicep -p infra/params/<env>.bicepparam
// =====================================================================================
targetScope = 'subscription'

// =====================================================================================
// Types
// =====================================================================================
@description('A resource group to use. create = false means it must already exist in the deployment subscription.')
type resourceGroupConfig = {
  @description('Resource group name. Empty string = default naming convention (rg-<workload>-<env>-<region>-<role>).')
  name: string

  @description('true = create (or update) the resource group; false = it already exists.')
  create: bool
}

type resourceGroupsConfig = {
  @description('Host pool, application group, workspace, scaling plan.')
  service: resourceGroupConfig

  @description('Session host VMs, NICs and disks.')
  hosts: resourceGroupConfig

  @description('FSLogix storage account and private endpoint.')
  storage: resourceGroupConfig

  @description('New virtual network (only used when networkMode = new).')
  network: resourceGroupConfig

  @description('New Log Analytics workspace (only used when logAnalyticsMode = new).')
  monitor: resourceGroupConfig
}

// =====================================================================================
// Parameters
// =====================================================================================

// ----------------------------------------------------------------------------- General
@description('Azure region for all new resources. Must be the same region as an existing VNet.')
param location string

@description('Short name used to build resource names (lowercase, no spaces).')
@minLength(2)
@maxLength(8)
param workloadName string = 'avd'

@description('Environment tag / name suffix, e.g. prod, dev.')
@maxLength(6)
param environmentName string = 'prod'

@description('Tags applied to every new resource.')
param tags object = {}

@description('Resource groups for each component, and whether each should be created. Several components may share one resource group.')
param resourceGroups resourceGroupsConfig = {
  service: { name: '', create: true }
  hosts: { name: '', create: true }
  storage: { name: '', create: true }
  network: { name: '', create: true }
  monitor: { name: '', create: true }
}

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

@description('Image for the session hosts: a marketplace reference {publisher, offer, sku, version} or a Compute Gallery image {id: <image or version resource ID>}. Must be multi-session, Gen2, Trusted Launch capable.')
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
@description('new = create a VNet; existing = use existing subnets (must be in the deployment subscription and region).')
@allowed([
  'new'
  'existing'
])
param networkMode string = 'new'

@description('[existing] Resource ID of the subnet for session hosts.')
param existingSessionHostSubnetId string = ''

@description('[existing] Resource ID of the subnet for the storage private endpoint (can be the same as the session host subnet).')
param existingPrivateEndpointSubnetId string = ''

@description('[new] VNet name. Empty = vnet-<workload>-<env>-<region>.')
param vnetName string = ''

@description('[new] Address space of the AVD virtual network.')
param vnetAddressPrefix string = '10.50.0.0/16'

@description('[new] Session host subnet. A /22 gives ~1,019 usable IPs - room for 100 hosts plus growth.')
param sessionHostSubnetPrefix string = '10.50.0.0/22'

@description('[new] Private endpoint subnet (storage).')
param privateEndpointSubnetPrefix string = '10.50.4.0/27'

@description('[new] Custom DNS servers for the VNet (e.g. hub DNS resolver / firewall). Empty = Azure-provided DNS.')
param dnsServers array = []

@description('[new] How session hosts reach the internet: NatGateway, FirewallUdr (0.0.0.0/0 to firewallPrivateIp), or None (you provide it).')
@allowed([
  'NatGateway'
  'FirewallUdr'
  'None'
])
param outboundMethod string = 'NatGateway'

@description('[new, FirewallUdr] Private IP of the hub firewall / NVA.')
param firewallPrivateIp string = ''

@description('[new] Optional resource ID of a hub VNet to peer with (may be in another subscription). Empty = no peering.')
param hubVnetId string = ''

@description('[new] Use the hub VNet gateway (VPN/ExpressRoute) for on-premises connectivity.')
param hubUseRemoteGateways bool = false

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

@description('Default share-level permission on the FSLogix share for all authenticated identities (FSLogix guidance: StorageFileDataSmbShareContributor). None = rely only on the users-group RBAC assignment.')
@allowed([
  'None'
  'StorageFileDataSmbShareContributor'
  'StorageFileDataSmbShareReader'
])
param fslogixDefaultSharePermission string = 'StorageFileDataSmbShareContributor'

@description('privatelink.file DNS zone: new = create one and link it to the VNet; existing = use existingFilePrivateDnsZoneId (e.g. in a hub/connectivity subscription); policyManaged = create no DNS records (Azure Policy does it).')
@allowed([
  'new'
  'existing'
  'policyManaged'
])
param privateDnsZoneMode string = 'new'

@description('[existing] Resource ID of the privatelink.file.core.windows.net private DNS zone.')
param existingFilePrivateDnsZoneId string = ''

// ----------------------------------------------------------------------------- Monitoring
@description('new = create a Log Analytics workspace; existing = send diagnostics to existingLogAnalyticsWorkspaceId (may be in another subscription).')
@allowed([
  'new'
  'existing'
])
param logAnalyticsMode string = 'new'

@description('[existing] Resource ID of the Log Analytics workspace.')
param existingLogAnalyticsWorkspaceId string = ''

@description('[new] Log Analytics retention in days.')
param logAnalyticsRetentionDays int = 30

// =====================================================================================
// Variables
// =====================================================================================
var locationShort = replace(location, ' ', '')
var nameSuffix = '${workloadName}-${environmentName}-${locationShort}'
var allTags = union(tags, {
  workload: 'AzureVirtualDesktop'
  environment: environmentName
})

// Integer ceiling division: hosts needed to serve targetUserCount at maxSessionsPerHost.
var requiredSessionHosts = (targetUserCount + maxSessionsPerHost - 1) / maxSessionsPerHost
var sessionHostCount = sessionHostCountOverride >= 0 ? sessionHostCountOverride : requiredSessionHosts

// Resolve resource group names (empty => default convention).
var rgServiceName = empty(resourceGroups.service.name) ? 'rg-${nameSuffix}-service' : resourceGroups.service.name
var rgHostsName = empty(resourceGroups.hosts.name) ? 'rg-${nameSuffix}-hosts' : resourceGroups.hosts.name
var rgStorageName = empty(resourceGroups.storage.name) ? 'rg-${nameSuffix}-storage' : resourceGroups.storage.name
var rgNetworkName = empty(resourceGroups.network.name) ? 'rg-${nameSuffix}-network' : resourceGroups.network.name
var rgMonitorName = empty(resourceGroups.monitor.name) ? 'rg-${nameSuffix}-monitor' : resourceGroups.monitor.name

var newNetwork = networkMode == 'new'
var newLogAnalytics = logAnalyticsMode == 'new'

// Resource groups to create. union() de-duplicates, so components may share a group.
var rgNamesToCreate = union(
  resourceGroups.service.create ? [rgServiceName] : [],
  resourceGroups.hosts.create ? [rgHostsName] : [],
  (deployFslogixStorage && resourceGroups.storage.create) ? [rgStorageName] : [],
  (newNetwork && resourceGroups.network.create) ? [rgNetworkName] : [],
  (newLogAnalytics && resourceGroups.monitor.create) ? [rgMonitorName] : []
)

var hostPoolName = 'vdpool-${nameSuffix}'

// Existing VNet ID is derived from the subnet ID.
var existingVnetId = newNetwork ? '' : substring(existingSessionHostSubnetId, 0, indexOf(toLower(existingSessionHostSubnetId), '/subnets/'))
// Fallbacks keep the (skipped) hub peering module's scope valid when no hub is given.
var hubSubscriptionId = empty(hubVnetId) ? subscription().subscriptionId : split(hubVnetId, '/')[2]
var hubResourceGroupName = empty(hubVnetId) ? rgNetworkName : split(hubVnetId, '/')[4]

// =====================================================================================
// Resource groups
// =====================================================================================
resource rgs 'Microsoft.Resources/resourceGroups@2024-03-01' = [
  for rgName in rgNamesToCreate: {
    name: rgName
    location: location
    tags: allTags
  }
]

// =====================================================================================
// Monitoring
// =====================================================================================
module monitoring 'modules/monitoring.bicep' = if (newLogAnalytics) {
  name: 'avd-monitoring'
  scope: resourceGroup(rgMonitorName)
  params: {
    location: location
    name: 'log-${nameSuffix}'
    retentionInDays: logAnalyticsRetentionDays
    tags: allTags
  }
  dependsOn: [
    rgs
  ]
}

var logAnalyticsWorkspaceId = newLogAnalytics ? monitoring!.outputs.workspaceId : existingLogAnalyticsWorkspaceId

// =====================================================================================
// Network
// =====================================================================================
module network 'modules/network.bicep' = if (newNetwork) {
  name: 'avd-network'
  scope: resourceGroup(rgNetworkName)
  params: {
    location: location
    nameSuffix: nameSuffix
    vnetName: empty(vnetName) ? 'vnet-${nameSuffix}' : vnetName
    vnetAddressPrefix: vnetAddressPrefix
    sessionHostSubnetPrefix: sessionHostSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    dnsServers: dnsServers
    outboundMethod: outboundMethod
    firewallPrivateIp: firewallPrivateIp
    tags: allTags
  }
  dependsOn: [
    rgs
  ]
}

// Spoke -> hub peering
module peeringToHub 'modules/vnet-peering.bicep' = if (newNetwork && !empty(hubVnetId)) {
  name: 'avd-peering-to-hub'
  scope: resourceGroup(rgNetworkName)
  params: {
    localVnetName: network!.outputs.vnetName
    remoteVnetId: hubVnetId
    allowGatewayTransit: false
    useRemoteGateways: hubUseRemoteGateways
  }
  dependsOn: [
    // useRemoteGateways requires the hub side (allowGatewayTransit) to exist first.
    peeringFromHub
  ]
}

// Hub -> spoke peering (deployed into the hub's subscription / resource group)
module peeringFromHub 'modules/vnet-peering.bicep' = if (newNetwork && !empty(hubVnetId)) {
  name: 'avd-peering-from-hub-${uniqueString(subscription().id, rgNetworkName)}'
  scope: resourceGroup(hubSubscriptionId, hubResourceGroupName)
  params: {
    localVnetName: empty(hubVnetId) ? 'none' : last(split(hubVnetId, '/'))
    remoteVnetId: network!.outputs.vnetId
    allowGatewayTransit: hubUseRemoteGateways
    useRemoteGateways: false
  }
}

var sessionHostSubnetId = newNetwork ? network!.outputs.sessionHostSubnetId : existingSessionHostSubnetId
var privateEndpointSubnetId = newNetwork ? network!.outputs.privateEndpointSubnetId : (empty(existingPrivateEndpointSubnetId) ? existingSessionHostSubnetId : existingPrivateEndpointSubnetId)
var vnetId = newNetwork ? network!.outputs.vnetId : existingVnetId

// =====================================================================================
// AVD control plane
// =====================================================================================
module hostPool 'modules/hostpool.bicep' = {
  name: 'avd-hostpool'
  scope: resourceGroup(rgServiceName)
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
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: allTags
  }
  dependsOn: [
    rgs
  ]
}

// =====================================================================================
// FSLogix storage
// =====================================================================================
module fslogixStorage 'modules/storage.bicep' = if (deployFslogixStorage) {
  name: 'avd-fslogix-storage'
  scope: resourceGroup(rgStorageName)
  params: {
    location: location
    storageSku: fslogixStorageSku
    shareQuotaGiB: fslogixShareQuotaGiB
    privateEndpointSubnetId: privateEndpointSubnetId
    vnetId: vnetId
    privateDnsZoneMode: privateDnsZoneMode
    existingFilePrivateDnsZoneId: existingFilePrivateDnsZoneId
    avdUsersGroupObjectId: avdUsersGroupObjectId
    avdAdminsGroupObjectId: avdAdminsGroupObjectId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    defaultSharePermission: fslogixDefaultSharePermission
    tags: allTags
  }
  dependsOn: [
    rgs
  ]
}

// =====================================================================================
// RBAC
// =====================================================================================
// Sign-in + power management RBAC on the session host resource group.
module hostsRbac 'modules/hosts-rbac.bicep' = {
  name: 'avd-hosts-rbac'
  scope: resourceGroup(rgHostsName)
  params: {
    avdUsersGroupObjectId: avdUsersGroupObjectId
    avdAdminsGroupObjectId: avdAdminsGroupObjectId
    avdServicePrincipalObjectId: avdServicePrincipalObjectId
  }
  dependsOn: [
    rgs
  ]
}

// The AVD service principal also needs power on/off rights where the host pool lives.
module serviceRbac 'modules/hosts-rbac.bicep' = if (!empty(avdServicePrincipalObjectId) && rgServiceName != rgHostsName) {
  name: 'avd-service-rbac'
  scope: resourceGroup(rgServiceName)
  params: {
    avdServicePrincipalObjectId: avdServicePrincipalObjectId
  }
  dependsOn: [
    rgs
  ]
}

// =====================================================================================
// Session hosts
// =====================================================================================
// Deploy hosts 20 at a time to stay well inside ARM / Compute API throttling limits.
@batchSize(20)
module sessionHosts 'modules/sessionhost.bicep' = [
  for i in range(sessionHostStartIndex, sessionHostCount): {
    name: 'avd-sh-${padLeft(i + 1, 3, '0')}'
    scope: resourceGroup(rgHostsName)
    params: {
      location: location
      vmName: '${sessionHostNamePrefix}-${padLeft(i + 1, 3, '0')}'
      vmSize: vmSize
      zone: empty(availabilityZones) ? '' : availabilityZones[i % length(availabilityZones)]
      subnetId: sessionHostSubnetId
      imageReference: imageReference
      osDiskType: osDiskType
      osDiskSizeGB: osDiskSizeGB
      encryptionAtHost: encryptionAtHost
      adminUsername: localAdminUsername
      adminPassword: localAdminPassword
      hostPoolResourceGroupName: rgServiceName
      hostPoolName: hostPool.outputs.hostPoolName
      avdAgentDscPackageUrl: avdAgentDscPackageUrl
      fslogixEnabled: deployFslogixStorage
      fslogixVhdLocation: deployFslogixStorage ? fslogixStorage!.outputs.fslogixUncPath : ''
      fslogixProfileSizeMB: fslogixProfileSizeMB
      tags: allTags
    }
    dependsOn: [
      hostsRbac
      peeringToHub
      peeringFromHub
    ]
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
output resourceGroupsCreated array = rgNamesToCreate
output sessionHostResourceGroup string = rgHostsName
output sessionHostSubnetId string = sessionHostSubnetId
output fslogixStorageAccountName string = deployFslogixStorage ? fslogixStorage!.outputs.storageAccountName : ''
output fslogixUncPath string = deployFslogixStorage ? fslogixStorage!.outputs.fslogixUncPath : ''
