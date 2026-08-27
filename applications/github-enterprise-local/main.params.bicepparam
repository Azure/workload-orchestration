using './main.bicep'

// ----- Edge / Workload Orchestration -----
param cloudTargetName = 'cloud-target'
param infraCapabilityName = 'test-capability'
param Location = 'eastus2'
param contextId = '/subscriptions/<context-subscription-id>/resourceGroups/<context-resource-group>/providers/Microsoft.Edge/contexts/<your-edge-context>'
param subscriptionId = '<subscription-id>'
param resourceGroupName = '<template-spec-resource-group>'

// ----- Single (merged) GHES solution template + single template spec -----
param ghesSolutionTemplateName = 'ghes-solution-template'
param ghesSolutionTemplateVersionName = '1.0.0'
param ghesSpecName = 'ghesspec'
param ghesSpecVersion = '1.0.0'

// ----- Cluster (unlocks auto-resolution of networking/infra from deploymentSettings) -----
param clusterName = '<azure-local-cluster-name>'

// ----- Image -----
// CustomLocationId is auto-derived from clusterName. Provide only to override.
param VmImageName = 'ghes-image'
param LocalSharePath = 'C:\\ClusterStorage\\<share>\\<github-enterprise-image>.vhdx'
param StoragePathId = '/subscriptions/<subscription-id>/resourceGroups/<cluster-registration-rg>/providers/Microsoft.AzureStackHCI/storageContainers/<storage-container-name>'
param CreateImage = true

// ----- Logical network -----
// AddressPrefix, VmSwitchName, DnsServers, DefaultGateway are auto-derived from deploymentSettings.
// StartIp/EndIp are NOT in deploymentSettings and must be provided.
param LogicalNetworkName = 'ghes-lnet'
param IpAllocationMethod = 'Static'
param Vlan = 0
param StartIp = '10.0.0.52'
param EndIp = '10.0.0.60'

// ----- VM -----
// VmName is auto-derived (<VmNamePrefix>-1). Provide only to override.
param AdminUsername = 'ghesadmin'
param AdminPassword = readEnvironmentVariable('GHES_ADMIN_PASSWORD','')
param CPU = 16
param Memory = 32768
param NumberDataDisks = 1
param DiskSizeGB = 500

// ----- Key Vault -----
param KeyVaultName = '<globally-unique-keyvault-name>'
param KeyVaultSkuName = 'standard'
param ManagementConsolePasswordSecretName = 'ghes-mgmt-console-password'
param AdminPasswordSecretName = 'ghes-admin-password'
param ManagementConsolePassword = readEnvironmentVariable('GHES_MGMT_CONSOLE_PASSWORD','')

// ----- Post-Config -----
// GithubHostName is auto-derived (<GithubHostLabel>.<domainFqdn>). Provide only to override.
param LicenseBase64 = readEnvironmentVariable('GHES_LICENSE_B64','')
param SubdomainIsolation = true
param SignupEnabled = false
param PublicPages = false
param ManagePort = 8443
param ApplyTimeoutMinutes = 120
param ReadyTimeoutMinutes = 30
param SkipApply = false
param AsyncExecution = false
param RunCommandName = 'ghes-postconfig'

