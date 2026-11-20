// Scenario: personal (1:1) host pool with direct assignment, no FSLogix (default for
// Personal), alongside an existing deployment's network.
using '../../infra/main.bicep'

param location = 'uksouth'
param environmentName = 'pd'
param hostPoolType = 'Personal'
param personalAssignmentType = 'Direct'
param targetUserCount = 50
param sessionHostNamePrefix = 'avdpd'
param vmSize = 'Standard_D4s_v5'
param networkMode = 'existing'
param existingSessionHostSubnetId = '/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-avd'
param logAnalyticsMode = 'new'
param deployPoolAutomation = true
param spareDesktops = 5
param deleteUnusedAfterDays = 90
param avdUsersGroupObjectId = '11111111-1111-1111-1111-111111111111'
param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')
