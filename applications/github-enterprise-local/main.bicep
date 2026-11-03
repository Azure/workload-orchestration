// Portal entry point for deploying GitHub Enterprise Server (GHES) on Azure Local.
// This is intentionally self-contained: it creates the Key Vault and password secrets,
// publishes the GHES Template Spec, and deploys it through Workload Orchestration.

// ----- Cluster / auto-resolution -----
@description('Azure Local cluster name')
param clusterName string

// ----- Image -----
@description('Required cluster-local path to the source GHES VHDX.')
param LocalSharePath string

@description('Resource ID of the Azure Local storage container used by the image and VM configuration.')
param StoragePathId string

// ----- Logical network -----
@description('Name of the logical network resource.')
param LogicalNetworkName string

@description('Static IP assigned to GHES and the start of the workload IP pool.')
param StartIp string

@description('End of the workload IP pool.')
param EndIp string

// ----- VM -----
@description('Required name of the GHES virtual machine and Arc machine.')
param VmName string

@description('Administrator username for the GHES VM.')
param AdminUsername string

@description('Administrator password.')
@secure()
param AdminPassword string

@description('Number of virtual processors assigned to the VM. Input values: 4, 8, 16 or 32 vCPUs.')
@allowed([
  4
  8
  16
  32
])
@minValue(4)
@maxValue(32)
param CPU int

@description('Memory assigned to the VM in MB. Supported range: 32768-131072 MB (32-128 GB).')
@minValue(32768)
@maxValue(131072)
param Memory int

@description('Number of data disks to create and attach. Default: 1')
@minValue(1)
param NumberDataDisks int

@description('Size of each data disk in GB. Minimum value is 500')
@minValue(500)
param DiskSizeGB int

// ----- Key Vault and portal-collected secrets -----
@description('Globally unique Key Vault name (3-24 characters, alphanumeric and dashes).')
@minLength(3)
@maxLength(24)
param KeyVaultName string

@description('Management-console password.')
@secure()
param ManagementConsolePassword string

// ----- Post-configuration -----
@description('Base64-encoded GHES .ghl license file.')
@secure()
param LicenseBase64 string

var Location = 'eastus'
var cloudTargetName = 'cloud-target'
var contextName = 'defaultContext'
var contextHierarchyName = 'line'
var infraCapabilityName = 'ghes-infrastructure'
var ghesSolutionTemplateName = 'ghes-solution-template'
var ghesSolutionTemplateVersionName = '1.0.0'
var ghesSpecName = 'ghesspec'
var ghesSpecVersion = '1.0.0'
var CustomLocationId = ''
var VmImageName = 'ghes-image'
var CreateImage = true
var ExistingImageResourceId = ''
var IpAllocationMethod = 'Static'
var AddressPrefix = ''
var Vlan = 0
var VmSwitchName = ''
var DnsServers = []
var DefaultGateway = ''
var VmNamePrefix = 'ghes'
var TenantId = subscription().tenantId
var KeyVaultSkuName = 'standard'
var EnableRbacAuthorization = true
var SoftDeleteRetentionInDays = 7
var ManagementConsolePasswordSecretName = 'ghes-mgmt-console-password'
var AdminPasswordSecretName = 'ghes-admin-password'
var GithubHostName = ''
var GithubHostLabel = 'githubenterpriselocal'
var LicensePart1SecretName = 'ghl-license-part1'
var LicensePart2SecretName = 'ghl-license-part2'
var SubdomainIsolation = true
var SignupEnabled = false
var PublicPages = false
var ManagePort = 8443
var ApplyTimeoutMinutes = 180
var ReadyTimeoutMinutes = 30
var SkipApply = false
var AsyncExecution = true
var RunCommandName = 'ghes-postconfig'

