# Deploy CloudCasa through Azure Workload Orchestration

This folder deploys CloudCasa Self-Hosted to an Arc-connected Kubernetes cluster from one
self-contained resource-group Bicep deployment. No helper Bicep modules, deployment PowerShell
script, or deployment-user `kubectl` access is required.

## Deployment model

`main.bicep` creates or configures:

1. A dedicated Workload Orchestration context when `contextId` is empty, or a prepared existing
   context when its resource ID is supplied.
2. Certificate Management, Azure Key Vault Secret Store, and Workload Orchestration Arc
   extensions.
3. A Key Vault created or reconciled in the deployment resource group.
4. A user-assigned managed identity with `Key Vault Reader` and `Key Vault Secrets User`.
5. Federated identity credentials for the CloudCasa server and MongoDB namespaces.
6. The Custom Location, a `default`-scoped bootstrap target, a `cloudcasa-server` application
   target, and optional registry-scoped `AcrPull`.
7. A bootstrap Helm solution deployed through the `default`-scoped target that creates
   namespaces, service accounts,
   `SecretProviderClass`, `SecretSync`, and the optional Issuer.
8. The CloudCasa application solution through the `cloudcasa-server`-scoped target after the
   bootstrap solution.

Secret values enter ARM only as secure parameters when `populateKeyVaultSecrets = true`. Bicep
writes them to Key Vault. WO receives only the vault name, managed-identity client ID, secret
names, tenant ID, and Kubernetes Secret names. Registry credentials, license contents, and the
local administrator password are not retained in WO solution configuration or revisions.

The Secret Store extension copies the selected values into native Kubernetes Secrets. Kubernetes
RBAC, audit, and encryption-at-rest controls therefore still apply to those local copies.

## Files

| File | Purpose |
|---|---|
| `main.bicep` | Complete, self-contained Bicep-only CloudCasa deployment. |
| `main.params.bicepparam` | Generic non-secret parameter example. |
| `cloudcasa-bootstrap-0.2.4.tgz` | Validated namespace and Key Vault synchronization bootstrap chart. |
| `cloudcasa-server-2.0.0-wo.4.tgz` | Validated CloudCasa Workload Orchestration chart. |

## Required prerequisites

- Kubernetes 1.27 or later.
- An OIDC issuer for Kubernetes service-account tokens.
- An existing Workload Orchestration context resource ID when the subscription already has one.
  The existing context must already contain a hierarchy and the `cloudcasa` capability.
- The deployment identity can create role assignments on the Key Vault and, when enabled, ACR.
- The customer ACR is in the same subscription and resource group as the Arc cluster.
- The customer ACR contains:
  - `helm/cloudcasa-bootstrap:0.2.4`
  - `helm/cloudcasa-server:2.0.0-wo.4`

Each cluster-specific parameter file supplies `acrName`. `main.bicep` derives both OCI chart
repository URLs from `acrName` and creates the `AcrPull` assignment directly on that registry.

Check for an existing Workload Orchestration context before deployment:

```powershell
az resource list `
  --subscription "<subscription-id>" `
  --resource-type "Microsoft.Edge/contexts" `
  --query "[].{name:name,resourceGroup:resourceGroup,id:id}" `
  --output table
```

When a context is returned, set:

```bicep
param contextId = '<existing-context-resource-id>'
```

Only when the command returns no context, set:

```bicep
param contextId = ''
```

An empty or omitted `contextId` tells `main.bicep` to create a context in the deployment resource
group. Supplying the existing resource ID prevents a second-context creation from failing with
`ContextAlreadyExists`.

For an Azure AKS cluster, retrieve the issuer with:

```powershell
az aks show `
  --subscription "<subscription-id>" `
  --resource-group "<aks-resource-group>" `
  --name "<aks-cluster-name>" `
  --query oidcIssuerProfile.issuerUrl `
  --output tsv
