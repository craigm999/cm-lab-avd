// Example parameter file: existing VNet, existing Log Analytics, central private DNS zone.
// Generate your own with:  pwsh ./scripts/New-AvdParameterFile.ps1
// (writes infra/params/<env>.bicepparam). See docs/questionnaire.md.
//
// subscriptionId: 00000000-0000-0000-0000-000000000000
using 'main.bicep'

// ---------------------------------------------------------------- General
param location = 'uksouth'
param workloadName = 'avd'
param environmentName = 'prod'
param tags = {
  owner: 'it-infrastructure'
  costCentre: 'tbc'
}

// ---------------------------------------------------------------- Resource groups
// name '' = default convention; create false = already exists.
param resourceGroups = {
  service: { name: 'rg-avd-prod-uksouth-service', create: true }
  hosts: { name: 'rg-avd-prod-uksouth-hosts', create: true }
  storage: { name: 'rg-avd-prod-uksouth-storage', create: true }
  network: { name: '', create: false } // unused: existing VNet
  monitor: { name: '', create: false } // unused: existing Log Analytics
}

// ---------------------------------------------------------------- Network (existing)
param networkMode = 'existing'
param existingSessionHostSubnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-spoke-avd/subnets/snet-avd-hosts'
param existingPrivateEndpointSubnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-spoke-avd/subnets/snet-privateendpoints'

// For a new VNet instead:
// param networkMode = 'new'
// param vnetAddressPrefix = '10.50.0.0/16'
// param sessionHostSubnetPrefix = '10.50.0.0/22'
// param privateEndpointSubnetPrefix = '10.50.4.0/27'
// param dnsServers = ['10.0.0.4']
// param outboundMethod = 'FirewallUdr'
// param firewallPrivateIp = '10.0.1.4'
// param hubVnetId = '/subscriptions/<hub-sub>/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub'

// ---------------------------------------------------------------- Capacity / session hosts
// 1000 users / 10 per host = 100 session hosts
param targetUserCount = 1000
param maxSessionsPerHost = 10
param sessionHostCountOverride = -1
param sessionHostStartIndex = 0
param sessionHostNamePrefix = 'avdsh'
param vmSize = 'Standard_D8s_v5'
param imageReference = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'office-365'
  sku: 'win11-24h2-avd-m365'
  version: 'latest'
}
param availabilityZones = [
  '1'
  '2'
  '3'
]
param localAdminUsername = 'avdadmin'
param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')

// ---------------------------------------------------------------- Identity
param avdUsersGroupObjectId = '00000000-0000-0000-0000-000000000000'
param avdAdminsGroupObjectId = ''
// az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv
param avdServicePrincipalObjectId = ''
param enableSingleSignOn = true

// ---------------------------------------------------------------- Host pool / scaling
param loadBalancerType = 'BreadthFirst'
param deployScalingPlan = true
param scalingPlanTimeZone = 'GMT Standard Time'

// ---------------------------------------------------------------- Monitoring (existing)
param logAnalyticsMode = 'existing'
param existingLogAnalyticsWorkspaceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-management/providers/Microsoft.OperationalInsights/workspaces/log-central'

// ---------------------------------------------------------------- FSLogix
param deployFslogixStorage = true
param fslogixShareQuotaGiB = 10240
param fslogixStorageSku = 'Premium_ZRS'
param fslogixProfileSizeMB = 30000
param privateDnsZoneMode = 'existing'
param existingFilePrivateDnsZoneId = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net'
