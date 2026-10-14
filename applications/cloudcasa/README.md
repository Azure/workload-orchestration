# Deploy CloudCasa through Azure Workload Orchestration

This folder contains the initial Bicep and PowerShell implementation for deploying
**CloudCasa Self-Hosted** to an Arc-connected Kubernetes cluster through Azure
**Workload Orchestration** (`Microsoft.Edge`).

The deployment is separated into three stages:

1. Azure and Workload Orchestration prerequisites.
2. Secure Kubernetes prerequisite bootstrap.
3. CloudCasa solution-template version and solution deployment.

CloudCasa passwords, registry credentials, license contents, and private keys are not stored in
Bicep parameter files or Workload Orchestration configuration.

---

## Files

| File | Purpose |
|---|---|
| `prerequisites.bicep` | Creates the certificate extension, WO extension, Custom Location, and Kubernetes target. |
| `prerequisites.params.bicepparam` | Placeholder parameters for the platform resources. |
| `*.local.bicepparam` | Git-ignored environment-specific parameter files. |
| `Initialize-CloudCasaPrerequisites.ps1` | Securely creates namespaces, vendor image-pull Secrets, license Secret, optional local-auth Secret, and optional POC Issuer. |
| `main.bicep` | Declares the existing CloudCasa solution-template version and creates the solution deployment against an existing target. |
| `main.params.bicepparam` | Non-secret CloudCasa deployment parameters. |
| `Deploy-CloudCasa.ps1` | Runs the prerequisite, Kubernetes bootstrap, and application stages. |

---

## Deployment model

```text
Arc-connected Kubernetes cluster
  -> cert-manager Arc extension
  -> Workload Orchestration Arc extension
  -> Custom Location
  -> Microsoft.Edge target with helm.v3 binding
  -> secure Kubernetes prerequisites
  -> CloudCasa solution template and immutable version through the WO CLI
  -> CloudCasa solution deployment
  -> CloudCasa Helm release
```

The wrapper Helm chart must support:

- Pre-created `cc-user-license-key`.
- Pre-created `myregistrykey` in both CloudCasa namespaces.
- Pre-created local-auth Secret when local POC authentication is enabled.
- WO stringified booleans, using explicit checks such as:

  ```gotemplate
  {{- if eq (toString .Values.license.createSecret) "true" }}
  ```

The Bicep configuration omits the local-authentication override unless it is explicitly enabled.
This preserves the chart's native Boolean `false` default and avoids treating a WO string value
of `"false"` as truthy in Helm.

CloudCasa Dex requires at least one authentication connector. The current reusable parameter model
supports the pre-created local-auth Secret. If local authentication is disabled, extend the model
with a securely supplied external OIDC, LDAP, or Microsoft identity-provider configuration before
deployment. Allowed-user lists alone do not configure a Dex connector.

`Deploy-CloudCasa.ps1` creates and waits for the immutable solution-template version through the
Workload Orchestration CLI before running the application Bicep deployment. This avoids overlapping
ARM PUT operations against the same immutable version. Temporary non-secret configuration and
specification files are deleted immediately after version creation.

---

## Prerequisites

- Azure CLI with Bicep.
- `kubectl`.
- Helm 3 for wrapper-chart validation and publication.
- Arc-connected Kubernetes cluster.
- Existing Workload Orchestration context.
- Context capability matching `capabilityNames`.
- Linux `amd64` worker capacity.
- Dynamic Kubernetes StorageClass.
- Customer ACR containing the CloudCasa wrapper chart.
- WO extension managed identity with `AcrPull` on that customer ACR.
- CloudCasa vendor ACR username and password.
- CloudCasa license file.
- Approved DNS name and TLS issuer.
- Kubernetes administrator access through an explicit kubeconfig and context.

Required Azure permissions include:

- `Microsoft.KubernetesConfiguration/extensions/*`
- `Microsoft.ExtendedLocation/customLocations/*`
- `Microsoft.Edge/targets/*`
- `Microsoft.Edge/solutiontemplates/*`
- `Microsoft.Edge/solutiondeployments/*`

Granting `AcrPull` requires `Microsoft.Authorization/roleAssignments/write` at the customer ACR
or a parent scope.

---

## Configure the parameter files

Replace every value enclosed in `<...>` in:

- `prerequisites.params.bicepparam`
- `main.params.bicepparam`

Important application values:

- `chartRepository`
- `chartVersion`
- `solutionTemplateVersion`
- `storageClassName`
- `cloudCasaFqdn`
- `certificateIssuerName`
- allowed and site-administrator users or groups