// The generated object below is the compiled form of the existing ghes.bicep template,
// with Key Vault creation removed and the runtime scripts loaded from package sources.
var ghesTemplate = {
  '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
  contentVersion: '1.0.0.0'
  metadata: {
    _generator: {
      name: 'bicep'
      version: '0.48.1.52935'
      templateHash: '12638164160614974244'
    }
  }
  parameters: {
    clusterName: {
      type: 'string'
      metadata: {
        description: 'Azure Local cluster name; its deploymentSettings/default supplies domain/gateway/DNS/subnet/switch, and its custom location is derived by convention.'
      }
    }
    ImageName: {
      type: 'string'
      defaultValue: 'ghes-image'
      metadata: {
        description: 'Name for the VM image.'
      }
    }
    CustomLocationId: {
      type: 'string'
      defaultValue: ''
      metadata: {
        description: 'OVERRIDE: Resource ID of the custom location for Azure Local. Blank => derived by convention <clusterName>-customlocation.'
      }
    }
    LocalSharePath: {
      type: 'string'
      defaultValue: ''
      metadata: {
        description: 'Local file share path for the source image (VHDX). Required only when CreateImage=true.'
      }
    }
    StoragePathId: {
      type: 'string'
      metadata: {
        description: 'Resource ID of the storage path (container) where the image is stored.'
      }
    }
    CreateImage: {
      type: 'bool'
      defaultValue: true
      metadata: {
        description: 'Create the gallery image (true) or reference an existing one (false). Set false on redeploys against an existing image.'
      }
    }
    ExistingImageResourceId: {
      type: 'string'
      defaultValue: ''
      metadata: {
        description: 'When CreateImage=false: Resource ID of an existing gallery image. Blank => the image named <ImageName> in this resource group.'
      }
    }
    LogicalNetworkName: {
      type: 'string'
      defaultValue: 'ghes-lnet'
      metadata: {
        description: 'Name of the logical network resource.'
      }
    }
    IpAllocationMethod: {
      type: 'string'
      defaultValue: 'Static'
      metadata: {
        description: 'IP allocation method for the subnet (e.g. Static).'
      }
    }
    AddressPrefix: {
      type: 'string'
      defaultValue: ''
      metadata: {
        description: 'OVERRIDE: CIDR address prefix for the subnet (e.g. 10.0.0.0/24). Blank => derived from deploymentSettings subnetMask + gateway (octet-aligned masks /8,/16,/24). REQUIRED for non-octet-aligned masks.'
      }
    }
    Vlan: {
      type: 'int'
      defaultValue: 0
      minValue: 0
      maxValue: 4094
      metadata: {
        description: 'VLAN ID for the subnet (0-4094). Use 0 for untagged.'
      }
    }
    Location: {
      type: 'string'
      defaultValue: '[resourceGroup().location]'
      metadata: {
        description: 'Azure region/location for the deployment metadata.'
      }
    }
    VmSwitchName: {
      type: 'string'
      defaultValue: ''
      metadata: {
        description: 'OVERRIDE: Name of the Hyper-V virtual switch. Blank => derived from deploymentSettings host-network intent (ConvergedSwitch(<intent>)).'
      }
    }
    StartIp: {
      type: 'string'
      metadata: {
        description: 'Static IP for the GHES VM; also the start of the workload IP pool (NOT in deploymentSettings).'
      }
    }
    EndIp: {
      type: 'string'
      metadata: {
        description: 'End of the workload IP pool (NOT in deploymentSettings).'
      }
    }
    DnsServers: {
      type: 'array'
      defaultValue: []
      metadata: {
        description: 'OVERRIDE: One or more DNS server IP addresses. Empty array => from deploymentSettings.'
      }
    }
    DefaultGateway: {
      type: 'string'
      defaultValue: ''
      metadata: {
        description: 'OVERRIDE: Default gateway IP address for the subnet. Blank => from deploymentSettings.'
      }
    }
    VmName: {
      type: 'string'
      defaultValue: ''
      metadata: {
        description: 'OVERRIDE: Name of the virtual machine / Arc machine to create. Blank => <VmNamePrefix>-1.'
      }
    }
    VmNamePrefix: {
      type: 'string'
      defaultValue: 'ghes'
      metadata: {
        description: 'Hostname prefix used when VmName is blank.'
      }
    }
    KeyVaultId: {
      type: 'string'
      metadata: {
        description: 'Resource ID of the Key Vault containing the GHES secrets.'
      }
    }
    AdminUsername: {
      type: 'string'
      metadata: {
        description: 'Administrator username for the VM.'
      }
    }
    AdminPasswordKeyName: {
      type: 'string'
      metadata: {
        description: 'Name of the secret in the Key Vault containing the administrator password for the VM.'
      }
    }
    CPU: {
      type: 'int'
      defaultValue: 16
      minValue: 4
      maxValue: 32
      metadata: {
        description: 'Number of virtual processors to assign to the VM.'
      }
    }
    Memory: {
      type: 'int'
      defaultValue: 32768
      minValue: 32768
      maxValue: 131072
      metadata: {
        description: 'Memory to assign to the VM, in MB.'
      }
    }
    NumberDataDisks: {
      type: 'int'
      defaultValue: 1
      minValue: 0
      metadata: {
        description: 'Number of data disks to create and attach.'
      }
    }
    DiskSizeGB: {
      type: 'int'
      defaultValue: 500
      metadata: {
        description: 'Size of each data disk in GB.'
      }
    }
    ManagementConsolePasswordKeyName: {
      type: 'string'
      metadata: {
        description: 'Name of the secret in the Key Vault containing the management console password for the VM.'
      }
    }
    GithubHostName: {
      type: 'string'
      defaultValue: ''
      metadata: {
        description: 'OVERRIDE: full GHES hostname (FQDN). Blank => <GithubHostLabel>.<domainFqdn-from-deploymentSettings>.'
      }
    }
    GithubHostLabel: {
      type: 'string'
      defaultValue: 'githubenterpriselocal'
      metadata: {
        description: 'Hostname label prepended to the domain FQDN when GithubHostName is blank.'
      }
    }
    LicenseBase64Part1KeyName: {
      type: 'string'
      metadata: {
        description: 'Name of the secret in the Key Vault containing the first half of the base64 of the GHES .ghl license file.'
      }
    }
    LicenseBase64Part2KeyName: {
      type: 'string'
      metadata: {
        description: 'Name of the secret in the Key Vault containing the second half of the base64 of the GHES .ghl license file.'
      }
    }
    SubdomainIsolation: {
      type: 'bool'
      defaultValue: true
      metadata: {
        description: 'Enable subdomain isolation.'
      }
    }
    SignupEnabled: {
      type: 'bool'
      defaultValue: false
      metadata: {
        description: 'Allow built-in signups (kept off for AD/LDAP-backed instances).'
      }
    }
    PublicPages: {
      type: 'bool'
      defaultValue: false
      metadata: {
        description: 'Enable public GitHub Pages.'
      }
    }
    ManagePort: {
      type: 'int'
      defaultValue: 8443
      metadata: {
        description: 'Manage API port on the appliance.'
      }
    }
    ApplyTimeoutMinutes: {
      type: 'int'
      defaultValue: 120
      minValue: 10
      maxValue: 1440
      metadata: {
        description: 'Cap (minutes) on the on-box ghe-config-apply.'
      }
    }
    ReadyTimeoutMinutes: {
      type: 'int'
      defaultValue: 30
      minValue: 5
      maxValue: 240
      metadata: {
        description: 'Minutes to wait for the Manage API + init-triggered apply to settle before staging settings.'
      }
    }
    SkipApply: {
      type: 'bool'
      defaultValue: false
      metadata: {
        description: 'Stage settings only; skip ghe-config-apply (useful for a dry run).'
      }
    }
    AsyncExecution: {
      type: 'bool'
      defaultValue: false
      metadata: {
        description: 'Run the config-apply asynchronously (deployment returns immediately). Default false so the deployment waits for completion.'
      }
    }
    RunCommandName: {
      type: 'string'
      defaultValue: 'ghes-postconfig'
      metadata: {
        description: 'Name of the Run Command resource created on the appliance.'
      }
    }
    ScriptSasStartTime: {
      type: 'string'
      defaultValue: '[dateTimeAdd(utcNow(\'u\'), \'-PT15M\')]'
    }
    ScriptSasExpiryTime: {
      type: 'string'
      defaultValue: '[dateTimeAdd(utcNow(\'u\'), \'P1DT15M\')]'
    }
    ScriptUploadToken: {
      type: 'string'
      defaultValue: '[utcNow(\'u\')]'
    }
  }
  variables: {
    effectiveCustomLocationId: '[if(empty(parameters(\'CustomLocationId\')), resourceId(\'Microsoft.ExtendedLocation/customLocations\', format(\'{0}-customlocation\', parameters(\'clusterName\'))), parameters(\'CustomLocationId\'))]'
    maskToPrefix: {
      '255.0.0.0': 8
      '255.255.0.0': 16
      '255.255.255.0': 24
    }
    effectiveVmName: '[if(empty(parameters(\'VmName\')), format(\'{0}-1\', parameters(\'VmNamePrefix\')), parameters(\'VmName\'))]'
    effectiveImageId: '[if(parameters(\'CreateImage\'), resourceId(\'Microsoft.AzureStackHCI/galleryImages\', parameters(\'ImageName\')), if(empty(parameters(\'ExistingImageResourceId\')), resourceId(\'Microsoft.AzureStackHCI/galleryImages\', parameters(\'ImageName\')), parameters(\'ExistingImageResourceId\')))]'
    scriptStorageAccountName: '[toLower(format(\'ghes{0}\', take(uniqueString(subscription().id, resourceGroup().id, parameters(\'VmName\')), 20)))]'
    scriptContainerName: 'scripts'
    scriptBlobName: 'post-config.sh'
    scriptSasRequest: {
      canonicalizedResource: '[format(\'/blob/{0}/{1}/{2}\', variables(\'scriptStorageAccountName\'), variables(\'scriptContainerName\'), variables(\'scriptBlobName\'))]'
      signedResource: 'b'
      signedPermission: 'r'
      signedProtocol: 'https'
      signedStart: '[parameters(\'ScriptSasStartTime\')]'
      signedExpiry: '[parameters(\'ScriptSasExpiryTime\')]'
    }
  }
  resources: [
    {
      type: 'Microsoft.Storage/storageAccounts'
      apiVersion: '2023-05-01'
      name: '[variables(\'scriptStorageAccountName\')]'
      location: '[parameters(\'Location\')]'
      kind: 'StorageV2'
      sku: {
        name: 'Standard_LRS'
      }
      properties: {
        allowBlobPublicAccess: false
        allowSharedKeyAccess: true
        minimumTlsVersion: 'TLS1_2'
        publicNetworkAccess: 'Enabled'
        supportsHttpsTrafficOnly: true
      }
    }
    {
      type: 'Microsoft.Storage/storageAccounts/blobServices'
      apiVersion: '2023-05-01'
      name: '[format(\'{0}/default\', variables(\'scriptStorageAccountName\'))]'
      dependsOn: [
        '[resourceId(\'Microsoft.Storage/storageAccounts\', variables(\'scriptStorageAccountName\'))]'
      ]
    }
    {
      type: 'Microsoft.Storage/storageAccounts/blobServices/containers'
      apiVersion: '2023-05-01'
      name: '[format(\'{0}/default/{1}\', variables(\'scriptStorageAccountName\'), variables(\'scriptContainerName\'))]'
      properties: {
        publicAccess: 'None'
      }
      dependsOn: [
        '[resourceId(\'Microsoft.Storage/storageAccounts/blobServices\', variables(\'scriptStorageAccountName\'), \'default\')]'
      ]
    }
    {
      type: 'Microsoft.Resources/deployments'
      apiVersion: '2022-09-01'
      name: 'upload-ghes-post-config'
      properties: {
        mode: 'Incremental'
        expressionEvaluationOptions: {
          scope: 'inner'
        }
        parameters: {
          Location: { value: '[parameters(\'Location\')]' }
          StorageAccountId: { value: '[resourceId(\'Microsoft.Storage/storageAccounts\', variables(\'scriptStorageAccountName\'))]' }
          StorageAccountName: { value: '[variables(\'scriptStorageAccountName\')]' }
          ContainerName: { value: '[variables(\'scriptContainerName\')]' }
          ScriptBlobName: { value: '[variables(\'scriptBlobName\')]' }
          PostConfigScript: { value: loadTextContent('./BicepTemplates/ghes-all/post-config.sh') }
          ScriptUploadToken: { value: '[parameters(\'ScriptUploadToken\')]' }
        }
        template: {
          '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
          contentVersion: '1.0.0.0'
          parameters: {
            Location: { type: 'string' }
            StorageAccountId: { type: 'string' }
            StorageAccountName: { type: 'string' }
            ContainerName: { type: 'string' }
            ScriptBlobName: { type: 'string' }
            PostConfigScript: { type: 'string' }
            ScriptUploadToken: { type: 'string' }
          }
          resources: [
            {
              type: 'Microsoft.Resources/deploymentScripts'
              apiVersion: '2023-08-01'
              name: 'upload-ghes-post-config'
              location: '[parameters(\'Location\')]'
              kind: 'AzureCLI'
              properties: {
                azCliVersion: '2.89.1'
                environmentVariables: [
                  {
                    name: 'AZURE_STORAGE_KEY'
                    secureValue: '[listKeys(parameters(\'StorageAccountId\'), \'2023-05-01\').keys[0].value]'
                  }
                  {
                    name: 'STORAGE_ACCOUNT_NAME'
                    value: '[parameters(\'StorageAccountName\')]'
                  }
                  {
                    name: 'ASSET_CONTAINER_NAME'
                    value: '[parameters(\'ContainerName\')]'
                  }
                  {
                    name: 'SCRIPT_BLOB_NAME'
                    value: '[parameters(\'ScriptBlobName\')]'
                  }
                  {
                    name: 'POST_CONFIG_SCRIPT'
                    value: '[parameters(\'PostConfigScript\')]'
                  }
                ]
                scriptContent: loadTextContent('./BicepTemplates/ghes-all/upload-post-config.sh')
                timeout: 'PT15M'
                cleanupPreference: 'Always'
                retentionInterval: 'P1D'
                forceUpdateTag: '[parameters(\'ScriptUploadToken\')]'
              }
            }
          ]
        }
      }
      dependsOn: [
        '[resourceId(\'Microsoft.Storage/storageAccounts/blobServices/containers\', variables(\'scriptStorageAccountName\'), \'default\', variables(\'scriptContainerName\'))]'
      ]
    }
    {
      condition: '[parameters(\'CreateImage\')]'
      type: 'Microsoft.AzureStackHCI/galleryImages'
      apiVersion: '2025-04-01-preview'
      name: '[parameters(\'ImageName\')]'
      location: '[parameters(\'Location\')]'
      extendedLocation: {
        name: '[variables(\'effectiveCustomLocationId\')]'
        type: 'CustomLocation'
      }
      tags: {}
      properties: {
        osType: 'Linux'
        hyperVGeneration: 'V2'
        containerId: '[parameters(\'StoragePathId\')]'
        imagePath: '[parameters(\'LocalSharePath\')]'
      }
    }
    {
      type: 'Microsoft.AzureStackHCI/logicalNetworks'
      apiVersion: '2025-04-01-preview'
      name: '[parameters(\'LogicalNetworkName\')]'
      location: '[parameters(\'Location\')]'
      extendedLocation: {
        type: 'CustomLocation'
        name: '[variables(\'effectiveCustomLocationId\')]'
      }
      tags: {}
      properties: {
        subnets: [
          {
            name: '[parameters(\'LogicalNetworkName\')]'
            properties: {
              ipAllocationMethod: '[parameters(\'IpAllocationMethod\')]'
              addressPrefix: '[if(not(empty(parameters(\'AddressPrefix\'))), parameters(\'AddressPrefix\'), if(empty(if(equals(int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)), 24), format(\'{0}.{1}.{2}.0\', split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[0], split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[1], split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[2]), if(equals(int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)), 16), format(\'{0}.{1}.0.0\', split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[0], split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[1]), if(equals(int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)), 8), format(\'{0}.0.0.0\', split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[0]), \'\')))), \'\', format(\'{0}/{1}\', if(equals(int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)), 24), format(\'{0}.{1}.{2}.0\', split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[0], split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[1], split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[2]), if(equals(int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)), 16), format(\'{0}.{1}.0.0\', split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[0], split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[1]), if(equals(int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)), 8), format(\'{0}.0.0.0\', split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[0]), \'\'))), int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)))))]'
              vlan: '[parameters(\'Vlan\')]'
              ipPools: [
                {
                  name: '[format(\'{0}_ippool\', parameters(\'LogicalNetworkName\'))]'
                  start: '[parameters(\'StartIp\')]'
                  end: '[parameters(\'EndIp\')]'
                }
              ]
              routeTable: {
                properties: {
                  routes: [
                    {
                      name: '[parameters(\'LogicalNetworkName\')]'
                      properties: {
                        addressPrefix: '0.0.0.0/0'
                        nextHopIpAddress: '[if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\'))]'
                      }
                    }
                  ]
                }
              }
            }
          }
        ]
        vmSwitchName: '[if(not(empty(parameters(\'VmSwitchName\'))), parameters(\'VmSwitchName\'), format(\'ConvergedSwitch({0})\', toLower(reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.hostNetwork.intents[0].name)))]'
        dhcpOptions: {
          dnsServers: '[if(empty(parameters(\'DnsServers\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].dnsServers, parameters(\'DnsServers\'))]'
        }
      }
    }
    {
      copy: {
        name: 'dataDisks'
        count: '[length(range(0, parameters(\'NumberDataDisks\')))]'
      }
      type: 'Microsoft.AzureStackHCI/virtualHardDisks'
      apiVersion: '2025-04-01-preview'
      name: '[format(\'{0}-datadisk{1}\', variables(\'effectiveVmName\'), range(0, parameters(\'NumberDataDisks\'))[copyIndex()])]'
      location: '[parameters(\'Location\')]'
      extendedLocation: {
        type: 'CustomLocation'
        name: '[variables(\'effectiveCustomLocationId\')]'
      }
      properties: {
        diskSizeGB: '[parameters(\'DiskSizeGB\')]'
        dynamic: true
      }
    }
    {
      type: 'Microsoft.HybridCompute/machines'
      apiVersion: '2023-06-20-preview'
      name: '[variables(\'effectiveVmName\')]'
      location: '[parameters(\'Location\')]'
      kind: 'HCI'
      identity: {
        type: 'SystemAssigned'
      }
    }
    {
      type: 'Microsoft.AzureStackHCI/networkInterfaces'
      apiVersion: '2025-04-01-preview'
      name: '[variables(\'effectiveVmName\')]'
      location: '[parameters(\'Location\')]'
      extendedLocation: {
        type: 'CustomLocation'
        name: '[variables(\'effectiveCustomLocationId\')]'
      }
      properties: {
        ipConfigurations: [
          {
            name: '[variables(\'effectiveVmName\')]'
            properties: {
              gateway: '[if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\'))]'
              privateIPAddress: '[parameters(\'StartIp\')]'
              subnet: {
                id: '[resourceId(\'Microsoft.AzureStackHCI/logicalNetworks\', parameters(\'LogicalNetworkName\'))]'
              }
            }
          }
        ]
      }
      dependsOn: [
        '[resourceId(\'Microsoft.AzureStackHCI/logicalNetworks\', parameters(\'LogicalNetworkName\'))]'
      ]
    }
    {
      type: 'Microsoft.Resources/deployments'
      apiVersion: '2022-09-01'
      name: 'ghes-secrets'
      properties: {
        mode: 'Incremental'
        expressionEvaluationOptions: {
          scope: 'inner'
        }
        parameters: {
          Location: { value: '[parameters(\'Location\')]' }
          VmName: { value: '[variables(\'effectiveVmName\')]' }
          CustomLocationId: { value: '[variables(\'effectiveCustomLocationId\')]' }
          ImageId: { value: '[variables(\'effectiveImageId\')]' }
          StoragePathId: { value: '[parameters(\'StoragePathId\')]' }
          AdminUsername: { value: '[parameters(\'AdminUsername\')]' }
          CPU: { value: '[parameters(\'CPU\')]' }
          Memory: { value: '[parameters(\'Memory\')]' }
          NumberDataDisks: { value: '[parameters(\'NumberDataDisks\')]' }
          DiskSizeGB: { value: '[parameters(\'DiskSizeGB\')]' }
          RunCommandName: { value: '[parameters(\'RunCommandName\')]' }
          AsyncExecution: { value: '[parameters(\'AsyncExecution\')]' }
          ApplyTimeoutMinutes: { value: '[parameters(\'ApplyTimeoutMinutes\')]' }
          ReadyTimeoutMinutes: { value: '[parameters(\'ReadyTimeoutMinutes\')]' }
          SkipApply: { value: '[parameters(\'SkipApply\')]' }
          SubdomainIsolation: { value: '[parameters(\'SubdomainIsolation\')]' }
          SignupEnabled: { value: '[parameters(\'SignupEnabled\')]' }
          PublicPages: { value: '[parameters(\'PublicPages\')]' }
          ManagePort: { value: '[parameters(\'ManagePort\')]' }
          PostConfigScriptUri: {
            value: '[concat(reference(resourceId(\'Microsoft.Storage/storageAccounts\', variables(\'scriptStorageAccountName\')), \'2023-05-01\').primaryEndpoints.blob, variables(\'scriptContainerName\'), \'/\', variables(\'scriptBlobName\'), \'?\', listServiceSas(resourceId(\'Microsoft.Storage/storageAccounts\', variables(\'scriptStorageAccountName\')), \'2023-05-01\', variables(\'scriptSasRequest\')).serviceSasToken)]'
          }
          ManagementConsolePassword: {
            reference: {
              keyVault: { id: '[parameters(\'KeyVaultId\')]' }
              secretName: '[parameters(\'ManagementConsolePasswordKeyName\')]'
            }
          }
          LicenseBase64Part1: {
            reference: {
              keyVault: { id: '[parameters(\'KeyVaultId\')]' }
              secretName: '[parameters(\'LicenseBase64Part1KeyName\')]'
            }
          }
          LicenseBase64Part2: {
            reference: {
              keyVault: { id: '[parameters(\'KeyVaultId\')]' }
              secretName: '[parameters(\'LicenseBase64Part2KeyName\')]'
            }
          }
          GithubHostName: {
            value: '[if(not(empty(parameters(\'GithubHostName\'))), parameters(\'GithubHostName\'), format(\'{0}.{1}\', parameters(\'GithubHostLabel\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.domainFqdn))]'
          }
          AdminPassword: {
            reference: {
              keyVault: { id: '[parameters(\'KeyVaultId\')]' }
              secretName: '[parameters(\'AdminPasswordKeyName\')]'
            }
          }
        }
        template: {
          '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
          contentVersion: '1.0.0.0'
          parameters: {
            Location: { type: 'string' }
            VmName: { type: 'string' }
            CustomLocationId: { type: 'string' }
            ImageId: { type: 'string' }
            StoragePathId: { type: 'string' }
            AdminUsername: { type: 'string' }
            AdminPassword: { type: 'securestring' }
            CPU: { type: 'int' }
            Memory: { type: 'int' }
            NumberDataDisks: { type: 'int' }
            DiskSizeGB: { type: 'int' }
            RunCommandName: { type: 'string' }
            AsyncExecution: { type: 'bool' }
            ApplyTimeoutMinutes: { type: 'int' }
            ReadyTimeoutMinutes: { type: 'int' }
            SkipApply: { type: 'bool' }
            SubdomainIsolation: { type: 'bool' }
            SignupEnabled: { type: 'bool' }
            PublicPages: { type: 'bool' }
            ManagePort: { type: 'int' }
            PostConfigScriptUri: { type: 'securestring' }
            GithubHostName: { type: 'string' }
            ManagementConsolePassword: { type: 'securestring' }
            LicenseBase64Part1: { type: 'securestring' }
            LicenseBase64Part2: { type: 'securestring' }
          }
          resources: [
            {
              type: 'Microsoft.AzureStackHCI/virtualMachineInstances'
              apiVersion: '2025-04-01-preview'
              scope: '[resourceId(\'Microsoft.HybridCompute/machines\', parameters(\'VmName\'))]'
              name: 'default'
              extendedLocation: {
                type: 'CustomLocation'
                name: '[parameters(\'CustomLocationId\')]'
              }
              properties: {
                osProfile: {
                  adminUsername: '[parameters(\'AdminUsername\')]'
                  adminPassword: '[parameters(\'AdminPassword\')]'
                  computerName: '[parameters(\'VmName\')]'
                  linuxConfiguration: {
                    provisionVMAgent: true
                    provisionVMConfigAgent: true
                  }
                }
                hardwareProfile: {
                  vmSize: 'Default'
                  processors: '[parameters(\'CPU\')]'
                  memoryMB: '[parameters(\'Memory\')]'
                }
                securityProfile: {
                  uefiSettings: {
                    secureBootEnabled: false
                  }
                }
                storageProfile: {
                  copy: [
                    {
                      name: 'dataDisks'
                      count: '[length(range(0, parameters(\'NumberDataDisks\')))]'
                      input: {
                        id: '[resourceId(\'Microsoft.AzureStackHCI/virtualHardDisks\', format(\'{0}-datadisk{1}\', parameters(\'VmName\'), range(0, parameters(\'NumberDataDisks\'))[copyIndex(\'dataDisks\')]))]'
                      }
                    }
                  ]
                  imageReference: {
                    id: '[parameters(\'ImageId\')]'
                  }
                  vmConfigStoragePathId: '[parameters(\'StoragePathId\')]'
                }
                networkProfile: {
                  networkInterfaces: [
                    {
                      id: '[resourceId(\'Microsoft.AzureStackHCI/networkInterfaces\', parameters(\'VmName\'))]'
                    }
                  ]
                }
                httpProxyConfig: {}
              }
            }
            {
              type: 'Microsoft.HybridCompute/machines/runCommands'
              apiVersion: '2024-07-10'
              name: '[format(\'{0}/{1}\', parameters(\'VmName\'), parameters(\'RunCommandName\'))]'
              location: '[parameters(\'Location\')]'
              properties: {
                asyncExecution: '[parameters(\'AsyncExecution\')]'
                timeoutInSeconds: '[mul(add(add(parameters(\'ReadyTimeoutMinutes\'), parameters(\'ApplyTimeoutMinutes\')), 30), 60)]'
                source: {
                  scriptUri: '[parameters(\'PostConfigScriptUri\')]'
                }
                parameters: [
                  {
                    name: 'GHES_HOSTNAME'
                    value: '[parameters(\'GithubHostName\')]'
                  }
                  {
                    name: 'GHES_SUBDOMAIN_ISOLATION'
                    value: '[string(parameters(\'SubdomainIsolation\'))]'
                  }
                  {
                    name: 'GHES_SIGNUP_ENABLED'
                    value: '[string(parameters(\'SignupEnabled\'))]'
                  }
                  {
                    name: 'GHES_PUBLIC_PAGES'
                    value: '[string(parameters(\'PublicPages\'))]'
                  }
                  {
                    name: 'GHES_MANAGE_PORT'
                    value: '[string(parameters(\'ManagePort\'))]'
                  }
                  {
                    name: 'GHES_APPLY_TIMEOUT_MIN'
                    value: '[string(parameters(\'ApplyTimeoutMinutes\'))]'
                  }
                  {
                    name: 'GHES_READY_TIMEOUT_MIN'
                    value: '[string(parameters(\'ReadyTimeoutMinutes\'))]'
                  }
                  {
                    name: 'GHES_SKIP_APPLY'
                    value: '[string(parameters(\'SkipApply\'))]'
                  }
                ]
                protectedParameters: [
                  {
                    name: 'GHES_MGMT_PASSWORD'
                    value: '[parameters(\'ManagementConsolePassword\')]'
                  }
                  {
                    name: 'GHES_LICENSE_B64_PART1'
                    value: '[parameters(\'LicenseBase64Part1\')]'
                  }
                  {
                    name: 'GHES_LICENSE_B64_PART2'
                    value: '[parameters(\'LicenseBase64Part2\')]'
                  }
                ]
              }
              dependsOn: [
                '[extensionResourceId(resourceId(\'Microsoft.HybridCompute/machines\', parameters(\'VmName\')), \'Microsoft.AzureStackHCI/virtualMachineInstances\', \'default\')]'
              ]
            }
          ]
        }
      }
      dependsOn: [
        '[resourceId(\'Microsoft.Resources/deployments\', \'upload-ghes-post-config\')]'
        '[resourceId(\'Microsoft.HybridCompute/machines\', variables(\'effectiveVmName\'))]'
        'dataDisks'
        '[resourceId(\'Microsoft.AzureStackHCI/galleryImages\', parameters(\'ImageName\'))]'
        '[resourceId(\'Microsoft.AzureStackHCI/networkInterfaces\', variables(\'effectiveVmName\'))]'
      ]
    }
  ]
  outputs: {
    imageId: {
      type: 'string'
      metadata: {
        description: 'Resource ID of the gallery image used by the VM (created or existing).'
      }
      value: '[variables(\'effectiveImageId\')]'
    }
    logicalNetworkId: {
      type: 'string'
      metadata: {
        description: 'Resource ID of the created logical network.'
      }
      value: '[resourceId(\'Microsoft.AzureStackHCI/logicalNetworks\', parameters(\'LogicalNetworkName\'))]'
    }
    machineId: {
      type: 'string'
      metadata: {
        description: 'Resource ID of the Arc HybridCompute machine.'
      }
      value: '[resourceId(\'Microsoft.HybridCompute/machines\', variables(\'effectiveVmName\'))]'
    }
    runCommandResourceId: {
      type: 'string'
      metadata: {
        description: 'Resource ID of the post-config Run Command.'
      }
      value: '[resourceId(\'Microsoft.HybridCompute/machines/runCommands\', variables(\'effectiveVmName\'), parameters(\'RunCommandName\'))]'
    }
    resolvedCustomLocationId: {
      type: 'string'
      metadata: {
        description: 'Resolved custom location resource ID.'
      }
      value: '[variables(\'effectiveCustomLocationId\')]'
    }
    resolvedGateway: {
      type: 'string'
      metadata: {
        description: 'Resolved default gateway.'
      }
      value: '[if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\'))]'
    }
    resolvedAddressPrefix: {
      type: 'string'
      metadata: {
        description: 'Resolved subnet CIDR (address prefix).'
      }
      value: '[if(not(empty(parameters(\'AddressPrefix\'))), parameters(\'AddressPrefix\'), if(empty(if(equals(int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)), 24), format(\'{0}.{1}.{2}.0\', split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[0], split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[1], split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[2]), if(equals(int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)), 16), format(\'{0}.{1}.0.0\', split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[0], split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[1]), if(equals(int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)), 8), format(\'{0}.0.0.0\', split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[0]), \'\')))), \'\', format(\'{0}/{1}\', if(equals(int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)), 24), format(\'{0}.{1}.{2}.0\', split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[0], split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[1], split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[2]), if(equals(int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)), 16), format(\'{0}.{1}.0.0\', split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[0], split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[1]), if(equals(int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)), 8), format(\'{0}.0.0.0\', split(if(empty(parameters(\'DefaultGateway\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].gateway, parameters(\'DefaultGateway\')), \'.\')[0]), \'\'))), int(coalesce(tryGet(variables(\'maskToPrefix\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].subnetMask), 0)))))]'
    }
    resolvedDnsServers: {
      type: 'array'
      metadata: {
        description: 'Resolved DNS servers.'
      }
      value: '[if(empty(parameters(\'DnsServers\')), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.infrastructureNetwork[0].dnsServers, parameters(\'DnsServers\'))]'
    }
    resolvedVmSwitchName: {
      type: 'string'
      metadata: {
        description: 'Resolved VM switch name.'
      }
      value: '[if(not(empty(parameters(\'VmSwitchName\'))), parameters(\'VmSwitchName\'), format(\'ConvergedSwitch({0})\', toLower(reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.hostNetwork.intents[0].name)))]'
    }
    resolvedDomainFqdn: {
      type: 'string'
      metadata: {
        description: 'Resolved AD domain FQDN.'
      }
      value: '[reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.domainFqdn]'
    }
    resolvedVmName: {
      type: 'string'
      metadata: {
        description: 'Resolved VM name.'
      }
      value: '[variables(\'effectiveVmName\')]'
    }
    resolvedGithubHostName: {
      type: 'string'
      metadata: {
        description: 'Resolved GHES hostname (FQDN).'
      }
      value: '[if(not(empty(parameters(\'GithubHostName\'))), parameters(\'GithubHostName\'), format(\'{0}.{1}\', parameters(\'GithubHostLabel\'), reference(resourceId(\'Microsoft.AzureStackHCI/clusters/deploymentSettings\', split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[0], split(format(\'{0}/default\', parameters(\'clusterName\')), \'/\')[1]), \'2024-04-01\').deploymentConfiguration.scaleUnits[0].deploymentData.domainFqdn))]'
    }
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: KeyVaultName
  location: Location
  properties: {
    tenantId: TenantId
    sku: {
      family: 'A'
      name: KeyVaultSkuName
    }
    enableRbacAuthorization: EnableRbacAuthorization
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: SoftDeleteRetentionInDays
    publicNetworkAccess: 'Enabled'
  }
}

resource adminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: AdminPasswordSecretName
  properties: {
    value: AdminPassword
    contentType: 'GHES VM administrator password'
  }
}

