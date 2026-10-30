targetScope = 'resourceGroup'

@description('Azure region for the Arc cluster and Workload Orchestration resources.')
param location string = resourceGroup().location

@description('Name of the Arc-connected Kubernetes cluster in the deployment resource group.')
@minLength(1)
param connectClusterName string

@description('Existing Workload Orchestration context resource ID. Leave blank to create a context in this resource group.')
param contextId string = ''

@description('Workload Orchestration target name.')
@minLength(1)
param targetName string = '${connectClusterName}-cloudcasa-target'

@description('Workload Orchestration target used to bootstrap namespaces and Key Vault synchronization.')
@minLength(1)
param bootstrapTargetName string = '${targetName}-bootstrap'

@description('Workload Orchestration custom location name.')
param workloadOrchestrationCustomLocationName string = '${connectClusterName}-wo-cl'

@description('Name of the cert-manager extension installed on the Arc cluster.')
param certManagerExtensionName string = 'cert-manager-extension'

@description('Name of the Workload Orchestration extension installed on the Arc cluster.')
param workloadOrchestrationExtensionName string = 'workloadorchestration-extension'

@description('Name of the Azure Key Vault Secret Store extension installed on the Arc cluster.')
#disable-next-line secure-secrets-in-params
param secretStoreExtensionName string = 'cloudcasa-secret-store'

@description('Name of the Azure Key Vault used for CloudCasa secrets.')
@minLength(3)
@maxLength(24)
param keyVaultName string = 'cc${uniqueString(subscription().id, resourceGroup().id, connectClusterName)}'

@description('Create or update CloudCasa secret values in Key Vault from the secure deployment parameters.')
param populateKeyVaultSecrets bool = true

@description('Name of the user-assigned identity used by the Arc Secret Store extension.')
#disable-next-line secure-secrets-in-params
param secretStoreIdentityName string = '${connectClusterName}-cloudcasa-secrets'

@description('OIDC issuer used by Kubernetes service-account tokens. For Azure AKS, use the managed cluster oidcIssuerProfile.issuerUrl.')
@minLength(1)
param workloadIdentityIssuerUrl string

@description('Kubernetes service account federated to the Secret Store identity in each CloudCasa namespace.')
#disable-next-line secure-secrets-in-params
param secretStoreServiceAccountName string = 'cloudcasa-secret-sync'

@description('SecretProviderClass name created in each CloudCasa namespace.')
#disable-next-line secure-secrets-in-params
param secretProviderClassName string = 'cloudcasa-key-vault'

@description('Azure Key Vault secret containing the complete Docker configuration JSON.')
param registryDockerConfigSecretName string = 'cloudcasa-registry-dockerconfig'

@description('Azure Key Vault secret containing the raw CloudCasa license contents.')
param licenseKeyVaultSecretName string = 'cloudcasa-license'

@description('Azure Key Vault secret containing the local administrator username.')
param localAdminUsernameSecretName string = 'cloudcasa-local-admin-username'

@description('Azure Key Vault secret containing the local administrator email.')
param localAdminEmailSecretName string = 'cloudcasa-local-admin-email'

@description('Azure Key Vault secret containing the local administrator password.')
param localAdminPasswordSecretName string = 'cloudcasa-local-admin-password'

@description('Create a registry-scoped AcrPull assignment for the Workload Orchestration identity.')
param createAcrPullRoleAssignment bool = true

@description('Subscription containing the customer Azure Container Registry.')
param acrSubscriptionId string

@description('Resource group containing the customer Azure Container Registry.')
param acrResourceGroupName string

@description('Name of the customer Azure Container Registry.')
param acrName string

@description('OCI repository containing the CloudCasa bootstrap chart.')
param bootstrapChartRepository string = 'oci://${acrName}.azurecr.io/helm/cloudcasa-bootstrap'

@description('CloudCasa bootstrap chart version.')
param bootstrapChartVersion string = '0.2.4'

@description('Bootstrap Helm release name.')
param bootstrapReleaseName string = 'cloudcasa-bootstrap'

@description('Bootstrap solution-template name.')
param bootstrapSolutionTemplateName string = 'cloudcasa-bootstrap'

@description('Immutable bootstrap solution-template version.')
param bootstrapSolutionTemplateVersion string = '1.1.4'

@description('Bootstrap solution-deployment name.')
param bootstrapSolutionDeploymentName string = 'cloudcasa-bootstrap'

@description('CloudCasa vendor registry server.')
param vendorRegistryServer string = 'cloudcasa.azurecr.io'