Solution-template versions are immutable. Increment `solutionTemplateVersion` whenever the chart
version or configuration changes.

Do not place credentials or license contents in either parameter file.

Environment-specific parameter files should use the suffix `.local.bicepparam`. They are ignored
by Git so subscription IDs, resource IDs, FQDNs, and administrator identities are not included in
the reusable application contribution.

---

## Validate before deployment

```powershell
Set-Location "<repository-root>\applications\cloudcasa"

az bicep build --file .\prerequisites.bicep --stdout | Out-Null
az bicep build --file .\main.bicep --stdout | Out-Null
```

Preview the prerequisite stage:

```powershell
az deployment group what-if `
  --subscription "<subscription-id>" `
  --resource-group "<arc-cluster-resource-group>" `
  --template-file .\prerequisites.bicep `
  --parameters .\prerequisites.params.bicepparam
```

Preview the application stage only after the target exists:

```powershell
az deployment group what-if `
  --subscription "<subscription-id>" `
  --resource-group "<arc-cluster-resource-group>" `
  --template-file .\main.bicep `
  --parameters .\main.params.bicepparam
```

Preview `Microsoft.Edge` resources carefully because their preview API types may produce Bicep
`BCP081` warnings when local type metadata is unavailable.

---

## Deploy

For a new target:

```powershell
.\Deploy-CloudCasa.ps1 `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroupName "<arc-cluster-resource-group>" `
  -KubeConfigPath "<kubeconfig-path>" `
  -KubeContext "<kube-context>" `
  -LicensePath "<cloudcasa-license-path>"
```

To deploy only the platform prerequisites and stop before the Kubernetes bootstrap and CloudCasa
application deployment:

```powershell
.\Deploy-CloudCasa.ps1 `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroupName "<arc-cluster-resource-group>" `
  -PrerequisiteParameterFile ".\prerequisites.<environment>.local.bicepparam" `
  -PrerequisitesOnly `
  -SkipKubernetesBootstrap
```

`PrerequisitesOnly` is the recommended first deployment stage. Validate the extension, Custom
Location, target, WO pods, and Redis PVC before running the application stage.

For an existing WO target:

```powershell
.\Deploy-CloudCasa.ps1 `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroupName "<arc-cluster-resource-group>" `
  -KubeConfigPath "<kubeconfig-path>" `
  -KubeContext "<kube-context>" `
  -LicensePath "<cloudcasa-license-path>" `
  -UseExistingTarget
```

The script prompts securely for the CloudCasa vendor-registry password and, when enabled, the
local administrator password.

---

## Validate the deployment

Azure:

```powershell
az deployment group show `
  --name cloudcasa-application `
  --resource-group "<arc-cluster-resource-group>" `
  --query properties.provisioningState `
  --output tsv
```

Kubernetes:

```powershell
kubectl --kubeconfig "<kubeconfig-path>" --context "<kube-context>" `
  get pods -n cloudcasa-server

kubectl --kubeconfig "<kubeconfig-path>" --context "<kube-context>" `
  get pods -n cloudcasa-mongo

kubectl --kubeconfig "<kubeconfig-path>" --context "<kube-context>" `
  get pvc -A

kubectl --kubeconfig "<kubeconfig-path>" --context "<kube-context>" `
  get certificate -n cloudcasa-server

kubectl --kubeconfig "<kubeconfig-path>" --context "<kube-context>" `
  get service amds-envoy-grpcapi -n cloudcasa-server -o wide
```

Success requires:

1. Azure deployment state `Succeeded`.
2. WO solution deployment state `Deployed`.
3. Helm release state `deployed`.
4. Ready CloudCasa and MongoDB workloads.
5. Bound PVCs.
6. Ready certificates.
7. DNS and certificate SAN matching `cloudCasaFqdn`.
8. HTTPS and HTTP/2 connectivity on TCP 443.
9. Successful administrator login.
10. Successful backup-storage and restore validation.

---

## Important limitations

- Do not deploy a second CloudCasa release on a cluster already running CloudCasa. The chart
  contains cluster-scoped CRDs and shared resources.
- Use a fresh validation cluster or an approved replacement window for the first Bicep-managed
  installation.
- Self-signed TLS and local authentication are POC-only.
- The initial implementation does not create a static Public IP or DNS record.
- Long-lived secrets should use an approved secret-management and synchronization design in
  production.
- Do not delete CloudCasa PVCs during troubleshooting or rollback without explicit data-retention
  approval.
