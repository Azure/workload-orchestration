// ghes.bicep
// Template spec that deploys a GitHub Enterprise Server (GHES) instance on Azure Local in one
// deployment: gallery image, logical network, VM, Key Vault and post-config Run Command. See README.md for details.

// ===================== Cluster / auto-resolution =====================
// The single value that unlocks agentless auto-resolution of networking/infra from the
// cluster's Microsoft.AzureStackHCI/clusters/<cluster>/deploymentSettings/default resource.
@description('Azure Local cluster name; its deploymentSettings/default supplies domain/gateway/DNS/subnet/switch, and its custom location is derived by convention.')
param clusterName string

// ===================== Image (create-image) =====================
@description('Name for the VM image.')
param ImageName string = 'ghes-image'

@description('OVERRIDE: Resource ID of the custom location for Azure Local. Blank => derived by convention <clusterName>-customlocation.')
param CustomLocationId string = ''

@description('Local file share path for the source image (VHDX). Required only when CreateImage=true.')
param LocalSharePath string = ''

@description('Resource ID of the storage path (container) where the image is stored.')
param StoragePathId string

@description('Create the gallery image (true) or reference an existing one (false). Set false on redeploys against an existing image.')
param CreateImage bool = true

@description('When CreateImage=false: Resource ID of an existing gallery image. Blank => the image named <ImageName> in this resource group.')
param ExistingImageResourceId string = ''

// ===================== Logical network (create-lnet) =====================
@description('Name of the logical network resource.')
param LogicalNetworkName string = 'ghes-lnet'

@description('IP allocation method for the subnet (e.g. Static).')
param IpAllocationMethod string = 'Static'

@description('OVERRIDE: CIDR address prefix for the subnet (e.g. 10.0.0.0/24). Blank => derived from deploymentSettings subnetMask + gateway (octet-aligned masks /8,/16,/24). REQUIRED for non-octet-aligned masks.')
param AddressPrefix string = ''

@description('VLAN ID for the subnet (0-4094). Use 0 for untagged.')
@minValue(0)
@maxValue(4094)
param Vlan int = 0

@description('Azure region/location for the deployment metadata.')
param Location string = resourceGroup().location

@description('OVERRIDE: Name of the Hyper-V virtual switch. Blank => derived from deploymentSettings host-network intent (ConvergedSwitch(<intent>)).')
param VmSwitchName string = ''

@description('Static IP for the GHES VM; also the start of the workload IP pool (NOT in deploymentSettings).')
param StartIp string

@description('End of the workload IP pool (NOT in deploymentSettings).')
param EndIp string

@description('OVERRIDE: One or more DNS server IP addresses. Empty array => from deploymentSettings.')
param DnsServers array = []

@description('OVERRIDE: Default gateway IP address for the subnet. Blank => from deploymentSettings.')
param DefaultGateway string = ''

// ===================== VM (create-vm) =====================
@description('OVERRIDE: Name of the virtual machine / Arc machine to create. Blank => <VmNamePrefix>-1.')
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

// ===================== Key Vault (create-kv) =====================
@description('Key Vault name (3-24 chars, globally unique, alphanumeric and dashes).')
@minLength(3)
@maxLength(24)
param KeyVaultName string

@description('Entra tenant ID that owns the vault. Defaults to the deployment tenant.')
param TenantId string = subscription().tenantId

@description('Key Vault SKU.')
@allowed([
  'standard'
  'premium'
])
param KeyVaultSkuName string = 'standard'

@description('Use Azure RBAC for data-plane authorization (recommended) instead of access policies.')
param EnableRbacAuthorization bool = true

@description('Soft-delete retention in days.')
@minValue(7)
@maxValue(90)
param SoftDeleteRetentionInDays int = 7

@description('OPTIONAL: GHES management-console password to seed. Blank => not seeded here.')
@secure()
param ManagementConsolePassword string = ''

@description('Secret name for the management-console password.')
param ManagementConsolePasswordSecretName string = 'ghes-mgmt-console-password'

@description('Secret name for the admin password.')
param AdminPasswordSecretName string = 'ghes-admin-password'

// ===================== Post-Config (create-postconfig) =====================
@description('OVERRIDE: full GHES hostname (FQDN). Blank => <GithubHostLabel>.<domainFqdn-from-deploymentSettings>.')
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
// Agentless auto-resolution from the cluster deploymentSettings
// (no node Invoke-Command / blueprint file). Any explicit param wins.
// ============================================================
resource ds 'Microsoft.AzureStackHCI/clusters/deploymentSettings@2024-04-01' existing = {
  name: '${clusterName}/default'
}

var dd = ds.properties.deploymentConfiguration.scaleUnits[0].deploymentData
var infra = dd.infrastructureNetwork[0]

// Custom location: derived by the standard Azure Local convention (<clusterName>-customlocation).
// .id only builds the resource-id string (no runtime GET), so this is safe even when overridden.
resource customLocation 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: '${clusterName}-customlocation'
}
var effectiveCustomLocationId = empty(CustomLocationId) ? customLocation.id : CustomLocationId

