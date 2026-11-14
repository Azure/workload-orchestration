# CloudCasa Day 0 Quick Start

This is the supported fresh-user path for deploying CloudCasa through Azure Workload
Orchestration. The user does not run a deployment script or `kubectl`.

## What the platform owner prepares once

These are platform setup tasks, not per-user deployment steps:

- Publish `cloudcasa-bootstrap:0.2.4` and the CloudCasa wrapper chart to the customer ACR.
- Grant the deployment user access to the target resource group.
- Grant role-assignment permission when Bicep will create Key Vault and ACR assignments.
- Provide the cluster-specific `.local.bicepparam` file.

The AKG test parameter file is already configured:

```text
main.akg-cc-test.local.bicepparam
```

It creates `akgcccloudcasakv`, populates its secrets, uses the AKS OIDC issuer, and enables the
Bicep-managed ACR pull assignment.

## New cluster: prepare one parameter file

Copy the generic example once for the new cluster:

```powershell
$ClusterName = '<new-arc-cluster-name>'
$ParameterFile = ".\main.$ClusterName.local.bicepparam"

Copy-Item '.\main.params.bicepparam' $ParameterFile
```

For an AKS cluster, discover the cluster-specific values:

```powershell
$AksSubscriptionId = '<aks-subscription-id>'
$AksResourceGroupName = '<aks-resource-group>'
$AksClusterName = '<aks-cluster-name>'

$WorkloadIdentityIssuerUrl = az aks show `
  --subscription $AksSubscriptionId `
  --resource-group $AksResourceGroupName `
  --name $AksClusterName `
  --query oidcIssuerProfile.issuerUrl `
  --output tsv

$LoadBalancerDnsRegion = az aks show `
  --subscription $AksSubscriptionId `
  --resource-group $AksResourceGroupName `
  --name $AksClusterName `
  --query location `
  --output tsv
```

Update only these new-cluster values in the copied parameter file:

| Parameter | New-cluster value |
|---|---|
| `location` | Arc/AKS cluster Azure region |
| `connectClusterName` | Arc `Microsoft.Kubernetes/connectedClusters` resource name |
| `workloadIdentityIssuerUrl` | `$WorkloadIdentityIssuerUrl` |
| `acrSubscriptionId` | Subscription containing the customer ACR |
| `acrResourceGroupName` | Resource group containing the customer ACR |
| `acrName` | Customer ACR name |
| `localAdminEmail` | Initial administrator email |

`main.bicep` generates the Key Vault name, target names, extension names, chart repositories,
tested chart and solution versions, storage class, Azure LoadBalancer hostname, certificate
Issuer name, and administrator allowlists. It enables local authentication for this Day-0 flow.
The parameter file supplies the cluster location and environment-specific ACR location.

The default StorageClass name is `default`. Add `param storageClassName = '<name>'` to the
cluster-specific parameter file only when that cluster does not provide a dynamic StorageClass
with this name.

After this one-time parameter preparation and loading the four secure environment variables, the
entire CloudCasa deployment is one command:

```powershell
az deployment group create `
  --name "cloudcasa-day0-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroupName `
  --template-file .\main.bicep `
  --parameters $ParameterFile `
  --only-show-errors `
  --output table
```

## User step 1: Sign in

```powershell
Set-Location 'C:\Users\v-agondagare\source\repos\workload-orchestration\applications\cloudcasa'

$TenantId = '72f988bf-86f1-41af-91ab-2d7cd011db47'
$SubscriptionId = '973d15c6-6c57-447e-b9c6-6d79b5b784ab'
$ResourceGroupName = 'akg-cc-test-rg'
$ParameterFile = '.\main.akg-cc-test.local.bicepparam'

az login --tenant $TenantId
az account set --subscription $SubscriptionId

az account show `
  --query '{subscription:name,id:id,tenant:tenantId,user:user.name}' `
  --output table
```

Stop if the displayed tenant or subscription is incorrect.

## User step 2: Load the four secure values

```powershell
$LicensePath = 'C:\Users\v-agondagare\Downloads\cloudcasa-server_20261031.key'

if (-not (Test-Path $LicensePath)) {
  throw "License file not found: $LicensePath"
}

$RegistryCredential = Get-Credential `
  -Message 'Enter CloudCasa vendor-registry credentials'

$LocalCredential = Get-Credential `
  -UserName 'cloudcasa-admin' `
  -Message 'Enter the CloudCasa local administrator password'

