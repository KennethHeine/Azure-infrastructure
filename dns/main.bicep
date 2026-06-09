// DNS Zone: kscloud.io (data-driven)
//
// The zone's records are declared in dns/records.json (the single source of
// truth) and projected into Azure DNS record sets by the loops below. Add or
// remove records with the Add DNS Record / Remove DNS Record workflows — they
// edit records.json and push, which triggers the Deploy DNS Zone workflow.
//
// NOTE: ARM incremental deployments never delete records dropped from the
// template, so the Deploy DNS Zone workflow runs a reconcile/prune step after
// this deployment to delete any record set in the zone that is no longer in
// records.json. NS and SOA at the apex are Azure-managed and excluded here.

targetScope = 'resourceGroup'

// ─── Records: single source of truth ─────────────────────────────────
var config = loadJsonContent('records.json')
var zoneName = config.zoneName
var records = config.records

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
