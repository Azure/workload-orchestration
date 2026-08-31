# Deploy Foundry Local on an Arc-connected AKS cluster

This folder contains everything needed to deploy **Foundry Local** to an Arc-connected
**Azure Kubernetes Service (AKS)** cluster by using Azure **Workload Orchestration**
(`Microsoft.Edge`) and a single Bicep template.

The deployment installs the Workload Orchestration cluster dependencies, creates a Kubernetes
target, and deploys both the Foundry inference operator and a configurable CPU or GPU model.
The supplied parameter file uses a CPU-based Phi-4 model as the example.

---

## 1. What gets deployed

The template provisions the complete Foundry Local stack in the following order:

| # | Resource | Purpose |
|---|----------|---------|
| 1 | **cert-manager Arc extension** | Provides certificate management required by Workload Orchestration. |
| 2 | **Workload Orchestration Arc extension** | Installs the Workload Orchestration services on the Arc-connected cluster. |
| 3 | **Custom Location** | Represents the cluster as an Azure deployment location. |
| 4 | **Kubernetes target** | Creates a `Microsoft.Edge/targets` resource with a `helm.v3` provider binding. |
| 5 | **Inference solution template and deployment** | Deploys the Foundry inference operator Helm chart. |
| 6 | **Model solution template and deployment** | Deploys the configured AI model Helm chart after the inference operator is ready. |

The model deployment explicitly depends on the inference deployment.

---

## 2. Files in this folder

| File | Description |
|------|-------------|
| `main.bicep` | **Entry point.** Deploys the Arc extensions, Custom Location, Workload Orchestration target, solution templates, and solution deployments. |
| `main.params.bicepparam` | Bicep parameter file containing the environment, chart, and model settings to review before deployment. |

No template spec is required because both Foundry components are represented directly as
`helm.v3` components in the Workload Orchestration solution templates.

---

## 3. Prerequisites

Before you start, make sure you have:

- **Azure CLI** with Bicep tooling installed:

  ```powershell
  az --version
  az bicep install
  ```

- An existing **AKS cluster connected to Azure Arc**. The
  `Microsoft.Kubernetes/connectedClusters` resource must be in the resource group where this
  template is deployed.
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
  The sample model configuration requests 2 CPU and 8 GiB memory per replica.
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

The cluster name returned by this command must match `connectClusterName`, and this resource group must
be used for the deployment in Step 4.

### Step 2 - Confirm the Workload Orchestration context and capability

```powershell
az resource show `
  --ids "<workload-orchestration-context-resource-id>" `
  --output json
```

Set `contextId` to this resource ID. Confirm with the Workload Orchestration service owner that
every value used in `capabilityNames` is declared by the context.

### Step 3 - Edit the parameters

Open `main.params.bicepparam` and replace every value enclosed in `<...>` with the corresponding
value from your Azure environment. At minimum, review:

- `location`
- `connectClusterName`
- `contextId`
- `capabilityNames`
- `workloadOrchestrationCustomLocationName`
- `workloadOrchestrationExtensionName`
- `workloadOrchestrationExtensionType`
- `workloadOrchestrationExtensionVersion`
- `workloadOrchestrationCustomLocationNamespace`
- `workloadOrchestrationRedisStorageClass`
- `workloadOrchestrationRedisStorageSize`
- `inferenceoperatorChartRepository` and `inferenceoperatorChartVersion`
- `modelChartRepository` and `modelChartVersion`
- All `model*` settings

Confirm preview/private extension versions and registry locations with the relevant service
owners before deployment.

### Step 4 - Preview and deploy

Run the following commands from the `foundry-local` directory:

```powershell
Set-Location ".\foundry-local"
```

Preview the changes:

```powershell
az deployment group what-if `
  --resource-group "<cluster-resource-group>" `
  --template-file ".\main.bicep" `
  --parameters ".\main.params.bicepparam"
```

Deploy:

```powershell
az deployment group create `
  --name "foundry-local" `
  --resource-group "<cluster-resource-group>" `
  --template-file ".\main.bicep" `
  --parameters ".\main.params.bicepparam"
```

The Helm components use a seven-minute timeout and wait for their workloads to become ready.

### Step 5 - Verify the Azure deployment

```powershell
az deployment group show `
  --name "foundry-local" `
  --resource-group "<cluster-resource-group>" `
  --query properties.provisioningState `
  --output tsv
```

Inspect the resource IDs emitted by the deployment:

```powershell
az deployment group show `
  --name "foundry-local" `
  --resource-group "<cluster-resource-group>" `
  --query properties.outputs `
  --output json
```

The outputs include the target, Custom Location, inference deployment, and model deployment IDs.

### Step 6 - Verify the Kubernetes workloads

Get AKS credentials and inspect the deployed workloads:

```powershell
az aks get-credentials `
  --resource-group "<aks-resource-group>" `
  --name "<aks-cluster-name>" `
  --overwrite-existing

kubectl get pods --all-namespaces
helm list --all-namespaces
```

The expected Helm releases are `foundry` for the inference operator and `aifoundry` for the
model.

---

## 5. Parameter reference

