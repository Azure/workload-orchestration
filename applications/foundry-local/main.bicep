targetScope = 'resourceGroup'

@description('Azure region for Workload Orchestration resources. Defaults to the resource group region; use a region supported by the WO resource provider.')
param location string = resourceGroup().location

@description('Name of the Arc-connected AKS cluster in the deployment resource group.')
@minLength(1)
param connectClusterName string

@description('Existing Workload Orchestration context resource ID. Leave empty to create a dedicated context for this cluster.')
param contextId string = ''

@description('Workload Orchestration target name.')
@minLength(1)
param targetName string = '${connectClusterName}-foundry-local-target'

@description('Existing certificate-management extension name, or the name to create.')
param certManagerExtensionName string = 'cert-manager-extension'

@description('Workload Orchestration custom location name.')
param workloadOrchestrationCustomLocationName string = '${connectClusterName}-wo-cl'

@description('Name of the Workload Orchestration extension installed on the Arc cluster.')
param workloadOrchestrationExtensionName string = 'workloadorchestration-extension'

@description('Namespace registered by the custom location.')
param workloadOrchestrationCustomLocationNamespace string = 'workloadorchestration'

@description('Workload Orchestration extension type.')
param workloadOrchestrationExtensionType string = 'microsoft.workloadorchestration'

@description('Foundry inference operator chart repository.')
param inferenceoperatorChartRepository string = 'mcr.microsoft.com/foundrylocalonazurelocal/helmcharts/helm/inference-operator'

@description('Foundry inference operator chart version.')
param inferenceoperatorChartVersion string = '0.0.1-prp.3'

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

@description('Compute type used by the model deployment.')
@allowed([
  'cpu'
  'gpu'
])
param modelCompute string = 'cpu'

@description('Number of model replicas.')
@minValue(1)
param modelReplicas int = 1

@description('CPU request and limit for each model replica, including GPU models.')
param modelCpu string = '4'

@description('Memory request and limit for each model replica.')
param modelMemory string = '8Gi'

@description('Enable the model endpoint.')
param modelEndpointEnabled bool = false

var workloadOrchestrationReleaseTrain = 'stable'
var workloadOrchestrationRedisStorageClass = 'default'
var workloadOrchestrationRedisStorageSize = '5Gi'

var capabilityNames = [
  'foundry-local'
]

@export()
func mergeCapabilities(existingCapabilities array, requiredNames string[]) array => concat(existingCapabilities, map(filter(union(requiredNames, requiredNames), name => !contains(map(existingCapabilities, capability => capability.name), name)), name => {
  name: name
  description: 'Capability for Foundry Local workloads.'
  state: 'active'
}))

@export()
func resolveHierarchies(existingHierarchies array) array => empty(existingHierarchies) ? [
  {
    name: 'level-1'
    description: 'Foundry Local deployment level.'
  }
] : existingHierarchies

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2025-12-01-preview' existing = {
  name: connectClusterName
}
resource certManagerExtension 'Microsoft.KubernetesConfiguration/extensions@2022-03-01' = {
  name: certManagerExtensionName
  scope: connectedCluster
  properties: {
    extensionType: 'microsoft.certmanagement'
    autoUpgradeMinorVersion: true
    releaseTrain: 'stable'
  }
}
resource workloadOrchestrationExtension 'Microsoft.KubernetesConfiguration/extensions@2022-03-01' = {
  name: workloadOrchestrationExtensionName
  scope: connectedCluster
  dependsOn: [
    certManagerExtension
  ]
  properties: {
    extensionType: workloadOrchestrationExtensionType
    autoUpgradeMinorVersion: true
    releaseTrain: workloadOrchestrationReleaseTrain
    configurationSettings: {
      'redis.persistentVolume.storageClass': workloadOrchestrationRedisStorageClass
      'redis.persistentVolume.size': workloadOrchestrationRedisStorageSize
    }
  }
}

resource workloadOrchestrationCustomLocation 'Microsoft.ExtendedLocation/customLocations@2021-03-15-preview' = {
  name: workloadOrchestrationCustomLocationName
  location: location
  properties: {
    displayName: 'Foundry Local Workload Orchestration'
    hostResourceId: connectedCluster.id
    namespace: workloadOrchestrationCustomLocationNamespace
    clusterExtensionIds: [
      workloadOrchestrationExtension.id
    ]
  }
}

@onlyIfNotExists()
resource managedContext 'Microsoft.Edge/contexts@2025-08-01' = if (empty(contextId)) {
  name: 'foundry-${uniqueString(connectedCluster.id)}'
  location: location
  properties: {
    capabilities: [
      for capabilityName in capabilityNames: {
        name: capabilityName
        description: 'Capability for Foundry Local workloads.'
        state: 'active'
      }
    ]
    hierarchies: resolveHierarchies([])
  }
}

var resolvedContextId = empty(contextId) ? managedContext!.id : contextId

// Read by ID to avoid declaring the Day 0 context twice in the same template.
var selectedContext = reference(resolvedContextId, '2025-08-01', 'Full')

var mergedCapabilities = mergeCapabilities(selectedContext.properties.capabilities, capabilityNames)
var effectiveHierarchies = resolveHierarchies(selectedContext.properties.hierarchies)

// A module snapshots the existing state before updating the context at its own scope.
module contextRegistration './update-context.bicep' = {
  name: '${uniqueString(connectedCluster.id)}-foundry-context'
  scope: resourceGroup(split(resolvedContextId, '/')[2], split(resolvedContextId, '/')[4])
  params: {
    contextName: last(split(resolvedContextId, '/'))
    location: selectedContext.location
    tags: selectedContext.?tags ?? {}
    capabilities: mergedCapabilities
    hierarchies: effectiveHierarchies
    updateRequired: length(mergedCapabilities) > length(selectedContext.properties.capabilities) || empty(selectedContext.properties.hierarchies)
  }
}

var effectiveHierarchyLevel = contextRegistration.outputs.hierarchyLevel

resource foundryTarget 'Microsoft.Edge/targets@2026-05-01-preview' = {
  name: targetName
  location: location
  extendedLocation: {
    name: workloadOrchestrationCustomLocation.id
    type: 'CustomLocation'
  }
  properties: {
    capabilities: capabilityNames
    contextId: resolvedContextId
    description: 'Kubernetes target for Foundry Local'
    displayName: 'Foundry Local Target'
    hierarchyLevel: effectiveHierarchyLevel
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
  dependsOn: [
    foundryTarget
  ]
  properties: {
    description: 'Foundry Local inference operator'
    capabilities: capabilityNames
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
                repo: inferenceoperatorChartRepository
                version: inferenceoperatorChartVersion
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
  dependsOn: [
    foundryTarget
  ]
  properties: {
    description: 'Foundry Local AI model'
    capabilities: capabilityNames
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
            compute: modelCompute
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

output contextResourceId string = resolvedContextId
output hierarchyLevel string = effectiveHierarchyLevel
output targetCapabilities array = capabilityNames
output targetId string = foundryTarget.id
output customLocationId string = workloadOrchestrationCustomLocation.id
output inferenceDeploymentId string = inferenceDeployment.id
output modelDeploymentId string = modelDeployment.id
