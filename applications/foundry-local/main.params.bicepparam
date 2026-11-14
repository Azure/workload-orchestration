using './main.bicep'

// Deploy into the resource group containing this Arc-connected cluster.
// Set location as well if the resource group region is not the intended WO region.
param connectClusterName = '<arc-connected-cluster-name>'

// Leave empty to create a dedicated context, or set an existing context resource ID.
param contextId = ''

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
