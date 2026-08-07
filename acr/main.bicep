// Shared Container Registry — estate-wide resource, like dns/main.bicep.
//
// Consolidates what were up to 9 per-repo ACRs (one per container-app repo,
// each in its own rg-<repo>) into a single registry here in rg-acr. Repo
// isolation moves from "separate registry resource" to Entra ABAC repository
// permissions (roleAssignmentMode: AbacRepositoryPermissions,
// see https://learn.microsoft.com/azure/container-registry/container-registry-rbac-abac-repository-permissions):
// each repo's OIDC service principal gets 'Container Registry Repository
// Writer' and each app's runtime UAMI gets 'Container Registry Repository
// Reader', both ABAC-conditioned to that repo's own `<repo>/*` path only —
// declared in role-grants.json (this repo's cross-RG grant mechanism) and
// applied by the onboarding SP, same as every other cross-RG grant.
//
// Decided 2026-08-05: Kenneth explicitly chose to consolidate for cost after
// this estate had deliberately BUILT AND ABANDONED a shared-ACR model once
// before, precisely for per-repo isolation (see this repo's CLAUDE.md
// history) — ABAC repository permissions are what makes this reversal safe:
// a compromised repo SP can push/pull only its own repository path, same
// blast radius as the old per-registry isolation, at a fraction of the cost.
//
// The migration COMPLETED 2026-08-06: every container-app repo is on this
// registry and all nine per-repo registries were deleted the same day. Each
// repo's own Bicep still carries a `useSharedAcr` toggle whose false branch
// creates a per-repo ACR — that path is now a deliberate rollback hatch only.
//
// IMPORTANT — ABAC-enabled roles do NOT support catalog listing. A repo
// identity that needs `az acr repository list` (most don't — push/pull only
// needs Repository Writer/Reader) also needs the UNCONDITIONED
// 'Container Registry Repository Catalog Lister' role, which cannot carry a
// condition — that would grant it visibility into every repo's catalog
// entries (not content), so avoid it unless a repo actually needs it.

targetScope = 'resourceGroup'

@description('Azure region for the shared registry.')
param location string = resourceGroup().location

@description('Registry name — globally unique across Azure, alphanumeric only. Fixed (not uniqueString-suffixed) because this is an estate-wide singleton, not a per-repo resource.')
param registryName string = 'acrkscloud'

@description('Object id of the control-plane onboarding SP (sp-azure-infrastructure-github). Granted registry-wide Repository Contributor + Catalog Lister so decommission-repo.ps1 can enumerate and delete a torn-down repo\'s images. Subscription Owner alone does NOT grant this — see the note on the grants below. Empty = skip.')
param controlPlanePrincipalId string = ''

@description('Object ids of human operators granted registry-wide Catalog Lister + Repository Reader, so this registry can actually be inspected. Empty = skip.')
param operatorPrincipalIds array = []

// ABAC-enabled built-in role definition ids (constant across tenants).
var repositoryContributorRoleId = '2efddaa5-3f1f-4df3-97df-af3f13818f4c'
var repositoryReaderRoleId = 'b93aa761-3e63-49ed-ac28-beffa264f7ac'
var catalogListerRoleId = 'bfdb9389-c9a5-478a-bb2f-ba9ca092c3c7'

resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
  name: registryName
  location: location
  // Basic (was Standard until 2026-08-07, Kenneth's cost call). Per the ACR SKU
  // table, Basic and Standard have IDENTICAL data-plane rate limits and both
  // fully support ABAC repository permissions; the only differences that reach
  // this estate are included storage (10 vs 100 GiB) and webhooks (2 vs 10 — we
  // use zero). At ~10 GiB stored, and 0.66 DKK/GB/month for storage above the
  // included allowance, Basic (1.09 DKK/day) stays cheaper than Standard
  // (4.37 DKK/day) until roughly 158 GB stored — far beyond where the reusable
  // deploy-app `cleanup` job lets this registry settle. Both tiers share the
  // same 40 TiB hard storage limit, so a downgrade is never blocked by current
  // usage, and changing SKU is online (no downtime, no impact on operations).
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    // ABAC repository permissions — see header comment. Legacy roles
    // (AcrPull/AcrPush/AcrDelete) are NOT honored once this is set; every
    // grant against this registry must use the ABAC-enabled roles instead
    // (Container Registry Repository Reader/Writer/Contributor), with a
    // condition to scope it to one repo's path.
    roleAssignmentMode: 'AbacRepositoryPermissions'
  }
}

// ---------------------------------------------------------------------------
// Control-plane + operator data-plane access.
//
// Under AbacRepositoryPermissions, Azure RBAC control-plane roles grant ZERO
// data-plane access: subscription Owner cannot list or delete repositories, and
// `az acr repository list` returns
//   401 {"code":"UNAUTHORIZED", detail:[{Type:"registry",Name:"catalog"}]}
// for every principal that lacks an explicit grant. Two consequences this block
// fixes, both registry-wide and unconditioned (Catalog Lister structurally
// cannot carry an ABAC condition):
//
//   1. decommission-repo.ps1 must enumerate and delete a torn-down repo's
//      `<repo>/*` images. Before consolidation those died with rg-<repo>; now
//      they outlive it and would be paid for forever.
//   2. A human operator must be able to see what this registry holds at all.
//
// Both are control-plane/audit roles held by principals that are already
// subscription Owner, so this widens no real blast radius — but it is
// deliberately NOT granted to any repo identity, which stays path-scoped.
// ---------------------------------------------------------------------------

resource controlPlaneRepositoryContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(controlPlanePrincipalId)) {
  scope: acr
  name: guid(acr.id, controlPlanePrincipalId, repositoryContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', repositoryContributorRoleId)
    principalId: controlPlanePrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource controlPlaneCatalogLister 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(controlPlanePrincipalId)) {
  scope: acr
  name: guid(acr.id, controlPlanePrincipalId, catalogListerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', catalogListerRoleId)
    principalId: controlPlanePrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource operatorCatalogLister 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in operatorPrincipalIds: {
    scope: acr
    name: guid(acr.id, principalId, catalogListerRoleId)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', catalogListerRoleId)
      principalId: principalId
      principalType: 'User'
    }
  }
]

resource operatorRepositoryReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in operatorPrincipalIds: {
    scope: acr
    name: guid(acr.id, principalId, repositoryReaderRoleId)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', repositoryReaderRoleId)
      principalId: principalId
      principalType: 'User'
    }
  }
]

output loginServer string = acr.properties.loginServer
output registryId string = acr.id
