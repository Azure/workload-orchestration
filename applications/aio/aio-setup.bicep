param targets object[]
param location string
param opEnablementSolutionTemplate object
param opInstanceSolutionTemplate object
param targetConfigTemplate string
param contextId string


// ============================================================
// Cloud Target - for ARM template deployments (no custom location)
// ============================================================

@onlyIfNotExists()
resource aioOpSpec 'Microsoft.Resources/templateSpecs@2022-02-01' = {
  name: 'aio-op-spec'
  location: location
  properties: {
    description: 'Template spec'
  }

   @onlyIfNotExists()
  resource aioOpSpecVersion 'versions@2022-02-01' = {
    name: '1.0'
    location: location
    properties: {
      mainTemplate: loadJsonContent('./AioOnboardingTemplates/azure-iot-operations-enablement.json')
    }
  }
}

@onlyIfNotExists()
resource aioOpInstanceSpec 'Microsoft.Resources/templateSpecs@2022-02-01' = {
  name: 'aio-op-instance-spec'
  location: location
  properties: {
    description: 'Template spec'
  }

   @onlyIfNotExists()
  resource aioOpInstanceSpecVersion 'versions@2022-02-01' = {
    name: '1.0'
    location: location
    properties: {
      mainTemplate: loadJsonContent('./AioOnboardingTemplates/azure-iot-operations-instance.json')
    }
  }
}

// ============================================================
// Cloud Target - for ARM template deployments (no custom location)
// ============================================================
resource cloudTargets 'Microsoft.Edge/targets@2026-05-01-preview' = [ for target in targets: {
  name: target.name
  location: location
  properties: {
    capabilities: [
      target.capability
    ]
    contextId: contextId
    description: 'Cloud target for ARM template infrastructure deployment'
    displayName: 'Cloud Infrastructure Target'
    hierarchyLevel: 'line'
  }
}]

@onlyIfNotExists()
resource configTemplate 'Microsoft.Edge/configTemplates@2026-05-01-preview' = {
  name: 'cloud-target-config'
  location: location
  dependsOn:[cloudTargets]
  properties: {
   description: 'Configuration template for cloud target'
  }

  @onlyIfNotExists()
  resource configTemplateVersion 'versions@2026-05-01-preview' = {
    name: '1.0.0'
    properties: {
      configurations: targetConfigTemplate
    }
  }

  resource configTemplateMetadata 'configTemplateMetadatas@2026-05-01-preview' = {
    name: 'config-metadata'
    properties: {
      templateUniqueIdentifier: configTemplate.properties.uniqueIdentifier
      linkedHierarchies: [
        {
          level: 'line'
          hierarchyIds: [for (target, i) in targets: cloudTargets[i].id]
        }
      ]
      contextId: contextId
    }
  }
}

module dynamicConfigModule './Modules/cloud-target-dc.bicep' = [for (target, i) in targets: {
  name: 'cloud-target-dynamic-config${i}'
  dependsOn: [
    configTemplate
  ]
  params: {
    configResourceName: cloudTargets[i].name
    stUniqueIdentifier: configTemplate.properties.uniqueIdentifier
    targetConfiguration: target.configuration
  }
}
]

  @onlyIfNotExists()
resource opEnablement 'Microsoft.Edge/solutionTemplates@2026-05-01-preview' = {
  name: opEnablementSolutionTemplate.name
  location: location
  dependsOn: [
    configTemplate
  ]
  properties: {
    description: 'Infrastructure deployment - Connected Cluster + WO Extension + Custom Location'
    capabilities: [
      opEnablementSolutionTemplate.capability
    ]
  }

 
}

 @onlyIfNotExists()
  resource v1_0_0_op 'Microsoft.Edge/solutionTemplates/versions@2026-05-01-preview'  = {
    name: opEnablementSolutionTemplate.version
    parent: opEnablement
    properties: {
      configurations: {
        configs: opEnablementSolutionTemplate.configuration
      }
      specification: {
        components: [
          {
            name: opEnablementSolutionTemplate.name
            type: 'armtemplate'
            properties: {
              template: {
                name: aioOpSpec.name
                version: aioOpSpec::aioOpSpecVersion.name
              }
            }
          }
        ]
      }
    }
  }
@onlyIfNotExists()
resource opInstance 'Microsoft.Edge/solutionTemplates@2026-05-01-preview' = {
  name: opInstanceSolutionTemplate.name
  location: location
  dependsOn: [
    configTemplate
  ]
  properties: {
    description: 'Infrastructure deployment - Connected Cluster + WO Extension + Custom Location'
    capabilities: [
      opInstanceSolutionTemplate.capability
    ]
  }

}


  @onlyIfNotExists()
  resource v1_0_0_instance 'Microsoft.Edge/solutionTemplates/versions@2026-05-01-preview'  ={
    parent: opInstance
    name: opInstanceSolutionTemplate.version
    properties: {
      configurations: {
        configs: opInstanceSolutionTemplate.configuration
      }
      specification: {
        components: [
          {
            name: opInstanceSolutionTemplate.name
            type: 'armtemplate'
            properties: {
              template: {
                name: aioOpInstanceSpec.name
                version: aioOpInstanceSpec::aioOpInstanceSpecVersion.name
              }
            }
          }
        ]
      }
    }
  }


resource opEnablementDeployment 'Microsoft.Edge/solutionDeployments@2026-05-01-preview' = {
  name: opEnablementSolutionTemplate.name // deployment name
  location: location
  dependsOn: [
    cloudTargets
    v1_0_0_op
    v1_0_0_instance
    dynamicConfigModule
  ]
  properties: {
    solutionTemplateProperties: {
      name: opEnablementSolutionTemplate.name //Solution template name
      version: opEnablementSolutionTemplate.version //solution template version
    }
    targetProperties: {
    targetIds: [
      for (target, i) in targets: cloudTargets[i].id
    ]
  }
}
}

resource opInstanceDeployment 'Microsoft.Edge/solutionDeployments@2026-05-01-preview' = {
  name: opInstanceSolutionTemplate.name // deployment name
  location: location
  dependsOn: [
    opEnablementDeployment
  ]
  properties: {
    solutionTemplateProperties: {
      name: opInstanceSolutionTemplate.name //Solution template name
      version: opInstanceSolutionTemplate.version //solution template version 
    }
    targetProperties: {
    targetIds: [
      for (target, i) in targets: cloudTargets[i].id
    ]
  }
}
}

