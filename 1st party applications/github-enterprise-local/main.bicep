// main.bicep
// Entry point that deploys the Workload Orchestration Cloud Target, Solution Template and
// Solution Deployment for GHES. It references the published ghes.bicep template spec. See README.md for details.

@description('Azure region/location for the deployment metadata.')
param Location string = 'eastus2'

@description('Name of the Cloud Target')
param cloudTargetName string

@description('Capability name for cloud/infra targets and solution templates')
param infraCapabilityName string

@description('Context ID for the cloud target.')
param contextId string

@description('Subscription ID hosting the single template spec.')
param subscriptionId string

@description('Resource group name hosting the single template spec.')
param resourceGroupName string

@description('Name of the single (merged) GHES solution template')
param ghesSolutionTemplateName string = 'ghes-solution-template'

@description('Name of the single (merged) GHES solution template version')
param ghesSolutionTemplateVersionName string = '1.0.0'

@description('Name of the single (merged) GHES template spec.')
param ghesSpecName string

@description('Version of the single (merged) GHES template spec.')
param ghesSpecVersion string

// ----- Cluster / auto-resolution -----
@description('Azure Local cluster name; unlocks auto-resolution of networking/infra in the spec.')
param clusterName string

// ----- Image -----
@description('OVERRIDE: Resource ID of the custom location. Blank => derived from clusterName.')
param CustomLocationId string = ''

@description('Name of the VM image.')
param VmImageName string = 'ghes-image'

@description('Local share path for the image. Required only when CreateImage=true.')
param LocalSharePath string = ''

@description('Resource ID of the storage path.')
param StoragePathId string

@description('Create the gallery image (true) or reference an existing one (false).')
param CreateImage bool = true

@description('When CreateImage=false: Resource ID of an existing gallery image. Blank => <VmImageName> in the spec RG.')
param ExistingImageResourceId string = ''

// ----- Logical network -----
@description('Name of the logical network resource.')
param LogicalNetworkName string = 'ghes-lnet'

@description('IP allocation method for the subnet (e.g. Static).')
param IpAllocationMethod string = 'Static'

@description('OVERRIDE: CIDR address prefix. Blank => derived from deploymentSettings.')
param AddressPrefix string = ''

@description('VLAN ID for the subnet (0-4094). Use 0 for untagged.')
@minValue(0)
@maxValue(4094)
param Vlan int = 0

@description('OVERRIDE: Name of the Hyper-V virtual switch. Blank => derived from deploymentSettings.')
param VmSwitchName string = ''

@description('Static IP for the GHES VM; also the start of the workload IP pool.')
param StartIp string

@description('End of the workload IP pool.')
param EndIp string

@description('OVERRIDE: DNS server IP addresses. Empty => from deploymentSettings.')
param DnsServers array = []

@description('OVERRIDE: Default gateway IP address. Blank => from deploymentSettings.')
param DefaultGateway string = ''

// ----- VM -----
@description('OVERRIDE: Name of the virtual machine / Arc machine. Blank => <VmNamePrefix>-1.')
param VmName string = ''

@description('Hostname prefix used when VmName is blank.')
param VmNamePrefix string = 'ghes'

@description('Administrator username for the VM.')
param AdminUsername string

@description('Administrator password for the VM.')
@secure()
param AdminPassword string

@description('Number of virtual processors to assign to the VM.')
param CPU int = 16

@description('Memory to assign to the VM, in MB.')
param Memory int = 32768

@description('Number of data disks to create and attach.')
@minValue(0)
param NumberDataDisks int = 1

@description('Size of each data disk in GB.')
param DiskSizeGB int = 500

// ----- Key Vault -----
@description('Key Vault name (3-24 chars, globally unique, alphanumeric and dashes).')
@minLength(3)
@maxLength(24)
param KeyVaultName string

@description('Entra tenant ID that owns the vault.')
param TenantId string = subscription().tenantId

@description('Key Vault SKU.')
@allowed([
  'standard'
  'premium'
])
param KeyVaultSkuName string = 'standard'

@description('OPTIONAL: GHES management-console password to seed. Blank => not seeded here.')
@secure()
param ManagementConsolePassword string = ''

@description('Secret name for the management-console password.')
param ManagementConsolePasswordSecretName string = 'ghes-mgmt-console-password'

@description('Secret name for the admin password.')
param AdminPasswordSecretName string = 'ghes-admin-password'