// subnet mask -> prefix length (octet-aligned only; other masks require AddressPrefix override).
var maskToPrefix = {
  '255.0.0.0': 8
  '255.255.0.0': 16
  '255.255.255.0': 24
}

var effectiveGateway = empty(DefaultGateway) ? infra.gateway : DefaultGateway
var gwOctets = split(effectiveGateway, '.')
var prefixLen = int(maskToPrefix[?infra.subnetMask] ?? 0)
var derivedNetwork = prefixLen == 24 ? '${gwOctets[0]}.${gwOctets[1]}.${gwOctets[2]}.0' : (prefixLen == 16 ? '${gwOctets[0]}.${gwOctets[1]}.0.0' : (prefixLen == 8 ? '${gwOctets[0]}.0.0.0' : ''))
var derivedCidr = empty(derivedNetwork) ? '' : '${derivedNetwork}/${prefixLen}'

var effectiveAddressPrefix = !empty(AddressPrefix) ? AddressPrefix : derivedCidr
var effectiveDnsServers = empty(DnsServers) ? infra.dnsServers : DnsServers
var effectiveVmSwitchName = !empty(VmSwitchName) ? VmSwitchName : 'ConvergedSwitch(${toLower(dd.hostNetwork.intents[0].name)})'
var effectiveDomainFqdn = dd.domainFqdn
var effectiveVmName = empty(VmName) ? '${VmNamePrefix}-1' : VmName
var effectiveGithubHostName = !empty(GithubHostName) ? GithubHostName : '${GithubHostLabel}.${effectiveDomainFqdn}'
var effectiveImageId = CreateImage ? galleryImage.id : (empty(ExistingImageResourceId) ? resourceId('Microsoft.AzureStackHCI/galleryImages', ImageName) : ExistingImageResourceId)


// ============================================================
// 1) Gallery image
// ============================================================
resource galleryImage 'Microsoft.AzureStackHCI/galleryImages@2025-04-01-preview' = if (CreateImage) {
  name: ImageName
  location: Location
  extendedLocation: {
    name: effectiveCustomLocationId
    type: 'CustomLocation'
  }
  tags: {}
  properties: {
    osType: 'Linux'
    hyperVGeneration: 'V2'
    containerId: StoragePathId
    imagePath: LocalSharePath
  }
}

// ============================================================
// 2) Logical network
// ============================================================
resource logicalNetwork 'Microsoft.AzureStackHCI/logicalNetworks@2025-04-01-preview' = {
  name: LogicalNetworkName
  location: Location
  extendedLocation: {
    type: 'CustomLocation'
    name: effectiveCustomLocationId
  }
  tags: {}
  properties: {
    subnets: [
      {
        name: LogicalNetworkName
        properties: {
          ipAllocationMethod: IpAllocationMethod
          addressPrefix: effectiveAddressPrefix
          vlan: Vlan
          ipPools: [
            {
              name: '${LogicalNetworkName}_ippool'
              start: StartIp
              end: EndIp
            }
          ]
          routeTable: {
            properties: {
              routes: [
                {
                  name: LogicalNetworkName
                  properties: {
                    addressPrefix: '0.0.0.0/0'
                    nextHopIpAddress: effectiveGateway
                  }
                }
              ]
            }
          }
        }
      }
    ]
    vmSwitchName: effectiveVmSwitchName
    dhcpOptions: {
      dnsServers: effectiveDnsServers
    }
  }
}

// ============================================================
// 3) VM (data disks + Arc machine + NIC + VM instance)
// ============================================================
resource dataDisks 'Microsoft.AzureStackHCI/virtualHardDisks@2025-04-01-preview' = [
  for i in range(0, NumberDataDisks): {
    name: '${effectiveVmName}-datadisk${i}'
    location: Location
    extendedLocation: {
      type: 'CustomLocation'
      name: effectiveCustomLocationId
    }
    properties: {
      diskSizeGB: DiskSizeGB
      dynamic: true
    }
  }
]

resource arcMachine 'Microsoft.HybridCompute/machines@2023-06-20-preview' = {
  name: effectiveVmName
  location: Location
  kind: 'HCI'
  identity: {
    type: 'SystemAssigned'
  }
}

resource networkInterface 'Microsoft.AzureStackHCI/networkInterfaces@2025-04-01-preview' = {
  name: effectiveVmName
  location: Location
  extendedLocation: {
    type: 'CustomLocation'
    name: effectiveCustomLocationId
  }
  properties: {
    ipConfigurations: [
      {
        name: effectiveVmName
        properties: {
          gateway: effectiveGateway
          privateIPAddress: StartIp
          subnet: {
            id: logicalNetwork.id
          }
        }
      }
    ]
  }
}

