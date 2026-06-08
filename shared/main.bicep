// Shared infrastructure for all onboarded repositories.
//
// Currently this provisions a single shared Azure Container Registry (ACR) that
// every container-app repo pushes images to and pulls images from. It lives in
// its own resource group (rg-shared) and is owned/managed by this
// Azure-infrastructure repo via the deploy-shared workflow.
//
// Access model (see CLAUDE.md):
//   - Each onboarded repo's service principal is granted AcrPush on this ACR so
//     its deploy-app workflow can push images.
//   - Each repo's SP is also granted "Role Based Access Control Administrator"
//     scoped to this ACR, constrained by an ABAC condition to ONLY assign the
//     AcrPull role — so the app's own deploy can grant its Container App's
//     user-assigned managed identity pull access (secret-less), and nothing
//     more. Those grants are created by the onboarding script, not here.
//
// Image pull uses managed identities (no admin user, no stored credentials),
// the Microsoft-recommended pattern for Container Apps + ACR.

@description('Globally-unique ACR name (5-50 lowercase alphanumeric chars).')
@minLength(5)
@maxLength(50)
param acrName string = 'acrks${uniqueString(subscription().id, 'shared-acr')}'

param location string = resourceGroup().location

@description('ACR service tier. Standard suits most production workloads.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param sku string = 'Standard'

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: sku
  }
  properties: {
    // Identity-based access only — no admin username/password. Repos authenticate
    // with their service principal (push) and Container Apps with their managed
    // identity (pull) via Azure RBAC.
    adminUserEnabled: false
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output acrResourceId string = acr.id
output acrResourceGroup string = resourceGroup().name
