using 'main.bicep'

// ---------------------------------------------------------------- General
param location = readEnvironmentVariable('LOCATION', 'uksouth')
param workloadName = 'avd'
param environmentName = 'prod'
param tags = {
  owner: 'it-infrastructure'
  costCentre: 'tbc'
}

// ---------------------------------------------------------------- Capacity
// 1000 users / 10 per host = 100 session hosts
param targetUserCount = 1000
param maxSessionsPerHost = 10

// Staged rollout example: deploy the first 20 hosts, then re-run with
//   sessionHostStartIndex = 20, sessionHostCountOverride = 80
param sessionHostCountOverride = -1
param sessionHostStartIndex = 0

// ---------------------------------------------------------------- Session hosts
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
// Supplied at deploy time - never commit a password.
param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')

// ---------------------------------------------------------------- Identity
// Entra ID security group containing the AVD users.
param avdUsersGroupObjectId = readEnvironmentVariable('AVD_USERS_GROUP_ID')
// Optional: Entra ID group for session host admins.
param avdAdminsGroupObjectId = readEnvironmentVariable('AVD_ADMINS_GROUP_ID', '')
// az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv
param avdServicePrincipalObjectId = readEnvironmentVariable('AVD_SP_OBJECT_ID', '')

// ---------------------------------------------------------------- Host pool / scaling
param loadBalancerType = 'BreadthFirst'
param enableSingleSignOn = true
param deployScalingPlan = true
param scalingPlanTimeZone = 'GMT Standard Time'

// ---------------------------------------------------------------- FSLogix
param deployFslogixStorage = true
param fslogixShareQuotaGiB = 10240
param fslogixStorageSku = 'Premium_ZRS'
param fslogixProfileSizeMB = 30000