resource managementConsolePasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: ManagementConsolePasswordSecretName
  properties: {
    value: ManagementConsolePassword
    contentType: 'GHES management-console password'
  }
}

// Split the base64 license into two halves so each fits under Key Vault's
// 25,600-character secret value limit (a real .ghl base64 is ~27 KB).
var licenseLength = length(LicenseBase64)
var licenseHalf = licenseLength / 2
var licensePart1 = substring(LicenseBase64, 0, licenseHalf)
var licensePart2 = substring(LicenseBase64, licenseHalf, licenseLength - licenseHalf)

resource licensePart1Secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: LicensePart1SecretName
  properties: {
    value: licensePart1
    contentType: 'GHES license base64 (part 1 of 2)'
  }
}

resource licensePart2Secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: LicensePart2SecretName
  properties: {
    value: licensePart2
    contentType: 'GHES license base64 (part 2 of 2)'
  }
}

resource ghesTemplateSpec 'Microsoft.Resources/templateSpecs@2022-02-01' = {
  name: ghesSpecName
  location: Location
  properties: {
    displayName: 'GitHub Enterprise Server on Azure Local'
    description: 'Self-published GHES infrastructure template used by the Workload Orchestration solution.'
  }
}

resource ghesTemplateSpecVersion 'Microsoft.Resources/templateSpecs/versions@2022-02-01' = {
  parent: ghesTemplateSpec
  name: ghesSpecVersion
  location: Location
  properties: {
    description: 'GHES image, logical network, VM, and post-configuration resources.'
    mainTemplate: ghesTemplate
  }
}

