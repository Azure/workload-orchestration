using './prerequisites.bicep'

// Deploy this file into the resource group containing the Arc-connected cluster.
param location = '<location>'
param connectedClusterName = '<arc-connected-cluster-name>'

param contextId = '/subscriptions/<context-subscription-id>/resourceGroups/<context-resource-group>/providers/Microsoft.Edge/contexts/<workload-orchestration-context-name>'

param capabilityNames = [
  'cloudcasa'
]
param targetName = 'cloudcasa-target'
param hierarchyLevel = '<context-hierarchy-level>'

param workloadOrchestrationCustomLocationName = 'cloudcasa-workload-orchestration-location'
param certManagerExtensionName = 'cert-manager-extension'
param workloadOrchestrationExtensionName = 'cloudcasa-workload-orchestration-extension'
param workloadOrchestrationCustomLocationNamespace = 'workloadorchestrationresources'
param workloadOrchestrationExtensionType = 'microsoft.workloadorchestration'
param workloadOrchestrationReleaseTrain = 'stable'
param workloadOrchestrationExtensionVersion = '2.1.46'
param workloadOrchestrationRedisStorageClass = 'default'
param workloadOrchestrationRedisStorageSize = '5Gi'
