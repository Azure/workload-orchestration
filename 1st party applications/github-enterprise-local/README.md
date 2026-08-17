# Deploy GitHub Enterprise Server (github-local) on Azure Local

This folder contains everything you need to deploy a **GitHub Enterprise Server (GHES)** instance
— referred to as **github-local** — onto an **Azure Local** (Azure Stack HCI) cluster using Azure
**Workload Orchestration** (the `Microsoft.Edge` provider) and a single, consolidated Bicep template.

You do **not** need to read the Bicep source to deploy. This README gives you the exact commands,
the order to run them in, and a full description of every parameter.

---

## 1. What gets deployed

The deployment provisions the complete GHES stack in **one** solution deployment:

| # | Resource | Purpose |
|---|----------|---------|
| 1 | **Gallery image** (`Microsoft.AzureStackHCI/galleryImages`) | The GHES appliance VHDX imported as an Azure Local gallery image. |
| 2 | **Logical network** (`Microsoft.AzureStackHCI/logicalNetworks`) | Subnet, VLAN, IP pool, gateway route and DNS for the VM. |
| 3 | **Virtual machine** (Arc machine + NIC + data disks + VM instance) | The GHES appliance VM itself. |
| 4 | **Key Vault** (`Microsoft.KeyVault/vaults`) | Stores the admin password and management-console password as secrets. |
| 5 | **Post-config Run Command** | Runs on the appliance to upload the license, set the console password, configure the hostname/settings, and run `ghe-config-apply`. |

These are packaged as a Workload Orchestration **Cloud Target → Solution Template → Solution
Deployment** (`main.bicep`), which points at a published **template spec** (`ghes.bicep`)
that contains the five resources above.

> **Auto-resolution:** Networking and infrastructure values (address prefix, VM switch, DNS,
> gateway, domain FQDN, custom location) are **auto-derived** from the cluster's
> `deploymentSettings/default` resource. You only need to supply the values that are *not* in
> deployment settings (like the IP pool `StartIp`/`EndIp`), plus your secrets. Any value you set
> explicitly always overrides the auto-resolved one.

---

## 2. Files in this folder

| File | Description |
|------|-------------|
| `main.bicep` | **Entry point.** Deploys the Workload Orchestration Cloud Target, Solution Template (+version) and Solution Deployment. This is what you deploy. |
| `main.params.bicepparam` | Sample parameter file for `main.bicep` (reads secrets from environment variables). |
| `BicepTemplates/ghes-all/ghes.bicep` | The **template spec** source that actually creates the 5 resources. You publish this once as `ghesspec`. |
| `BicepTemplates/ghes-all/post-config.sh` | On-box script that configures GHES (license, hostname, apply). Embedded automatically into the template spec. |

---

## 3. Prerequisites

Before you start, make sure you have:

- **Azure CLI** installed, with the Bicep tooling:
  ```powershell
  az --version
  az bicep install
  ```
- **Permissions** to create resources in the target subscription/resource group and to publish
  a template spec.
- An **Azure Local cluster** that is Arc-connected and has a `deploymentSettings/default`
  resource (this is what enables auto-resolution).
- The **GHES appliance VHDX** already copied to a cluster storage share (e.g.
  `C:\ClusterStorage\<share>\<github-enterprise-image>.vhdx`).
- A **storage path (container) resource ID** on the cluster where the image/VM config will live.
- Your **GHES license file** (`.ghl`).
- The Workload Orchestration **context ID** for your environment (a `Microsoft.Edge/contexts` resource ID).

---

## 4. Step-by-step deployment

### Step 0 — Sign in and select your subscription

```powershell
az login
az account set --subscription "<your-subscription-id>"
```

### Step 1 — Prepare your secrets

The sample `main.params.bicepparam` reads secrets from **environment variables** so they are
never written to disk. Set them in your PowerShell session:

```powershell
# GHES license file -> base64 (single line)
$env:GHES_LICENSE_B64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\your.ghl"))

# VM administrator password
$env:GHES_ADMIN_PASSWORD = "<strong-admin-password>"

# GHES management-console password
$env:GHES_MGMT_CONSOLE_PASSWORD = "<strong-mgmt-console-password>"
```

> The `.bicepparam` + environment-variable approach keeps secrets out of source files. Avoid
> committing any real values for `LicenseBase64`, `AdminPassword`, or `ManagementConsolePassword`.

### Step 2 — Publish the template spec (`ghesspec`)

`main.bicep` references a template spec by name/version/resource group. Publish
`ghes.bicep` **once** as that template spec. The name, version and resource group must match
the `ghesSpecName`, `ghesSpecVersion`, `subscriptionId` and `resourceGroupName` parameters you
use in Step 4.

```powershell
az ts create `
  --name "ghesspec" `
  --version "1.0.0" `
  --resource-group "<template-spec-resource-group>" `
  --location "eastus2" `
  --template-file ".\BicepTemplates\ghes-all\ghes.bicep"
