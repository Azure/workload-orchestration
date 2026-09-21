using './main.bicep'

// Deploy after prerequisites.bicep and the admission-policy compatibility step.
param location = '<location>'

param capabilityNames = [
  '<capability-name>'
]
param targetName = 'foundry-local-target'

param inferenceoperatorChartRepository = 'mcr.microsoft.com/foundrylocalonazurelocal/helmcharts/helm/inference-operator'
param inferenceoperatorChartVersion = '0.0.1-prp.3'
param inferenceTemplateName = 'foundry-local-inference'
param inferenceTemplateVersion = '1.0.0'
param inferenceDeploymentName = 'foundry-inference'

param modelChartRepository = 'foundrypoc.azurecr.io/helm/ai-model'
param modelChartVersion = '0.1.0'
param modelTemplateName = 'foundry-local-model'
param modelTemplateVersion = '1.0.0'
param modelDeploymentName = 'foundry-model'
param modelName = 'phi-4-cpu'
param modelDisplayName = 'Phi-4 CPU'
param modelCatalogName = 'Phi-4-generic-cpu'
param modelVersion = '2'
param modelCompute = 'cpu'
param modelReplicas = 1
param modelCpu = '8'
param modelMemory = '24Gi'
param modelEndpointEnabled = false
