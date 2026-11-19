// Scenario: FSLogix without a private endpoint or private DNS. New VNet; the session host
// subnet gets the Microsoft.Storage service endpoint and the storage firewall allows it.
using '../../infra/main.bicep'

param location = 'uksouth'
param environmentName = 'se'
param networkMode = 'new'
param logAnalyticsMode = 'new'
param fslogixNetworkAccess = 'serviceEndpoint'
param avdUsersGroupObjectId = '11111111-1111-1111-1111-111111111111'
param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')
