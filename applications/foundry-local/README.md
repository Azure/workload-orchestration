# Deploy Foundry Local on an Arc-connected AKS cluster

This folder contains the Bicep and PowerShell files needed to deploy **Foundry Local** to an
Arc-connected **Azure Kubernetes Service (AKS)** cluster by using Azure
**Workload Orchestration** (`Microsoft.Edge`).

The deployment is split into prerequisites and application stages so application retries do not
reconcile healthy cluster extensions. A policy compatibility script runs between the stages.

---

## 1. What gets deployed

| # | Stage | Resource | Purpose |
|---|-------|----------|---------|
| 1 | Prerequisites | **cert-manager Arc extension** | Provides certificate management required by Workload Orchestration. |
| 2 | Prerequisites | **Workload Orchestration Arc extension** | Installs the Workload Orchestration services on the Arc-connected cluster. |
| 3 | Prerequisites | **Custom Location** | Represents the cluster as an Azure deployment location. |
| 4 | Prerequisites | **Kubernetes target** | Creates a `Microsoft.Edge/targets` resource with a `helm.v3` provider binding. |
| 5 | Application | **Inference solution template and deployment** | Deploys the Foundry inference operator Helm chart. |
| 6 | Application | **Model solution template and deployment** | Deploys the configured AI model Helm chart after the inference operator is ready. |

The model deployment explicitly depends on the inference deployment.

---

## 2. Files in this folder

| File | Description |
|------|-------------|
| `prerequisites.bicep` | Deploys the Arc extensions, Custom Location, and Workload Orchestration target. |
| `prerequisites.params.bicepparam` | Parameters for the prerequisite resources. |
| `Apply-FoundryPolicyCompatibility.ps1` | Applies the admission-policy compatibility settings before the application deployment. |
| `Deploy-FoundryLocal.ps1` | Runs the prerequisite deployment, Arc proxy, policy compatibility, and application deployment. |
| `main.bicep` | Deploys the Foundry inference operator and model to an existing target. |
| `main.params.bicepparam` | Parameters for the Foundry application resources. |

No template spec is required because both Foundry components are represented directly as
`helm.v3` components in the Workload Orchestration solution templates.

---

## 3. Prerequisites

Before you start, make sure you have:

- **Windows PowerShell**, because the deployment wrapper uses `Get-NetTCPConnection`.
- **Azure CLI** with Bicep tooling and the `connectedk8s` extension installed:

  ```powershell
  az --version
  az bicep install
  az extension add --name connectedk8s
  ```

- `kubectl` installed. The deployment wrapper opens and closes the Arc proxy automatically.
- An existing **AKS cluster connected to Azure Arc**. The
  `Microsoft.Kubernetes/connectedClusters` resource must be in the resource group where the
  templates are deployed.
- An existing Workload Orchestration **context** and the full resource ID of its
  `Microsoft.Edge/contexts` resource.
- One or more capabilities declared by that context. Every value in `capabilityNames` must match
  a context capability exactly.
- Permissions to manage:
  - `Microsoft.KubernetesConfiguration/extensions`
  - `Microsoft.ExtendedLocation/customLocations`
  - `Microsoft.Edge/targets`
  - `Microsoft.Edge/solutiontemplates`
  - `Microsoft.Edge/solutiondeployments`
- A Kubernetes storage class that supports dynamic provisioning for the Workload Orchestration
  Redis persistent volume.
- Cluster access to pull both configured Helm charts and their referenced container images.
- Enough cluster capacity for Workload Orchestration, the inference operator, and the model.
  The sample Phi-4 configuration requests 8 CPU and 24 GiB memory per replica.
- Any required private-preview provider access and private registry permissions.

---

## 4. Step-by-step deployment

### Step 0 - Sign in and select your subscription

```powershell
az login
az account set --subscription "<your-subscription-id>"
```

### Step 1 - Confirm the Arc-connected cluster

```powershell
az connectedk8s show `
  --resource-group "<cluster-resource-group>" `
  --name "<arc-connected-cluster-name>" `
  --query id `
  --output tsv
```

The cluster name returned by this command must match both `connectClusterName` in
`prerequisites.params.bicepparam` and the `-ClusterName` value passed to the deployment wrapper.

### Step 2 - Confirm the Workload Orchestration context and capability

```powershell
az resource show `
  --ids "<workload-orchestration-context-resource-id>" `
  --output json
```

Set `contextId` to this resource ID. Confirm with the Workload Orchestration service owner that
every value used in `capabilityNames` is declared by the context.

### Step 3 - Edit the parameters

Open `prerequisites.params.bicepparam` and review:

- `location`
- `connectClusterName`
- `contextId`
- `capabilityNames`
- `targetName`
- `hierarchyLevel`
- `workloadOrchestrationCustomLocationName`
- `workloadOrchestrationExtensionName`
- `workloadOrchestrationExtensionType`
- `workloadOrchestrationExtensionVersion`
- `workloadOrchestrationCustomLocationNamespace`
- `workloadOrchestrationRedisStorageClass`
- `workloadOrchestrationRedisStorageSize`