```

> Re-run this command (same name, new `--version`) whenever you change `ghes.bicep`, and
> bump `ghesSpecVersion` in your parameters accordingly.

### Step 3 — Edit your parameters

Open `main.params.bicepparam` and set the values for your environment.
At minimum, review these (see the full reference in [Section 5](#5-parameter-reference)):

- `subscriptionId`, `resourceGroupName` — where the template spec from Step 2 lives.
- `contextId` — your Workload Orchestration context resource ID.
- `clusterName` — your Azure Local cluster name (drives auto-resolution).
- `StoragePathId` — storage container resource ID on the cluster.
- `LocalSharePath` — path to the GHES VHDX on the cluster share.
- `StartIp` / `EndIp` — the workload IP pool (also the VM's static IP = `StartIp`).
- `KeyVaultName` — a globally unique Key Vault name (3–24 chars).

### Step 4 — Deploy

Deploy `main.bicep` into a resource group of your choice (this is the RG that will hold the
Workload Orchestration Cloud Target / Solution Template / Solution Deployment resources):

```powershell
az deployment group create `
  --resource-group "<deployment-resource-group>" `
  --template-file ".\main.bicep" `
  --parameters ".\main.params.bicepparam"
```

The deployment **waits** for the on-box configuration to complete by default
(`AsyncExecution = false`). Depending on `ApplyTimeoutMinutes` and `ReadyTimeoutMinutes` this can
take a while (the run command timeout is `ReadyTimeoutMinutes + ApplyTimeoutMinutes + 30` minutes).

### Step 5 — Verify

Check the deployment succeeded:

```powershell
az deployment group show `
  --resource-group "<deployment-resource-group>" `
  --name "main" `
  --query "properties.provisioningState"
```

The template spec (`ghes.bicep`) also emits **resolved outputs** so you can confirm what
auto-resolution picked (custom location, gateway, address prefix, DNS servers, VM switch, domain
FQDN, VM name, and the final GHES hostname). Inspect the Solution Deployment resource in the
portal to review these.

Once the post-config Run Command finishes, browse to your GHES hostname
(e.g. `https://githubenterpriselocal.<your-domain>`) to complete any remaining setup.

---

## 5. Parameter reference

Secrets are marked 🔒. Parameters with **auto-resolve** blank-defaults are pulled from the
cluster `deploymentSettings` when left empty; set them only to override.

### 5.1 Workload Orchestration / Edge

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `cloudTargetName` | Yes | — | Name of the Cloud Target resource created for the ARM deployment. |
| `infraCapabilityName` | Yes | — | Capability name applied to the cloud target and solution template. |
| `Location` | No | `eastus2` | Azure region for the Workload Orchestration metadata resources. |
| `contextId` | Yes | — | Resource ID of your `Microsoft.Edge/contexts` context. |
| `subscriptionId` | Yes | — | Subscription that hosts the published template spec (Step 2). |
| `resourceGroupName` | Yes | — | Resource group that hosts the published template spec (Step 2). |
| `ghesSolutionTemplateName` | No | `ghes-solution-template` | Name of the solution template resource. |
| `ghesSolutionTemplateVersionName` | No | `1.0.0` | Version label of the solution template. |
| `ghesSpecName` | Yes | — | Name of the published template spec. Must match Step 2 (`ghesspec`). |
| `ghesSpecVersion` | Yes | — | Version of the published template spec. Must match Step 2 (`1.0.0`). |

### 5.2 Cluster / auto-resolution

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `clusterName` | Yes | — | Azure Local cluster name. Unlocks auto-resolution of networking/infra and the custom location (`<clusterName>-customlocation`). |

### 5.3 Image

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `VmImageName` | No | `ghes-image` | Name of the gallery image resource. |
| `CustomLocationId` | No (override) | `''` → derived from `clusterName` | Resource ID of the Azure Local custom location. |
| `LocalSharePath` | Yes when `CreateImage=true` | `''` | Path to the source GHES VHDX on the cluster share. |
| `StoragePathId` | Yes | — | Resource ID of the storage container for the image and VM config. |
| `CreateImage` | No | `true` | `true` = create the gallery image; `false` = reference an existing one. Set `false` on redeploys. |
| `ExistingImageResourceId` | No | `''` | When `CreateImage=false`: resource ID of an existing image. Blank = image named `VmImageName` in the spec RG. |

### 5.4 Logical network

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `LogicalNetworkName` | No | `ghes-lnet` | Name of the logical network resource. |
| `IpAllocationMethod` | No | `Static` | IP allocation method for the subnet. |
| `AddressPrefix` | No (override) | `''` → derived from deployment settings | Subnet CIDR (e.g. `10.0.0.0/24`). **Required** for non-octet-aligned masks (anything other than /8, /16, /24). |
| `Vlan` | No | `0` | VLAN ID (0–4094). `0` = untagged. |
| `VmSwitchName` | No (override) | `''` → derived from deployment settings | Hyper-V virtual switch name. |
| `StartIp` | Yes | — | Static IP for the GHES VM **and** the start of the workload IP pool. Not in deployment settings. |
| `EndIp` | Yes | — | End of the workload IP pool. Not in deployment settings. |
| `DnsServers` | No (override) | `[]` → derived from deployment settings | Array of DNS server IPs. |
| `DefaultGateway` | No (override) | `''` → derived from deployment settings | Default gateway IP for the subnet. |

