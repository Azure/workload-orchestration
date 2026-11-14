# Deploy Foundry Local as an Arc extension through Workload Orchestration

This sample uses a **WO cloud target** and an **ARM Template Spec** to install
`Microsoft.CertManagement` and `Microsoft.Foundry` on an existing Arc-connected AKS
cluster. It uses one Bicep file, one parameter file and one ARM deployment command.

You do **not** need to read the Bicep source to deploy. This guide lists the files,
prerequisites, parameters and commands in execution order, followed by workload and
authenticated inference validation.

```text
Bicep -> AKS prerequisite bootstrap -> WO cloud deployment
      -> ARM Template Spec -> Arc extensions -> Foundry operator platform
                          -> optional model script -> ModelDeployment -> ready model
```

The Template Spec and independent Azure resources may be created before bootstrap
finishes; the WO solution deployment waits for bootstrap.

**Scope:** by default this installs only the operator platform. With `deployModel = true`
and either a full catalog `modelAssetId` or exact alias/version/runtime/compute selectors,
the same WO ARM package also creates/updates one
authenticated, internally exposed generative model and waits for readiness.
No separate model Helm chart, YAML, script file or Bicep module is required.
Inference testing remains a separate user validation step.
The AKS-specific bootstrap requires the existing AKS and Arc resources in the same
deployment subscription/resource group. Neither is created or onboarded here.

For WO-managed operator **and model charts**, see the alternative
[Helm sample](../foundry-local/README.md). Do not install both operators on the same
cluster without a supported migration/data-retention plan.

## 1. What gets deployed

| Component | Purpose |
|---|---|
| Bootstrap managed identity and AKS role assignment | Gives the script access to retrieve AKS admin credentials. |
| Azure deployment script | Installs prerequisites, performs readiness/recovery checks and gates WO execution. |
| Gateway API / Inference CRDs and Istio | Pins `1.4.0`, `1.5.0` and `1.31.3` respectively. |
| WO context registration | Reuses the supplied context and adds missing `foundry-local` capability without replacing existing hierarchy/capabilities/tags. |
| Template Spec and version | Packages the two Arc extension definitions and conditional inline model script. |
| WO cloud target, solution template/version and deployment | Executes the Template Spec using an `armtemplate` component. |
| Arc extensions | `azure-cert-management` (`Microsoft.CertManagement`) then `inference-operator` (`Microsoft.Foundry`). |
| Kubernetes platform | Certificate/trust managers, operator, model store, internal gateway, telemetry and supporting resources/PVCs. |
| Optional WO model deployment script | Reuses the bootstrap identity after the Foundry extension succeeds; validates the installed catalog/schema, applies the inline ModelDeployment and waits for current model/workload readiness. |
| Optional ModelDeployment | One generative catalog asset, with configurable replicas/CPU/memory/GPU; authentication enabled and endpoint exposure `internal`. |

There is no custom location or WO Kubernetes Helm binding in this sample.
Bootstrap uses Helm for **Istio**; the Foundry extension internally owns its Helm
release. Do not separately install the Foundry chart.

Temporary deployment-script ACI/storage helpers are cleaned on success. The bootstrap
identity/role and persistent application data remain. Both scripts use the same
checksum-verified clients and credential handling. Deleting the private kubeconfig
file does not revoke the identity's retained credential-retrieval permission.

## 2. Files in this folder

| File | Description |
|---|---|
| `main.bicep` | **Entry point.** Creates the bootstrap resources, Template Spec, WO cloud target, solution template/version and solution deployment. Embeds the extension definitions and optional model script. |
| `main.params.bicepparam` | Environment and model settings to review before deployment. The supplied example enables Phi-4 CPU version `2` with `16Gi` memory. |
| `tests\test_model_deployment.py` | Offline regression tests for catalog selection, model schema, ownership and readiness checks. |
| `tests\test_aks_credentials.py` | Offline regression tests for AKS credential retries and managed-identity reauthentication. |

No separate Template Spec publication, `update-context.bicep`, model Helm chart or
model manifest is required. Deploy `main.bicep` using the supplied parameter file.

## 3. Prerequisites and permissions

- Existing healthy AKS and its correct Arc registration in the deployment RG/subscription.
  The two Azure resource names can differ.
- A supported WO/Foundry region, appropriate Kubernetes version, free compute and dynamic
  persistent storage. Replace the parameter file's region placeholders with supported
  regions for your environment; the ACI/bootstrap region can differ from the WO region.
- AKS local accounts enabled for the implemented `--admin` bootstrap.
- AKS API reachability from the deployment-script container. Private/API-restricted clusters
  need an approved connectivity design; this sample does not provision script VNet integration.
- Required Azure providers, ACI/storage capacity and package/product network access.
- Azure CLI/Bicep supporting `.bicepparam` `using` declarations.
  `connectedk8s` and `k8s-extension` CLI extensions support the validation commands.
  Workstation kubectl and `curl.exe` are needed for the optional local inference test.
  Python is needed only for catalog decoding or the offline tests.
- No conflicting independently Helm-managed Foundry operator or duplicate certificate extension.

| Identity | Required access |
|---|---|
| Deployment user/pipeline | Resource-management permissions, including context write at its actual scope. Subscription Contributor covers the ordinary resource-management steps, subject to policy. |
| Deployment user: AKS role delegation | **Role Based Access Control Administrator scoped to the AKS resource**, or equivalent `Microsoft.Authorization/roleAssignments/write`. Contributor alone is insufficient for `bootstrapAksAccess`. |
| Bootstrap managed identity | Bicep grants **Azure Kubernetes Service Cluster Admin Role** on the AKS resource. This allows full Kubernetes admin credentials, not namespace-only access. |
| Existing WO ARM execution principal | Template Spec/version read and target-RG `Microsoft.Resources/deployments/write` plus ARM/Arc-extension deployment permissions. With models enabled, also deployment-script, ACI/storage helper creation and `Microsoft.ManagedIdentity/userAssignedIdentities/assign/action` on the bootstrap identity. Target-RG **Contributor** covers ordinary management/identity assignment actions, subject to policy; custom roles must include the deployment-script service's required storage data actions. Pre-authorize the correct principal separately. |
| Optional validation operator | Azure read, AKS user-credential retrieval permission (for example, AKS Cluster User Role), and appropriate Kubernetes read/watch permissions. The inference example also requires read access to the named model-key Secret. Do not grant admin solely for validation or give ordinary application callers Kubernetes Secret access. |

