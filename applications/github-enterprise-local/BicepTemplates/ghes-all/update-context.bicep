targetScope = 'resourceGroup'

param contextName string
param location string
param tags object
param capabilities array
param hierarchies array

resource context 'Microsoft.Edge/contexts@2026-03-01' = {
  name: contextName
  location: location
  tags: tags
  properties: {
    capabilities: capabilities
    hierarchies: hierarchies
  }
}