### 5.5 Virtual machine

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `VmName` | No (override) | `''` → `<VmNamePrefix>-1` | Name of the VM / Arc machine. |
| `VmNamePrefix` | No | `ghes` | Hostname prefix used when `VmName` is blank. |
| `AdminUsername` | Yes | — | Administrator username for the VM. |
| `AdminPassword` 🔒 | Yes | — | Administrator password for the VM. Also stored in Key Vault. |
| `CPU` | No | `16` | Number of virtual processors. |
| `Memory` | No | `32768` | Memory in MB (default 32 GB). |
| `NumberDataDisks` | No | `1` | Number of data disks to create/attach. |
| `DiskSizeGB` | No | `500` | Size of each data disk in GB. |

### 5.6 Key Vault

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `KeyVaultName` | Yes | — | Key Vault name (3–24 chars, globally unique, alphanumeric + dashes). |
| `TenantId` | No | Deployment tenant | Entra tenant ID that owns the vault. |
| `KeyVaultSkuName` | No | `standard` | `standard` or `premium`. |
| `ManagementConsolePassword` 🔒 | No | `''` | GHES management-console password to seed as a secret and use in post-config. Blank = not seeded here. |
| `ManagementConsolePasswordSecretName` | No | `ghes-mgmt-console-password` | Secret name for the management-console password. |
| `AdminPasswordSecretName` | No | `ghes-admin-password` | Secret name for the admin password. |

### 5.7 Post-configuration

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `GithubHostName` | No (override) | `''` → `<GithubHostLabel>.<domainFqdn>` | Full GHES hostname (FQDN). |
| `GithubHostLabel` | No | `githubenterpriselocal` | Hostname label prepended to the domain FQDN when `GithubHostName` is blank. |
| `LicenseBase64` 🔒 | Yes | — | Base64 of the GHES `.ghl` license file. |
| `SubdomainIsolation` | No | `true` | Enable subdomain isolation. |
| `SignupEnabled` | No | `false` | Allow built-in signups (keep off for AD/LDAP-backed instances). |
| `PublicPages` | No | `false` | Enable public GitHub Pages. |
| `ManagePort` | No | `8443` | Manage API port on the appliance. |
| `ApplyTimeoutMinutes` | No | `120` | Cap (minutes) on the on-box `ghe-config-apply` (10–1440). |
| `ReadyTimeoutMinutes` | No | `30` | Minutes to wait for the Manage API + initial apply to settle before staging settings (5–240). |
| `SkipApply` | No | `false` | Stage settings only; skip `ghe-config-apply` (dry run). |
| `AsyncExecution` | No | `false` | `true` = deployment returns immediately; `false` = waits for post-config to complete. |
| `RunCommandName` | No | `ghes-postconfig` | Name of the Run Command resource on the appliance. |

---

## 6. What the post-config step does

After the VM is created, an Azure Arc **Run Command** executes `post-config.sh` on the appliance
(as root). It:

1. Uploads the license and sets the management-console password via `POST /manage/v1/config/init`.
2. Stages core settings (hostname, subdomain isolation, signup, pages) via `PUT /manage/v1/config/settings`.
3. Runs `ghe-config-apply` on-box (unless `SkipApply=true`).
4. Performs an on-box self-verify (`curl localhost`) after the apply.

**Kept manual by design (not done by this deployment):** Active Directory objects, DNS records,
and LDAP auth-mode wiring. Configure those out-of-band before/after this runs.

---

## 7. Redeploying against an existing image

On a redeploy where the gallery image already exists, avoid recreating it:

- Set `CreateImage = false`.
- Either leave `ExistingImageResourceId` blank (it will reference the image named `VmImageName`
  in the spec resource group) or set it to a specific image resource ID.

---

## 8. Troubleshooting

- **Template spec not found:** ensure `ghesSpecName`, `ghesSpecVersion`, `subscriptionId` and
  `resourceGroupName` in your parameters match exactly what you published in Step 2.
- **Auto-resolution produced empty/incorrect values:** for non-octet-aligned subnet masks, you
  **must** set `AddressPrefix` explicitly. You can also override `VmSwitchName`, `DnsServers`,
  `DefaultGateway`, and `CustomLocationId`.
- **Deployment times out during post-config:** increase `ApplyTimeoutMinutes` / `ReadyTimeoutMinutes`,
  or set `AsyncExecution = true` to return immediately and monitor the Run Command separately.
- **Key Vault name conflict:** `KeyVaultName` must be globally unique; soft-delete keeps deleted
  vault names reserved for the retention period.
- **Review resolved values:** check the Solution Deployment / template spec outputs
  (`resolvedGateway`, `resolvedAddressPrefix`, `resolvedDnsServers`, `resolvedVmSwitchName`,
  `resolvedDomainFqdn`, `resolvedGithubHostName`, etc.) to see what auto-resolution chose.