@description('Leave blank if tenant has no context.')
param existingContextId string = ''

var createContext = empty(existingContextId)

resource newContext 'Microsoft.Edge/contexts@2026-03-01' = if (createContext) {
  name: contextName
  location: Location
  properties: {
    capabilities: [
      {
        name: infraCapabilityName
        description: 'Capability used by the GHES deployment.'
        state: 'active'
      }
    ]
    hierarchies: [
      {
        name: contextHierarchyName
        description: 'Hierarchy used by the GHES cloud target.'
      }
    ]
  }
}

var contextIdParts = split(
  createContext
    ? resourceId('Microsoft.Edge/contexts', contextName)
    : existingContextId,
  '/'
)
var existingContextSubscriptionId = contextIdParts[2]
var existingContextResourceGroup = contextIdParts[4]
var existingContextName = contextIdParts[8]

resource existingContext 'Microsoft.Edge/contexts@2026-03-01' existing = if (!createContext) {
  name: existingContextName
  scope: resourceGroup(existingContextSubscriptionId, existingContextResourceGroup)
}

var existingCapabilities = createContext
  ? []
  : existingContext!.properties.capabilities
var existingCapabilityNames = map(existingCapabilities, capability => capability.name)
var mergedCapabilities = contains(existingCapabilityNames, infraCapabilityName)
  ? existingCapabilities
  : concat(existingCapabilities, [
      {
        name: infraCapabilityName
        description: 'Capability used by the GHES deployment.'
        state: 'active'
      }
    ])

