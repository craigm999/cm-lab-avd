// Scenario: new spoke VNet peered to a hub in another subscription, outbound via the
// hub firewall, custom DNS, policy-managed private DNS, gallery image, all components
// in ONE shared new resource group (tests resource group de-duplication), pilot of 20.
using '../../infra/main.bicep'

param location = 'westeurope'
param environmentName = 'hub'
param resourceGroups = {
  service: { name: 'rg-avd-shared', create: true }
  hosts: { name: 'rg-avd-shared', create: true }
  storage: { name: 'rg-avd-shared', create: true }
  network: { name: 'rg-avd-shared', create: true }
  monitor: { name: '', create: false }
}
param networkMode = 'new'
param vnetAddressPrefix = '10.60.0.0/16'
param sessionHostSubnetPrefix = '10.60.0.0/22'
param privateEndpointSubnetPrefix = '10.60.4.0/27'
param dnsServers = [
  '10.0.0.4'
  '10.0.0.5'
]
param outboundMethod = 'FirewallUdr'
param firewallPrivateIp = '10.0.1.4'
param hubVnetId = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub'
param hubUseRemoteGateways = true
param logAnalyticsMode = 'existing'
param existingLogAnalyticsWorkspaceId = '/subscriptions/44444444-4444-4444-4444-444444444444/resourceGroups/rg-mgmt/providers/Microsoft.OperationalInsights/workspaces/log-central'
param privateDnsZoneMode = 'policyManaged'
param imageReference = {
  id: '/subscriptions/55555555-5555-5555-5555-555555555555/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/gal_avd/images/win11-avd'
}
param availabilityZones = []
param sessionHostCountOverride = 20
param avdUsersGroupObjectId = '11111111-1111-1111-1111-111111111111'
param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')