Open `main.params.bicepparam` and review:

- `location`
- `capabilityNames`
- `targetName`
- `inferenceoperatorChartRepository` and `inferenceoperatorChartVersion`
- `inferenceTemplateName`, `inferenceTemplateVersion`, and `inferenceDeploymentName`
- `modelChartRepository` and `modelChartVersion`
- `modelTemplateName`, `modelTemplateVersion`, and `modelDeploymentName`
- All `model*` settings

Confirm preview/private extension versions and registry locations with the relevant service
owners before deployment.

List the Workload Orchestration versions supported by the target cluster and set
`workloadOrchestrationExtensionVersion` to one of the returned versions:

```powershell
az k8s-extension extension-types list-versions-by-cluster `
  --subscription "<subscription-id>" `
  --resource-group "<cluster-resource-group>" `
  --cluster-name "<arc-connected-cluster-name>" `
  --cluster-type connectedClusters `
  --extension-type microsoft.workloadorchestration `
  --release-train stable `
  --query "[].name" `
  --output tsv
```

### Step 4 - Run the deployment

```powershell
Set-Location "<repository-root>\applications\foundry-local"

.\Deploy-FoundryLocal.ps1 `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroupName "<cluster-resource-group>" `
  -ClusterName "<arc-connected-cluster-name>"
```

The resource group must contain the Arc-connected cluster. The script:

1. Deploys `prerequisites.bicep` with `prerequisites.params.bicepparam`.
2. Starts an Arc proxy and waits for Kubernetes access.
3. Restricts `symphony-namespace-deny` to namespaced resources and removes `cert-manager` from
   `protectedNamespaces`.
4. Deploys `main.bicep` with `main.params.bicepparam`.
5. Stops the Arc proxy and releases its ports.

The inference operator uses a 15-minute timeout and the model uses a 20-minute timeout. Both
components wait for their workloads to become ready.

### Step 5 - Verify the Azure deployment

```powershell
az deployment group show `
  --name "foundry-local-application" `
  --resource-group "<cluster-resource-group>" `
  --query properties.provisioningState `
  --output tsv
```

Inspect the resource IDs emitted by the application deployment:

```powershell
az deployment group show `
  --name "foundry-local-application" `
  --resource-group "<cluster-resource-group>" `
  --query properties.outputs `
  --output json
```

### Step 6 - Verify the Kubernetes workloads

The deployment wrapper closes its Arc proxy after deployment. Start a temporary proxy in a
separate PowerShell window:

```powershell
az connectedk8s proxy `
  --subscription "<subscription-id>" `
  --resource-group "<cluster-resource-group>" `
  --name "<arc-connected-cluster-name>" `
  --port 47011 `
  --kube-context "<arc-connected-cluster-name>"
