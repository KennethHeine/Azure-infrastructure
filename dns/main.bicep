// DNS Zone: kscloud.io (data-driven)
//
// The zone's records are split across two source files and projected into Azure
// DNS record sets (the loops below operate on their UNION):
//   - records.platform.json : mail / M365 foundation (MX, SPF, DKIM, DMARC,
//                             autodiscover, enrollment). Carries the canonical
//                             zoneName. Changed via PR only — high blast radius.
//   - records.app.json      : app custom domains (CNAMEs + validation TXTs).
//                             Edited by the Add/Remove DNS Record workflows.
//
// NOTE: ARM incremental deployments never delete records dropped from the
// template, so the Deploy DNS Zone workflow runs a reconcile/prune step after
// this deployment to delete any record set in the zone that is in neither file.
// NS and SOA at the apex are Azure-managed and excluded here.

targetScope = 'resourceGroup'

// ─── Records: union of the platform + app source files ────────────────
var platform = loadJsonContent('records.platform.json')
var app = loadJsonContent('records.app.json')
var zoneName = platform.zoneName
var records = concat(platform.records, app.records)

// Partition by type — each Azure DNS record-set type is its own resource type.
var aRecords = filter(records, r => r.type == 'A')
var cnameRecords = filter(records, r => r.type == 'CNAME')
var txtRecords = filter(records, r => r.type == 'TXT')
var mxRecords = filter(records, r => r.type == 'MX')

// ─── DNS Zone ─────────────────────────────────────────────────────────
resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' = {
  name: zoneName
  location: 'global'
}

// ─── A records ──────────────────────────────────────────────────────
resource aSets 'Microsoft.Network/dnsZones/A@2018-05-01' = [
  for r in aRecords: {
    parent: dnsZone
    name: r.name
    properties: {
      TTL: r.ttl
      ARecords: [for v in r.values: { ipv4Address: v }]
    }
  }
]

// ─── CNAME records (a CNAME set holds exactly one target) ─────────────
resource cnameSets 'Microsoft.Network/dnsZones/CNAME@2018-05-01' = [
  for r in cnameRecords: {
    parent: dnsZone
    name: r.name
    properties: {
      TTL: r.ttl
      CNAMERecord: {
        cname: r.values[0]
      }
    }
  }
]

// ─── TXT records ──────────────────────────────────────────────────────
resource txtSets 'Microsoft.Network/dnsZones/TXT@2018-05-01' = [
  for r in txtRecords: {
    parent: dnsZone
    name: r.name
    properties: {
      TTL: r.ttl
      TXTRecords: [for v in r.values: { value: [v] }]
    }
  }
]

// ─── MX records (each value is "<preference> <exchange>") ─────────────
resource mxSets 'Microsoft.Network/dnsZones/MX@2018-05-01' = [
  for r in mxRecords: {
    parent: dnsZone
    name: r.name
    properties: {
      TTL: r.ttl
      MXRecords: [
        for v in r.values: {
          preference: int(split(v, ' ')[0])
          exchange: split(v, ' ')[1]
        }
      ]
    }
  }
]

// ─── Outputs ──────────────────────────────────────────────────────────
output nameServers array = dnsZone.properties.nameServers
output zoneId string = dnsZone.id
