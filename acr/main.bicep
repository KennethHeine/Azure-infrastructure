// Shared Container Registry — estate-wide resource, like dns/main.bicep.
//
// Consolidates what were up to 9 per-repo ACRs (one per container-app repo,
// each in its own rg-<repo>) into a single Standard-tier registry here in
// rg-acr. Repo isolation moves from "separate registry resource" to Entra
// ABAC repository permissions (roleAssignmentMode: AbacRepositoryPermissions,
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
// blast radius as the old per-registry isolation, at a fraction of the cost
// (Standard tier ≈ $0.667/day fixed + 100 GiB included, vs. 9× Basic's
// ≈ $0.167/day each once any of them cross the 10 GiB free tier).
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

@description('Registry name — globally unique across Azure, alphanumeric only. Fixed (not uniqueString-suffixed) because this is a estate-wide singleton, not a per-repo resource.')
param registryName string = 'acrkscloud'

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: registryName
  location: location
  sku: {
    name: 'Standard'
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

output loginServer string = acr.properties.loginServer
output registryId string = acr.id
