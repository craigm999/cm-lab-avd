// AVD control plane: pooled host pool, desktop application group, workspace,
// optional autoscale scaling plan and diagnostics.
param location string
param nameSuffix string
param hostPoolName string

@description('Pooled (shared, multi-session) or Personal (1:1 - each user gets their own VM).')
@allowed([
  'Pooled'
  'Personal'
])
param hostPoolType string = 'Pooled'

@description('[Personal] Automatic: a user gets a free desktop the first time they connect. Direct: an admin assigns users to desktops (scripts/Set-AvdPersonalAssignment.ps1).')
@allowed([
  'Automatic'
  'Direct'
])
param personalAssignmentType string = 'Automatic'
param maxSessionsPerHost int
param loadBalancerType string
param enableSingleSignOn bool
param registrationTokenValidity string
param desktopFriendlyName string
param avdUsersGroupObjectId string
param deployScalingPlan bool
param scalingPlanTimeZone string
param logAnalyticsWorkspaceId string
@description('Device redirection settings (true = allowed) - the "redirection" block of infra/customizations/customizations.json. Missing keys default to blocked, except clipboard/audio/microphone/WebAuthn which default to allowed.')
param redirection object = {}
param tags object = {}

@description('Do not set - used to calculate the registration token expiry.')
param baseTime string = utcNow('u')

// Entra ID join RDP properties:
//  targetisaadjoined:i:1  - required so clients can connect to Entra-joined hosts
//  enablerdsaadauth:i:1   - Entra ID single sign-on (Microsoft Entra authentication for RDP)
var entraRdpProperties = enableSingleSignOn
  ? 'targetisaadjoined:i:1;enablerdsaadauth:i:1;'
  : 'targetisaadjoined:i:1;'
var baseRdpProperties = 'videoplaybackmode:i:1;enablecredsspsupport:i:1;use multimon:i:1;autoreconnection enabled:i:1;bandwidthautodetect:i:1;networkautodetect:i:1;encode redirected video capture:i:1;'

// Device redirection (Microsoft Learn: Azure Virtual Desktop RDP properties). The same
// settings are enforced on each host as policy by Customize-SessionHost.ps1; where they
// differ, the most restrictive wins.
var allow = {
  drives: redirection.?drives ?? false
  printers: redirection.?printers ?? false
  usbDevices: redirection.?usbDevices ?? false
  comPorts: redirection.?comPorts ?? false
  smartCards: redirection.?smartCards ?? false
  cameras: redirection.?cameras ?? false
  clipboard: redirection.?clipboard ?? true
  audioPlayback: redirection.?audioPlayback ?? true
  microphone: redirection.?microphone ?? true
  webAuthn: redirection.?webAuthn ?? true
}
var redirectionRdpProperties = join([
  'drivestoredirect:s:${allow.drives ? '*' : ''}'
  'redirectprinters:i:${allow.printers ? 1 : 0}'
  'usbdevicestoredirect:s:${allow.usbDevices ? '*' : ''}'
  'devicestoredirect:s:${allow.usbDevices ? '*' : ''}'
  'redirectcomports:i:${allow.comPorts ? 1 : 0}'
  'redirectsmartcards:i:${allow.smartCards ? 1 : 0}'
  'camerastoredirect:s:${allow.cameras ? '*' : ''}'
  'redirectclipboard:i:${allow.clipboard ? 1 : 0}'
  'audiomode:i:${allow.audioPlayback ? 0 : 2}'
  'audiocapturemode:i:${allow.microphone ? 1 : 0}'
  'redirectwebauthn:i:${allow.webAuthn ? 1 : 0}'
  'redirectlocation:i:0'
], ';')

var isPersonal = hostPoolType == 'Personal'
// Host pool type can't be changed in place, so personal resources get their own names and
// can sit alongside an existing pooled deployment (the shared workspace is reused).
var poolTag = isPersonal ? '-personal' : ''

