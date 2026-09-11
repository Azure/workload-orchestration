param targets object[]
param opEnablementSolutionTemplate object
param opInstanceSolutionTemplate object
param targetConfigTemplate string
param contextId string
param capability string


// ============================================================
// Cloud Target - for ARM template deployments (no custom location)
// ============================================================


param addresses_SiteAddress_name string = 'SiteAddress'

@onlyIfNotExists()
resource addresses_SiteAddress_name_resource 'Microsoft.EdgeOrder/addresses@2024-02-01' = {
  name: addresses_SiteAddress_name
  location: 'eastus'
  properties: {
    addressClassification: 'Shipping'
    shippingAddress: {
      streetAddress1: '1'
      streetAddress2: 'First Lane'
      city: 'CloudTestSite'
      country: 'US'
      companyName: 'Contoso'
      addressType: 'None'
    }
    contactDetails: {
      contactName: 'Persona'
      phone: '0000000000'
      emailList: [
        'noreply@contoso.com'
      ]
    }
  }
}

@onlyIfNotExists()
resource site 'Microsoft.Edge/sites@2024-02-01-preview' = {
  name: 'aiosite'
  properties: {
    addressResourceId: addresses_SiteAddress_name_resource.id
    description: 'aio site'
    displayName: 'aio Site'
  }
}

var splt = split(contextId, '/')
var ctxRg = splt[4]
var ctxName = splt[8]
module siteReference './Modules/sitereference.bicep' = {
  name: 'aio-site-reference'
  scope: resourceGroup(ctxRg)
  params: {
    siteId: site.id
    contextName: ctxName
  }
}


@onlyIfNotExists()
resource aioOpSpec 'Microsoft.Resources/templateSpecs@2022-02-01' = {
  name: 'aio-op-spec'
  location: resourceGroup().location
  properties: {
    description: 'Template spec'
  }
}

@onlyIfNotExists()
  resource aioOpSpecVersion 'Microsoft.Resources/templateSpecs/versions@2022-02-01' = {
    name: '1.0'
    parent: aioOpSpec
    location: resourceGroup().location
    properties: {
      mainTemplate: loadJsonContent('./AioOnboardingTemplates/azure-iot-operations-enablement.json')
    }
  }

@onlyIfNotExists()
resource aioOpInstanceSpec 'Microsoft.Resources/templateSpecs@2022-02-01' = {
  name: 'aio-op-instance-spec'
  location: resourceGroup().location
  properties: {
    description: 'Template spec'
  }
}

@onlyIfNotExists()
  resource aioOpInstanceSpecVersion 'Microsoft.Resources/templateSpecs/versions@2022-02-01' = {
    parent: aioOpInstanceSpec
    name: '1.0'
    location: resourceGroup().location
    properties: {
      mainTemplate: loadJsonContent('./AioOnboardingTemplates/azure-iot-operations-instance.json')
    }
  }

// ============================================================
// Cloud Target - for ARM template deployments (no custom location)
// ============================================================
module cloudTargets './Modules/target.bicep' = [for (target, i) in targets: {
  name: target.name
  scope: resourceGroup(target.resourceGroupName)
  dependsOn: [
    siteReference
  ]
  params: {
    contextId: contextId
    capability: capability
    name: target.name
    location: target.location
  }
}
]

@onlyIfNotExists()
resource configTemplate 'Microsoft.Edge/configTemplates@2026-05-01-preview' = {
  name: 'cloud-target-config'
  location: resourceGroup().location
  dependsOn:[cloudTargets]
  properties: {
   description: 'Configuration template for cloud target'
  }
}

resource configTemplateMetadata 'Microsoft.Edge/configTemplates/configTemplateMetadatas@2026-05-01-preview' = {
    parent: configTemplate
    name: 'config-metadata'
    properties: {
      templateUniqueIdentifier: configTemplate.properties.uniqueIdentifier
      linkedHierarchies: [
        {
          level: 'line'
          hierarchyIds: [for (target, i) in targets: cloudTargets[i].outputs.id]
        }
      ]
      contextId: contextId
    }
}


@onlyIfNotExists()
  resource configTemplateVersion 'Microsoft.Edge/configTemplates/versions@2026-05-01-preview' = {
    parent: configTemplate
    name: '1.0.0'
    properties: {
      configurations: targetConfigTemplate
    }
  }
module dynamicConfigModule './Modules/cloud-target-dc.bicep' = [for (target, i) in targets: {
  name: 'cloud-target-dynamic-config${i}'
  dependsOn: [
    configTemplateVersion
    configTemplateMetadata
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
  location: resourceGroup().location
  properties: {
    description: 'Infrastructure deployment - Connected Cluster + WO Extension + Custom Location'
    capabilities: [
      capability
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
                version: aioOpSpecVersion.name
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
  location: resourceGroup().location
  dependsOn: [
    configTemplate
  ]
  properties: {
    description: 'Infrastructure deployment - Connected Cluster + WO Extension + Custom Location'
    capabilities: [
      capability
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
                version: aioOpInstanceSpecVersion.name
              }
            }
          }
        ]
      }
    }
  }


resource opEnablementDeployment 'Microsoft.Edge/solutionDeployments@2026-05-01-preview' = {
  name: opEnablementSolutionTemplate.name // deployment name
  location: resourceGroup().location
  dependsOn: [
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
      for (target, i) in targets: cloudTargets[i].outputs.id
    ]
  }
}
}

resource opInstanceDeployment 'Microsoft.Edge/solutionDeployments@2026-05-01-preview' = {
  name: opInstanceSolutionTemplate.name // deployment name
  location: resourceGroup().location
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
      for (target, i) in targets: cloudTargets[i].outputs.id
    ]
  }
}
}