resource virtualMachineInstance 'Microsoft.AzureStackHCI/virtualMachineInstances@2025-04-01-preview' = {
  name: 'default'
  scope: arcMachine
  extendedLocation: {
    type: 'CustomLocation'
    name: effectiveCustomLocationId
  }
  properties: {
    osProfile: {
      adminUsername: AdminUsername
      adminPassword: AdminPassword
      computerName: effectiveVmName
      linuxConfiguration: {
        provisionVMAgent: true
        provisionVMConfigAgent: true
      }
    }
    hardwareProfile: {
      vmSize: 'Default'
      processors: CPU
      memoryMB: Memory
    }
    securityProfile: {
      uefiSettings: {
        secureBootEnabled: false
      }
    }
    storageProfile: {
      imageReference: {
        id: effectiveImageId
      }
      vmConfigStoragePathId: StoragePathId
      dataDisks: [
        for i in range(0, NumberDataDisks): {
          id: dataDisks[i].id
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
        }
      ]
    }
    httpProxyConfig: {}
  }
}

// ============================================================
// 4) Key Vault (+ optional secrets)
// ============================================================
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

resource mgmtSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(ManagementConsolePassword)) {
  parent: keyVault
  name: ManagementConsolePasswordSecretName
  properties: {
    value: ManagementConsolePassword
    contentType: 'GHES management-console password'
  }
}

resource adminSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(AdminPassword)) {
  parent: keyVault
  name: AdminPasswordSecretName
  properties: {
    value: AdminPassword
    contentType: 'GHES admin password'
  }
}

// ============================================================
// 5) Post-config Run Command (runs after the VM instance exists)
// ============================================================
#disable-next-line BCP081 // runCommands type has no local Bicep types yet; deploy-safe (validated against the live provider API versions)
resource postConfig 'Microsoft.HybridCompute/machines/runCommands@2024-07-10' = {
  parent: arcMachine
  name: RunCommandName
  location: Location
  dependsOn: [
    virtualMachineInstance
  ]
  properties: {
    asyncExecution: AsyncExecution
    // Overall script timeout: ready-wait + apply + headroom for init/settings.
    timeoutInSeconds: (ReadyTimeoutMinutes + ApplyTimeoutMinutes + 30) * 60
    source: {
      script: loadTextContent('./post-config.sh')
    }
    parameters: [
      {
        name: 'GHES_HOSTNAME'
        value: effectiveGithubHostName
      }
      {
        name: 'GHES_SUBDOMAIN_ISOLATION'
        value: string(SubdomainIsolation)
      }
      {
        name: 'GHES_SIGNUP_ENABLED'
        value: string(SignupEnabled)
      }
      {
        name: 'GHES_PUBLIC_PAGES'
        value: string(PublicPages)
      }
      {
        name: 'GHES_MANAGE_PORT'
        value: string(ManagePort)
      }
      {
        name: 'GHES_APPLY_TIMEOUT_MIN'
        value: string(ApplyTimeoutMinutes)
      }
      {
        name: 'GHES_READY_TIMEOUT_MIN'
        value: string(ReadyTimeoutMinutes)
      }
      {
        name: 'GHES_SKIP_APPLY'
        value: string(SkipApply)
      }
    ]
    protectedParameters: [
      {
        name: 'GHES_MGMT_PASSWORD'
        value: ManagementConsolePassword
      }
      {
        name: 'GHES_LICENSE_B64'
        value: LicenseBase64
      }
    ]
  }
}

// ===================== Outputs =====================
@description('Resource ID of the gallery image used by the VM (created or existing).')
output imageId string = effectiveImageId

@description('Resource ID of the created logical network.')
output logicalNetworkId string = logicalNetwork.id

@description('Resource ID of the Arc HybridCompute machine.')
output machineId string = arcMachine.id

@description('Resource ID of the Key Vault.')
output keyVaultResourceId string = keyVault.id

@description('URI of the Key Vault.')
output keyVaultUri string = keyVault.properties.vaultUri

@description('Resource ID of the post-config Run Command.')
output runCommandResourceId string = postConfig.id

// ---- Resolved (auto-sourced) values, surfaced for debugging what the spec picked ----
@description('Resolved custom location resource ID.')
output resolvedCustomLocationId string = effectiveCustomLocationId

@description('Resolved default gateway.')
output resolvedGateway string = effectiveGateway

@description('Resolved subnet CIDR (address prefix).')
output resolvedAddressPrefix string = effectiveAddressPrefix

@description('Resolved DNS servers.')
output resolvedDnsServers array = effectiveDnsServers

@description('Resolved VM switch name.')
output resolvedVmSwitchName string = effectiveVmSwitchName

@description('Resolved AD domain FQDN.')
output resolvedDomainFqdn string = effectiveDomainFqdn

@description('Resolved VM name.')
output resolvedVmName string = effectiveVmName

@description('Resolved GHES hostname (FQDN).')
output resolvedGithubHostName string = effectiveGithubHostName

