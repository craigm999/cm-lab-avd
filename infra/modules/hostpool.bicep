// AVD control plane: pooled host pool, desktop application group, workspace,
// optional autoscale scaling plan and diagnostics.
param location string
param nameSuffix string
param hostPoolName string
param maxSessionsPerHost int
param loadBalancerType string
param enableSingleSignOn bool
param registrationTokenValidity string
param desktopFriendlyName string
param avdUsersGroupObjectId string
param deployScalingPlan bool
param scalingPlanTimeZone string
param logAnalyticsWorkspaceId string
param tags object = {}

@description('Do not set - used to calculate the registration token expiry.')
param baseTime string = utcNow('u')

// Entra ID join RDP properties:
//  targetisaadjoined:i:1  - required so clients can connect to Entra-joined hosts
//  enablerdsaadauth:i:1   - Entra ID single sign-on (Microsoft Entra authentication for RDP)
var entraRdpProperties = enableSingleSignOn
  ? 'targetisaadjoined:i:1;enablerdsaadauth:i:1;'
  : 'targetisaadjoined:i:1;'
var baseRdpProperties = 'drivestoredirect:s:;audiomode:i:0;videoplaybackmode:i:1;redirectclipboard:i:1;redirectprinters:i:1;devicestoredirect:s:;redirectcomports:i:0;redirectsmartcards:i:1;usbdevicestoredirect:s:;enablecredsspsupport:i:1;use multimon:i:1;autoreconnection enabled:i:1;bandwidthautodetect:i:1;networkautodetect:i:1;audiocapturemode:i:1;encode redirected video capture:i:1;camerastoredirect:s:*;'

// Built-in role: Desktop Virtualization User
var desktopVirtualizationUserRoleId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: hostPoolName
  location: location
  tags: tags
  properties: {
    friendlyName: hostPoolName
    hostPoolType: 'Pooled'
    loadBalancerType: loadBalancerType
    maxSessionLimit: maxSessionsPerHost
    preferredAppGroupType: 'Desktop'
    startVMOnConnect: true
    validationEnvironment: false
    customRdpProperty: '${baseRdpProperties}${entraRdpProperties}'
    registrationInfo: {
      expirationTime: dateTimeAdd(baseTime, registrationTokenValidity)
      registrationTokenOperation: 'Update'
    }
    agentUpdate: {
      type: 'Scheduled'
      useSessionHostLocalTime: true
      maintenanceWindows: [
        {
          dayOfWeek: 'Sunday'
          hour: 2
        }
      ]
    }
  }
}

resource desktopAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: 'vdag-${nameSuffix}-desktop'
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPool.id
    friendlyName: desktopFriendlyName
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-03' = {
  name: 'vdws-${nameSuffix}'
  location: location
  tags: tags
  properties: {
    friendlyName: 'Azure Virtual Desktop'
    applicationGroupReferences: [
      desktopAppGroup.id
    ]
  }
}

// Users group -> Desktop Virtualization User on the desktop app group.
resource appGroupAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(desktopAppGroup.id, avdUsersGroupObjectId, desktopVirtualizationUserRoleId)
  scope: desktopAppGroup
  properties: {
    principalId: avdUsersGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', desktopVirtualizationUserRoleId)
  }
}

// ----------------------------------------------------------------------------- Autoscale
// Keeps a minimum of hosts warm off-peak and powers hosts on/off as demand changes,
// so all 100 hosts are not running 24x7.
resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2024-04-03' = if (deployScalingPlan) {
  name: 'vdscaling-${nameSuffix}'
  location: location
  tags: tags
  properties: {
    friendlyName: 'Autoscale - ${hostPoolName}'
    hostPoolType: 'Pooled'
    timeZone: scalingPlanTimeZone
    exclusionTag: 'ExcludeFromScaling'
    schedules: [
      {
        name: 'Weekdays'
        daysOfWeek: [
          'Monday'
          'Tuesday'
          'Wednesday'
          'Thursday'
          'Friday'
        ]
        rampUpStartTime: {
          hour: 7
          minute: 0
        }
        rampUpLoadBalancingAlgorithm: 'BreadthFirst'
        rampUpMinimumHostsPct: 20
        rampUpCapacityThresholdPct: 60
        peakStartTime: {
          hour: 9
          minute: 0
        }
        peakLoadBalancingAlgorithm: loadBalancerType
        rampDownStartTime: {
          hour: 18
          minute: 0
        }
        rampDownLoadBalancingAlgorithm: 'DepthFirst'
        rampDownMinimumHostsPct: 10
        rampDownCapacityThresholdPct: 90
        rampDownForceLogoffUsers: false
        rampDownWaitTimeMinutes: 30
        rampDownNotificationMessage: 'You will be logged off in 30 minutes. Please save your work.'
        rampDownStopHostsWhen: 'ZeroSessions'
        offPeakStartTime: {
          hour: 20
          minute: 0
        }
        offPeakLoadBalancingAlgorithm: 'DepthFirst'
      }
      {
        name: 'Weekends'
        daysOfWeek: [
          'Saturday'
          'Sunday'
        ]
        rampUpStartTime: {
          hour: 9
          minute: 0
        }
        rampUpLoadBalancingAlgorithm: 'DepthFirst'
        rampUpMinimumHostsPct: 2
        rampUpCapacityThresholdPct: 90
        peakStartTime: {
          hour: 10
          minute: 0
        }
        peakLoadBalancingAlgorithm: 'DepthFirst'
        rampDownStartTime: {
          hour: 16
          minute: 0
        }
        rampDownLoadBalancingAlgorithm: 'DepthFirst'
        rampDownMinimumHostsPct: 1
        rampDownCapacityThresholdPct: 90
        rampDownForceLogoffUsers: false
        rampDownWaitTimeMinutes: 30
        rampDownNotificationMessage: 'You will be logged off in 30 minutes. Please save your work.'
        rampDownStopHostsWhen: 'ZeroSessions'
        offPeakStartTime: {
          hour: 18
          minute: 0
        }
        offPeakLoadBalancingAlgorithm: 'DepthFirst'
      }
    ]
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPool.id
        scalingPlanEnabled: true
      }
    ]
  }
}

// ----------------------------------------------------------------------------- Diagnostics
resource hostPoolDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: hostPool
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource appGroupDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: desktopAppGroup
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource workspaceDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: workspace
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource scalingPlanDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployScalingPlan) {
  name: 'diag-to-law'
  scope: scalingPlan
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output hostPoolName string = hostPool.name
output hostPoolId string = hostPool.id
output workspaceName string = workspace.name
output appGroupName string = desktopAppGroup.name