@secure()
@description('CloudCasa vendor registry username. Used only when populateKeyVaultSecrets is true.')
param vendorRegistryUsername string = ''

@secure()
@description('CloudCasa vendor registry password. Used only when populateKeyVaultSecrets is true.')
param vendorRegistryPassword string = ''

@secure()
@description('Raw CloudCasa license file contents. Used only when populateKeyVaultSecrets is true.')
param licenseContent string = ''

@description('CloudCasa wrapper Helm chart OCI repository.')
param chartRepository string = 'oci://${acrName}.azurecr.io/helm/cloudcasa-server'

@description('CloudCasa wrapper Helm chart version.')
param chartVersion string = '2.0.0-wo.4'

@description('CloudCasa Helm release name.')
param releaseName string = 'cloudcasa-server'

@description('CloudCasa solution template name.')
param solutionTemplateName string = 'cloudcasa-server'

@description('Immutable CloudCasa solution template version.')
param solutionTemplateVersion string = '2.0.7'

@description('CloudCasa solution deployment name.')
param solutionDeploymentName string = 'cloudcasa-server'

@description('Helm deployment timeout.')
param chartTimeout string = '30m'

@description('Kubernetes image-pull Secret containing CloudCasa vendor registry credentials.')
param imagePullSecretName string = 'myregistrykey'

@description('CloudCasa server namespace.')
param serverNamespace string = 'cloudcasa-server'

@description('CloudCasa license Secret name.')
param licenseSecretName string = 'cc-user-license-key'

@description('Dynamic Kubernetes storage class used by CloudCasa.')
param storageClassName string = 'default'

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

@description('Azure public IP DNS label for a LoadBalancer service.')
param loadBalancerDnsLabelName string = toLower('${connectClusterName}-${uniqueString(subscription().id, resourceGroup().id)}')

@description('Optional public DNS name for the CloudCasa Envoy endpoint. Leave blank to use the Azure LoadBalancer hostname.')
param cloudCasaFqdn string = ''

@description('cert-manager Issuer or ClusterIssuer name.')
param certificateIssuerName string = 'cloudcasa-selfsigned-issuer'

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
param allowedUsers string[] = [
  localAdminEmail
]

@description('Identity-provider groups allowed to sign in.')
param allowedUserGroups string[] = []

@description('Email addresses granted CloudCasa site administrator access.')
param siteAdminUsers string[] = [
  localAdminEmail
]

@description('Identity-provider groups granted CloudCasa site administrator access.')
param siteAdminUserGroups string[] = []

@description('Enable local authentication for controlled proof-of-concept deployments.')
param localAuthenticationEnabled bool = true

@description('Base name of the Secret containing username, email, and password for local authentication.')
param localAuthenticationSecretName string = 'cloudcasa-local-auth'

@description('Non-secret revision appended to the local-authentication Secret name. Increment whenever local credentials change.')
@minLength(1)
@maxLength(20)
param localAuthenticationRevision string = 'r1'

@description('CloudCasa local administrator username.')
param localAdminUsername string = 'cloudcasa-admin'

@description('CloudCasa local administrator email.')
param localAdminEmail string

@secure()
@maxLength(64)
@description('CloudCasa local administrator password, limited to 64 characters for Dex bcrypt compatibility. Used only when populateKeyVaultSecrets is true.')
param localAdminPassword string = ''

@description('Create a namespaced self-signed Issuer through the bootstrap chart.')
param createSelfSignedIssuer bool = true

var workloadOrchestrationCustomLocationNamespace = 'workloadorchestrationresources'
var workloadOrchestrationExtensionType = 'microsoft.workloadorchestration'
var workloadOrchestrationReleaseTrain = 'stable'
var workloadOrchestrationExtensionVersion = '2.1.43'
var workloadOrchestrationRedisStorageClass = storageClassName
var workloadOrchestrationRedisStorageSize = '20Gi'
var keyVaultReaderRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '21090545-7ca7-4776-b22c-e363652d74d2'
)
var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)
var registryAuthorization = base64('${vendorRegistryUsername}:${vendorRegistryPassword}')
var registryDockerConfig = string({
  auths: {
    '${vendorRegistryServer}': {
      username: vendorRegistryUsername
      password: vendorRegistryPassword
      auth: registryAuthorization
    }
    'https://${vendorRegistryServer}': {
      username: vendorRegistryUsername
      password: vendorRegistryPassword
      auth: registryAuthorization
    }
  }
})
var capabilityNames = [
  'cloudcasa'
]

