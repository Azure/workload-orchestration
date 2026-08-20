targetScope = 'resourceGroup'

@description('Azure region for the Arc cluster and Workload Orchestration resources.')
param location string

@description('Name of the Arc-connected AKS cluster in the deployment resource group.')
param clusterName string

@description('Workload Orchestration context resource ID.')
param contextId string

@description('Capability shared by the target and solution templates.')
param capabilityName string = 'foundry-local'

@description('Workload Orchestration target name.')
param targetName string = 'foundry-local-target'

@description('Workload Orchestration custom location name.')
param woCustomLocationName string = 'foundry-local-wo-location'

@description('Name of the Workload Orchestration extension installed on the Arc cluster.')
param woExtensionName string = 'workloadorchestration-extension'

@description('Namespace used by the Workload Orchestration extension.')
param woReleaseNamespace string = 'workloadorchestration'

@description('Namespace registered by the custom location.')
param woCustomLocationNamespace string = 'wo'

@description('Workload Orchestration extension type.')
param woExtensionType string = 'microsoft.workloadorchestration'

@description('Workload Orchestration release train.')
param woReleaseTrain string = 'dev'

@description('Workload Orchestration extension version.')
param woExtensionVersion string = '2.1.40'

@description('Storage class used by Workload Orchestration Redis.')
param woRedisStorageClass string = 'default'

@description('Persistent volume size used by Workload Orchestration Redis.')
param woRedisStorageSize string = '5Gi'

@description('Foundry inference operator chart repository.')
param inferenceChartRepository string = 'mcr.microsoft.com/foundrylocalonazurelocal/helmcharts/helm/inference-operator'

@description('Foundry inference operator chart version.')
param inferenceChartVersion string = '0.0.1-prp.3'

@description('AI model chart repository.')
param modelChartRepository string = 'foundrypoc.azurecr.io/helm/ai-model'

@description('AI model chart version.')
param modelChartVersion string = '0.1.0'

@description('Model deployment name.')
param modelName string = 'phi-4-cpu'

@description('Model display name.')
param modelDisplayName string = 'Phi-4 CPU'

@description('Model catalog name.')
param modelCatalogName string = 'Phi-4-generic-cpu'

@description('Model version.')
param modelVersion string = '1'

@description('Number of model replicas.')
@minValue(1)
param modelReplicas int = 1

@description('CPU request and limit for each model replica.')
param modelCpu string = '4'

@description('Memory request and limit for each model replica.')
param modelMemory string = '8Gi'

@description('Enable the model endpoint.')
param modelEndpointEnabled bool = false

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2025-12-01-preview' existing = {
  name: clusterName
}

resource certManagerExtension 'Microsoft.KubernetesConfiguration/extensions@2022-03-01' = {
  name: 'cert-manager-extension'
  scope: connectedCluster
  properties: {
    extensionType: 'microsoft.certmanagement'
    autoUpgradeMinorVersion: true
    releaseTrain: 'stable'
    version: '0.11.0'
    scope: {
      cluster: {
        releaseNamespace: 'cert-manager'
      }
    }
  }
}

resource workloadOrchestrationExtension 'Microsoft.KubernetesConfiguration/extensions@2022-03-01' = {
  name: woExtensionName
  scope: connectedCluster
  dependsOn: [
    certManagerExtension
  ]
  properties: {
    extensionType: woExtensionType
    autoUpgradeMinorVersion: false
    releaseTrain: woReleaseTrain
    version: woExtensionVersion
    scope: {
      cluster: {
        releaseNamespace: woReleaseNamespace
      }
    }
    configurationSettings: {
      'redis.persistentVolume.storageClass': woRedisStorageClass
      'redis.persistentVolume.size': woRedisStorageSize
    }
  }
}

resource workloadOrchestrationCustomLocation 'Microsoft.ExtendedLocation/customLocations@2021-03-15-preview' = {
  name: woCustomLocationName
  location: location
  properties: {
    displayName: 'Foundry Local Workload Orchestration'
    hostResourceId: connectedCluster.id
    namespace: woCustomLocationNamespace
    clusterExtensionIds: [
      workloadOrchestrationExtension.id
    ]
  }
}

resource foundryTarget 'Microsoft.Edge/targets@2026-05-01-preview' = {
  name: targetName
  location: location
  extendedLocation: {
    name: workloadOrchestrationCustomLocation.id
    type: 'CustomLocation'
  }
  properties: {
    capabilities: [
      capabilityName
    ]
    contextId: contextId
    description: 'Kubernetes target for Foundry Local'
    displayName: 'Foundry Local Target'
    hierarchyLevel: 'line'
    solutionScope: 'foundry-local'
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

resource inferenceTemplate 'Microsoft.Edge/solutiontemplates@2026-05-01-preview' = {
  name: 'foundry-local-inference'
  location: location
  properties: {
    description: 'Foundry Local inference operator'
    capabilities: [
      capabilityName
    ]
  }
  resource version 'versions@2026-05-01-preview' = {
    name: '1.0.0'
    properties: {
      configurations: '{}'
      specification: {
        components: [
          {
            name: 'inference-operator'
            type: 'helm.v3'
            properties: {
              releaseName: 'foundry'
              chart: {
                repo: inferenceChartRepository
                version: inferenceChartVersion
                wait: true
                timeout: '7m'
              }
            }
          }
        ]
      }
    }
  }
}

resource inferenceDeployment 'Microsoft.Edge/solutiondeployments@2026-05-01-preview' = {
  name: 'foundry-inference'
  location: location
  properties: {
    solutionTemplateProperties: {
      name: inferenceTemplate.name
      version: inferenceTemplate::version.name
    }
    targetProperties: {
      targetIds: [
        foundryTarget.id
      ]
    }
  }
}

resource modelTemplate 'Microsoft.Edge/solutiontemplates@2026-05-01-preview' = {
  name: 'foundry-local-model'
  location: location
  properties: {
    description: 'Foundry Local AI model'
    capabilities: [
      capabilityName
    ]
  }

  resource version 'versions@2026-05-01-preview' = {
    name: '1.0.0'
    properties: {
      configurations: string({
        configs: {
          model: {
            name: modelName
            displayName: modelDisplayName
            catalogName: modelCatalogName
            version: modelVersion
            workloadType: 'generative'
            compute: 'cpu'
            replicas: modelReplicas
            resources: {
              requests: {
                cpu: modelCpu
                memory: modelMemory
              }
              limits: {
                cpu: modelCpu
                memory: modelMemory
              }
            }
            endpoint: {
              enabled: modelEndpointEnabled
            }
          }
        }
      })
      specification: {
        components: [
          {
            name: 'ai-model'
            type: 'helm.v3'
            properties: {
              releaseName: 'aifoundry'
              chart: {
                repo: modelChartRepository
                version: modelChartVersion
                wait: true
                timeout: '7m'
              }
            }
          }
        ]
      }
    }
  }
}

resource modelDeployment 'Microsoft.Edge/solutiondeployments@2026-05-01-preview' = {
  name: 'foundry-model'
  location: location
  dependsOn: [
    inferenceDeployment
  ]
  properties: {
    solutionTemplateProperties: {
      name: modelTemplate.name
      version: modelTemplate::version.name
    }
    targetProperties: {
      targetIds: [
        foundryTarget.id
      ]
    }
  }
}

output targetId string = foundryTarget.id
output customLocationId string = workloadOrchestrationCustomLocation.id
output inferenceDeploymentId string = inferenceDeployment.id
output modelDeploymentId string = modelDeployment.id