// ----- Post-Config -----
@description('OVERRIDE: full GHES hostname (FQDN). Blank => <GithubHostLabel>.<domainFqdn from deploymentSettings>.')
param GithubHostName string = ''

@description('Hostname label prepended to the domain FQDN when GithubHostName is blank.')
param GithubHostLabel string = 'githubenterpriselocal'

@description('Base64 of the GHES .ghl license file.')
@secure()
param LicenseBase64 string

@description('Enable subdomain isolation.')
param SubdomainIsolation bool = true

@description('Allow built-in signups (kept off for AD/LDAP-backed instances).')
param SignupEnabled bool = false

@description('Enable public GitHub Pages.')
param PublicPages bool = false

@description('Manage API port on the appliance.')
param ManagePort int = 8443

@description('Cap (minutes) on the on-box ghe-config-apply.')
@minValue(10)
@maxValue(1440)
param ApplyTimeoutMinutes int = 120

@description('Minutes to wait for the Manage API + init-triggered apply to settle before staging settings.')
@minValue(5)
@maxValue(240)
param ReadyTimeoutMinutes int = 30

@description('Stage settings only; skip ghe-config-apply (useful for a dry run).')
param SkipApply bool = false

@description('Run the config-apply asynchronously (deployment returns immediately). Default false so the deployment waits for completion.')
param AsyncExecution bool = false

@description('Name of the Run Command resource created on the appliance.')
param RunCommandName string = 'ghes-postconfig'

// ============================================================
// Cloud Target - for ARM template deployments (no custom location)
// ============================================================
resource cloudTarget 'Microsoft.Edge/targets@2026-05-01-preview' = {
  name: cloudTargetName
  location: Location
  properties: {
    capabilities: [
      infraCapabilityName
    ]
    contextId: contextId
    description: 'Cloud target for ARM template infrastructure deployment'
    displayName: 'Cloud Infrastructure Target'
    hierarchyLevel: 'line'
  }
}

// ============================================================
// Single (merged) GHES Solution Template + single version.
// specification.components has ONE armtemplate component pointing
// at the SINGLE merged template spec (ghesSpecName/ghesSpecVersion).
// ============================================================
resource ghesSolutionTemplate 'Microsoft.Edge/solutionTemplates@2026-03-01' = {
  name: ghesSolutionTemplateName
  location: Location
  properties: {
    description: 'Consolidated GHES solution template (image + lnet + vm + key vault + post-config) in a single template spec'
    capabilities: [
      infraCapabilityName
    ]
  }

  resource v1_0_0 'versions@2026-05-01-preview' = {
    name: ghesSolutionTemplateVersionName
    properties: {
      configurations: {
        configs: {
          // Cluster / auto-resolution
          clusterName: clusterName
          // Image
          ImageName: VmImageName
          CustomLocationId: CustomLocationId
          LocalSharePath: LocalSharePath
          StoragePathId: StoragePathId
          CreateImage: CreateImage
          ExistingImageResourceId: ExistingImageResourceId
          // Logical network
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
          // VM
          VmName: VmName
          VmNamePrefix: VmNamePrefix
          AdminUsername: AdminUsername
          AdminPassword: AdminPassword
          CPU: CPU
          Memory: Memory
          NumberDataDisks: NumberDataDisks
          DiskSizeGB: DiskSizeGB
          // Key Vault
          KeyVaultName: KeyVaultName
          TenantId: TenantId
          KeyVaultSkuName: KeyVaultSkuName
          ManagementConsolePasswordSecretName: ManagementConsolePasswordSecretName
          ManagementConsolePassword: ManagementConsolePassword
          AdminPasswordSecretName: AdminPasswordSecretName
          // Post-config
          GithubHostName: GithubHostName
          GithubHostLabel: GithubHostLabel
          LicenseBase64: LicenseBase64
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
                subscriptionId: subscriptionId
                resourceGroupName: resourceGroupName
                name: ghesSpecName
                version: ghesSpecVersion
              }
            }
          }
        ]
      }
    }
  }
}

// ============================================================
// Single Solution Deployment (ARM path) targeting the cloud target
// ============================================================
resource ghesDeployment 'Microsoft.Edge/solutionDeployments@2026-05-01-preview' = {
  name: 'ghesDeployment'
  location: Location
  dependsOn: [
    ghesSolutionTemplate::v1_0_0
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