@export()
func mergeCapabilities(existingCapabilities array, requiredNames string[]) array => concat(
  existingCapabilities,
  map(
    filter(
      union(requiredNames, requiredNames),
      name => !contains(map(existingCapabilities, capability => capability.name), name)
    ),
    name => {
      name: name
      description: 'Capability for CloudCasa workloads.'
      state: 'active'
    }
  )
)

@export()
func resolveHierarchies(existingHierarchies array) array => empty(existingHierarchies)
  ? [
      {
        name: 'line'
        description: 'CloudCasa deployment hierarchy.'
      }
    ]
  : existingHierarchies

var serviceAnnotations = union(
  {
    'service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout': string(loadBalancerIdleTimeoutMinutes)
  },
  empty(loadBalancerDnsLabelName)
    ? {}
    : {
        'service.beta.kubernetes.io/azure-dns-label-name': loadBalancerDnsLabelName
      }
)

var baseAuthConfiguration = {
  allowedUsers: join(allowedUsers, ',')
  allowedUserGroups: join(allowedUserGroups, ',')
  siteadminUsers: join(siteAdminUsers, ',')
  siteadminUserGroups: join(siteAdminUserGroups, ',')
}

var effectiveLocalAuthenticationSecretName = localAuthenticationEnabled
  ? '${localAuthenticationSecretName}-${localAuthenticationRevision}'
  : localAuthenticationSecretName

var effectiveCloudCasaFqdn = empty(cloudCasaFqdn)
  ? '${loadBalancerDnsLabelName}.${location}.cloudapp.azure.com'
  : cloudCasaFqdn

var authConfiguration = localAuthenticationEnabled
  ? union(baseAuthConfiguration, {
      local: {
        enabled: true
        existingSecret: effectiveLocalAuthenticationSecretName
        users: []
      }
    })
  : baseAuthConfiguration

var solutionTemplateInputFingerprint = uniqueString(string({
  capabilities: capabilityNames
  bootstrapChart: {
    repository: bootstrapChartRepository
    version: bootstrapChartVersion
    releaseName: bootstrapReleaseName
  }
  secretStore: {
    keyVaultName: keyVaultName
    identityName: secretStoreIdentityName
    serviceAccountName: secretStoreServiceAccountName
    secretProviderClassName: secretProviderClassName
    registryDockerConfigSecretName: registryDockerConfigSecretName
    licenseKeyVaultSecretName: licenseKeyVaultSecretName
    localAdminUsernameSecretName: localAdminUsernameSecretName
    localAdminEmailSecretName: localAdminEmailSecretName
    localAdminPasswordSecretName: localAdminPasswordSecretName
    localAuthenticationSecretName: effectiveLocalAuthenticationSecretName
    localAuthenticationRevision: localAuthenticationRevision
  }
  chart: {
    repository: chartRepository
    version: chartVersion
    releaseName: releaseName
    timeout: chartTimeout
  }
  configuration: {
    imagePullSecretName: imagePullSecretName
    storageClassName: storageClassName
    cloudCasaFqdn: effectiveCloudCasaFqdn
    serviceType: serviceType
    serviceAnnotations: serviceAnnotations
    certificateIssuerName: certificateIssuerName
    certificateIssuerType: certificateIssuerType
    mongoNamespace: mongoNamespace
    mongoStorageSize: mongoStorageSize
    logsStorageSize: logsStorageSize
    auth: authConfiguration
  }
}))

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2025-12-01-preview' existing = {
  name: connectClusterName
}

@onlyIfNotExists()
resource managedContext 'Microsoft.Edge/contexts@2026-03-01' = if (empty(contextId)) {
  name: 'cloudcasa-${uniqueString(connectedCluster.id)}'
  location: location
  properties: {
    capabilities: mergeCapabilities([], capabilityNames)
    hierarchies: resolveHierarchies([])
  }
}

var resolvedContextId = empty(contextId) ? managedContext!.id : contextId
var selectedContext = reference(resolvedContextId, '2026-03-01', 'Full')
var selectedCapabilities = selectedContext.properties.capabilities ?? []
var selectedHierarchies = selectedContext.properties.hierarchies ?? []
var mergedCapabilities = mergeCapabilities(selectedCapabilities, capabilityNames)
var effectiveHierarchies = resolveHierarchies(selectedHierarchies)

