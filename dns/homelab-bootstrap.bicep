// Explicit bootstrap only. Regular DNS deployments never overwrite dynamic values.
targetScope = 'resourceGroup'
@description('Current public IPv4 confirmed by two independent checks on dockhost')
param publicIpv4 string
resource zone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: 'kscloud.io'
}
resource ha 'Microsoft.Network/dnsZones/A@2018-05-01' = {
  parent: zone
  name: 'ha'
  properties: {
    TTL: 300
    ARecords: [{ ipv4Address: publicIpv4 }]
    metadata: {
      owner: 'homelab-azure-ddns'
    }
  }
}
output recordId string = ha.id
