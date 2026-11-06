# Deploy Foundry Local as an Arc extension through Workload Orchestration

This sample uses a **WO cloud target** and an **ARM Template Spec** to install
`Microsoft.CertManagement` and `Microsoft.Foundry` on an existing Arc-connected AKS
cluster. It uses one Bicep file, one parameter file and one ARM deployment command.

```text
Bicep -> AKS prerequisite bootstrap -> WO cloud deployment
      -> ARM Template Spec -> Arc extensions -> Foundry operator platform
```

The Template Spec and independent Azure resources may be created before bootstrap
finishes; the WO solution deployment waits for bootstrap.

**Scope:** this installs the operator platform, not an LLM model or an inference test.
The AKS-specific bootstrap requires the existing AKS and Arc resources in the same
deployment subscription/resource group. Neither is created or onboarded here.

For WO-managed operator **and model charts**, see the alternative
[Helm sample](../foundry-local/README.md). Do not install both operators on the same
cluster without a supported migration/data-retention plan.

## 1. What is created or deployed

| Component | Purpose |
|---|---|
| Bootstrap managed identity and AKS role assignment | Gives the script access to retrieve AKS admin credentials. |
| Azure deployment script | Installs prerequisites, performs readiness/recovery checks and gates WO execution. |
| Gateway API / Inference CRDs and Istio | Pins `1.4.0`, `1.5.0` and `1.31.3` respectively. |
| WO context registration | Reuses the supplied context and adds missing `foundry-local` capability without replacing existing hierarchy/capabilities/tags. |
| Template Spec and version | Packages the two Arc extension definitions. |
| WO cloud target, solution template/version and deployment | Executes the Template Spec using an `armtemplate` component. |
| Arc extensions | `azure-cert-management` (`Microsoft.CertManagement`) then `inference-operator` (`Microsoft.Foundry`). |
| Kubernetes platform | Certificate/trust managers, operator, model store, internal gateway, telemetry and supporting resources/PVCs. |

There is no custom location or WO Kubernetes Helm binding in this sample.
Bootstrap uses Helm for **Istio**; the Foundry extension internally owns its Helm
release. Do not separately install the Foundry chart.

Temporary deployment-script ACI/storage helpers are cleaned on success. The bootstrap
identity/role and persistent application data remain. Deleting the private kubeconfig
file does not revoke the identity's retained credential-retrieval permission.

## 2. Pre-requisites and permissions

- Existing healthy AKS and its correct Arc registration in the deployment RG/subscription.
  The two Azure resource names can differ.
- A supported WO/Foundry region, appropriate Kubernetes version, free compute and dynamic
  persistent storage. The supplied `eastus2euap` is environment-specific, not a universal
  customer recommendation.
- AKS local accounts enabled for the implemented `--admin` bootstrap.
- AKS API reachability from the deployment-script container. Private/API-restricted clusters
  need an approved connectivity design; this sample does not provision script VNet integration.
- Required Azure providers, ACI/storage capacity and package/product network access.
- Azure CLI/Bicep supporting `.bicepparam` `using` declarations.
  `connectedk8s` and `k8s-extension` CLI extensions support the validation commands.
  Workstation kubectl/Helm are needed only for optional local validation.
- No conflicting independently Helm-managed Foundry operator or duplicate certificate extension.

| Identity | Required access |
|---|---|
| Deployment user/pipeline | Resource-management permissions, including context write at its actual scope. Subscription Contributor covers the ordinary resource-management steps, subject to policy. |
| Deployment user: AKS role delegation | **Role Based Access Control Administrator scoped to the AKS resource**, or equivalent `Microsoft.Authorization/roleAssignments/write`. Contributor alone is insufficient for `bootstrapAksAccess`. |
| Bootstrap managed identity | Bicep grants **Azure Kubernetes Service Cluster Admin Role** on the AKS resource. This allows full Kubernetes admin credentials, not namespace-only access. |
| Existing WO ARM execution principal | Template Spec/version read and approved ARM/Arc-extension deployment permissions in the target RG; pre-authorize the correct principal separately. |
| Optional validation operator | Azure read and appropriate Kubernetes read/watch permissions. Do not grant admin solely for validation. |

