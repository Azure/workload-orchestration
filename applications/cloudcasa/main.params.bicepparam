using './main.bicep'

param location = '<cluster-region>'
param connectClusterName = '<arc-connected-cluster-name>'

// Set an existing context resource ID when one is available.
// Leave empty to create a context in the deployment resource group.
param contextId = ''

param workloadIdentityIssuerUrl = '<kubernetes-oidc-issuer-url>'

param acrName = '<acr-name>'
param storageClassName = 'default'

param vendorRegistryUsername = readEnvironmentVariable('CLOUDCASA_REGISTRY_USERNAME')
param vendorRegistryPassword = readEnvironmentVariable('CLOUDCASA_REGISTRY_PASSWORD')
param licenseContent = readEnvironmentVariable('CLOUDCASA_LICENSE_CONTENT')

param localAdminEmail = '<cloudcasa-admin-email>'
param localAdminPassword = readEnvironmentVariable('CLOUDCASA_LOCAL_ADMIN_PASSWORD')