### 5.1 Azure and Workload Orchestration

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `location` | Yes | - | Azure region for the Arc cluster and Workload Orchestration resources. |
| `connectClusterName` | Yes | - | Name of the Arc-connected AKS cluster in the deployment resource group. |
| `contextId` | Yes | - | Full resource ID of the existing `Microsoft.Edge/contexts` resource. |
| `capabilityNames` | No | `['foundry-local']` | Capabilities shared by the target and both solution templates. Each capability must exist in the context. |
| `targetName` | No | `foundry-local-target` | Name of the Workload Orchestration Kubernetes target. |

### 5.2 Cluster extensions and Custom Location

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `workloadOrchestrationCustomLocationName` | No | `foundry-local-workload-orchestration-location` | Name of the Workload Orchestration Custom Location. |
| `workloadOrchestrationExtensionName` | No | `workloadorchestration-extension` | Name of the Workload Orchestration Arc extension. |
| `workloadOrchestrationCustomLocationNamespace` | No | `workloadorchestration` | Namespace registered by the Custom Location. |
| `workloadOrchestrationExtensionType` | No | `microsoft.workloadorchestration` | Arc extension type. |
| `workloadOrchestrationReleaseTrain` | No | `stable` | Arc extension release train. |
| `workloadOrchestrationExtensionVersion` | No | `2.1.43` | Exact Workload Orchestration extension version. Minor-version auto-upgrade is disabled. |
| `workloadOrchestrationRedisStorageClass` | No | `default` | Storage class used by the Workload Orchestration Redis persistent volume. |
| `workloadOrchestrationRedisStorageSize` | No | `5Gi` | Persistent volume size used by Workload Orchestration Redis. |

The cert-manager extension settings are defined directly in `main.bicep`: extension type
`microsoft.certmanagement`, stable release train, and automatic minor-version upgrades.

### 5.3 Foundry inference operator

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `inferenceoperatorChartRepository` | No | `mcr.microsoft.com/foundrylocalonazurelocal/helmcharts/helm/inference-operator` | OCI repository for the Foundry inference operator Helm chart. |
| `inferenceoperatorChartVersion` | No | `0.0.1-prp.3` | Inference operator chart version. |

### 5.4 AI model

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `modelChartRepository` | No | `foundrypoc.azurecr.io/helm/ai-model` | OCI repository for the AI model Helm chart. |
| `modelChartVersion` | No | `0.1.0` | AI model chart version. |
| `modelName` | No | `phi-4-cpu` | Model deployment name passed to the chart. |
| `modelDisplayName` | No | `Phi-4 CPU` | Human-readable model name. |
| `modelCatalogName` | No | `Phi-4-generic-cpu` | Model catalog identifier. |
| `modelVersion` | No | `2` | Model version passed to the chart. |
| `modelCompute` | No | `cpu` | Model compute type. Set to `gpu` when using a GPU-capable model and cluster. |
| `modelReplicas` | No | `1` | Number of model replicas. Must be at least 1. |
| `modelCpu` | No | `4` | CPU request and limit for each model replica. The sample parameter file overrides this to `2`. |
| `modelMemory` | No | `8Gi` | Memory request and limit for each model replica. |
| `modelEndpointEnabled` | No | `false` | Enables the model endpoint when set to `true`. |

---

## 6. Deployment behavior

- The target uses the `helm.v3` provider with in-cluster access.
- The inference operator is deployed first as the `foundry` Helm release.
- The model is deployed second as the `aifoundry` Helm release.
- Both Helm deployments wait for readiness and use a seven-minute timeout.
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
The template uses `@onlyIfNotExists()` for solution templates and their versions so an unchanged
redeployment reuses existing resources instead of attempting to update them.

When changing chart configuration or component specifications:

1. Update the corresponding solution-template version in `main.bicep`.
2. Validate the Bicep template without generating an ARM JSON file:

   ```powershell
   az bicep build --file ".\main.bicep" --stdout | Out-Null
   ```

3. Run `what-if` before redeploying.

Do not commit registry credentials, access tokens, or other secrets to parameter files.

---

## 8. Troubleshooting

- **Arc cluster not found:** deploy to the resource group containing the
  `Microsoft.Kubernetes/connectedClusters` resource and verify `connectClusterName`.
- **Capability validation fails:** ensure every value in `capabilityNames` exactly matches a capability declared
  by the context referenced by `contextId`.
- **Extension installation fails:** verify the configured extension type, release train, version,
  preview access, and cluster connectivity.
- **Redis remains pending:** verify `workloadOrchestrationRedisStorageClass` exists and supports dynamic
  provisioning, and that sufficient storage is available.
- **Helm chart pull fails:** confirm the chart repository/version and ensure the cluster identity
  has access to any private registry.
- **Inference or model deployment times out:** inspect the Workload Orchestration solution
  deployment status, then review `kubectl get events --all-namespaces` and the affected pod logs.
- **Model pod remains pending:** verify the requested CPU and memory are available on schedulable
  nodes, or reduce the values only if the model's documented minimums permit it.
- **Model endpoint is unavailable:** confirm `modelEndpointEnabled` is set as intended and inspect
  the resources created by the `aifoundry` Helm release.
