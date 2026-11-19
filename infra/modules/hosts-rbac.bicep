// RBAC on the session host resource group.
//  - Entra-joined sign-in requires "Virtual Machine User Login" (or Administrator Login).
//  - Autoscale + Start VM on Connect require the Azure Virtual Desktop service principal
//    to hold "Desktop Virtualization Power On Off Contributor".
param avdUsersGroupObjectId string = ''
param avdAdminsGroupObjectId string = ''
param avdServicePrincipalObjectId string = ''

var vmUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'
var vmAdminLoginRoleId = '1c0163c0-47e6-4577-8991-ea5c82e286e4'
var powerOnOffContributorRoleId = '40c5ff49-9181-41f8-ae61-143b0e78555e'

resource usersLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdUsersGroupObjectId)) {
  name: guid(resourceGroup().id, avdUsersGroupObjectId, vmUserLoginRoleId)
  properties: {
    principalId: avdUsersGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmUserLoginRoleId)
  }
}

resource adminsLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdAdminsGroupObjectId)) {
  name: guid(resourceGroup().id, avdAdminsGroupObjectId, vmAdminLoginRoleId)
  properties: {
    principalId: avdAdminsGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmAdminLoginRoleId)
  }
}

resource avdPowerOnOff 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdServicePrincipalObjectId)) {
  name: guid(resourceGroup().id, avdServicePrincipalObjectId, powerOnOffContributorRoleId)
  properties: {
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', powerOnOffContributorRoleId)
  }
}
