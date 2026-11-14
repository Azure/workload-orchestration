using './main.bicep'

// Replace every <...> placeholder with values for your environment before deploying.
// AKS and Arc must exist in the deployment subscription and resource group.
param location = '<location>'
param connectClusterName = '<arc-connected-cluster-name>'
param aksClusterName = '<aks-cluster-name>'

// Use an ACI-supported region for bootstrap.
param bootstrapLocation = '<aci-supported-region>'
param gatewayApiVersion = '1.4.0'
param inferenceExtensionVersion = '1.5.0'
param istioVersion = '1.31.3'
param templateSpecVersion = '1.0.1'
param solutionTemplateVersion = '1.0.1'

// Blank disables Foundry API Entra; enabling it requires an app ID and new package versions.
param entraClientId = ''

// Updating the existing WO context requires context-write permission.
param contextId = '/subscriptions/973d15c6-6c57-447e-b9c6-6d79b5b784ab/resourceGroups/Mehoopany/providers/Microsoft.Edge/contexts/Mehoopany-Context'

// Resolve this exact CPU offering from the installed catalog; an explicit assetId overrides it.
param deployModel = true
param modelDeploymentName = 'foundry-model'
param modelDisplayName = 'Foundry Local Model'
param modelAssetId = ''
param modelCatalogAlias = 'phi-4'
param modelVersion = '2'
param modelRuntime = 'onnx-genai'
param modelCompute = 'cpu'
param modelReplicas = 1
param modelCpu = '2'
param modelMemory = '16Gi'
param modelGpuCount = 0
param modelReadyTimeoutSeconds = 1800
