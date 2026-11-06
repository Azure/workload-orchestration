using './main.bicep'

// AKS and Arc must exist in the deployment subscription and resource group.
param location = 'eastus2euap'
param connectClusterName = 'BVT-Test-Cluster-foundry'
param aksClusterName = 'BVT-Test-Cluster'

// Use an ACI-supported region for bootstrap.
param bootstrapLocation = 'eastus2'
param gatewayApiVersion = '1.4.0'
param inferenceExtensionVersion = '1.5.0'
param istioVersion = '1.31.3'

// Blank disables Foundry API Entra; enabling it requires an app ID and new package versions.
param entraClientId = ''

// Updating this shared context requires context-write permission.
param contextId = '/subscriptions/973d15c6-6c57-447e-b9c6-6d79b5b784ab/resourceGroups/Mehoopany/providers/Microsoft.Edge/contexts/Mehoopany-Context'
