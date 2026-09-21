targetScope = 'resourceGroup'

@description('Azure region for the Arc cluster and Workload Orchestration resources.')
param location string

@description('Name of the Arc-connected AKS cluster in the deployment resource group.')
param connectClusterName string

@description('Workload Orchestration context resource ID.')
param contextId string

@description('Capabilities assigned to the Workload Orchestration target.')
param capabilityNames string[] = [
  'foundry-local'
]

@description('Workload Orchestration target name.')
param targetName string = 'foundry-local-target'

@description('Hierarchy level from the Workload Orchestration context used by the target.')
param hierarchyLevel string = 'line'

@description('Workload Orchestration custom location name.')
param workloadOrchestrationCustomLocationName string = 'foundry-local-workload-orchestration-location'

@description('Name of the Workload Orchestration extension installed on the Arc cluster.')
param workloadOrchestrationExtensionName string = 'workloadorchestration-extension'

@description('Namespace registered by the custom location.')
param workloadOrchestrationCustomLocationNamespace string = 'workloadorchestration'

@description('Workload Orchestration extension type.')
param workloadOrchestrationExtensionType string = 'microsoft.workloadorchestration'

@description('Workload Orchestration release train.')
param workloadOrchestrationReleaseTrain string = 'stable'

@description('Workload Orchestration extension version.')
param workloadOrchestrationExtensionVersion string = '2.1.37'

@description('Storage class used by Workload Orchestration Redis.')
param workloadOrchestrationRedisStorageClass string = 'default'

@description('Persistent volume size used by Workload Orchestration Redis.')
param workloadOrchestrationRedisStorageSize string = '5Gi'

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2025-12-01-preview' existing = {
  name: connectClusterName
}

resource certManagerExtension 'Microsoft.KubernetesConfiguration/extensions@2022-03-01' = {
  name: 'cert-manager-extension'
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
    autoUpgradeMinorVersion: false
    releaseTrain: workloadOrchestrationReleaseTrain
    version: workloadOrchestrationExtensionVersion
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

resource foundryTarget 'Microsoft.Edge/targets@2026-05-01-preview' = {
  name: targetName
  location: location
  extendedLocation: {
    name: workloadOrchestrationCustomLocation.id
    type: 'CustomLocation'
  }
  properties: {
    capabilities: capabilityNames
    contextId: contextId
    description: 'Kubernetes target for Foundry Local'
    displayName: 'Foundry Local Target'
    hierarchyLevel: hierarchyLevel
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

output targetId string = foundryTarget.id
output customLocationId string = workloadOrchestrationCustomLocation.id
output workloadOrchestrationExtensionId string = workloadOrchestrationExtension.id
