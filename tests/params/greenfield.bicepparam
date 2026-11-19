// Scenario: everything new - new RGs, new VNet with NAT gateway, new Log Analytics,
// new private DNS zone. 1000 users / 10 per host.
using '../../infra/main.bicep'

param location = 'uksouth'
param environmentName = 'green'
param networkMode = 'new'
param outboundMethod = 'NatGateway'
param logAnalyticsMode = 'new'
param privateDnsZoneMode = 'new'
param avdUsersGroupObjectId = '11111111-1111-1111-1111-111111111111'
param avdServicePrincipalObjectId = '22222222-2222-2222-2222-222222222222'
param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')