An authorized administrator must grant the human/pipeline's role-delegation permission.
Subscription Owner is not necessary for the AKS assignment step. The human deployer's,
bootstrap identity's and WO execution principal's permissions are separate.

An Entra-authenticated/custom-RBAC bootstrap could reduce privilege, but that redesign
is **not implemented** here. Switching only to Cluster User does not reduce access on
AKS without Entra integration. AKS authentication is separate from Foundry API Entra.

The model script uses Kubernetes admin access, not the Foundry control-plane REST API;
it does not require an additional Foundry API token or create an API app registration.
GPU models require already configured hardware, drivers and scheduling support. This
sample targets the generic platform; Jetson/ARM64-specific deployment settings are not
implemented. Confirm resource sizing, storage capacity and catalog compatibility first.

## 4. Step-by-step deployment

### Step 1 - Open the supplied sample and define values

```powershell
Set-Location "C:\path\to\workload-orchestration\applications\foundry-local-extension"
Get-Item .\main.bicep, .\main.params.bicepparam
$TenantId = "<tenant-id>"
$SubscriptionId = "<subscription-id>"
$ResourceGroupName = "<resource-group-containing-AKS-and-Arc>"
$AksClusterName = "<underlying-AKS-resource-name>"
$ArcClusterName = "<arc-connected-cluster-resource-name>"
$DeploymentName = "foundry-local-wo-extension"
$ParameterFile = ".\main.params.bicepparam"
az login --tenant $TenantId
if ($LASTEXITCODE -ne 0) { throw "Sign-in failed." }
az account show --subscription $SubscriptionId `
  --query "{subscription:id,tenant:tenantId,state:state}" -o table
if ($LASTEXITCODE -ne 0) { throw "Subscription verification failed." }
```

Use the supplied reviewed files; do not assume this local sample is available in a
clone of the repository's default branch before it is published.

### Step 2 - Verify both existing resources

```powershell
az group show --subscription $SubscriptionId --name $ResourceGroupName `
  --query "{name:name,location:location}" -o table
if ($LASTEXITCODE -ne 0) { throw "Target RG verification failed." }
az aks show --subscription $SubscriptionId `
  --resource-group $ResourceGroupName --name $AksClusterName `
  --query "{name:name,state:provisioningState,version:currentKubernetesVersion,localAccountsDisabled:disableLocalAccounts}" -o table
if ($LASTEXITCODE -ne 0) { throw "AKS verification failed." }
az connectedk8s show --subscription $SubscriptionId `
  --resource-group $ResourceGroupName --name $ArcClusterName `
  --query "{name:name,state:provisioningState,connectivity:connectivityStatus}" -o table
if ($LASTEXITCODE -ne 0) { throw "Arc verification failed." }
```

Continue only with the intended healthy pair, Arc Connected and local admin accounts
not disabled. Do not target an obsolete Arc registration or an unrelated kube-context.

### Step 3 - Configure `main.params.bicepparam`

Keep `using './main.bicep'` and replace every `<...>` placeholder in the supplied
parameter file: both regions, the AKS/Arc names and the context resource ID's
subscription/resource-group/name segments. For example:

```bicep
using './main.bicep'

param location = '<supported-WO-and-Template-Spec-region>'
param connectClusterName = '<arc-connected-cluster-resource-name>'
param aksClusterName = '<underlying-AKS-resource-name>'
param bootstrapLocation = '<aci-supported-region>'
param gatewayApiVersion = '1.4.0'
param inferenceExtensionVersion = '1.5.0'
param istioVersion = '1.31.3'
param entraClientId = ''
param contextId = '<existing-WO-context-resource-id>'
param deployModel = false
param modelAssetId = ''
```

The following defaults are declared in `main.bicep`; the supplied parameter file
explicitly sets both package versions:

| Default in `main.bicep` | Value |
|---|---|
| `templateSpecVersion` | `1.0.11` |
| `solutionTemplateVersion` | `1.0.11` |
| `certManagerExtensionName` | `azure-cert-management` |
| `foundryExtensionName` | `inference-operator` |

They remain overridable when approved existing names/configuration require it.
Package `1.0.4` introduced optional model deployment; `1.0.5` added compute/display
controls. Package `1.0.7` added runtime catalog resolution and explicit runtime/readiness
checks; `1.0.8` corrected compatibility with native API-key authentication in the installed
v1 CRD. Package `1.0.10` corrected native endpoint/readiness status handling; `1.0.11`
adds bounded managed-identity subscription-cache recovery. The supplied
parameter file explicitly overrides both versions to `1.0.11`.
These are WO/Template Spec versions,
not Foundry software or catalog model versions.

Use an existing full context ID when available. The target uses its last hierarchy
level by default. A supplied hierarchy override must
exist in a nonempty hierarchy. Leave `contextId = ''` only for first-context creation,
then reuse the output ID.

Blank `entraClientId` disables Foundry API Entra for initial operator setup; SAT support
is enabled and the API remains internal. No app is created. Configure production API
and future model caller authorization separately; Agentic Retrieval needs Entra enabled.
Increment the version defaults/overrides after reviewed template/configuration changes.

#### Optional model settings in the same parameter file

The supplied parameter file enables the model and leaves `modelAssetId` empty.
The existing inline script waits for the installed catalog and resolves these selectors
at deployment time, so a separate operator-only deployment or manual catalog copy is
not required:

```bicep
param deployModel = true
param modelAssetId = ''
param modelCatalogAlias = 'phi-4'
param modelVersion = '2'
param modelRuntime = 'onnx-genai'
param modelCompute = 'cpu'
```

This is a pinned CPU example for parity with the Helm sample, not proof that version 2
is offered on your cluster or that the supplied resources are sufficient.
Alias matching is exact and case-insensitive; version, runtime and compute must all
match. There is no partial/display-name matching, latest-version selection, arbitrary
first match or constructed asset ID. The script requires exactly one distinct full
asset ID and reports available version/runtime/compute combinations if selection fails.

