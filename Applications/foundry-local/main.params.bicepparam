using './main.bicep'

// Deploy this file into the resource group containing the Arc-connected cluster.
param location = 'eastus2euap'
param clusterName = 'akg-test-Cluster'

param contextId = '/subscriptions/973d15c6-6c57-447e-b9c6-6d79b5b784ab/resourceGroups/Mehoopany/providers/Microsoft.Edge/contexts/Mehoopany-Context'

param capabilityName = 'bugbash-akg-App'
param targetName = 'foundry-local-target'
param woCustomLocationName = 'akg-test-Location'
param woExtensionName = 'woextension'

param woReleaseNamespace = 'workloadorchestration'
param woCustomLocationNamespace = 'cloudtestsite'
param woExtensionType = 'microsoft.workloadorchestration'
param woReleaseTrain = 'dev'
param woExtensionVersion = '2.1.40'
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
