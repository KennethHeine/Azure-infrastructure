// SWA custom-domain PUT completes, then ARM polls a subscription/location URL.
// RG Owner cannot read that URL. The exact action is absent from the provider
// catalogue, so use its narrow regional metadata/status read pattern (no app/data writes).
targetScope = 'subscription'

@description('Verified object ID of sp-bogstavvenner-github; not the runtime or a client ID.')
param deploymentPrincipalId string = 'c17e4f05-e194-449d-afbd-fadbfa06009e'

resource operationStatusRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, 'bogstavvenner-swa-operation-status-reader')
  properties: {
    roleName: 'Bogstavvenner SWA operation status reader'
    description: 'Lets the Bogstavvenner deployment identity read regional Web metadata/status for SWA polling. Exact SWA action is uncatalogued; no app/data writes.'
    type: 'CustomRole'
    permissions: [{
      actions: ['Microsoft.Web/locations/*/read']
      notActions: []
      dataActions: []
      notDataActions: []
    }]
    assignableScopes: [subscription().id]
  }
}
resource operationStatusGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, deploymentPrincipalId, operationStatusRole.id)
  properties: {
    principalId: deploymentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: operationStatusRole.id
  }
}