It handles catalog model records and their nested variants, retaining the full asset ID
from the catalog. ONNX framework metadata maps to `onnx-genai`; unknown runtime/compute
metadata is not guessed. Model version metadata is checked against artifact-ID and
Azure ML asset-ID versions when available. Unsupported or ambiguous catalog layouts
require reviewed selectors or an explicit full asset ID, not a bypass.
See the [catalog reference](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/concept-model-catalog)
and [public catalog schema snapshot](https://github.com/Azure-Samples/foundry-local-model-catalog/blob/main/MODEL_CATALOG.md).

For troubleshooting or selecting an explicit asset, use the verified direct AKS context
from Step 8 to inspect the non-secret ConfigMap:

```powershell
& $Kubectl @KubeArgs --request-timeout=30s -n foundry-local-operator `
  get configmap foundry-local-catalog -o json |
  python -c "import sys,json,base64,gzip; cm=json.load(sys.stdin); print(json.dumps(json.loads(gzip.decompress(base64.b64decode(cm['binaryData']['catalog.json.gz']))), indent=2))"
if ($LASTEXITCODE -ne 0) { throw "Catalog decoding failed." }
```

An explicitly supplied **full `assetId`** overrides alias/version resolution.
Runtime and compute remain optional manifest constraints and must match that asset;
set them empty to inherit both. Review the entry's task and resource requirements.
Edit existing assignments rather than adding duplicates:

```bicep
param deployModel = true
param modelAssetId = '<full-assetId-copied-from-installed-catalog>'
param modelCatalogAlias = ''
param modelVersion = ''
param modelRuntime = ''
param modelDeploymentName = 'foundry-model'
param modelDisplayName = 'Foundry Local Model'
param modelCompute = 'cpu'
param modelReplicas = 1
param modelCpu = '2'
param modelMemory = '16Gi'
param modelGpuCount = 0
param modelReadyTimeoutSeconds = 1800
```

CPU/memory values are illustrative, not minimum model requirements; requests and limits
are equal per replica. The supplied parameter file shows an
enabled CPU resolver example. `modelCompute = 'cpu'` requires zero GPUs, while `'gpu'` requires
a GPU count of 1-8. Explicit compute must also match the selected asset.
With an explicit asset ID, leave `modelRuntime = ''` and `modelCompute = ''` to inherit
the catalog settings. With alias resolution, both must be supplied. This sample creates
`workloadType: generative`; it does not support predictive/BYO model registration.

For a GPU deployment, edit the same model block rather than appending duplicate assignments:

```bicep
param modelAssetId = ''
param modelCatalogAlias = 'phi-4'
param modelVersion = '2'
param modelRuntime = 'onnx-genai'
param modelDisplayName = 'Foundry Local GPU Model'
param modelCompute = 'gpu'
param modelGpuCount = 1
param modelCpu = '4'
param modelMemory = '32Gi'
```

GPU CPU/memory values above are illustrative, not minimum requirements. Set appropriate
resources for the actual asset and available hardware. A GPU asset is a different ID
from its CPU variant; changing only `modelCompute` does not convert a CPU asset into one.
This sample does not provision GPUs, drivers, node selectors or tolerations.

#### Model controls compared with the Helm sample

The Helm sample creates a separate WO `helm.v3` model component using the
`foundrypoc.azurecr.io/helm/ai-model` chart (`0.1.0`), after its inference deployment.
Its supplied parameters select catalog name `Phi-4-generic-cpu`, model version `2`,
CPU compute, one replica, `2` CPU and `16Gi` memory. These are configuration values,
not evidence that this model is currently running.

| Helm model input | Extension equivalent |
|---|---|
| `modelName` | `modelDeploymentName`; native resource name, not catalog selection. |
| `modelDisplayName` | `modelDisplayName`; optional native `spec.displayName`. |
| `modelCatalogName` + `modelVersion` | `modelCatalogAlias` + `modelVersion` + `modelRuntime` + `modelCompute` resolve an exact catalog asset, or supply `modelAssetId` directly. Catalog aliases are not necessarily the legacy chart names. |
| `modelCompute` | `modelCompute`; `cpu`, `gpu`, or empty to inherit the asset's compute. |
| `modelReplicas` | `modelReplicas`. |
| `modelCpu`, `modelMemory` | Same inputs; equal requests/limits per replica for both CPU and GPU models. |
| GPU allocation | Extension adds explicit `modelGpuCount`; the Helm Bicep does not pass an explicit GPU count. |
| `modelChartRepository`, `modelChartVersion` | Not used: the model is a native ModelDeployment, not another Helm chart. |
| `modelEndpointEnabled` | No legacy toggle copied; the extension model retains authenticated internal routing. |

**Selecting model version 2:** the resolver requests version `2` only **if that
version/variant is offered**. It still creates a native `model.assetId` manifest, not
a legacy `model.catalog` name/version manifest. No model version is inferred from the
display name, deployment name, chart version or WO package version. The script reports
the selected asset and the operator's resolved model version, compute and runtime.

Increment **both package versions** after template/configuration changes. This update
uses `1.0.11` instead of the previously published `1.0.10`; choose another unused
version if `1.0.11` already exists. WO solution-template versions are immutable.

WO manages the ARM/script package; the Foundry operator reconciles the model and child
workloads. The script refuses automatic adoption of a model created outside this WO
solution and uses server-side apply **without forced field ownership**. Keep the WO
solution name stable. Changing the model name creates another model; disabling
`deployModel` does **not** delete the existing model. Coordinate deletion, data retention
and any migration separately.

### Step 4 - Review automatic bootstrap and rerun impact

Bootstrap downloads checksum-verified tools, retrieves a private AKS admin kubeconfig,
applies/waits for CRDs, installs/upgrades Istio and verifies GatewayClass readiness.
Both scripts retry known AKS credential authorization failures for up to 30 attempts
with ten-second delays. If Azure CLI reports that the exact expected subscription is
absent from its cache, the script re-authenticates the same attached user-assigned
identity by client ID before retrying. This handles fresh role-assignment visibility
without granting the bootstrap identity broader permissions. Other credential errors,
reauthentication failures and exhausted retries remain fatal; the target subscription
and AKS scope never change.

It always refreshes an existing cert-manager's discovery and performs
release-label-scoped recovery:

- `model-store-auth` CPU: `250m` request / `1` CPU limit, retaining memory and health probes.
- Any matching existing operator is patched to `Recreate` to recover an RWO surge problem,
  even if it is currently healthy. Bootstrap does not restore the original strategy;
  a later extension-managed Helm update can restore the vendor configuration.
- After these recovery changes, pending/unknown native release states block another
  WO deployment. A blocked WO operation does not mean bootstrap made no cluster changes.

`bootstrapRunTag = utcNow()` reruns these actions on every deployment, so unchanged
parameters do not imply a no-op. Schedule maintenance; do not overlap unfinished native
extension operations or bypass hooks/authentication.

With models enabled, WO waits for extension success, then runs the model script.
It waits up to ten minutes for an Established supported model CRD, a deployed native
Foundry release, current operator/model-store rollouts and a populated catalog.
It resolves the exact selector match or validates an explicit asset against
the compressed installed catalog, server-validates required model fields, and applies
only after catalog, schema and ownership checks pass. Failure is explicit; there is no
legacy-selector fallback or forced apply.

Current v1 operators generate per-model API keys natively and report only their Secret
name in `status.authentication.keysSecretName`. They do not expose
`spec.authentication.enabled`; adding that field is invalid. The script requires the
asset-ID and native key-status schema, omits the unsupported field, and still requires
the generated key Secret name before declaring readiness. On older supported schemas
that expose a boolean `spec.authentication.enabled`, it explicitly sets that flag true.
`spec.authenticationMethods` is for optional SAT role/subject grants and is not changed
by this sample. See [authentication behavior](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/concept-authentication-authorization).
Neither deployment script disables authentication checks, TLS checks, hooks or probes.

The model wait is separately bounded by `modelReadyTimeoutSeconds`. Success requires
`Running`, the selected resolved asset and explicit compute/runtime (when supplied),
model/service/route readiness, an API-key Secret
**name** and internal endpoint, plus a current owner-matched Deployment with the
requested replicas and resources. This prevents an old `Running` status from hiding
an unfinished resource/replica update. Neither script reads or outputs model API keys.
The model script has an overall `PT90M` execution cap.

For current native status, the script requires `serviceCreated`, `httpRouteReady` and
`tlsEnabled`, and reads the HTTPS URL from `endpoints.internal`. Owner-matched current
ready replicas remain mandatory; service existence alone is not success. Older status
with `serviceReady`, `endpointReady` and `internalEndpoint` is also supported, without
falling back to native fields when that legacy contract is incomplete or false.

Shared-context registration preserves the read snapshot of capability, hierarchy and
tag entries; coordinate with the context owner and avoid concurrent context writers.

### Step 5 - Build, validate and preview

```powershell
az bicep build --file .\main.bicep --stdout | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Bicep build failed." }
az bicep build-params --file $ParameterFile --stdout | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Parameter compilation failed." }
az deployment group validate --subscription $SubscriptionId `
  --resource-group $ResourceGroupName --parameters $ParameterFile -o none
if ($LASTEXITCODE -ne 0) { throw "ARM validation failed." }
az deployment group what-if --subscription $SubscriptionId `
  --resource-group $ResourceGroupName --parameters $ParameterFile
if ($LASTEXITCODE -ne 0) { throw "What-if failed." }
```

Review all changes and reject unexpected deletes. Known warnings include BCP081 for
WO preview schemas and `no-deployments-resources` for inline context registration.
Nested context changes may be short-circuited in what-if; Kubernetes script actions and
downstream WO execution also need review. Warnings are not deployment-health evidence.

For local regression checks without Azure/Kubernetes access, run
`python -B -m unittest discover -s .\tests -v` from this sample directory.
These tests exercise the inline model script with local fakes, not a live model.

### Step 6 - Deploy with one ARM command

```powershell
az deployment group create `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroupName `
  --name $DeploymentName `
  --parameters $ParameterFile
if ($LASTEXITCODE -ne 0) { throw "Foundry extension WO deployment failed." }
```

No separate `update-context.bicep`, model manifest/script, prerequisite-install command
or direct Foundry Helm/Arc-extension creation command is required for the implemented flow.

### Step 7 - Verify Azure, WO and extension states

```powershell
$ResultJson = az deployment group show --subscription $SubscriptionId `
  --resource-group $ResourceGroupName --name $DeploymentName `
  --query "{state:properties.provisioningState,correlationId:properties.correlationId,outputs:properties.outputs}" -o json
if ($LASTEXITCODE -ne 0) { throw "Deployment lookup failed." }
$Result = $ResultJson | ConvertFrom-Json
$Result | ConvertTo-Json -Depth 8
if ($Result.state -ne "Succeeded") { throw "ARM deployment is not Succeeded." }
$WoId = $Result.outputs.solutionDeploymentId.value
$SpecId = $Result.outputs.templateSpecVersionId.value
if (-not $WoId -or -not $SpecId) { throw "Required output IDs are missing." }
az resource show --subscription $SubscriptionId --ids $WoId `
  --api-version 2026-05-01-preview `
  --query "{id:id,state:properties.provisioningState}" -o json
if ($LASTEXITCODE -ne 0) { throw "WO lookup failed." }
az resource show --subscription $SubscriptionId --ids $SpecId `
  --api-version 2022-02-01 --query "{id:id}" -o json
if ($LASTEXITCODE -ne 0) { throw "Template Spec lookup failed." }
foreach ($Name in @("azure-cert-management", "inference-operator")) {
  # Adjust these names if you intentionally override extension defaults.
  az k8s-extension show --subscription $SubscriptionId `
    --resource-group $ResourceGroupName --cluster-name $ArcClusterName `
    --cluster-type connectedClusters --name $Name `
    --query "{name:name,type:extensionType,state:provisioningState,version:version}" -o table
  if ($LASTEXITCODE -ne 0) { throw "Extension lookup failed: $Name" }
}
```

Confirm Arc Connected, WO/both extensions Succeeded and the Template Spec version exists.
Record actual extension versions; both use stable train with automatic minor upgrades.
**Do not stop at ARM success:** final post-hook Kubernetes rollouts can still be stabilizing.

### Step 8 - Verify the kube-context and workloads

Use a **separate kubeconfig file** and normal user credentials for validation, not
`--admin`. This avoids changing the default kubeconfig or using a same-named context
that belongs to another cluster/resource group. Use this file for one validation
session at a time; it contains credentials and must not be shared or committed.

```powershell
$KubeFile = Join-Path $env:TEMP "foundry-ext-validation.kubeconfig"
$KubeContext = "foundry-ext-verify"
$Kubectl = (Get-Command kubectl -CommandType Application |
  Select-Object -First 1).Source
$AksJson = az aks show --subscription $SubscriptionId `
  --resource-group $ResourceGroupName --name $AksClusterName -o json
if ($LASTEXITCODE -ne 0) { throw "Cannot verify the AKS endpoint." }
$Aks = $AksJson | ConvertFrom-Json
$ExpectedHosts = @($Aks.fqdn, $Aks.privateFqdn) |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

az aks get-credentials --subscription $SubscriptionId `
  --resource-group $ResourceGroupName --name $AksClusterName `
  --file $KubeFile --context $KubeContext --overwrite-existing
if ($LASTEXITCODE -ne 0) { throw "Cannot obtain AKS user credentials." }
$KubeArgs = @("--kubeconfig", $KubeFile, "--context", $KubeContext)
$Server = & $Kubectl @KubeArgs config view --minify `
  -o "jsonpath={.clusters[0].cluster.server}"
if ($LASTEXITCODE -ne 0) { throw "Kube-context is unavailable." }
if ($ExpectedHosts -notcontains ([uri]$Server).DnsSafeHost) {
  throw "Endpoint mismatch. Stop; do not query another cluster."
}
& $Kubectl @KubeArgs --request-timeout=75s wait `
  --for=condition=Established --timeout=60s `
  crd/gateways.gateway.networking.k8s.io `
  crd/inferencepools.inference.networking.k8s.io
if ($LASTEXITCODE -ne 0) { throw "Prerequisite CRDs are not Established." }
& $Kubectl @KubeArgs --request-timeout=75s wait `
  gatewayclass/istio --for=condition=Accepted --timeout=60s
if ($LASTEXITCODE -ne 0) { throw "GatewayClass is not Accepted." }
foreach ($Namespace in @("istio-system", "cert-manager", "foundry-local-operator")) {
  & $Kubectl @KubeArgs --request-timeout=15s `
    -n $Namespace get deployment,pods,pvc
  if ($LASTEXITCODE -ne 0) { throw "Workload lookup failed: $Namespace" }
  $Deployments = @(& $Kubectl @KubeArgs --request-timeout=15s `
    -n $Namespace get deployment -o name)
  if ($LASTEXITCODE -ne 0 -or $Deployments.Count -eq 0) {
    throw "Deployment discovery failed or is empty: $Namespace"
  }
  foreach ($Deployment in $Deployments) {
    & $Kubectl @KubeArgs --request-timeout=11m `
      -n $Namespace rollout status $Deployment --timeout=10m
    if ($LASTEXITCODE -ne 0) { throw "Rollout is not ready: $Deployment" }
  }
}
& $Kubectl @KubeArgs --request-timeout=15s `
  -n foundry-local-operator get jobs
if ($LASTEXITCODE -ne 0) { throw "Job lookup failed." }
```

Verify current ready deployments, Bound evaluation/model-store PVCs, current completed
maintenance/auth Jobs and retained CPU/probe settings. Historical failed retry pods are
not the same as current failed Jobs. These platform checks alone do not establish model
readiness or successful inference.

### Step 9 - Verify the optional model

If `deployModel = false`, skip the model/inference steps. Otherwise, continue in the
same PowerShell terminal used for Steps 7-8.

`modelDeploymentRequested` is configuration, not a readiness assertion. When true, inspect
the model script's state and safe outputs before its retained resource expires:

```powershell
if ($Result.outputs.modelDeploymentRequested.value) {
  $ModelScriptId = $Result.outputs.modelDeploymentScriptId.value
  az resource show --subscription $SubscriptionId --ids $ModelScriptId `
    --api-version 2023-08-01 `
    --query "{state:properties.provisioningState,outputs:properties.outputs}" -o json
  if ($LASTEXITCODE -ne 0) { throw "Model script lookup failed; check retention and WO execution." }
  $ModelName = $Result.outputs.modelResourceName.value
  & $Kubectl @KubeArgs --request-timeout=30s -n foundry-local-operator `
    get modeldeployments.foundrylocal.azure.com $ModelName -o `
    'jsonpath={.status.state}{"\n"}{.status.resolvedModel.assetId}{"\n"}{.status.resolvedModel.version}{"\n"}{.status.resolvedModel.compute}{"\n"}{.status.endpoints.internal}{"\n"}{.status.internalEndpoint}{"\n"}'
  if ($LASTEXITCODE -ne 0) { throw "Model lookup failed." }
  & $Kubectl @KubeArgs --request-timeout=75s -n foundry-local-operator `
    rollout status "deployment/$ModelName" --timeout=60s
  if ($LASTEXITCODE -ne 0) { throw "Model workload is not ready." }
  & $Kubectl @KubeArgs --request-timeout=30s -n foundry-local-operator get pods
  if ($LASTEXITCODE -ne 0) { throw "Model pod lookup failed." }
}
```

Require script `Succeeded` and current model `Running`, and investigate non-ready child
pods/PVCs or events. Script outputs include name, namespace, selected asset, reported
model version/compute/runtime, state and internal endpoint; they do not include keys.
Version/compute/runtime metadata can be null when not reported and not explicitly
constrained; the full asset ID remains the version/variant pin. Explicit compute and
runtime inputs must match the operator's resolved values before success. A previous
successful script does not prove continuing model health.

For the supplied CPU example, expect model `Running`, Deployment `1/1` ready and the
model pod `3/3 Running`. Investigate restarts, `OOMKilled`, pending pods or unbound PVCs
before inference testing. These are readiness checks, not proof of generated text.

### Step 10 - Test authenticated inference from your workstation

The default endpoint is **cluster-internal**, not a public URL. The following
two-terminal PowerShell example tests a chat-completion model through the internal
HTTPS gateway without creating a public endpoint or deploying a client pod.
Keep the `/foundry-model` routing prefix when using the supplied model name.

This is an **operator validation** example: it reads the model's primary API key
directly into memory using your authorized Kubernetes access. The key is not printed,
written to a file or passed in curl's process arguments. Do not use verbose/trace
logging, share Secret contents or grant Kubernetes admin just to obtain a key.
Ordinary application users should receive approved connectivity and credentials
through the platform operator's secret-distribution process.

#### Terminal 1 - Forward the gateway's HTTPS port

Continue in the verified terminal from Steps 8-9:

```powershell
& $Kubectl @KubeArgs -n foundry-local-operator port-forward `
  --address 127.0.0.1 service/inference-internal-gateway-istio 8443:443
```