$env:CLOUDCASA_REGISTRY_USERNAME = $RegistryCredential.UserName
$env:CLOUDCASA_REGISTRY_PASSWORD = $RegistryCredential.GetNetworkCredential().Password
$env:CLOUDCASA_LICENSE_CONTENT = [IO.File]::ReadAllText($LicensePath)
$env:CLOUDCASA_LOCAL_ADMIN_PASSWORD = $LocalCredential.GetNetworkCredential().Password

if (
  $env:CLOUDCASA_LOCAL_ADMIN_PASSWORD -notmatch '^[\x21-\x7E]{16,64}$'
) {
  throw 'The local administrator password must contain 16-64 printable ASCII characters without spaces.'
}
```

Do not Base64-encode the license and do not place these values in the parameter file.

## User step 3: Validate

```powershell
az bicep build --file .\main.bicep --stdout | Out-Null
az bicep build-params --file $ParameterFile --stdout | Out-Null

az deployment group validate `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroupName `
  --template-file .\main.bicep `
  --parameters $ParameterFile `
  --output none
```

Continue only when the command completes without an error.

## User step 4: Deploy

```powershell
$DeploymentName = 'cloudcasa-day0'

az deployment group create `
  --name $DeploymentName `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroupName `
  --template-file .\main.bicep `
  --parameters $ParameterFile `
  --output table
```

Bicep creates or reconciles the context, extensions, Key Vault, Secret Store identity and roles,
the `default`-scoped bootstrap target, the `cloudcasa-server` application target, and both
solutions in the required order.

## User step 5: Check the result

```powershell
az deployment group show `
  --name $DeploymentName `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroupName `
  --query '{state:properties.provisioningState,error:properties.error}' `
  --output jsonc

az keyvault secret list `
  --subscription $SubscriptionId `
  --vault-name 'akgcccloudcasakv' `
  --query '[].{name:name,enabled:attributes.enabled}' `
  --output table

az k8s-extension list `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroupName `
  --cluster-type connectedClusters `
  --cluster-name 'akg-test-Cluster' `
  --query '[].{name:name,type:extensionType,state:provisioningState}' `
  --output table
```

Expected results:

- ARM deployment state is `Succeeded`.
- The Azure LoadBalancer hostname resolves to the public IP.
- Key Vault lists the five CloudCasa secret names without displaying their values.
- `microsoft.azure.secretstore`, `microsoft.certmanagement`, and
  `microsoft.workloadorchestration` are `Succeeded`.

## Clear local values

```powershell
Remove-Item Env:CLOUDCASA_REGISTRY_USERNAME -ErrorAction SilentlyContinue
Remove-Item Env:CLOUDCASA_REGISTRY_PASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:CLOUDCASA_LICENSE_CONTENT -ErrorAction SilentlyContinue
Remove-Item Env:CLOUDCASA_LOCAL_ADMIN_PASSWORD -ErrorAction SilentlyContinue

$RegistryCredential = $null
$LocalCredential = $null
```

## Advanced: use an existing Key Vault

The normal new-user path creates and populates the vault. The same resource declaration can also
reconcile an RBAC-enabled vault already present in the deployment resource group.

To let Bicep populate the named vault:

```bicep
param keyVaultName = '<existing-key-vault-name>'
param populateKeyVaultSecrets = true
```

To use secrets already populated by the platform owner:

```bicep
param keyVaultName = '<existing-key-vault-name>'
param populateKeyVaultSecrets = false
```

Prepopulated mode requires:

| Secret | Content |
|---|---|
| `cloudcasa-license` | Raw CloudCasa license file |
| `cloudcasa-registry-dockerconfig` | Complete Docker configuration JSON |
| `cloudcasa-local-admin-username` | Local administrator username |
| `cloudcasa-local-admin-email` | Local administrator email |
| `cloudcasa-local-admin-password` | Local administrator password |

An existing vault in another resource group or subscription is not supported by the current
single-file template.

## Platform owner: publish bootstrap chart 0.2.4

This is a one-time artifact publication step. New deployment users should not repeat it.

```powershell
$AcrName = 'akgtestacr'
$AcrResourceGroupName = 'akg-wu2-ConfigManager-CloudTest-Playground-C'
$AcrLoginServer = "$AcrName.azurecr.io"

$AcrToken = az acr login `
  --name $AcrName `
  --resource-group $AcrResourceGroupName `
  --subscription $SubscriptionId `
  --expose-token `
  --query accessToken `
  --output tsv

$AcrToken | helm registry login $AcrLoginServer `
  --username '00000000-0000-0000-0000-000000000000' `
  --password-stdin

helm push `
  .\cloudcasa-bootstrap-0.2.4.tgz `
  "oci://$AcrLoginServer/helm"
```