var existingHierarchies = createContext
  ? []
  : existingContext!.properties.hierarchies
var effectiveHierarchies = empty(existingHierarchies)
  ? [
      {
        name: contextHierarchyName
        description: 'Hierarchy used by the GHES cloud target.'
      }
    ]
  : existingHierarchies
var effectiveHierarchyName = last(effectiveHierarchies).name

module updateExistingContext './BicepTemplates/ghes-all/update-context.bicep' = if (!createContext) {
  scope: resourceGroup(existingContextSubscriptionId, existingContextResourceGroup)
  params: {
    contextName: existingContextName
    location: createContext ? Location : existingContext!.location
    tags: createContext ? {} : existingContext!.tags ?? {}
    capabilities: mergedCapabilities
    hierarchies: effectiveHierarchies
  }
}

var effectiveContextId = createContext
  ? resourceId('Microsoft.Edge/contexts', contextName)
  : existingContextId

resource cloudTarget 'Microsoft.Edge/targets@2026-05-01-preview' = {
  name: cloudTargetName
  location: Location
  dependsOn: [
    newContext
    updateExistingContext
  ]
  properties: {
    capabilities: [
      infraCapabilityName
    ]
    contextId: effectiveContextId
    description: 'Cloud target for ARM template infrastructure deployment'
    displayName: 'Cloud Infrastructure Target'
    hierarchyLevel: effectiveHierarchyName
  }
}