Leave this command running. Forward gateway Service port **443**, not the model
Service's separate port. The tunnel listens only on loopback.

#### Terminal 2 - Verify authentication, discover the model and send a prompt

Open a second PowerShell terminal on the same workstation. Match `$ModelName` to
`modelDeploymentName` if you changed the supplied `foundry-model` name.
This block uses the separate kubeconfig verified in Step 8.

**Windows TLS revocation policy:** the example includes `--ssl-revoke-best-effort`
for Schannel clients using the private cluster CA. It retains CA-chain and hostname
verification but tolerates missing/offline revocation information; it is **not strict
revocation validation**. Use it only if your policy permits this behavior.
If strict revocation checking is required, remove that flag and provide working
revocation infrastructure/reachability instead. Do not substitute `-k`,
`--ssl-no-revoke` or `-SkipCertificateCheck`.

The public CA bundle is read from a ConfigMap, not a private-key Secret.
`--resolve` connects to loopback while preserving the original HTTPS hostname for
SNI and certificate matching; `--noproxy` applies only to that tunneled hostname.
The internal URL is read from model status, preserving its routing prefix.

Copy the **entire block**, including the `$CurlArgs` definition. Setting arguments
alone does not send a request, and the `finally` block removes the temporary files,
so rerun the whole block after a failed attempt.

