# Deploy GitHub Enterprise Server on Azure Local

Deploy a **GitHub Enterprise Server (GHES)** appliance on an **Azure Local** (Azure Stack HCI)
cluster through Azure **Workload Orchestration** (`Microsoft.Edge`).

`main.bicep` creates the Key Vault, publishes the infrastructure template spec, creates or
updates a Workload Orchestration context, and starts the solution deployment. **You no longer
publish a template spec separately or supply its subscription, resource group, name, or version.**
Use `main.bicepparam` for the deployment inputs.

The infrastructure template is embedded in `main.bicep`; the supporting scripts and context
module are included in `BicepTemplates\ghes-all`. Keep that folder with the entry point when
copying or deploying the application. **A separate `ghes.bicep` is no longer needed.**

## 1. What gets deployed

| Resource | Purpose |
|----------|---------|
| **Key Vault and four secrets** | Stores the VM administrator password, management-console password, and two halves of the base64 license. |
| **Template spec** (`ghesspec`, version `1.0.0`) | Publishes the embedded GHES infrastructure template in the deployment subscription and resource group. |
| **Workload Orchestration context** | Creates `defaultContext` when `existingContextId` is blank, or updates the supplied context. |
| **Cloud target, solution template, and solution deployment** | Associates the context with the `ghes-infrastructure` capability and deploys the template spec. |
| **Gallery image** (`ghes-image`) | Imports the appliance VHDX from the cluster-local share. |
| **Logical network** | Creates the subnet, static IP pool, gateway route, and DNS configuration. |
| **Virtual machine** | Creates the Arc machine, NIC, data disks, and Azure Local VM instance. The VM uses `StartIp` as its static IP. |
| **Script storage account and private blob container** | Stores `post-config.sh` in the `scripts` container. The Run Command downloads it using an HTTPS, read-only blob SAS. |
| **Deployment scripts** | Uploads the post-configuration script and adds a short capability-propagation delay before creating the solution template. Temporary script resources are cleaned up after execution. |
| **Arc Run Command** (`ghes-postconfig`) | Starts appliance post-configuration with the hostname, settings, license parts, and management-console password. |

Azure metadata resources use **`eastus`**, which is currently a variable in `main.bicep`, not a
deployment parameter. The template spec and solution template versions are both fixed at `1.0.0`.

### Context behavior

Leave `existingContextId = ''` to create `defaultContext` with the `ghes-infrastructure`
capability and a hierarchy named `line`.

When you supply an existing `Microsoft.Edge/contexts` resource ID, the template preserves its
capabilities and adds `ghes-infrastructure` if missing. It keeps existing hierarchies, or adds
`line` when none exist, and uses the last hierarchy for the cloud target. The context may be in
another resource group or subscription; deployment permissions must cover that scope too.

### Automatic cluster configuration

The embedded template reads the named cluster's `deploymentSettings/default` to resolve:

| Value | Resolution |
|-------|------------|
| Subnet CIDR | Derived from the first infrastructure network's gateway and subnet mask; supports `/8`, `/16`, and `/24` masks only. |
| DNS servers and gateway | Taken from the first infrastructure network. |
| Virtual switch | `ConvergedSwitch(<first-host-network-intent-name-in-lowercase>)`. |
| GHES hostname | `githubenterpriselocal.<domainFqdn>` from the first scale unit's deployment data. |
| Custom location | Resource ID constructed as `<clusterName>-customlocation` in the solution's resource group. This is a naming convention, not a deployment-settings lookup. |

The cluster and conventionally named custom location must be available in the resource group
where the infrastructure is deployed. IP pool endpoints are **not** auto-resolved.

