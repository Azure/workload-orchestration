
var woExtensionTemplate = {
  '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
  contentVersion: '1.0.0.0'
  parameters: {
    clusterName: {
      type: 'string'
    }
    location: {
      type: 'string'
      defaultValue: '[resourceGroup().location]'
    }
  }
  resources: [
    {
      type: 'Microsoft.KubernetesConfiguration/extensions'
      apiVersion: '2023-05-01'
      scope: '[resourceId(\'Microsoft.Kubernetes/connectedClusters\', parameters(\'clusterName\'))]'
      name: 'cert-manager'
      identity: {
        type: 'SystemAssigned'
      }
      properties: {
        extensionType: 'microsoft.certmanagement'
        releaseTrain: 'stable'
        version: '0.13.3'
        autoUpgradeMinorVersion: false
        scope: {
          cluster: {
            releaseNamespace: 'cert-manager'
          }
        }
        configurationSettings: {
          AgentOperationTimeoutInMinutes: '20'
          'global.telemetry.enabled': 'true'
        }
      }
    }
    {
      type: 'Microsoft.KubernetesConfiguration/extensions'
      apiVersion: '2023-05-01'
      scope: '[resourceId(\'Microsoft.Kubernetes/connectedClusters\', parameters(\'clusterName\'))]'
      name: 'wo-extension'
      dependsOn: [
        '[resourceId(\'Microsoft.Kubernetes/connectedClusters/providers/extensions\', parameters(\'clusterName\'), \'Microsoft.KubernetesConfiguration\', \'cert-manager\')]'
      ]
      identity: {
        type: 'SystemAssigned'
      }
      properties: {
        extensionType: 'microsoft.workloadorchestration'
        releaseTrain: 'stable'
        autoUpgradeMinorVersion: false
        configurationSettings: {
          'redis.persistentVolume.storageClass': 'default'
          'redis.persistentVolume.size': '20Gi'
        }
      }
    }
    {
      type: 'Microsoft.ExtendedLocation/customLocations'
      apiVersion: '2021-08-31-preview'
      name: 'woCl'
      location: '[parameters(\'location\')]'
      dependsOn: [
        '[resourceId(\'Microsoft.Kubernetes/connectedClusters/providers/extensions\', parameters(\'clusterName\'), \'Microsoft.KubernetesConfiguration\', \'wo-extension\')]'
      ]
      properties: {
        hostResourceId: '[resourceId(\'Microsoft.Kubernetes/connectedClusters\', parameters(\'clusterName\'))]'
        namespace: 'default'
        displayName: 'wo-cl'
        clusterExtensionIds: [
          '[resourceId(\'Microsoft.Kubernetes/connectedClusters/providers/extensions\', parameters(\'clusterName\'), \'Microsoft.KubernetesConfiguration\', \'wo-extension\')]'
        ]
      }
    }
  ]
}
param contextId string
param target object
param helmChartAcrUri string
param helmVersion string
param acrName string

@onlyIfNotExists()
resource woTemplateSpec 'Microsoft.Resources/templateSpecs@2022-02-01' = {
  name: 'woextspec'
  location: resourceGroup().location
  
  properties: {
    description: 'WO Extension + Custom Location ARM template'
  }
}

   @onlyIfNotExists()
  resource woTemplateSpecVer 'Microsoft.Resources/templateSpecs/versions@2022-02-01' = {
    name: '1.0'
    parent: woTemplateSpec
    location: resourceGroup().location
    properties: {
      mainTemplate: woExtensionTemplate
    }
  }

  @onlyIfNotExists()
resource woExtSolutionTemplate 'Microsoft.Edge/solutionTemplates@2026-03-01' = {
  name: 'woExtensionSolutionTemplate'
  location: resourceGroup().location
  dependsOn: [
    woTemplateSpec
  ]
  properties: {
    description: 'WO extension setup'
    capabilities: [
      target.capability
    ]
  }
}

  @onlyIfNotExists()
  resource v1_0_0_ext 'Microsoft.Edge/solutionTemplates/versions@2026-05-01-preview'  ={
    parent: woExtSolutionTemplate
    name: '1.0.0'
    properties: {
      configurations: {
        configs: {clusterName: target.clusterName}
      }
      specification: {
        components: [
          {
            name: 'wo-ext-st'
            type: 'armtemplate'
            properties: {
              template: {
                name: woTemplateSpec.name
                version: woTemplateSpecVer.name
              }
            }
          }
        ]
      }
    }
  }

