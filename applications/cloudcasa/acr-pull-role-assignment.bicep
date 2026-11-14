targetScope = 'resourceGroup'

@description('Name of the Azure Container Registry that stores the CloudCasa wrapper chart.')
param acrName string

@description('Object ID of the Workload Orchestration extension managed identity.')
param principalId string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

var acrPullRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)

@onlyIfNotExists()
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, principalId, acrPullRoleDefinitionId)
  scope: acr
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
  }
}

output roleAssignmentId string = acrPullRoleAssignment.id
