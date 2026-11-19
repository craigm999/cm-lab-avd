// VNet, subnets, NSG and NAT gateway for the session hosts.
// AVD uses reverse-connect, so NO inbound rules are required. Session hosts need
// outbound internet (AVD control plane, Entra ID, Windows Update). Default outbound
// access is retired for new VNets, so outbound is provided by either a NAT gateway or
// a 0.0.0.0/0 route to a hub firewall / NVA (outboundMethod).
param location string
param nameSuffix string
param vnetAddressPrefix string
param sessionHostSubnetPrefix string
param privateEndpointSubnetPrefix string
param vnetName string
param dnsServers array = []
@allowed([
  'NatGateway'
  'FirewallUdr'
  'None'
])
param outboundMethod string = 'NatGateway'
param firewallPrivateIp string = ''

@description('Add the Microsoft.Storage service endpoint to the session host subnet (FSLogix serviceEndpoint mode).')
param storageServiceEndpoint bool = false
param tags object = {}

resource nsgHosts 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${nameSuffix}-hosts'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Deny-Inbound-Internet'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgPe 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${nameSuffix}-pe'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SMB-From-SessionHosts'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: sessionHostSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: privateEndpointSubnetPrefix
          destinationPortRange: '445'
        }
      }
    ]
  }
}

resource natPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (outboundMethod == 'NatGateway') {
  name: 'pip-${nameSuffix}-nat'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = if (outboundMethod == 'NatGateway') {
  name: 'ng-${nameSuffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: natPip.id
      }
    ]
  }
}

resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = if (outboundMethod == 'FirewallUdr') {
  name: 'rt-${nameSuffix}-hosts'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    dhcpOptions: empty(dnsServers) ? null : {
      dnsServers: dnsServers
    }
    subnets: [
      {
        name: 'snet-sessionhosts'
        properties: {
          addressPrefix: sessionHostSubnetPrefix
          networkSecurityGroup: {
            id: nsgHosts.id
          }
          natGateway: outboundMethod == 'NatGateway' ? { id: natGateway.id } : null
          routeTable: outboundMethod == 'FirewallUdr' ? { id: routeTable.id } : null
          defaultOutboundAccess: false
          serviceEndpoints: storageServiceEndpoint
            ? [
                {
                  service: 'Microsoft.Storage'
                  locations: [
                    location
                  ]
                }
              ]
            : []
        }
      }
      {
        name: 'snet-privateendpoints'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          networkSecurityGroup: {
            id: nsgPe.id
          }
          privateEndpointNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output sessionHostSubnetId string = vnet.properties.subnets[0].id
output privateEndpointSubnetId string = vnet.properties.subnets[1].id
