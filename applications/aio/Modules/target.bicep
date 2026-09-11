param location string
param name string
param capability string
param contextId string
resource cloudTarget 'Microsoft.Edge/targets@2026-05-01-preview' = {
  name: name
  location: location
  properties: {
    capabilities: [
      capability
    ]
    contextId: contextId
    description: 'Cloud target for ARM template infrastructure deployment'
    displayName: 'Cloud Infrastructure Target'
    hierarchyLevel: 'line'
  }
}

output id string = cloudTarget.id