resource capabilityPropagationDelay 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'ghes-capability-delay'
  location: Location
  kind: 'AzureCLI'
  dependsOn: [
    cloudTarget
  ]
  properties: {
    azCliVersion: '2.89.1'
    scriptContent: 'sleep 5'
    timeout: 'PT5M'
    cleanupPreference: 'Always'
    retentionInterval: 'P1D'
    forceUpdateTag: deployment().name
  }
}

resource ghesSolutionTemplate 'Microsoft.Edge/solutionTemplates@2026-03-01' = {
  name: ghesSolutionTemplateName
  location: Location
  dependsOn: [
    capabilityPropagationDelay
  ]
  properties: {
    description: 'GHES solution template with a private blob-backed post-configuration script.'
    capabilities: [
      infraCapabilityName
    ]
  }

  resource solutionVersion 'versions@2026-05-01-preview' = {
    name: ghesSolutionTemplateVersionName
    properties: {
      configurations: {
        configs: {
          clusterName: clusterName
          ImageName: VmImageName
          CustomLocationId: CustomLocationId
          LocalSharePath: LocalSharePath
          StoragePathId: StoragePathId
          CreateImage: CreateImage
          ExistingImageResourceId: ExistingImageResourceId
          LogicalNetworkName: LogicalNetworkName
          IpAllocationMethod: IpAllocationMethod
          AddressPrefix: AddressPrefix
          Vlan: Vlan
          Location: Location
          VmSwitchName: VmSwitchName
          StartIp: StartIp
          EndIp: EndIp
          DnsServers: DnsServers
          DefaultGateway: DefaultGateway
          VmName: VmName
          VmNamePrefix: VmNamePrefix
          KeyVaultId: keyVault.id
          AdminUsername: AdminUsername
          AdminPasswordKeyName: adminPasswordSecret.name
          CPU: CPU
          Memory: Memory
          NumberDataDisks: NumberDataDisks
          DiskSizeGB: DiskSizeGB
          ManagementConsolePasswordKeyName: managementConsolePasswordSecret.name
          GithubHostName: GithubHostName
          GithubHostLabel: GithubHostLabel
          LicenseBase64Part1KeyName: licensePart1Secret.name
          LicenseBase64Part2KeyName: licensePart2Secret.name
          SubdomainIsolation: SubdomainIsolation
          SignupEnabled: SignupEnabled
          PublicPages: PublicPages
          ManagePort: ManagePort
          ApplyTimeoutMinutes: ApplyTimeoutMinutes
          ReadyTimeoutMinutes: ReadyTimeoutMinutes
          SkipApply: SkipApply
          AsyncExecution: AsyncExecution
          RunCommandName: RunCommandName
        }
      }
      specification: {
        components: [
          {
            name: 'ghesAll'
            type: 'armtemplate'
            properties: {
              template: {
                subscriptionId: subscription().subscriptionId
                resourceGroupName: resourceGroup().name
                name: ghesTemplateSpec.name
                version: ghesTemplateSpecVersion.name
              }
            }
          }
        ]
      }
    }
  }
}

resource ghesDeployment 'Microsoft.Edge/solutionDeployments@2026-05-01-preview' = {
  name: 'ghesDeployment'
  location: Location
  dependsOn: [
    ghesSolutionTemplate::solutionVersion
  ]
  properties: {
    solutionTemplateProperties: {
      name: ghesSolutionTemplateName
      version: ghesSolutionTemplateVersionName
    }
    targetProperties: {
      targetIds: [
        cloudTarget.id
      ]
    }
  }
}

@description('Resource ID of the Key Vault containing the GHES passwords.')
output keyVaultResourceId string = keyVault.id

@description('URI of the Key Vault containing the GHES passwords.')
output keyVaultUri string = keyVault.properties.vaultUri

@description('Resource ID of the GHES Template Spec version created by this deployment.')
output templateSpecVersionId string = ghesTemplateSpecVersion.id

@description('Resource ID of the Workload Orchestration Solution Deployment.')
output solutionDeploymentId string = ghesDeployment.id

@description('Resource ID of the Microsoft.Edge context used by the cloud target.')
output contextResourceId string = effectiveContextId