module contextRegistration './update-context.bicep' = {
  name: '${uniqueString(connectedCluster.id)}-cloudcasa-context'
  scope: resourceGroup(split(resolvedContextId, '/')[2], split(resolvedContextId, '/')[4])
  params: {
    contextName: last(split(resolvedContextId, '/'))
    location: selectedContext.location
    tags: selectedContext.?tags ?? {}
    capabilities: mergedCapabilities
    hierarchies: effectiveHierarchies
    updateRequired: length(mergedCapabilities) > length(selectedCapabilities) || empty(selectedHierarchies)
  }
}

resource certManagerExtension 'Microsoft.KubernetesConfiguration/extensions@2022-03-01' = {
  name: certManagerExtensionName
  scope: connectedCluster
  properties: {
    extensionType: 'microsoft.certmanagement'
    autoUpgradeMinorVersion: true
    releaseTrain: 'stable'
  }
}

resource secretStoreExtension 'Microsoft.KubernetesConfiguration/extensions@2022-03-01' = {
  name: secretStoreExtensionName
  scope: connectedCluster
  dependsOn: [
    certManagerExtension
  ]
  properties: {
    extensionType: 'microsoft.azure.secretstore'
    autoUpgradeMinorVersion: true
    releaseTrain: 'stable'
    scope: {
      cluster: {
        releaseNamespace: 'azure-secret-store'
      }
    }
  }
}

resource workloadOrchestrationExtension 'Microsoft.KubernetesConfiguration/extensions@2022-03-01' = {
  name: workloadOrchestrationExtensionName
  scope: connectedCluster
  identity: {
    type: 'SystemAssigned'
  }
  dependsOn: [
    certManagerExtension
  ]
  properties: {
    extensionType: workloadOrchestrationExtensionType
    autoUpgradeMinorVersion: false
    releaseTrain: workloadOrchestrationReleaseTrain
    version: workloadOrchestrationExtensionVersion
    configurationSettings: {
      'redis.persistentVolume.storageClass': workloadOrchestrationRedisStorageClass
      'redis.persistentVolume.size': workloadOrchestrationRedisStorageSize
    }
  }
}

resource managedKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    publicNetworkAccess: 'Enabled'
    softDeleteRetentionInDays: 7
    sku: {
      family: 'A'
      name: 'standard'
    }
  }
}

resource secretStoreIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: secretStoreIdentityName
  location: location
}

resource keyVaultReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedKeyVault.id, secretStoreIdentity.id, keyVaultReaderRoleDefinitionId)
  scope: managedKeyVault
  properties: {
    roleDefinitionId: keyVaultReaderRoleDefinitionId
    principalId: secretStoreIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedKeyVault.id, secretStoreIdentity.id, keyVaultSecretsUserRoleDefinitionId)
  scope: managedKeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: secretStoreIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource registryDockerConfigSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (populateKeyVaultSecrets) {
  name: registryDockerConfigSecretName
  parent: managedKeyVault
  properties: {
    value: registryDockerConfig
    contentType: 'application/json'
  }
}

resource licenseSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (populateKeyVaultSecrets) {
  name: licenseKeyVaultSecretName
  parent: managedKeyVault
  properties: {
    value: licenseContent
    contentType: 'application/octet-stream'
  }
}

resource localUsernameSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (populateKeyVaultSecrets) {
  name: localAdminUsernameSecretName
  parent: managedKeyVault
  properties: {
    value: localAdminUsername
    contentType: 'text/plain'
  }
}

resource localEmailSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (populateKeyVaultSecrets) {
  name: localAdminEmailSecretName
  parent: managedKeyVault
  properties: {
    value: localAdminEmail
    contentType: 'text/plain'
  }
}

resource localPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (populateKeyVaultSecrets) {
  name: localAdminPasswordSecretName
  parent: managedKeyVault
  properties: {
    value: localAdminPassword
    contentType: 'text/plain'
  }
}

resource serverFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  name: 'cloudcasa-server'
  parent: secretStoreIdentity
  dependsOn: [
    mongoFederatedCredential
  ]
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: workloadIdentityIssuerUrl
    subject: 'system:serviceaccount:${serverNamespace}:${secretStoreServiceAccountName}'
  }
}

resource mongoFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  name: 'cloudcasa-mongo'
  parent: secretStoreIdentity
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: workloadIdentityIssuerUrl
    subject: 'system:serviceaccount:${mongoNamespace}:${secretStoreServiceAccountName}'
  }
}

