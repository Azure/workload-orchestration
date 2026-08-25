using './main.bicep'

// Deploy this file into the resource group containing the Arc-connected cluster.
param location = '<location>'
param clusterName = '<arc-connected-cluster-name>'

param contextId = '/subscriptions/<context-subscription-id>/resourceGroups/<context-resource-group>/providers/Microsoft.Edge/contexts/<workload-orchestration-context-name>'

param capabilityName = '<capability-name>'
param targetName = 'foundry-local-target'
param woCustomLocationName = '<workload-orchestration-custom-location-name>'
param woExtensionName = '<workload-orchestration-extension-name>'

param woCustomLocationNamespace = '<custom-location-namespace>'
param woExtensionType = 'microsoft.workloadorchestration'
param woReleaseTrain = 'dev'
param woExtensionVersion = '2.1.43'
param woRedisStorageClass = 'default'
param woRedisStorageSize = '5Gi'

param inferenceChartRepository = 'mcr.microsoft.com/foundrylocalonazurelocal/helmcharts/helm/inference-operator'
param inferenceChartVersion = '0.0.1-prp.3'

param modelChartRepository = 'foundrypoc.azurecr.io/helm/ai-model'
param modelChartVersion = '0.1.0'
param modelName = 'phi-4-cpu'
param modelDisplayName = 'Phi-4 CPU'
param modelCatalogName = 'Phi-4-generic-cpu'
param modelVersion = '1'
param modelReplicas = 1
param modelCpu = '2'
param modelMemory = '8Gi'
param modelEndpointEnabled = false