```

Set `location` to the Arc/AKS cluster region. ARM requires resource locations to be known before
deployment, so this cannot be derived from the existing Arc resource inside the same template.
The default `storageClassName` is `default`, and the same StorageClass is used by CloudCasa and
the Workload Orchestration Redis dependency. Override it only when the target cluster does not
provide a dynamic StorageClass with that name. Kubernetes StorageClass names must be lowercase;
`main.bicep` normalizes the supplied value to lowercase before passing it to Helm.

For a non-AKS Arc-connected cluster, follow the Azure Arc workload identity federation procedure,
including configuring the Kubernetes API server to issue tokens from the Arc OIDC issuer.

## Key Vault behavior

Create or reconcile the named vault and populate its CloudCasa secrets:

```bicep
param keyVaultName = '<globally-unique-name>'
param populateKeyVaultSecrets = true
```

## Public hostname

For the single-file Day-0 path, use the Azure LoadBalancer hostname created by the Service DNS
label. Both values are generated from the Arc cluster name and deployment location by default:

```bicep
param connectClusterName = 'cloudcasa-example'
```

This produces the DNS label `cloudcasa-example-cloudcasa` and the hostname
`cloudcasa-example-cloudcasa.<resource-group-region>.cloudapp.azure.com`.

Custom domains such as `edge.cfgmgr.test.azure-test.net` are managed outside this resource-group
template because their Azure DNS zone is in a different resource group.

To preserve prepopulated CloudCasa secret values, reconcile the vault and skip secret writes:

```bicep
param keyVaultName = '<existing-vault-name>'
param populateKeyVaultSecrets = false
```

The existing vault must be in the deployment resource group and use Azure RBAC authorization.
Bicep still reconciles the vault settings and creates the Secret Store identity, role assignments,
federated credentials, and synchronization resources.

## Supply initial secret values

When `populateKeyVaultSecrets = true`, set the four environment variables referenced by the
parameter file:

```powershell
$LicensePath = "C:\path\to\cloudcasa-license.key"

$env:CLOUDCASA_REGISTRY_USERNAME = "<vendor-registry-username>"
$env:CLOUDCASA_REGISTRY_PASSWORD = "<vendor-registry-password>"
$env:CLOUDCASA_LICENSE_CONTENT = [IO.File]::ReadAllText($LicensePath)
$env:CLOUDCASA_LOCAL_ADMIN_PASSWORD = "<local-admin-password>"
```

The local administrator password must contain 16-64 printable ASCII characters without spaces.
This keeps the value within the Dex bcrypt input limit and prevents invalid generated configuration.

The license is stored as raw file content. `SecretSync` maps it to the `userLicense` key, producing
the same decoded Kubernetes Secret value as the previous Base64-in-Helm design.

Never place secret values directly in a `.bicepparam` file, generated ARM JSON, deployment debug
logs, or source control.

`localAuthenticationRevision` is appended to the Kubernetes Secret name. Increment it whenever
the local credentials change. This creates a new SecretSync destination, so bootstrap readiness
cannot succeed against a stale password.

## Publish the required charts

For a new customer ACR, sign in and publish the two included validated packages before deployment:

```powershell
$AcrToken = az acr login `
  --name "<acr-name>" `
  --resource-group "<arc-cluster-resource-group>" `
  --subscription "<subscription-id>" `
  --expose-token `
  --query accessToken `
  --output tsv

$AcrToken | helm registry login "<acr-name>.azurecr.io" `
  --username "00000000-0000-0000-0000-000000000000" `
  --password-stdin

helm push .\cloudcasa-bootstrap-0.2.4.tgz "oci://<acr-name>.azurecr.io/helm"
helm push .\cloudcasa-server-2.0.0-wo.4.tgz "oci://<acr-name>.azurecr.io/helm"
```

## Validate and deploy

```powershell
az bicep build --file .\main.bicep --stdout | Out-Null
az bicep build-params --file .\main.<cluster>.local.bicepparam --stdout | Out-Null

az deployment group validate `
  --subscription "<subscription-id>" `
  --resource-group "<arc-cluster-resource-group>" `
  --template-file .\main.bicep `
  --parameters .\main.<cluster>.local.bicepparam `
  --output none

az deployment group create `
  --name "cloudcasa-day0" `
  --subscription "<subscription-id>" `
  --resource-group "<arc-cluster-resource-group>" `
  --template-file .\main.bicep `
  --parameters .\main.<cluster>.local.bicepparam
```

No Azure deployment, role assignment, chart push, or commit is performed automatically by the
repository.

## Secret rotation

Update the secure parameter, increment `localAuthenticationRevision`, and increment both
`bootstrapSolutionTemplateVersion` and `solutionTemplateVersion`. The revision creates a new
Kubernetes Secret name, `forceSynchronization` triggers an immediate Key Vault check, and the
application references the same versioned Secret. WO versions must use `major.minor.patch`.

Increment `bootstrapSolutionTemplateVersion` whenever the bootstrap chart, vault metadata, secret
names, revision, or Kubernetes mapping changes. Increment `solutionTemplateVersion` whenever the
CloudCasa application configuration or referenced local-authentication Secret changes.

## Required Azure permissions

- Resource-group deployment write/read.
- Arc extension and Custom Location write/read.
- `Microsoft.Edge` context, target, solution template, and solution deployment write/read.
- Managed identity and federated identity credential write/read.
- Key Vault and Key Vault secret write/read when Bicep creates or populates the vault.
- `Microsoft.Authorization/roleAssignments/write` on the Key Vault.
- Optional `Microsoft.Authorization/roleAssignments/write` on the ACR when Bicep grants
  `AcrPull`.
