extension microsoftGraphV1
targetScope = 'resourceGroup'

@description('Exact HTTPS MCP endpoint, also the resource indicator and scope prefix.')
param resourceUrl string
@description('Exact callback copied from this ChatGPT connection, never a guessed shared callback.')
param callbackUrl string
@description('Second pass binds HTTPS identifier after the API is configured for v2 tokens.')
param bindIdentifier bool = false
var scopeId = guid(tenant().tenantId, 'ks-integrations', 'integrations.read')
var suffix = uniqueString(subscription().id, resourceGroup().id)

resource api 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: 'ks-integrations-mcp-${suffix}'
  displayName: 'KS Integrations MCP API'
  signInAudience: 'AzureADMyOrg'
  identifierUris: bindIdentifier ? [resourceUrl] : []
  api: {
    requestedAccessTokenVersion: 2
    oauth2PermissionScopes: [{
      id: scopeId
      value: 'integrations.read'
      type: 'User'
      isEnabled: true
      adminConsentDisplayName: 'Read KS Integrations'
      adminConsentDescription: 'Read bookkeeping overviews and prepare proposals. Does not post or reconcile.'
      userConsentDisplayName: 'Read KS Integrations'
      userConsentDescription: 'Read your bookkeeping overview and prepare proposals. Does not post or reconcile.'
    }]
  }
}
resource apiPrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: api.appId
}
resource client 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: 'ks-integrations-chatgpt-${suffix}'
  displayName: 'KS Integrations ChatGPT Client'
  signInAudience: 'AzureADMyOrg'
  isFallbackPublicClient: false
  publicClient: { redirectUris: [callbackUrl] }
  requiredResourceAccess: [{
    resourceAppId: api.appId
    resourceAccess: [{ id: scopeId, type: 'Scope' }]
  }]
  dependsOn: [apiPrincipal]
}
resource clientPrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: client.appId
}
output apiClientId string = api.appId
output oauthClientId string = client.appId
output tenantId string = tenant().tenantId
output oauthIssuer string = 'https://login.microsoftonline.com/${tenant().tenantId}/v2.0'
output resource string = resourceUrl
output scope string = '${resourceUrl}/integrations.read'
output callback string = callbackUrl
