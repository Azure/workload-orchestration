using './main.bicep'

// ----- Edge / Workload Orchestration -----
// Leave blank to create the default context, or provide an existing Microsoft.Edge context resource ID.
param existingContextId = ''

// ----- Cluster -----
param clusterName = '<cluster-name>'

// ----- Image -----
// Cluster-local path to the source GHES VHDX.
param LocalSharePath = '<cluster-local-vhdx-path>'

// Resource ID of the Azure Local storage container used by the image and VM configuration.
param StoragePathId = '<storage-container-resource-id>'

// ----- Logical network -----
// The template derives address prefix, DNS, gateway, and virtual switch from cluster deployment settings.
param LogicalNetworkName = '<logical-network-name>'
param StartIp = '<start-ip-address>'
param EndIp = '<end-ip-address>'

// ----- VM -----
param VmName = '<vm-name>'
param AdminUsername = '<admin-username>'
param AdminPassword = readEnvironmentVariable('GHES_ADMIN_PASSWORD', '')

// Supported CPU values: 4, 8, 16, or 32. Memory is specified in MB.
param CPU = 16
param Memory = 32768
param NumberDataDisks = 1
param DiskSizeGB = 500

// ----- Key Vault and post-configuration -----
// Must be a globally unique Key Vault name containing 3-24 alphanumeric or dash characters.
param KeyVaultName = '<key-vault-name>'
param ManagementConsolePassword = readEnvironmentVariable('GHES_MGMT_CONSOLE_PASSWORD', '')

// Base64-encode the original .ghl license file without modifying its contents.
param LicenseBase64 = readEnvironmentVariable('GHES_LICENSE_B64', '')
