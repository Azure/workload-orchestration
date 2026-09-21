targetScope = 'resourceGroup'

@description('Azure region for the Arc cluster and Workload Orchestration resources.')
param location string

@description('Capabilities shared by the target and solution templates.')
param capabilityNames string[] = [
  'foundry-local'
]

@description('Name of the existing Workload Orchestration target.')
param targetName string = 'foundry-local-target'

@description('Foundry inference operator chart repository.')
param inferenceoperatorChartRepository string = 'mcr.microsoft.com/foundrylocalonazurelocal/helmcharts/helm/inference-operator'

@description('Foundry inference operator chart version.')
param inferenceoperatorChartVersion string = '0.0.1-prp.3'

@description('Foundry inference operator solution template name.')
param inferenceTemplateName string = 'foundry-local-inference'

@description('Foundry inference operator solution template version.')
param inferenceTemplateVersion string = '1.0.0'

@description('Foundry inference operator solution deployment name.')
param inferenceDeploymentName string = 'foundry-inference'

@description('AI model chart repository.')
param modelChartRepository string = 'foundrypoc.azurecr.io/helm/ai-model'

@description('AI model chart version.')
param modelChartVersion string = '0.1.0'

@description('Foundry model solution template name.')
param modelTemplateName string = 'foundry-local-model'

@description('Foundry model solution template version.')
param modelTemplateVersion string = '1.0.0'

@description('Foundry model solution deployment name.')
param modelDeploymentName string = 'foundry-model'

@description('Model deployment name.')
param modelName string = 'phi-4-cpu'

@description('Model display name.')
param modelDisplayName string = 'Phi-4 CPU'

@description('Model catalog name.')
param modelCatalogName string = 'Phi-4-generic-cpu'

@description('Model version.')
param modelVersion string = '1'

@description('Compute type used by the model deployment. Set to gpu when using a GPU-capable model and cluster.')
@allowed([
  'cpu'
  'gpu'
])
param modelCompute string = 'cpu'

@description('Number of model replicas.')
@minValue(1)
param modelReplicas int = 1

@description('CPU request and limit for each model replica, including GPU models.')
param modelCpu string = '8'

@description('Memory request and limit for each model replica.')
param modelMemory string = '24Gi'

@description('Enable the model endpoint.')
param modelEndpointEnabled bool = false

resource foundryTarget 'Microsoft.Edge/targets@2026-05-01-preview' existing = {
  name: targetName
}

@onlyIfNotExists()
resource inferenceTemplate 'Microsoft.Edge/solutiontemplates@2026-05-01-preview' = {
  name: inferenceTemplateName
  location: location
  properties: {
    description: 'Foundry Local inference operator'
    capabilities: capabilityNames
  }
  @onlyIfNotExists()
  resource version 'versions@2026-05-01-preview' = {
    name: inferenceTemplateVersion
    properties: {
      configurations: '{}'
      specification: {
        components: [
          {
            name: 'inference-operator'
            type: 'helm.v3'
            properties: {
              releaseName: 'foundry'
              chart: {
                repo: inferenceoperatorChartRepository
                version: inferenceoperatorChartVersion
                wait: true
                timeout: '15m'
              }
            }
          }
        ]
      }
    }
  }
}

resource inferenceDeployment 'Microsoft.Edge/solutiondeployments@2026-05-01-preview' = {
  name: inferenceDeploymentName
  location: location
  properties: {
    solutionTemplateProperties: {
      name: inferenceTemplate.name
      version: inferenceTemplate::version.name
    }
    targetProperties: {
      targetIds: [
        foundryTarget.id
      ]
    }
  }
}

@onlyIfNotExists()
resource modelTemplate 'Microsoft.Edge/solutiontemplates@2026-05-01-preview' = {
  name: modelTemplateName
  location: location
  properties: {
    description: 'Foundry Local AI model'
    capabilities: capabilityNames
  }
  @onlyIfNotExists()
  resource version 'versions@2026-05-01-preview' = {
    name: modelTemplateVersion
    properties: {
      configurations: string({
        configs: {
          model: {
            name: modelName
            displayName: modelDisplayName
            catalogName: modelCatalogName
            version: modelVersion
            workloadType: 'generative'
            compute: modelCompute
            replicas: modelReplicas
            resources: {
              requests: {
                cpu: modelCpu
                memory: modelMemory
              }
              limits: {
                cpu: modelCpu
                memory: modelMemory
              }
            }
            endpoint: {
              enabled: modelEndpointEnabled
            }
          }
        }
      })
      specification: {
        components: [
          {
            name: 'ai-model'
            type: 'helm.v3'
            properties: {
              releaseName: 'aifoundry'
              chart: {
                repo: modelChartRepository
                version: modelChartVersion
                wait: true
                timeout: '20m'
              }
            }
          }
        ]
      }
    }
  }
}

resource modelDeployment 'Microsoft.Edge/solutiondeployments@2026-05-01-preview' = {
  name: modelDeploymentName
  location: location
  dependsOn: [
    inferenceDeployment
  ]
  properties: {
    solutionTemplateProperties: {
      name: modelTemplate.name
      version: modelTemplate::version.name
    }
    targetProperties: {
      targetIds: [
        foundryTarget.id
      ]
    }
  }
}

output inferenceDeploymentId string = inferenceDeployment.id
output modelDeploymentId string = modelDeployment.id