```

Then verify the workloads:

```powershell
kubectl --context "<arc-connected-cluster-name>" get pods -n foundry-local
kubectl --context "<arc-connected-cluster-name>" get modeldeployment -n foundry-local
kubectl --context "<arc-connected-cluster-name>" get service,endpoints -n foundry-local
```

The expected Helm releases are `foundry` for the inference operator and `aifoundry` for the
model. Stop the temporary proxy with `Ctrl+C` after verification.

---

## 5. Parameter reference

### 5.1 Azure and Workload Orchestration prerequisites

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `location` | Yes | - | Azure region for the Arc cluster and Workload Orchestration resources. |
| `connectClusterName` | Yes | - | Name of the Arc-connected AKS cluster in the deployment resource group. |
| `contextId` | Yes | - | Full resource ID of the existing `Microsoft.Edge/contexts` resource. |
| `capabilityNames` | No | `['foundry-local']` | Capabilities assigned to the target. |
| `targetName` | No | `foundry-local-target` | Name of the Workload Orchestration Kubernetes target. |
| `hierarchyLevel` | No | `line` | Hierarchy level declared by the Workload Orchestration context. |
| `workloadOrchestrationCustomLocationName` | No | `foundry-local-workload-orchestration-location` | Name of the Workload Orchestration Custom Location. |
| `workloadOrchestrationExtensionName` | No | `workloadorchestration-extension` | Name of the Workload Orchestration Arc extension. |
| `workloadOrchestrationCustomLocationNamespace` | No | `workloadorchestration` | Namespace registered by the Custom Location. |
| `workloadOrchestrationExtensionType` | No | `microsoft.workloadorchestration` | Arc extension type. |
| `workloadOrchestrationReleaseTrain` | No | `stable` | Arc extension release train. |
| `workloadOrchestrationExtensionVersion` | No | `2.1.43` | Exact Workload Orchestration extension version. |
| `workloadOrchestrationRedisStorageClass` | No | `default` | Storage class used by Redis. |
| `workloadOrchestrationRedisStorageSize` | No | `5Gi` | Redis persistent-volume size. |

The cert-manager extension settings are defined in `prerequisites.bicep`.

### 5.2 Foundry inference operator

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `inferenceoperatorChartRepository` | No | `mcr.microsoft.com/foundrylocalonazurelocal/helmcharts/helm/inference-operator` | OCI repository for the Foundry inference operator Helm chart. |
| `inferenceoperatorChartVersion` | No | `0.0.1-prp.3` | Inference operator chart version. |
| `inferenceTemplateName` | No | `foundry-local-inference` | Workload Orchestration solution template name for the inference operator. |
| `inferenceTemplateVersion` | No | `1.0.0` | Version of the inference operator solution template. |
| `inferenceDeploymentName` | No | `foundry-inference` | Workload Orchestration solution deployment name for the inference operator. |

### 5.3 AI model

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `modelChartRepository` | No | `foundrypoc.azurecr.io/helm/ai-model` | OCI repository for the AI model Helm chart. |
| `modelChartVersion` | No | `0.1.0` | AI model chart version. |
| `modelTemplateName` | No | `foundry-local-model` | Workload Orchestration solution template name for the model. |
| `modelTemplateVersion` | No | `1.0.0` | Version of the model solution template. |
| `modelDeploymentName` | No | `foundry-model` | Workload Orchestration solution deployment name for the model. |
| `modelName` | No | `phi-4-cpu` | Model deployment name passed to the chart. |
| `modelDisplayName` | No | `Phi-4 CPU` | Human-readable model name. |
| `modelCatalogName` | No | `Phi-4-generic-cpu` | Model catalog identifier. |
| `modelVersion` | No | `2` | Model version passed to the chart. |
| `modelCompute` | No | `cpu` | Model compute type. Set to `gpu` when using a GPU-capable model and cluster. |
| `modelReplicas` | No | `1` | Number of model replicas. |
| `modelCpu` | No | `8` | CPU request and limit for each model replica. |
| `modelMemory` | No | `24Gi` | Memory request and limit for each model replica. |
| `modelEndpointEnabled` | No | `false` | Enables the model endpoint when set to `true`. |

---

## 6. Deployment behavior

- The application template references the target as an existing resource.
- The inference operator is deployed first as the `foundry` Helm release.
- The model is deployed second as the `aifoundry` Helm release.
- Both Helm deployments wait for readiness. The inference timeout is 15 minutes and the model
  timeout is 20 minutes.
- The model workload type is `generative`; `modelCompute` selects CPU or GPU execution.
- Model CPU and memory values are used for both Kubernetes requests and limits.

### 6.1 Resource API versions

| Resource type | API version |
|---------------|-------------|
| `Microsoft.Kubernetes/connectedClusters` | `2025-12-01-preview` |
| `Microsoft.KubernetesConfiguration/extensions` | `2022-03-01` |
| `Microsoft.ExtendedLocation/customLocations` | `2021-03-15-preview` |
| `Microsoft.Edge/targets` | `2026-05-01-preview` |
| `Microsoft.Edge/solutiontemplates` | `2026-05-01-preview` |
| `Microsoft.Edge/solutiontemplates/versions` | `2026-05-01-preview` |
| `Microsoft.Edge/solutiondeployments` | `2026-05-01-preview` |

---

## 7. Redeployment

Workload Orchestration solution-template versions should be treated as immutable.
The application template uses `@onlyIfNotExists()` for solution templates and their versions.

When changing chart configuration or component specifications:

1. Set a new `inferenceTemplateVersion` or `modelTemplateVersion` in
   `main.params.bicepparam`.
2. Validate the Bicep templates:

   ```powershell
   az bicep build --file ".\prerequisites.bicep" --stdout | Out-Null
   az bicep build --file ".\main.bicep" --stdout | Out-Null
   ```

3. Run `what-if` before redeploying.

Do not commit registry credentials, access tokens, or other secrets to parameter files.

---

## 8. Troubleshooting

- **Arc cluster not found:** deploy prerequisites to the resource group containing the
  `Microsoft.Kubernetes/connectedClusters` resource.
- **Capability validation fails:** ensure every capability exactly matches the context.
- **Extension installation fails:** verify the extension type, release train, version, preview
  access, and cluster connectivity.
- **Policy script cannot find its resources:** wait for the Workload Orchestration extension to
  finish provisioning and verify the Kubernetes context.
- **Redis remains pending:** verify the configured storage class supports dynamic provisioning.
- **Helm chart pull fails:** confirm the chart repository and version and verify registry access.
- **Model pod remains pending:** verify sufficient schedulable CPU and memory.
- **Model endpoint is unavailable:** inspect the resources created by the `aifoundry` Helm release.
