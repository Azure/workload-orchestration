using './main.bicep'

// Deploy after prerequisites.bicep and Initialize-CloudCasaPrerequisites.ps1.
param location = '<location>'

param capabilityNames = [
  'cloudcasa'
]
param targetName = 'cloudcasa-target'

param chartRepository = 'oci://<customer-acr-login-server>/helm/cloudcasa-server'
param chartVersion = '<cloudcasa-wrapper-chart-version>'
param releaseName = 'cloudcasa-server'
param solutionTemplateName = 'cloudcasa-server'
param solutionTemplateVersion = '<immutable-solution-template-version>'
param solutionDeploymentName = 'cloudcasa-server'
param chartTimeout = '30m'

param imagePullSecretName = 'myregistrykey'
param storageClassName = '<dynamic-storage-class>'
param cloudCasaFqdn = '<cloudcasa-fqdn>'
param serviceType = 'LoadBalancer'
param loadBalancerIdleTimeoutMinutes = 100
param loadBalancerDnsLabelName = ''

param certificateIssuerName = '<issuer-name>'
param certificateIssuerType = 'Issuer'

param mongoNamespace = 'cloudcasa-mongo'
param mongoStorageSize = '16Gi'
param logsStorageSize = '4Gi'

param allowedUsers = [
  '<cloudcasa-admin-email>'
]
param allowedUserGroups = []
param siteAdminUsers = [
  '<cloudcasa-admin-email>'
]
param siteAdminUserGroups = []

param localAuthenticationEnabled = false
param localAuthenticationSecretName = 'cloudcasa-local-auth'