**Overrides are no longer public parameters.** For a different VLAN, subnet, switch, DNS,
gateway, custom location, or hostname, edit the corresponding variables in `main.bicep`
(see [Section 5](#5-template-controlled-settings)).

## 2. Files and prerequisites

| File | Description |
|------|-------------|
| `main.bicep` | Entry point containing the infrastructure template and Workload Orchestration resources. |
| `main.bicepparam` | Sample inputs; reads the three sensitive values from environment variables. Replaces `main.params.bicepparam`. |
| `BicepTemplates\ghes-all\post-config.sh` | Appliance configuration script; loaded at build time, uploaded to private blob storage, and executed by Arc Run Command. Accepts both protected license halves. |
| `BicepTemplates\ghes-all\upload-post-config.sh` | Build-time script executed by an Azure deployment script to upload the appliance script. No manual upload is required. |
| `BicepTemplates\ghes-all\update-context.bicep` | Module for updating an existing context. Required at build time even when creating a new context. |

Before deploying, have:

- **Azure CLI and Bicep tooling:** run `az --version` and `az bicep install`.
- The complete folder layout above, including the three build-time dependencies.
- An Arc-connected **Azure Local cluster** with `deploymentSettings/default` and its custom location.
- The **GHES appliance VHDX** copied to a cluster-accessible path, such as
  `C:\ClusterStorage\<share>\<github-enterprise-image>.vhdx`.
- The full resource ID of the cluster's **storage container** for the image and VM configuration.
- An available **static IP range** compatible with the resolved subnet, and enough cluster capacity
  for the requested CPU, memory, and disks.
- A valid **GHES `.ghl` license**, VM administrator password, and management-console password.
- Deployment permissions as described below, including access to an existing context's scope
  when applicable.
- The required Azure resource providers registered, including `Microsoft.Edge`,
  `Microsoft.AzureStackHCI`, `Microsoft.HybridCompute`, `Microsoft.ExtendedLocation`,
  `Microsoft.KeyVault`, `Microsoft.Resources`, and `Microsoft.Storage`.
- Outbound HTTPS access from the appliance to the script storage account, and network access
  from your client to GHES. Blob anonymous access is disabled, but the storage account uses a public endpoint.

### Deployment permissions

| Operation | Access to arrange |
|-----------|-------------------|
| Deploy `main.bicep` | The signed-in Azure CLI identity needs permission to create the vault and its ARM secret resources, template spec, deployment scripts, and Workload Orchestration resources in the deployment RG. |
| Update an existing context | The entry-point deployment identity needs read and update access in that context's resource group/subscription. |
| Deploy the infrastructure through Workload Orchestration | The identity used for that downstream deployment needs template-spec read access, infrastructure deployment permissions, and access to the cluster settings and referenced resources. |
| Resolve the four Key Vault secret references | The identity executing the infrastructure deployment needs `Microsoft.KeyVault/vaults/deploy/action` at the vault scope, or inherited from its RG/subscription. |

The vault enables template deployment and RBAC authorization, but **no role assignments are
created by this template**. It also does not explicitly select a downstream Workload
Orchestration deployment identity; confirm that identity and its access in your environment
before deploying. Do not assume it is the appliance's system-assigned identity.

ARM secret references are different from direct data-plane secret reads. A blanket
**Key Vault Secrets Officer** assignment is not the prerequisite for ARM secret retrieval.
Owner and Contributor include the ARM deployment action at their assigned scope; custom roles
must include it explicitly. See [Key Vault deployment permissions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/key-vault-parameter#grant-deployment-access-to-the-secrets).

## 3. Step-by-step deployment

Run these PowerShell commands from this folder. Keep the same session open through deployment
so Bicep can read the environment variables.

### Step 1 - Sign in and select the deployment resource group

```powershell
az login
az account set --subscription "<your-subscription-id>"

$deploymentResourceGroup = "<deployment-resource-group>"
$deploymentName = "ghes-main"
```

Use an existing resource group containing the Azure Local cluster and expected custom location,
unless you have explicitly adapted the template's resource resolution.

### Step 2 - Prepare the passwords and license

Read passwords without displaying them or putting literal passwords in command history:

```powershell
$env:GHES_ADMIN_PASSWORD = [System.Net.NetworkCredential]::new(
  '', (Read-Host "VM administrator password" -AsSecureString)
).Password

$env:GHES_MGMT_CONSOLE_PASSWORD = [System.Net.NetworkCredential]::new(
  '', (Read-Host "GHES management-console password" -AsSecureString)
).Password

$env:GHES_LICENSE_B64 = [Convert]::ToBase64String(
  [IO.File]::ReadAllBytes("C:\path\to\your.ghl")
)
```

Encode the original license bytes without editing the file. The template splits the resulting
base64 string into two Key Vault secrets to accommodate Key Vault's 25,600-character limit per
secret. The complete string must be no longer than **51,200 characters**. The appliance script
requires both protected halves, concatenates part 1 followed by part 2, and decodes the combined
string once. You still supply only the full `GHES_LICENSE_B64` value locally.

The parameter file uses `readEnvironmentVariable(..., '')`: an unset variable becomes an
empty string, **not** a prompt or an automatic validation error. Set all three before deploying.
Passwords and the license are secure Bicep inputs; they are not written into the parameter file.

### Step 3 - Edit `main.bicepparam`

Replace every `<...>` placeholder with your environment's values:

| Input group | Values to review |
|-------------|------------------|
| Context | Leave `existingContextId` blank for the default context, or provide a full existing context resource ID. |
| Cluster and image | `clusterName`, `LocalSharePath`, `StoragePathId`. |
| Network | `LogicalNetworkName`, `StartIp`, `EndIp`. `StartIp` is also the appliance IP. |
| VM | `VmName`, `AdminUsername`, `CPU`, `Memory`, `NumberDataDisks`, `DiskSizeGB`. |
| Key Vault | A globally unique `KeyVaultName`. |

The sample supplies **16 vCPUs, 32 GB RAM, and one 500 GB data disk**. These are sample values,
not defaults in `main.bicep`; all four sizing inputs are required.

Do not add the former `contextId`, `subscriptionId`, `resourceGroupName`, `ghesSpecName`, or
`ghesSpecVersion` parameters. They are no longer accepted by the entry point.

### Step 4 - Deploy

Check that the secrets are set, the license is decodable and within the size limit, and no
sample placeholders remain:

```powershell
foreach ($name in 'GHES_ADMIN_PASSWORD', 'GHES_MGMT_CONSOLE_PASSWORD', 'GHES_LICENSE_B64') {
  if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) {
    throw "$name is empty or unset."
  }
}
if ($env:GHES_LICENSE_B64.Length -gt 51200) {
  throw "The base64 license exceeds the two-secret size limit."
}
[void][Convert]::FromBase64String($env:GHES_LICENSE_B64)
if ((Get-Content ".\main.bicepparam" -Raw) -match "=\s*'<[^>]+>'") {
  throw "Replace the placeholders in main.bicepparam before deploying."
}
```

Validate the resource-group deployment before creating resources:

```powershell
az deployment group validate `
  --resource-group $deploymentResourceGroup `
  --template-file ".\main.bicep" `
  --parameters ".\main.bicepparam" `
  --only-show-errors `
  --output none
if ($LASTEXITCODE -ne 0) { throw "Deployment validation failed." }
```

Validation compiles the supporting files and checks the entry-point deployment. It is not a
test of the downstream Workload Orchestration deployment or appliance configuration.

Then deploy:

```powershell
az deployment group create `
  --name $deploymentName `
  --resource-group $deploymentResourceGroup `
  --template-file ".\main.bicep" `
  --parameters ".\main.bicepparam"
```

After the command returns, remove the sensitive environment variables from your session:

```powershell
Remove-Item Env:\GHES_ADMIN_PASSWORD, Env:\GHES_MGMT_CONSOLE_PASSWORD, Env:\GHES_LICENSE_B64
```

### Step 5 - Check the deployment and appliance

Check the entry-point deployment and its outputs:

```powershell
az deployment group show `
  --resource-group $deploymentResourceGroup `
  --name $deploymentName `
  --query "{state:properties.provisioningState, outputs:properties.outputs}"
```

The entry point returns:

| Output | Meaning |
|--------|---------|
| `keyVaultResourceId` | Key Vault containing the two passwords and license parts. |
| `keyVaultUri` | URI of that vault. |
| `templateSpecVersionId` | Published `ghesspec` version resource ID. |
| `solutionDeploymentId` | Workload Orchestration solution deployment to monitor. |
| `contextResourceId` | Created or reused context resource ID. |

Inspect the solution deployment in the portal to confirm infrastructure provisioning. Once the
Arc machine and Run Command exist, inspect the command separately:

```powershell
$subscriptionId = az account show --query id --output tsv
$vmName = "<VmName-from-main.bicepparam>"
$machineId = "/subscriptions/$subscriptionId/resourceGroups/$deploymentResourceGroup/providers/Microsoft.HybridCompute/machines/$vmName"

az rest --method get `
  --url "https://management.azure.com$machineId/runCommands/ghes-postconfig?api-version=2024-07-10" `
  --query "{provisioningState:properties.provisioningState, execution:properties.instanceView}"
```

Wait for `execution.executionState` to be **`Succeeded`** and `execution.exitCode` to be **`0`**.
If the command is not created yet, keep monitoring the solution deployment; if it is pending
or running, check again later. Review execution output and errors, including `verify FAIL` or
`WARNING` messages: endpoint verification failures are non-fatal by default.

The infrastructure template also defines `imageId`, `logicalNetworkId`, `machineId`,
`runCommandResourceId`, and `resolved*` outputs for the custom location, gateway, CIDR, DNS,
switch, domain, VM name, and GHES hostname. These belong to the infrastructure deployment,
**not** the five top-level outputs above.

After post-configuration succeeds and DNS is configured, browse to
`https://githubenterpriselocal.<your-domain>`. The management-console port is `8443`.
DNS records (including wildcard records needed for subdomain isolation), Active Directory
objects, and LDAP authentication wiring are not provisioned by this template.

## 4. Deployment parameter reference

These are the public parameters accepted by **`main.bicep`**. Only `existingContextId` has
a template default. Values shown in the sample column are from `main.bicepparam`.

| Parameter | Required | Sample value | Description |
|-----------|----------|--------------|-------------|
| `existingContextId` | No | `''` | Full existing `Microsoft.Edge/contexts` resource ID. Blank creates `defaultContext`. |
| `clusterName` | Yes | Placeholder | Azure Local cluster used for deployment-settings resolution. |
| `LocalSharePath` | Yes | Placeholder | Cluster-local path to the source GHES VHDX. |
| `StoragePathId` | Yes | Placeholder | Full Azure Local storage container resource ID for the image and VM configuration. |
| `LogicalNetworkName` | Yes | Placeholder | Name of the logical network to create. |
| `StartIp` | Yes | Placeholder | Static IP for GHES and first address in the workload IP pool. |
| `EndIp` | Yes | Placeholder | Last address in the workload IP pool. |
| `VmName` | Yes | Placeholder | VM and Arc machine name; also used for the NIC name and data disk naming. |
| `AdminUsername` | Yes | Placeholder | VM administrator username. |
| `AdminPassword` | Yes, secure | `GHES_ADMIN_PASSWORD` environment variable | VM administrator password, stored as `ghes-admin-password` in Key Vault. |
| `CPU` | Yes | `16` | vCPU count; allowed values are `4`, `8`, `16`, or `32`. |
| `Memory` | Yes | `32768` | Memory in MB, from `32768` to `131072` (32-128 GB). |
| `NumberDataDisks` | Yes | `1` | Number of data disks; minimum `1`. |
| `DiskSizeGB` | Yes | `500` | Size of each data disk in GB; minimum `500`. |
| `KeyVaultName` | Yes | Placeholder | Globally unique vault name, 3-24 characters, using alphanumeric characters and dashes. |
| `ManagementConsolePassword` | Yes, secure | `GHES_MGMT_CONSOLE_PASSWORD` environment variable | Console password, stored as `ghes-mgmt-console-password` in Key Vault. |
| `LicenseBase64` | Yes, secure | `GHES_LICENSE_B64` environment variable | Base64 of the original `.ghl` file, stored as `ghl-license-part1` and `ghl-license-part2`. |

## 5. Template-controlled settings

The following are **variables in `main.bicep`, not `.bicepparam` inputs**. Editing them changes
the published template or the solution configuration on the next deployment.

| Setting | Current value / behavior |
|---------|--------------------------|
| `Location` | `eastus`. |
| `cloudTargetName` / `infraCapabilityName` | `cloud-target` / `ghes-infrastructure`. |
| `contextName` / `contextHierarchyName` | `defaultContext` / `line` for new contexts or missing hierarchies. |
| `ghesSolutionTemplateName` / `ghesSolutionTemplateVersionName` | `ghes-solution-template` / `1.0.0`. |
| `ghesSpecName` / `ghesSpecVersion` | `ghesspec` / `1.0.0`; published in the current deployment scope. |
| `VmImageName` / `CreateImage` / `ExistingImageResourceId` | `ghes-image` / `true` / `''`. |
| `CustomLocationId` | `''`; uses the `<clusterName>-customlocation` convention. |
| `IpAllocationMethod` / `Vlan` | `Static` / `0` (untagged). |
| `AddressPrefix` / `VmSwitchName` / `DefaultGateway` | `''`; resolved from deployment settings. |
| `DnsServers` | `[]`; resolved from deployment settings. |
| `GithubHostName` / `GithubHostLabel` | `''` / `githubenterpriselocal`; combines the label with the cluster domain. |
| `KeyVaultSkuName` / `EnableRbacAuthorization` / `SoftDeleteRetentionInDays` | `standard` / `true` / `7`. Vault tenant is the deployment subscription's tenant. |
| `SubdomainIsolation` / `SignupEnabled` / `PublicPages` | `true` / `false` / `false`. |
| `ManagePort` | `8443`. |
| `ApplyTimeoutMinutes` / `ReadyTimeoutMinutes` | `180` / `30`. These entry-point values override the embedded template's defaults. |
| `SkipApply` / `AsyncExecution` | `false` / `true`. |
| `RunCommandName` | `ghes-postconfig`. |

The script SAS starts 15 minutes before template evaluation and expires approximately one day
and 15 minutes after evaluation. The script is uploaded again for a subsequent infrastructure
deployment using a time-based upload token.

### Appliance post-configuration behavior

`post-config.sh` runs as root on the appliance. It validates the required inputs, reconstructs
the license, and:

1. Checks whether the supplied console password already authenticates to the Manage API.
   If so, skips first-boot initialization.
2. Otherwise uploads the license and sets the console password through `/manage/v1/config/init`.
   It uses `/setup/api/start` only when the modern endpoint returns HTTP `404`, `405`, or `410`.
3. Waits for authenticated Manage API access and for any initial `ghe-config-apply` to settle.
4. Stages hostname, subdomain isolation, signup, and public Pages settings.
5. Runs `ghe-config-apply` unless `SkipApply` is true, then checks the web and management endpoints.

The apply log is written to
`/data/user/common/ghe-config-apply.<UTC-timestamp>.log` on the appliance; its final 20 lines
are included in command output. Temporary license, password, and API-response files are
removed on exit, using `shred` when available.

`GHES_VERIFY` defaults to `true` and `GHES_VERIFY_STRICT` to `false` inside the script.
Consequently, endpoint failures produce warnings rather than a failed Run Command.
These are script defaults, not public Bicep parameters, and are not currently passed by the
template. To change them for deployment, update the script defaults or the Run Command's
parameter wiring. Always review the health-check output and verify client access to GHES.

`SkipApply = true` still performs initialization, waits for readiness, and stages settings.
It is **not** a no-change dry run; it skips only the final explicit apply and endpoint checks.

## 6. Redeployment and troubleshooting

### Reuse an existing image

To avoid importing the VHDX again, change **`var CreateImage = false` in `main.bicep`**.
Leave `ExistingImageResourceId = ''` to reference `VmImageName` in the infrastructure resource
group, or set that variable to the full ID of an existing gallery image.

These cannot be set in `main.bicepparam`. `LocalSharePath` remains a required entry-point input
even when image creation is disabled. Keep resource names consistent when updating an existing
deployment; the default names do not distinguish multiple independent GHES instances in one RG.

### Reconfigure an initialized appliance

If post-config runs again with the existing console password, it detects authenticated Manage
API access and skips initialization, but still stages the configured settings and runs apply
unless `SkipApply` is true. **This is not a password-rotation or license-update workflow**:
initialization is skipped for an already authenticated instance.

Keep `ManagementConsolePassword` aligned with the appliance's current console password.
Changing the parameter updates the vault secret but does not guarantee a console-password
change on an initialized appliance. Use the supported GHES administration workflow for password
rotation or license changes before rerunning with the matching inputs.

### Common issues

| Symptom | Check / action |
|---------|----------------|
| Build reports a missing script or module | Keep `post-config.sh`, `upload-post-config.sh`, and `update-context.bicep` under `BicepTemplates\ghes-all` beside the entry point's folder structure. No separate `ghes.bicep` is needed. |
| Parameter is not recognized | Use `main.bicepparam` and the public inputs in Section 4. Former override and template-spec parameters are now variables or inferred from deployment scope. |
| Context update fails | Check the full `existingContextId`, permissions at that context's scope, and availability of the context module. |
| Cluster or custom location is not found | Check the deployment resource group, `clusterName`, `deploymentSettings/default`, and the `<clusterName>-customlocation` convention. Change `CustomLocationId` in the template if needed. |
| Subnet or networking values are empty or incorrect | Auto-derived CIDR supports only `/8`, `/16`, and `/24`. Set the `AddressPrefix` variable explicitly for other masks; review the DNS, gateway, switch, and VLAN variables for your network. |
| Password or license is empty | Set all three environment variables in the same PowerShell session used for deployment. Their parameter-file fallbacks are empty strings. |
| Key Vault name conflict or secret-reference failure | Use a globally unique vault name; deleted names can remain reserved by soft delete. Check entry-point ARM secret-resource write permissions and the downstream deployment identity's `Microsoft.KeyVault/vaults/deploy/action` permission. |
| Template spec or solution deployment fails | Inspect the entry-point deployment operations and Workload Orchestration solution status. The spec is published automatically; there is no external spec location to configure. |
| ARM deployment succeeds but GHES is not ready | Post-config is asynchronous. Monitor the solution deployment and `ghes-postconfig` execution separately. |
| Script download fails | Check appliance HTTPS access to the storage account, successful blob upload, and SAS validity. A later rerun after SAS expiry requires a fresh infrastructure deployment to generate a new URI. |
| Post-config times out | Review Run Command errors first. If needed, edit `ApplyTimeoutMinutes` and `ReadyTimeoutMinutes` in `main.bicep`; setting `AsyncExecution = false` makes provisioning wait for command completion. |
| Initialization fails or readiness never completes on redeployment | Verify that the supplied console password matches the initialized appliance. Legacy initialization is attempted only for HTTP `404`, `405`, or `410` from the modern endpoint. |
| Run Command succeeds but health checks report failures | Verification is non-fatal by default. Read `verify FAIL` / `WARNING` output and the appliance apply log; confirm DNS and client access separately. |
| GHES hostname does not resolve | Create the required DNS records pointing to `StartIp`; hostname configuration does not create DNS records. |
