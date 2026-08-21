// ============================================================
// Inner module called by cloud-target.bicep.
//
// Creates the DynamicConfiguration parent under configResource.
//
// Why this is a module rather than an inline resource in cloud-target.bicep:
// the dynamicConfigurations name segment is
//   configTemplate.properties.uniqueIdentifier
// (a GUID minted by the RP at create time). Bicep's static-name analyzer
// requires resource `name` fields to be computable at template-start time and
// rejects expressions that need reference() to resolve. Passing the uid as a
// module parameter makes it opaque to this module's static-name analyzer,
// which compiles cleanly. ARM evaluates the outer
//   configTemplate.properties.uniqueIdentifier
// at deployment time (via reference()) just before invoking this nested
// deployment.
// ============================================================

@description('Microsoft.Edge/configurations resource name (parent of dynamicConfigurations)')
param configResourceName string

@description('configTemplate properties.uniqueIdentifier (GUID) - dynamicConfigurations name segment')
param stUniqueIdentifier string

@description('Target configuration content as a YAML string (pass via loadTextContent in .bicepparam)')
param targetConfiguration string

// ============================================================
// DynamicConfiguration parent (singleton per (configResource, configTemplate) pair).
//
// `properties.currentVersion` is REQUIRED and must be a QUOTED-NUMERIC STRING
// like '1'. The RP validator rejects bare ints (1) and SemVer strings ('1.0.0').
// ============================================================
resource dynamicConfig 'Microsoft.Edge/configurations/dynamicConfigurations@2026-05-01-preview' = {
  name: '${configResourceName}/${stUniqueIdentifier}'
  properties: {
    currentVersion: '1'
  }
  resource targetLevelDcv 'versions@2026-05-01-preview' = {
  name: '1.0.0'
  properties: {
    values: targetConfiguration
  }
}
}