```powershell
$KubeFile = Join-Path $env:TEMP "foundry-ext-validation.kubeconfig"
$KubeArgs = @("--kubeconfig", $KubeFile, "--context", "foundry-ext-verify")
$Kubectl = (Get-Command kubectl -CommandType Application |
  Select-Object -First 1).Source
$ModelNamespace = "foundry-local-operator"
$ModelName = "foundry-model"
$CaFile = [IO.Path]::GetTempFileName()
$BodyFile = [IO.Path]::GetTempFileName()
$ApiKey = $B64 = $null

try {
  $ModelJson = & $Kubectl @KubeArgs --request-timeout=30s -n $ModelNamespace `
    get modeldeployments.foundrylocal.azure.com $ModelName -o json
  if ($LASTEXITCODE -ne 0) { throw "Model lookup failed." }
  $Model = $ModelJson | ConvertFrom-Json -ErrorAction Stop
  if ($Model.status.state -ne "Running") { throw "ModelDeployment is not Running." }

  $EndpointValue = $Model.status.endpoints.internal
  if ([string]::IsNullOrWhiteSpace($EndpointValue)) {
    $EndpointValue = $Model.status.internalEndpoint
  }
  if ([string]::IsNullOrWhiteSpace($EndpointValue)) {
    throw "Model status has no internal endpoint."
  }
  $Endpoint = [uri]$EndpointValue
  $ExpectedHost = "inference-internal-gateway-istio.$ModelNamespace.svc.cluster.local"
  if (-not $Endpoint.IsAbsoluteUri -or $Endpoint.Scheme -ne "https" -or
      $Endpoint.Port -ne 443 -or $Endpoint.DnsSafeHost -ne $ExpectedHost) {
    throw "Internal endpoint does not match the forwarded HTTPS gateway. Review the route."
  }
  $GatewayHost = $Endpoint.DnsSafeHost
  $BaseUrl = "https://${GatewayHost}:8443$($Endpoint.AbsolutePath.TrimEnd('/'))"

  $CaJson = & $Kubectl @KubeArgs --request-timeout=30s -n $ModelNamespace `
    get configmap foundry-local-operator-ca-bundle -o json
  if ($LASTEXITCODE -ne 0) { throw "CA bundle lookup failed." }
  $Ca = ($CaJson | ConvertFrom-Json -ErrorAction Stop).data.'ca.crt'
  if ([string]::IsNullOrWhiteSpace($Ca)) { throw "Public CA bundle is empty." }
  Set-Content -LiteralPath $CaFile -Value $Ca -Encoding ascii -ErrorAction Stop

  $CurlArgs = @(
    "-q", "--silent", "--show-error",
    "--cacert", $CaFile,
    "--ssl-revoke-best-effort",
    "--resolve", "${GatewayHost}:8443:127.0.0.1",
    "--noproxy", $GatewayHost,
    "--connect-timeout", "10", "--max-time", "180"
  )

  $Http = curl.exe @CurlArgs --output NUL --write-out '%{http_code}' "$BaseUrl/v1/models"
  if ($LASTEXITCODE -ne 0 -or $Http -ne "401") {
    throw "Expected HTTP 401 without a key; got $Http."
  }
  Write-Output "Missing-key test: HTTP $Http"

  $SecretName = $Model.status.authentication.keysSecretName
  if ([string]::IsNullOrWhiteSpace($SecretName)) {
    throw "Model key Secret name is not available."
  }
  $B64 = & $Kubectl @KubeArgs --request-timeout=30s -n $ModelNamespace `
    get secret $SecretName -o 'jsonpath={.data.primary-key}'
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($B64)) {
    throw "Cannot read the model API key; authorized Secret access is required."
  }
  $ApiKey = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B64))

  $ModelsJson = "api-key: $ApiKey" | curl.exe @CurlArgs `
    --fail-with-body --header '@-' "$BaseUrl/v1/models"
  if ($LASTEXITCODE -ne 0) { throw "Authenticated model discovery failed." }
  $Models = $ModelsJson | ConvertFrom-Json -ErrorAction Stop
  $ModelId = ($Models.data | Select-Object -First 1).id
  if ([string]::IsNullOrWhiteSpace($ModelId)) { throw "No served model ID was returned." }

  $Body = @{
    model = $ModelId
    messages = @(@{ role = "user"; content = "Say hello in one short sentence." })
    max_tokens = 32
    stream = $false
  } | ConvertTo-Json -Depth 5 -Compress
  [IO.File]::WriteAllText($BodyFile, $Body, [Text.UTF8Encoding]::new($false))

  $ReplyJson = "api-key: $ApiKey" | curl.exe @CurlArgs `
    --fail-with-body --header '@-' --header "Content-Type: application/json" `
    --data-binary "@$BodyFile" "$BaseUrl/v1/chat/completions"
  if ($LASTEXITCODE -ne 0) { throw "Chat request failed." }
  $Reply = $ReplyJson | ConvertFrom-Json -ErrorAction Stop
  $Text = ($Reply.choices | Select-Object -First 1).message.content
  if ([string]::IsNullOrWhiteSpace($Text)) {
    throw "Inference returned no generated text."
  }
  Write-Output "Served model: $ModelId"
  Write-Output $Text
} finally {
  $ApiKey = $B64 = $null
  Remove-Item -LiteralPath $CaFile, $BodyFile -ErrorAction Stop
}
```