// Built-in role: Desktop Virtualization User
var desktopVirtualizationUserRoleId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: hostPoolName
  location: location
  tags: tags
  properties: union({
    friendlyName: hostPoolName
    hostPoolType: hostPoolType
    loadBalancerType: isPersonal ? 'Persistent' : loadBalancerType
    preferredAppGroupType: 'Desktop'
    startVMOnConnect: true
    validationEnvironment: false
    customRdpProperty: '${baseRdpProperties}${redirectionRdpProperties};${entraRdpProperties}'
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
  }, isPersonal ? {
    personalDesktopAssignmentType: personalAssignmentType
  } : {
    maxSessionLimit: maxSessionsPerHost
  })
}

resource desktopAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: 'vdag-${nameSuffix}${poolTag}-desktop'
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
resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2024-04-03' = if (deployScalingPlan && !isPersonal) {
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

// Personal autoscale: start a user's VM when they connect, and deallocate it after they
// disconnect or sign out, so 1:1 desktops don't run (and bill) when nobody is using them.
resource scalingPlanPersonal 'Microsoft.DesktopVirtualization/scalingPlans@2024-04-03' = if (deployScalingPlan && isPersonal) {
  name: 'vdscaling-${nameSuffix}${poolTag}'
  location: location
  tags: tags
  properties: {
    friendlyName: 'Autoscale - ${hostPoolName}'
    hostPoolType: 'Personal'
    timeZone: scalingPlanTimeZone
    exclusionTag: 'ExcludeFromScaling'
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPool.id
        scalingPlanEnabled: true
      }
    ]
  }
}

var personalScheduleDays = {
  Weekdays: [
    'Monday'
    'Tuesday'
    'Wednesday'
    'Thursday'
    'Friday'
  ]
  Weekends: [
    'Saturday'
    'Sunday'
  ]
}

resource personalSchedules 'Microsoft.DesktopVirtualization/scalingPlans/personalSchedules@2024-04-03' = [
  for day in items(personalScheduleDays): if (deployScalingPlan && isPersonal) {
    parent: scalingPlanPersonal
    name: day.key
    properties: {
      daysOfWeek: day.value
      // Ramp-up: no pre-starting; VMs start when their user connects.
      rampUpStartTime: { hour: 7, minute: 0 }
      rampUpAutoStartHosts: 'None'
      rampUpStartVMOnConnect: 'Enable'
      rampUpActionOnDisconnect: 'None'
      rampUpMinutesToWaitOnDisconnect: 0
      rampUpActionOnLogoff: 'Deallocate'
      rampUpMinutesToWaitOnLogoff: 15
      // Peak: be generous - users step away during the working day.
      peakStartTime: { hour: 9, minute: 0 }
      peakStartVMOnConnect: 'Enable'
      peakActionOnDisconnect: 'Deallocate'
      peakMinutesToWaitOnDisconnect: 120
      peakActionOnLogoff: 'Deallocate'
      peakMinutesToWaitOnLogoff: 15
      // Ramp-down / off-peak: power off sooner.
      rampDownStartTime: { hour: 18, minute: 0 }
      rampDownStartVMOnConnect: 'Enable'
      rampDownActionOnDisconnect: 'Deallocate'
      rampDownMinutesToWaitOnDisconnect: 60
      rampDownActionOnLogoff: 'Deallocate'
      rampDownMinutesToWaitOnLogoff: 5
      offPeakStartTime: { hour: 20, minute: 0 }
      offPeakStartVMOnConnect: 'Enable'
      offPeakActionOnDisconnect: 'Deallocate'
      offPeakMinutesToWaitOnDisconnect: 30
      offPeakActionOnLogoff: 'Deallocate'
      offPeakMinutesToWaitOnLogoff: 5
    }
  }
]

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

resource scalingPlanDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployScalingPlan && !isPersonal) {
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

resource scalingPlanPersonalDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployScalingPlan && isPersonal) {
  name: 'diag-to-law'
  scope: scalingPlanPersonal
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
output appGroupId string = desktopAppGroup.id