module acrPullRoleAssignment './acr-pull-role-assignment.bicep' = if (createAcrPullRoleAssignment) {
  name: 'cloudcasa-single-acr-pull-${uniqueString(workloadOrchestrationExtension.id, acrName)}'
  scope: resourceGroup(acrSubscriptionId, acrResourceGroupName)
  params: {
    acrName: acrName
    principalId: workloadOrchestrationExtension.identity.principalId
  }
}

resource workloadOrchestrationCustomLocation 'Microsoft.ExtendedLocation/customLocations@2021-03-15-preview' = {
  name: workloadOrchestrationCustomLocationName
  location: location
  properties: {
    displayName: 'CloudCasa Workload Orchestration'
    hostResourceId: connectedCluster.id
    namespace: workloadOrchestrationCustomLocationNamespace
    clusterExtensionIds: [
      workloadOrchestrationExtension.id
    ]
  }
}

resource cloudCasaTarget 'Microsoft.Edge/targets@2026-05-01-preview' = {
  name: targetName
  location: location
  dependsOn: [
    contextRegistration
  ]
  extendedLocation: {
    name: workloadOrchestrationCustomLocation.id
    type: 'CustomLocation'
  }
  properties: {
    capabilities: capabilityNames
    contextId: resolvedContextId
    description: 'Kubernetes target for CloudCasa self-hosted'
    displayName: 'CloudCasa Target'
    hierarchyLevel: contextRegistration.outputs.hierarchyLevel
    solutionScope: 'cloudcasa-server'
    targetSpecification: {
      components: []
      scope: 'default'
      topologies: [
        {
          bindings: [
            {
              config: {
                inCluster: 'true'
              }
              provider: 'providers.target.helm'
              role: 'helm.v3'
            }
          ]
        }
      ]
    }
  }
}

resource cloudCasaBootstrapTarget 'Microsoft.Edge/targets@2026-05-01-preview' = {
  name: bootstrapTargetName
  location: location
  dependsOn: [
    contextRegistration
  ]
  extendedLocation: {
    name: workloadOrchestrationCustomLocation.id
    type: 'CustomLocation'
  }
  properties: {
    capabilities: capabilityNames
    contextId: resolvedContextId
    description: 'Kubernetes target for CloudCasa namespace and secret bootstrap'
    displayName: 'CloudCasa Bootstrap Target'
    hierarchyLevel: contextRegistration.outputs.hierarchyLevel
    solutionScope: 'default'
    targetSpecification: {
      components: []
      scope: 'default'
      topologies: [
        {
          bindings: [
            {
              config: {
                inCluster: 'true'
              }
              provider: 'providers.target.helm'
              role: 'helm.v3'
            }
          ]
        }
      ]
    }
  }
}

resource capabilityPropagationDelay 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'cloudcasa-capability-delay'
  location: location
  kind: 'AzureCLI'
  dependsOn: [
    cloudCasaTarget
    cloudCasaBootstrapTarget
  ]
  properties: {
    azCliVersion: '2.89.1'
    scriptContent: 'sleep 90'
    timeout: 'PT15M'
    cleanupPreference: 'Always'
    retentionInterval: 'P1D'
    forceUpdateTag: '${deployment().name}-bootstrap-target-v1'
  }
}