An authorized administrator must grant the human/pipeline's role-delegation permission.
Subscription Owner is not necessary for the AKS assignment step. The human deployer's,
bootstrap identity's and WO execution principal's permissions are separate.

An Entra-authenticated/custom-RBAC bootstrap could reduce privilege, but that redesign
is **not implemented** here. Switching only to Cluster User does not reduce access on
AKS without Entra integration. AKS authentication is separate from Foundry API Entra.

## 3. Step-by-step deployment

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

Keep `using './main.bicep'` and edit the environment-specific values:

```bicep
using './main.bicep'

param location = '<supported-WO-and-Template-Spec-region>'
param connectClusterName = '<arc-connected-cluster-resource-name>'
param aksClusterName = '<underlying-AKS-resource-name>'
param bootstrapLocation = 'eastus2'
param gatewayApiVersion = '1.4.0'
param inferenceExtensionVersion = '1.5.0'
param istioVersion = '1.31.3'
param entraClientId = ''
param contextId = '<existing-WO-context-resource-id>'
```

The current parameter file does **not** repeat these defaults from `main.bicep`:

| Default in `main.bicep` | Value |
|---|---|
| `templateSpecVersion` | `1.0.3` |
| `solutionTemplateVersion` | `1.0.3` |
| `certManagerExtensionName` | `azure-cert-management` |
| `foundryExtensionName` | `inference-operator` |

They remain overridable when approved existing names/configuration require it.
Package `1.0.3` is a WO/Template Spec version, not a pinned Foundry software version.

Use an existing full context ID when available. The target uses its last hierarchy
level by default (`line` in the supplied example). A supplied hierarchy override must
exist in a nonempty hierarchy. Leave `contextId = ''` only for first-context creation,
then reuse the output ID.

Blank `entraClientId` disables Foundry API Entra for initial operator setup; SAT support
is enabled and the API remains internal. No app is created. Configure production API
and future model caller authorization separately; Agentic Retrieval needs Entra enabled.
Increment the version defaults/overrides after reviewed template/configuration changes.

### Step 4 - Review automatic bootstrap and rerun impact

Bootstrap downloads checksum-verified tools, retrieves a private AKS admin kubeconfig,
applies/waits for CRDs, installs/upgrades Istio and verifies GatewayClass readiness.
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

### Step 6 - Deploy with one ARM command

```powershell
az deployment group create `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroupName `
  --name $DeploymentName `
  --parameters $ParameterFile
if ($LASTEXITCODE -ne 0) { throw "Foundry extension WO deployment failed." }
```

No separate `update-context.bicep`, prerequisite-install command or direct Foundry
Helm/Arc-extension creation command is required for the implemented flow.

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

Use an existing approved direct AKS kube-context. Do not overwrite shared kubeconfig,
fetch admin credentials solely for validation or query an unverified default context.

```powershell
$KubeContext = "<verified-direct-AKS-context>"
$Kubectl = (Get-Command kubectl -CommandType Application |
  Select-Object -First 1).Source
$AksJson = az aks show --subscription $SubscriptionId `
  --resource-group $ResourceGroupName --name $AksClusterName -o json
if ($LASTEXITCODE -ne 0) { throw "Cannot verify the AKS endpoint." }
$Aks = $AksJson | ConvertFrom-Json
$ExpectedHosts = @($Aks.fqdn, $Aks.privateFqdn) |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$Server = & $Kubectl config view --minify --context $KubeContext `
  -o "jsonpath={.clusters[0].cluster.server}"
if ($LASTEXITCODE -ne 0) { throw "Kube-context is unavailable." }
if ($ExpectedHosts -notcontains ([uri]$Server).DnsSafeHost) {
  throw "Endpoint mismatch. Stop; do not query another cluster."
}
& $Kubectl --context $KubeContext --request-timeout=75s wait `
  --for=condition=Established --timeout=60s `
  crd/gateways.gateway.networking.k8s.io `
  crd/inferencepools.inference.networking.k8s.io
if ($LASTEXITCODE -ne 0) { throw "Prerequisite CRDs are not Established." }
& $Kubectl --context $KubeContext --request-timeout=75s wait `
  gatewayclass/istio --for=condition=Accepted --timeout=60s
