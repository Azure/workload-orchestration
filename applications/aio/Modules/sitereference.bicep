param siteId string
param contextName string
resource context 'Microsoft.Edge/contexts@2026-05-01-preview' existing = {
  name: contextName
}

@onlyIfNotExists()
resource siteReference 'Microsoft.Edge/contexts/siteReferences@2026-05-01-preview' = {
  name: 'aio-site-reference'
  parent: context
  properties: {
    siteId: siteId
  }
}
