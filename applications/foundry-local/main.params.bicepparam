using './main.bicep'

// Deploy this file into the resource group containing the Arc-connected cluster.
param location = '<location>'
param connectClusterName = '<arc-connected-cluster-name>'

param contextId = '/subscriptions/<context-subscription-id>/resourceGroups/<context-resource-group>/providers/Microsoft.Edge/contexts/<workload-orchestration-context-name>'

param capabilityNames = [
  '<capability-name>'
]
param targetName = 'foundry-local-target'
param workloadOrchestrationCustomLocationName = '<workload-orchestration-custom-location-name>'
param workloadOrchestrationExtensionName = '<workload-orchestration-extension-name>'

param workloadOrchestrationCustomLocationNamespace = 'workloadorchestration'
param workloadOrchestrationExtensionType = 'microsoft.workloadorchestration'
param workloadOrchestrationReleaseTrain = 'stable'
param workloadOrchestrationExtensionVersion = '2.1.43'
param workloadOrchestrationRedisStorageClass = 'default'
param workloadOrchestrationRedisStorageSize = '5Gi'

param inferenceoperatorChartRepository = 'mcr.microsoft.com/foundrylocalonazurelocal/helmcharts/helm/inference-operator'
param inferenceoperatorChartVersion = '0.0.1-prp.3'

param modelChartRepository = 'foundrypoc.azurecr.io/helm/ai-model'
param modelChartVersion = '0.1.0'
param modelName = 'phi-4-cpu'
param modelDisplayName = 'Phi-4 CPU'
param modelCatalogName = 'Phi-4-generic-cpu'
param modelVersion = '2'
param modelCompute = 'cpu'
param modelReplicas = 1
param modelCpu = '2'
param modelMemory = '8Gi'
param modelEndpointEnabled = false
