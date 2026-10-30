targetScope = 'resourceGroup'

@description('Name of the existing Workload Orchestration context.')
param contextName string

@description('Azure region of the existing Workload Orchestration context.')
param location string

@description('Tags preserved on the existing Workload Orchestration context.')
param tags object = {}

@description('Complete capability collection for the Workload Orchestration context.')
param capabilities array

@description('Complete hierarchy collection for the Workload Orchestration context.')
param hierarchies array

@description('Whether the existing context requires reconciliation.')
param updateRequired bool

resource context 'Microsoft.Edge/contexts@2026-03-01' = if (updateRequired) {
  name: contextName
  location: location
  tags: tags
  properties: {
    capabilities: capabilities
    hierarchies: hierarchies
  }
}

output contextId string = context.id
output hierarchyLevel string = last(hierarchies).name
