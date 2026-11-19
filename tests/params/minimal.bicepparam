// Scenario: existing VNet, existing RGs, no FSLogix storage, no scaling plan,
// DepthFirst, SSO off - the "smallest footprint" path through the template.
using '../../infra/main.bicep'

param location = 'eastus2'
param environmentName = 'min'
param resourceGroups = {
  service: { name: 'rg-existing-avd', create: false }
  hosts: { name: 'rg-existing-avd-hosts', create: false }
  storage: { name: '', create: false }
  network: { name: '', create: false }
  monitor: { name: '', create: true }
}
param networkMode = 'existing'
param existingSessionHostSubnetId = '/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-avd'
param deployFslogixStorage = false
param deployScalingPlan = false
param loadBalancerType = 'DepthFirst'
param enableSingleSignOn = false
param avdUsersGroupObjectId = '11111111-1111-1111-1111-111111111111'
param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')