Example output from a successful validation of the supplied Phi-4 CPU configuration:

```text
Missing-key test: HTTP 401
Served model: Phi-4-generic-cpu:2
Hello! How can I assist you today?
```

Generated wording may vary. Success requires **all three**: rejection without a key,
authenticated model discovery, and nonempty generated text. HTTP `200` alone or a
healthy pod is not an inference test. The served `/v1/models` **ID**, not the catalog
asset ID or WO package version, is used in chat requests.
Repeat requests when checking stability; this short test is not a load/capacity test.

#### Use the model from an application

For an approved application inside the cluster, the supplied model's API base URL is:

```text
https://inference-internal-gateway-istio.foundry-local-operator.svc.cluster.local/foundry-model/v1
```

Use the actual model endpoint from status if the model name differs. Trust the public
cluster CA, provide the API key through an approved secret mechanism, and send
`api-key` as a request header. Append `/chat/completions` to the base URL and use the
served model ID in the JSON body. Do not append `/v1` twice or drop the model prefix.
Keep the port-forward for local testing, not permanent/public application access.
Embedding and speech assets need their task-specific endpoints; this sample deploys
a generative model and the chat test does not validate those tasks.

### Step 11 - Close local validation access

Press **Ctrl+C** in Terminal 1 to stop the tunnel. Then remove only the dedicated local
validation kubeconfig created in Step 8:

```powershell
Remove-Item -LiteralPath $KubeFile -ErrorAction Stop
```

The inference block already removes its temporary public-CA/request files and clears
the API-key variables. This local cleanup does not uninstall Foundry, delete a model,
revoke credentials or remove any Azure/Kubernetes resources.

## 5. Parameter reference

| Parameter | Default / meaning |
|---|---|
| `location` | Resource-group region; use a supported WO/Template Spec region. |
| `connectClusterName` | Required existing Arc resource name. |
| `aksClusterName` | Required existing AKS name in the same RG/subscription. |
| `bootstrapLocation` | `eastus2` in `main.bicep`; the parameter file uses a region placeholder. ACI/script availability and API access required. |
| `gatewayApiVersion` | `1.4.0`. |
| `inferenceExtensionVersion` | `1.5.0`. |
| `istioVersion` | `1.31.3`. |
| `bootstrapRunTag` | `utcNow()`; reruns bootstrap/recovery actions. |
| `contextId` | Empty by default; reuse an existing context when available. |
| `hierarchyLevel` | Empty; uses the last context level or initial `level-1`. |
| `capabilityName` | `foundry-local`. |
| `targetName` | `${connectClusterName}-foundry-extension-target`; 3-61 characters. |
| `solutionName` | `${connectClusterName}-foundry-extension`; 3-61 characters. |
| `solutionDeploymentName` | Deterministic `foundry-...` name; 3-24 characters. |
| `templateSpecName` | Defaults to `solutionName`. |
| `templateSpecVersion` | `1.0.11`, defaulted in `main.bicep` and supplied explicitly in the parameter file. |
| `solutionTemplateVersion` | `1.0.11`, defaulted in `main.bicep` and supplied explicitly in the parameter file. |
| `entraTenantId` | Subscription tenant; Foundry API tenant, not an AKS auth-mode switch. |
| `entraClientId` | Empty initially; no app registration is created. |
| `certManagerExtensionName` | `azure-cert-management`, defaulted in `main.bicep`. |
| `foundryExtensionName` | `inference-operator`, defaulted in `main.bicep`. |
| `deployModel` | `false`; opt in to model creation/update and readiness. Disabling does not delete models. |
| `modelDeploymentName` | `foundry-model`; lowercase DNS label, 1-63 characters. |
| `modelDisplayName` | Empty by default; optional human-readable name, at most 256 characters. Supplied file uses `Foundry Local Model`. |
| `modelAssetId` | Empty; optional exact catalog asset override, at most 256 characters. Empty requires the alias/version/runtime/compute selectors. |
| `modelCatalogAlias` | Empty by default; exact case-insensitive catalog alias, at most 256 characters. Supplied file uses `phi-4`. |
| `modelVersion` | Empty by default; exact catalog version string, at most 64 characters. Supplied file uses `2`; `latest`/`all` are rejected for resolution. |
| `modelRuntime` | Empty by default to inherit an explicit asset's runtime; `onnx-genai` or `vllm`. Required for alias resolution; supplied file uses `onnx-genai`. |
| `modelCompute` | Empty by default to inherit compute; `cpu` or `gpu` explicitly sets matching native compute. Supplied file uses `cpu`. |
| `modelReplicas` | `1`; range 1-100. |
| `modelCpu` | `2`; request and limit per replica, positive Kubernetes CPU quantity. |
| `modelMemory` | `8Gi` default; supplied file uses `16Gi`. Request and limit per replica, positive Kubernetes memory quantity. |
| `modelGpuCount` | `0`; omit GPU limit for CPU, or 1-8 GPUs for a matching GPU asset. |
| `modelReadyTimeoutSeconds` | `1800`; range 60-3600, after model apply. |

## 6. Troubleshooting and handoff

