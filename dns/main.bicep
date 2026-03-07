// DNS Zone: kscloud.io
// Manages the public DNS zone and all records in the 'kscloud' resource group.
// NS and SOA records are auto-managed by Azure and excluded from this template.

targetScope = 'resourceGroup'

@description('DNS zone name')
param zoneName string = 'kscloud.io'

// ─── DNS Zone ────────────────────────────────────────────────────────
resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' = {
  name: zoneName
  location: 'global'
}

// ─── MX Record: @ ───────────────────────────────────────────────────
resource mxRoot 'Microsoft.Network/dnsZones/MX@2018-05-01' = {
  parent: dnsZone
  name: '@'
  properties: {
    TTL: 3600
    MXRecords: [
      {
        preference: 0
        exchange: 'kscloud-io.mail.protection.outlook.com'
      }
    ]
  }
}

// ─── TXT Record: @ ──────────────────────────────────────────────────
resource txtRoot 'Microsoft.Network/dnsZones/TXT@2018-05-01' = {
  parent: dnsZone
  name: '@'
  properties: {
    TTL: 3600
    TXTRecords: [
      {
        value: [
          'v=spf1 include:spf.protection.outlook.com -all'
        ]
      }
    ]
  }
}

// ─── CNAME: autodiscover ────────────────────────────────────────────
resource cnameAutodiscover 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
  parent: dnsZone
  name: 'autodiscover'
  properties: {
    TTL: 3600
    CNAMERecord: {
      cname: 'autodiscover.outlook.com'
    }
  }
}

// ─── CNAME: chat ────────────────────────────────────────────────────
resource cnameChat 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
  parent: dnsZone
  name: 'chat'
  properties: {
    TTL: 3600
    CNAMERecord: {
      cname: 'blue-desert-0e5a3aa03.4.azurestaticapps.net'
    }
  }
}

// ─── CNAME: enterpriseenrollment ────────────────────────────────────
resource cnameEnterpriseEnrollment 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
  parent: dnsZone
  name: 'enterpriseenrollment'
  properties: {
    TTL: 3600
    CNAMERecord: {
      cname: 'enterpriseenrollment-s.manage.microsoft.com'
    }
  }
}

// ─── CNAME: enterpriseregistration ──────────────────────────────────
resource cnameEnterpriseRegistration 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
  parent: dnsZone
  name: 'enterpriseregistration'
  properties: {
    TTL: 3600
    CNAMERecord: {
      cname: 'enterpriseregistration.windows.net'
    }
  }
}

// ─── CNAME: fodbold ─────────────────────────────────────────────────
resource cnameFodbold 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
  parent: dnsZone
  name: 'fodbold'
  properties: {
    TTL: 3600
    CNAMERecord: {
      cname: 'calm-stone-04ffa2303.1.azurestaticapps.net'
    }
  }
}

// ─── CNAME: test-chat ────────────────────────────────────────────────
resource cnameTestChat 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = {
  parent: dnsZone
  name: 'test-chat'
  properties: {
    TTL: 3600
    CNAMERecord: {
      cname: 'ambitious-field-027ee2303.4.azurestaticapps.net'
    }
  }
}

// ─── Outputs ─────────────────────────────────────────────────────────
output nameServers array = dnsZone.properties.nameServers
output zoneId string = dnsZone.id