@onlyIfNotExists()
resource bootstrapTemplate 'Microsoft.Edge/solutionTemplates@2026-05-01-preview' = {
  name: bootstrapSolutionTemplateName
  location: location
  dependsOn: [
    capabilityPropagationDelay
  ]
  properties: {
    description: 'CloudCasa namespace and Azure Key Vault secret synchronization bootstrap'
    capabilities: capabilityNames
  }

  @onlyIfNotExists()
  resource version 'versions@2026-05-01-preview' = {
    name: bootstrapSolutionTemplateVersion
    properties: {
      configurations: {
        configs: {
          namespaces: {
            server: serverNamespace
            mongo: mongoNamespace
          }
          secretStore: {
            tenantId: tenant().tenantId
            keyVaultName: keyVaultName
            clientId: secretStoreIdentity.properties.clientId
            serviceAccountName: secretStoreServiceAccountName
            secretProviderClassName: secretProviderClassName
            registryDockerConfigSecretName: registryDockerConfigSecretName
            licenseKeyVaultSecretName: licenseKeyVaultSecretName
            localAdminUsernameSecretName: localAdminUsernameSecretName
            localAdminEmailSecretName: localAdminEmailSecretName
            localAdminPasswordSecretName: localAdminPasswordSecretName
          }
          kubernetesSecrets: {
            registry: imagePullSecretName
            license: licenseSecretName
            localAuthentication: effectiveLocalAuthenticationSecretName
          }
          localAuthenticationEnabled: localAuthenticationEnabled
          localAuthenticationRevision: localAuthenticationRevision
          issuer: {
            enabled: createSelfSignedIssuer
            name: certificateIssuerName
          }
        }
      }
      specification: {
        components: [
          {
            name: 'cloudcasa-bootstrap'
            type: 'helm.v3'
            properties: {
              releaseName: bootstrapReleaseName
              chart: {
                repo: bootstrapChartRepository
                version: bootstrapChartVersion
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

resource bootstrapDeployment 'Microsoft.Edge/solutionDeployments@2026-05-01-preview' = {
  name: bootstrapSolutionDeploymentName
  location: location
  dependsOn: [
    acrPullRoleAssignment
    bootstrapTemplate::version
    keyVaultReader
    keyVaultSecretsUser
    registryDockerConfigSecret
    licenseSecret
    localUsernameSecret
    localEmailSecret
    localPasswordSecret
    secretStoreExtension
    serverFederatedCredential
    mongoFederatedCredential
  ]
  properties: {
    solutionTemplateProperties: {
      name: bootstrapSolutionTemplateName
      version: bootstrapSolutionTemplateVersion
    }
    targetProperties: {
      targetIds: [
        cloudCasaBootstrapTarget.id
      ]
    }
  }
}

@onlyIfNotExists()
resource cloudCasaTemplate 'Microsoft.Edge/solutionTemplates@2026-05-01-preview' = {
  name: solutionTemplateName
  location: location
  dependsOn: [
    cloudCasaTarget
  ]
  properties: {
    description: 'CloudCasa self-hosted server'
    capabilities: capabilityNames
  }

  @onlyIfNotExists()
  resource version 'versions@2026-05-01-preview' = {
    name: solutionTemplateVersion
    properties: {
      configurations: {
        configs: {
          imagePullSecretName: imagePullSecretName
          storageClassName: storageClassName
          license: {
            createSecret: false
          }
          licenseKey: ''
          remoteLicenseServerAPIKey: ''
          serviceType: serviceType
          serviceAnnotations: serviceAnnotations
          localAuthenticationEnabled: localAuthenticationEnabled
          localAuthenticationSecretName: effectiveLocalAuthenticationSecretName
          amdsEnvoyUrl: effectiveCloudCasaFqdn
          amdsEnvoyPort: 443
          amdsEnvoyPortName: 'grpc-port'
          certificates: {
            createTlsSecrets: true
            issuerName: certificateIssuerName
            issuerType: certificateIssuerType
            issuerGroup: 'cert-manager.io'
          }
          mongo: {
            createStatefulset: true
            statefulsetNamespace: mongoNamespace
            createNamespace: false
            pv: {
              size: mongoStorageSize
            }
          }
          logs: {
            pv: {
              size: logsStorageSize
            }
          }
          auth: authConfiguration
        }
      }
      specification: {
        components: [
          {
            name: 'cloudcasa-server'
            type: 'helm.v3'
            properties: {
              releaseName: releaseName
              chart: {
                repo: chartRepository
                version: chartVersion
                wait: true
                timeout: chartTimeout
              }
            }
          }
        ]
      }
    }
  }
}

resource cloudCasaDeployment 'Microsoft.Edge/solutionDeployments@2026-05-01-preview' = {
  name: solutionDeploymentName
  location: location
  dependsOn: [
    bootstrapDeployment
    cloudCasaTemplate::version
  ]
  properties: {
    solutionTemplateProperties: {
      name: solutionTemplateName
      version: solutionTemplateVersion
    }
    targetProperties: {
      targetIds: [
        cloudCasaTarget.id
      ]
    }
  }
}

output contextResourceId string = resolvedContextId
output targetId string = cloudCasaTarget.id
output bootstrapTargetId string = cloudCasaBootstrapTarget.id
output customLocationId string = workloadOrchestrationCustomLocation.id
output workloadOrchestrationExtensionId string = workloadOrchestrationExtension.id
output secretStoreExtensionId string = secretStoreExtension.id
output keyVaultId string = managedKeyVault.id
output secretStoreIdentityId string = secretStoreIdentity.id
output bootstrapDeploymentId string = bootstrapDeployment.id
output cloudCasaDeploymentId string = cloudCasaDeployment.id
output solutionTemplateInputFingerprint string = solutionTemplateInputFingerprint
output effectiveLocalAuthenticationSecretName string = effectiveLocalAuthenticationSecretName
output configuredCloudCasaFqdn string = effectiveCloudCasaFqdn
