using './prerequisites.bicep'

// Deploy this file into the resource group containing the Arc-connected cluster.
param location = '<location>'
param connectClusterName = '<arc-connected-cluster-name>'

param contextId = '/subscriptions/<context-subscription-id>/resourceGroups/<context-resource-group>/providers/Microsoft.Edge/contexts/<workload-orchestration-context-name>'

param capabilityNames = [
  '<capability-name>'
]
param targetName = 'foundry-local-target'
param hierarchyLevel = '<context-hierarchy-level>'
param workloadOrchestrationCustomLocationName = '<workload-orchestration-custom-location-name>'
param workloadOrchestrationExtensionName = '<workload-orchestration-extension-name>'

param workloadOrchestrationCustomLocationNamespace = 'workloadorchestration'
param workloadOrchestrationExtensionType = 'microsoft.workloadorchestration'
param workloadOrchestrationReleaseTrain = 'stable'
param workloadOrchestrationExtensionVersion = '2.1.37'
param workloadOrchestrationRedisStorageClass = 'default'
param workloadOrchestrationRedisStorageSize = '5Gi'