| Symptom | Investigation / safe action |
|---|---|
| `roleAssignments/write` denied | Obtain AKS-scoped role-delegation permission for the deploying identity. |
| WO cannot deploy/read Template Spec | Check the separate WO execution principal and target-RG permissions. |
| RG not found / kube endpoint mismatch | Verify explicit tenant/subscription/RG and authoritative AKS target; stop mismatched Kubernetes queries. |
| ACI/API/package connectivity failure | Check region, quota, policy and approved network design; do not disable controls. |
| Bootstrap reports `Subscription '<expected ID>' not found` | This is the deployment script identity's CLI profile, not necessarily your terminal's subscription. Verify the attached bootstrap identity and AKS-scoped credential role. Package `1.0.11` retries the exact subscription-cache error with same-identity reauthentication; inspect persistent failures rather than granting blanket Contributor access. |
| CRDs missing / discovery stale | Inspect bootstrap logs and Istio/cert-manager rollout waits. |
| Auth readiness timeout / CPU throttling | Inspect current `model-store-auth` resources; keep probes/authentication enabled. |
| RWO Multi-Attach / pending native operation | Inspect lifecycle/attachment and supported recovery; do not delete PVCs, edit Helm status secrets or bypass hooks. |
| ARM success but pods not ready | Wait for actual current rollouts; distinguish historical retry pods from active failures. |
| WO model script cannot use identity or create helpers | Check WO execution-principal identity-assignment and script/ACI/storage permissions, not only AKS permissions. |
| Model asset/schema validation fails | Verify `model.assetId` and native API-key status support in the installed CRD. Package `1.0.8` fixes the incorrect requirement for `spec.authentication`; do not add unsupported fields, substitute legacy selectors or bypass validation. |
| Catalog selection matches zero/multiple assets | Review the reported alias version/runtime/compute offerings. Pin an exact available version/variant or supply its full asset ID. Unknown metadata is not guessed. |
| Compute/GPU-count conflict | CPU requires `modelGpuCount = 0`; GPU requires 1-8 GPUs and a matching GPU catalog asset. Keep CPU/memory sized for either compute type. |
| Model name or field ownership conflict | Use a distinct model name or coordinate the existing owner's migration; no automatic adoption/forced apply. |
| Model readiness timeout / `Error` | Inspect the named ModelDeployment, owner-matched Deployment, pods, PVCs and events; confirm model sizing, GPU scheduling and artifact connectivity. |
| Model is `Running` but the script times out | Package `1.0.10` fixes the incorrect requirement for legacy-only status fields. Check native `serviceCreated`, `httpRouteReady`, `tlsEnabled`, `endpoints.internal`, key Secret name and current workload readiness; do not extend the timeout to mask a status-contract mismatch. |
| Inference container `OOMKilled` / exit `137` | Increase model memory within per-node scheduling capacity or select a smaller supported catalog model. The supplied Phi-4 CPU configuration uses `16Gi`; this is not a universal model-memory requirement. |
| Client cannot reach internal model URL | Use an approved reachable client/network path and trusted TLS; this sample does not create public inference exposure. |
| `curl: (60) schannel: the revocation status is unknown` / HTTP `000` | TLS failed before HTTP/authentication. The Step 10 block includes `--ssl-revoke-best-effort` for policy-approved private-CA testing; adding it to a variable outside that block is overwritten when the block runs. Strict-revocation environments must fix revocation infrastructure/reachability. Do not use `-k` or disable all revocation checks. |
| Certificate hostname/CA failure | Keep the status endpoint's hostname, `--resolve` and public `ca.crt` bundle. A localhost URL does not match the gateway certificate. Verify the gateway/issuer; do not bypass certificate validation. |
| Connection refused on local port `8443` | Keep Terminal 1's port-forward running and confirm it targets gateway Service port `443` using the verified kubeconfig. Do not expose a LoadBalancer just for validation. |
| Missing-key request returns `200` | Stop validation and investigate API-key enforcement on the protected model route. Public health endpoints are not an authentication test. |
| Authenticated request returns `401` / Secret read is forbidden | Verify the model-reported Secret name, current key and caller's approved access. Do not print keys, grant cluster-admin to work around access, or disable authentication. |
| HTTP `404` / model ID rejected | Preserve the model path prefix, use the served `/v1/models` ID and avoid duplicating `/v1`. The Azure ML asset ID is not the inference model ID. |
| Reusing a failed client's temporary CA path | The `finally` block deletes that file. Rerun the whole Terminal 2 block so it recreates files and arguments before making requests. |

```powershell
az deployment operation group list --subscription $SubscriptionId `
  --resource-group $ResourceGroupName --name $DeploymentName `
  --query "[?properties.provisioningState=='Failed'].properties.statusMessage" -o json
$BootstrapName = "<name-from-prerequisiteBootstrapId-output>"
az deployment-scripts show-log --subscription $SubscriptionId `
  --resource-group $ResourceGroupName --name $BootstrapName
```

Record correlation ID, resource IDs, package/extension versions, rollout evidence and PVC
names. Script logs/resources use `P1D` retention. Do not share credentials, kubeconfig,
protected settings, Secret contents or full Helm values/manifests.

Before production, review shared-cluster changes, least-privilege bootstrap design,
supported upgrade paths, model authorization and storage backup/retention. Vendor
installation instructions include a Reader grant for the Foundry extension identity;
this Bicep does not declare it. Confirm the required identity/scope before using dependent
Azure-backed features. The AKS bootstrap role does not cover that assignment.

No automatic uninstall/migration is prescribed. Do not delete the RG, shared WO context,
CRDs, extensions or PVCs as routine cleanup.

## 7. Companion documentation

- [Helm operator and model through WO](../foundry-local/README.md)
- Word guide, distributed separately:
  `Foundry-Local-WO-Helm-and-Extension-Deployment-Guide.docx`
- [Foundry Arc-extension installation](https://learn.microsoft.com/en-us/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension)
- [AKS kubeconfig access](https://learn.microsoft.com/en-us/azure/aks/control-kubeconfig-access)
- [Azure role-assignment permissions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-portal)
- [Catalog model deployment](https://learn.microsoft.com/en-us/azure/azure-sovereign-clouds/private/foundry-local/how-to-deploy-model)
- [ModelDeployment schema and status](https://learn.microsoft.com/en-us/azure/azure-sovereign-clouds/private/foundry-local/reference-model-deployment-operator)
- [First model and inference](https://learn.microsoft.com/en-us/azure/azure-sovereign-clouds/private/foundry-local/deploy-run-first-model)
- [Foundry authentication and authorization](https://learn.microsoft.com/en-us/azure/azure-sovereign-clouds/private/foundry-local/concept-authentication-authorization)
- [kubectl port-forward](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/)
- [curl TLS verification](https://curl.se/docs/sslcerts.html)
- [curl Schannel best-effort revocation option](https://curl.se/docs/manpage.html#--ssl-revoke-best-effort)
- [Deployment-script permissions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deployment-script-template#configure-the-minimum-permissions)

This README describes the current two-file deployment sample. Separately distributed
Word guides/comparisons may describe the earlier operator-only `1.0.3` implementation;
they have not been revised for the optional model feature.
Local compilation is not a fresh live deployment/health or inference assertion.
Complete the workload and authenticated inference checks for each target environment.