resource woExtTarget 'Microsoft.Edge/targets@2026-05-01-preview' ={
  name: 'woExtTarget'
  location: resourceGroup().location
  properties: {
    capabilities: [
      target.capability
    ]
    contextId: contextId
    description: 'Cloud target for ARM template infrastructure deployment'
    displayName: 'Cloud Infrastructure Target'
    hierarchyLevel: 'line'
  }
}

resource woExtDeploy 'Microsoft.Edge/solutionDeployments@2026-05-01-preview' = {
  name: 'woExtDeploy' // deployment name
  location: resourceGroup().location

  properties: {
    solutionTemplateProperties: {
      name: woExtSolutionTemplate.name //Solution template name
      version: v1_0_0_ext.name //solution template version
    }
    targetProperties: {
    targetIds: [
      woExtTarget.id
    ]
  }
}
}
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource cluster 'Microsoft.Kubernetes/connectedClusters@2021-03-01' existing = {
  name: target.clusterName
}
resource woExtension 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' existing = {
  dependsOn: [
    woExtDeploy
  ]
  name: 'wo-extension'
  scope: cluster
}

var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

@onlyIfNotExists()
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, woExtension.id, acrPullRoleDefinitionId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: woExtension.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
@onlyIfNotExists()
resource edgeTarget 'Microsoft.Edge/targets@2026-05-01-preview' ={
  name: target.name
  location: resourceGroup().location
  dependsOn: [
    woExtDeploy
  ]
  extendedLocation: {
    name: '${resourceGroup().id}/providers/Microsoft.ExtendedLocation/customLocations/woCl' 
    type: 'CustomLocation'
  }
  properties: {
    capabilities: [
      target.capability
    ]
    contextId: contextId
    description: 'Edge target for Helm application deployment'
    displayName: 'Edge Application Target'
    hierarchyLevel: 'line'
    solutionScope: target.namespace
    targetSpecification: {
      components: []
      scope: 'default'
      topologies: [
        {
          bindings: [
            {
              config: {
                inCluster: 'true'
              }
              provider: 'providers.target.helm'
              role: 'helm.v3'
            }
          ]
        }
      ]
    }
  }
}

@onlyIfNotExists()
resource mongoDbSolutionTemplate 'Microsoft.Edge/solutionTemplates@2026-03-01' = {
  name: 'mongoDbSetupTemplate'
  location: resourceGroup().location
  dependsOn:[
    edgeTarget
  ]
  properties: {
    description: 'MongoDB'
    capabilities: [
      target.capability
    ]
  }
}

  @onlyIfNotExists()
  resource v1_0_0_mongoDb 'Microsoft.Edge/solutionTemplates/versions@2026-05-01-preview' = {
    parent: mongoDbSolutionTemplate
    name: '1.0.0'
    properties: {
      configurations: {}
      specification: {
        components: [
          {
            name: mongoDbSolutionTemplate.name
            type: 'helm.v3'
            properties: {
              chart: {
                repo: helmChartAcrUri
                version: helmVersion
                wait: true
                timeout: '5m'
              }
            }
          }
        ]
      }
    }
  }



resource mongoDbDeployment 'Microsoft.Edge/solutionDeployments@2026-05-01-preview' =  {
  name: 'mongodb-deployment' // deployment name
  location: resourceGroup().location
  properties: {
    solutionTemplateProperties: {
      name: mongoDbSolutionTemplate.name //Solution template name
      version: v1_0_0_mongoDb.name //solution template version
    }
    targetProperties: {
    targetIds: [
      edgeTarget.id
    ]
  }
}
}

