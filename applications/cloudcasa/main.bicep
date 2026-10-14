targetScope = 'resourceGroup'

@description('Azure region for the Workload Orchestration resources.')
param location string

@description('Capabilities shared by the target and CloudCasa solution template.')
param capabilityNames string[] = [
  'cloudcasa'
]

@description('Name of the existing Workload Orchestration target.')
param targetName string = 'cloudcasa-target'

@description('CloudCasa wrapper Helm chart OCI repository.')
param chartRepository string

@description('CloudCasa wrapper Helm chart version.')
param chartVersion string

@description('CloudCasa Helm release name.')
param releaseName string = 'cloudcasa-server'

@description('CloudCasa solution template name.')
param solutionTemplateName string = 'cloudcasa-server'

@description('Immutable CloudCasa solution template version.')
param solutionTemplateVersion string

@description('CloudCasa solution deployment name.')
param solutionDeploymentName string = 'cloudcasa-server'

@description('Helm deployment timeout.')
param chartTimeout string = '30m'

@description('Kubernetes image-pull Secret containing CloudCasa vendor registry credentials.')
param imagePullSecretName string = 'myregistrykey'

@description('Dynamic Kubernetes storage class used by CloudCasa.')
param storageClassName string

@description('Public DNS name for the CloudCasa Envoy endpoint.')
param cloudCasaFqdn string

@description('Kubernetes Service type used for the CloudCasa endpoint.')
@allowed([
  'LoadBalancer'
  'NodePort'
  'ClusterIP'
])
param serviceType string = 'LoadBalancer'

@description('Azure Load Balancer idle timeout in minutes.')
@minValue(4)
@maxValue(100)
param loadBalancerIdleTimeoutMinutes int = 100

@description('Optional Azure public IP DNS label for a LoadBalancer service.')
param loadBalancerDnsLabelName string = ''

@description('cert-manager Issuer or ClusterIssuer name.')
param certificateIssuerName string

@description('cert-manager issuer type.')
@allowed([
  'Issuer'
  'ClusterIssuer'
])
param certificateIssuerType string = 'Issuer'

@description('Namespace containing the bundled MongoDB StatefulSet.')
param mongoNamespace string = 'cloudcasa-mongo'

@description('Persistent volume size for the bundled MongoDB catalog.')
param mongoStorageSize string = '16Gi'

@description('Persistent volume size for CloudCasa logs and bundled MinIO.')
param logsStorageSize string = '4Gi'

@description('Email addresses allowed to sign in.')
param allowedUsers string[] = []

@description('Identity-provider groups allowed to sign in.')
param allowedUserGroups string[] = []

@description('Email addresses granted CloudCasa site administrator access.')
param siteAdminUsers string[] = []

@description('Identity-provider groups granted CloudCasa site administrator access.')
param siteAdminUserGroups string[] = []

@description('Enable local authentication for controlled proof-of-concept deployments.')
param localAuthenticationEnabled bool = false

@description('Existing Secret containing username, email, and password for local authentication.')
param localAuthenticationSecretName string = 'cloudcasa-local-auth'

var solutionTemplateInputFingerprint = uniqueString(string({
  capabilities: capabilityNames
  chart: {
    repository: chartRepository
    version: chartVersion
    releaseName: releaseName
    timeout: chartTimeout
  }
  configuration: {
    imagePullSecretName: imagePullSecretName
    storageClassName: storageClassName
    cloudCasaFqdn: cloudCasaFqdn
    serviceType: serviceType
    loadBalancerIdleTimeoutMinutes: loadBalancerIdleTimeoutMinutes
    loadBalancerDnsLabelName: loadBalancerDnsLabelName
    certificateIssuerName: certificateIssuerName
    certificateIssuerType: certificateIssuerType
    mongoNamespace: mongoNamespace
    mongoStorageSize: mongoStorageSize
    logsStorageSize: logsStorageSize
    allowedUsers: allowedUsers
    allowedUserGroups: allowedUserGroups
    siteAdminUsers: siteAdminUsers
    siteAdminUserGroups: siteAdminUserGroups
    localAuthenticationEnabled: localAuthenticationEnabled
    localAuthenticationSecretName: localAuthenticationSecretName
  }
}))

resource cloudCasaTarget 'Microsoft.Edge/targets@2026-05-01-preview' existing = {
  name: targetName
}

resource cloudCasaTemplate 'Microsoft.Edge/solutiontemplates@2026-05-01-preview' existing = {
  name: solutionTemplateName
}

resource cloudCasaTemplateVersion 'Microsoft.Edge/solutiontemplates/versions@2026-05-01-preview' existing = {
  parent: cloudCasaTemplate
  name: solutionTemplateVersion
}

resource cloudCasaDeployment 'Microsoft.Edge/solutiondeployments@2026-05-01-preview' = {
  name: solutionDeploymentName
  location: location
  properties: {
    solutionTemplateProperties: {
      name: cloudCasaTemplate.name
      version: cloudCasaTemplateVersion.name
    }
    targetProperties: {
      targetIds: [
        cloudCasaTarget.id
      ]
    }
  }
}

output solutionTemplateId string = cloudCasaTemplate.id
output solutionTemplateVersionId string = cloudCasaTemplateVersion.id
output solutionDeploymentId string = cloudCasaDeployment.id
output solutionTemplateInputFingerprint string = solutionTemplateInputFingerprint
