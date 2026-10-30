using './main.bicep'

param location = '<cluster-region>'
param connectClusterName = '<arc-connected-cluster-name>'

param workloadIdentityIssuerUrl = '<kubernetes-oidc-issuer-url>'

param acrSubscriptionId = '<acr-subscription-id>'
param acrResourceGroupName = '<acr-resource-group>'
param acrName = '<acr-name>'

param vendorRegistryUsername = readEnvironmentVariable('CLOUDCASA_REGISTRY_USERNAME')
param vendorRegistryPassword = readEnvironmentVariable('CLOUDCASA_REGISTRY_PASSWORD')
param licenseContent = readEnvironmentVariable('CLOUDCASA_LICENSE_CONTENT')

param localAdminEmail = '<cloudcasa-admin-email>'
param localAdminPassword = readEnvironmentVariable('CLOUDCASA_LOCAL_ADMIN_PASSWORD')
