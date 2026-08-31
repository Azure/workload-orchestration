using 'mongodb-setup.bicep'


param contextId = '<contextId>' // Context ID for the deployment (must already exist)
param target = {
    name: '<targetname>'
    namespace: '<namespace>' // namespace where the MongoDB Helm chart will be deployed in k8s cluster
    capability: '<capability>'
    clusterName: '<arc enable cluster name>'
  }

param acrName = '<acrname>' // Name of the Azure Container Registry (ACR) where the Helm chart is stored
param helmChartAcrUri= '<acrname>.azurecr.io/helm/mongodb-community'
param helmVersion= '0.1.0'
