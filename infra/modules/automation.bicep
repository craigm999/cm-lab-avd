// Automation account for personal-pool maintenance (spares + tidy-up). The runbook,
// its schedule and configuration are published by scripts/Publish-AvdPoolAutomation.ps1.
param location string
param name string
param tags object = {}

var hostPoolContributorRoleId = 'e307426c-f9b6-4e81-87de-d99efb3c32bc' // Desktop Virtualization Host Pool Contributor
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader (template spec, host pool)

resource account 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
  }
}

// Service RG: refresh the registration token and remove session hosts; read the template spec.
resource hostPoolRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, account.id, hostPoolContributorRoleId)
  properties: {
    principalId: account.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', hostPoolContributorRoleId)
  }
}

resource readerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, account.id, readerRoleId)
  properties: {
    principalId: account.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
  }
}

output name string = account.name
output principalId string = account.identity.principalId