if ($LASTEXITCODE -ne 0) { throw "GatewayClass is not Accepted." }
foreach ($Namespace in @("istio-system", "cert-manager", "foundry-local-operator")) {
  & $Kubectl --context $KubeContext --request-timeout=15s `
    -n $Namespace get deployment,pods,pvc
  $Deployments = @(& $Kubectl --context $KubeContext --request-timeout=15s `
    -n $Namespace get deployment -o name)
  if ($LASTEXITCODE -ne 0 -or $Deployments.Count -eq 0) {
    throw "Deployment discovery failed or is empty: $Namespace"
  }
  foreach ($Deployment in $Deployments) {
    & $Kubectl --context $KubeContext --request-timeout=11m `
      -n $Namespace rollout status $Deployment --timeout=10m
    if ($LASTEXITCODE -ne 0) { throw "Rollout is not ready: $Deployment" }
  }
}
& $Kubectl --context $KubeContext --request-timeout=15s `
  -n foundry-local-operator get jobs
```

Verify current ready deployments, Bound evaluation/model-store PVCs, current completed
maintenance/auth Jobs and retained CPU/probe settings. Historical failed retry pods are
not the same as current failed Jobs. No model/inference success is claimed by this sample.

## 4. Parameter reference

| Parameter | Default / meaning |
|---|---|
| `location` | Resource-group region; use a supported WO/Template Spec region. |
| `connectClusterName` | Required existing Arc resource name. |
| `aksClusterName` | Required existing AKS name in the same RG/subscription. |
| `bootstrapLocation` | `eastus2`; ACI/script availability and API access required. |
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
| `templateSpecVersion` | `1.0.3`, defaulted in `main.bicep`. |
| `solutionTemplateVersion` | `1.0.3`, defaulted in `main.bicep`. |
| `entraTenantId` | Subscription tenant; Foundry API tenant, not an AKS auth-mode switch. |
| `entraClientId` | Empty initially; no app registration is created. |
| `certManagerExtensionName` | `azure-cert-management`, defaulted in `main.bicep`. |
| `foundryExtensionName` | `inference-operator`, defaulted in `main.bicep`. |

## 5. Troubleshooting and handoff

| Symptom | Investigation / safe action |
|---|---|
| `roleAssignments/write` denied | Obtain AKS-scoped role-delegation permission for the deploying identity. |
| WO cannot deploy/read Template Spec | Check the separate WO execution principal and target-RG permissions. |
| RG not found / kube endpoint mismatch | Verify explicit tenant/subscription/RG and authoritative AKS target; stop mismatched Kubernetes queries. |
| ACI/API/package connectivity failure | Check region, quota, policy and approved network design; do not disable controls. |
| CRDs missing / discovery stale | Inspect bootstrap logs and Istio/cert-manager rollout waits. |
| Auth readiness timeout / CPU throttling | Inspect current `model-store-auth` resources; keep probes/authentication enabled. |
| RWO Multi-Attach / pending native operation | Inspect lifecycle/attachment and supported recovery; do not delete PVCs, edit Helm status secrets or bypass hooks. |
| ARM success but pods not ready | Wait for actual current rollouts; distinguish historical retry pods from active failures. |

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

## 6. Companion documentation

- [Helm operator and model through WO](../foundry-local/README.md)
- Word guide, distributed separately:
  `Foundry-Local-WO-Helm-and-Extension-Deployment-Guide.docx`
- [Foundry Arc-extension installation](https://learn.microsoft.com/en-us/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension)
- [AKS kubeconfig access](https://learn.microsoft.com/en-us/azure/aks/control-kubeconfig-access)
- [Azure role-assignment permissions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-portal)

This README matches the implemented two-file sample and the companion step-by-step guide.
Local compilation is not a fresh live deployment/health or inference assertion.
