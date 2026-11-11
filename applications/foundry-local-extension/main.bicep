targetScope = 'resourceGroup'

@description('Supported Azure region for Workload Orchestration and Template Spec resources.')
param location string = resourceGroup().location

@description('Existing Arc-connected Kubernetes cluster in the deployment subscription and resource group.')
@minLength(1)
param connectClusterName string

@description('Underlying AKS cluster in the deployment subscription and resource group. Its API must be reachable from the bootstrap container and local admin credentials must be enabled.')
@minLength(1)
param aksClusterName string

@description('Region supporting deployment scripts and Azure Container Instances. This can differ from the Arc and WO region.')
param bootstrapLocation string = 'eastus2'

@description('Gateway API experimental CRD bundle version.')
param gatewayApiVersion string = '1.4.0'

@description('Gateway API Inference Extension CRD bundle version.')
param inferenceExtensionVersion string = '1.5.0'

@description('Supported Istio chart version compatible with the AKS Kubernetes version.')
param istioVersion string = '1.31.3'

@description('Changes on each deployment so prerequisite readiness is rechecked before WO runs.')
param bootstrapRunTag string = utcNow()

@description('Existing WO context ID. Missing Foundry capability and an empty hierarchy are registered automatically, preserving existing entries and tags. Leave empty only for the first deployment into a subscription without a WO context; reuse the output context ID afterwards. The deploying identity needs context write permission.')
param contextId string = ''

@description('Optional target hierarchy override. Leave empty to use the last context hierarchy, or level-1 when the context has none. A supplied override must already exist in a nonempty context hierarchy.')
param hierarchyLevel string = ''

@description('Capability shared by the context, cloud target, and solution template.')
@minLength(1)
param capabilityName string = 'foundry-local'

@description('Workload Orchestration cloud target name.')
@minLength(3)
@maxLength(61)
param targetName string = '${connectClusterName}-foundry-extension-target'

@description('Name of the WO solution template.')
@minLength(3)
@maxLength(61)
param solutionName string = '${connectClusterName}-foundry-extension'

@description('WO solution deployment name, limited to 24 characters by the resource provider.')
@minLength(3)
@maxLength(24)
param solutionDeploymentName string = 'foundry-${uniqueString(resourceGroup().id, connectClusterName)}'

@description('ARM Template Spec name. Published automatically by this deployment.')
@minLength(1)
param templateSpecName string = solutionName

@description('ARM Template Spec version. Increment when changing the embedded extension/model template.')
@minLength(1)
param templateSpecVersion string = '1.0.3'

@description('WO solution version. Increment when changing configuration or the Template Spec version.')
@minLength(1)
param solutionTemplateVersion string = '1.0.3'

@description('Tenant ID configured for Foundry Local authentication.')
@minLength(1)
param entraTenantId string = subscription().tenantId

@description('Optional Foundry Entra application client ID. Leave empty to install with Entra authentication disabled; supply it on a later update to enable Entra.')
param entraClientId string = ''

@description('Certificate-management extension name. Use its actual name if it is already installed.')
@minLength(1)
param certManagerExtensionName string = 'azure-cert-management'

@description('Foundry Local extension name. Do not install alongside an existing Helm-managed inference operator.')
@minLength(1)
param foundryExtensionName string = 'inference-operator'

@description('Optionally deploy one catalog model after WO installs the extensions. False preserves operator-only installation; disabling this later does not delete an existing model.')
param deployModel bool = false

@description('ModelDeployment name in foundry-local-operator. Must be a lowercase DNS label. An existing name must belong to this WO solution.')
@minLength(1)
@maxLength(63)
param modelDeploymentName string = 'foundry-model'

@description('Optional human-readable model display name. Leave empty to omit it from the native ModelDeployment.')
@maxLength(256)
param modelDisplayName string = ''

@description('Optional exact installed-catalog asset ID. Overrides alias/version selection. Leave empty to resolve modelCatalogAlias, modelVersion, modelRuntime and modelCompute at deployment time.')
@maxLength(256)
param modelAssetId string = ''

@description('Exact catalog alias, matched case-insensitively. Required with modelVersion, modelRuntime and modelCompute when deployModel is true and modelAssetId is empty.')
@maxLength(256)
param modelCatalogAlias string = ''

@description('Exact catalog model version, not a WO/chart version. Required for alias resolution; latest/all selection is not supported.')
@maxLength(64)
param modelVersion string = ''

@description('Optional explicit inference runtime matching the asset. Required for alias resolution; leave empty with an explicit asset ID to inherit its runtime.')
@allowed([
  ''
  'onnx-genai'
  'vllm'
])
param modelRuntime string = ''

@description('Optional explicit compute type matching the selected catalog asset; required for alias resolution. Leave empty with an explicit asset ID to inherit it. CPU requires zero GPUs; GPU requires a GPU count of 1-8.')
@allowed([
  ''
  'cpu'
  'gpu'
])
param modelCompute string = ''

@description('Number of model replicas. Size the cluster for all replicas and supporting platform workloads.')
@minValue(1)
@maxValue(100)
param modelReplicas int = 1

@description('CPU request and limit per model replica, as a Kubernetes quantity. This illustrative default is not a model minimum.')
@minLength(1)
param modelCpu string = '2'

@description('Memory request and limit per model replica, as a Kubernetes quantity. Adjust to the selected model requirements.')
@minLength(1)
param modelMemory string = '8Gi'

@description('GPUs per replica for a matching GPU catalog asset; zero omits the GPU limit for a CPU model. Does not provision GPU nodes/drivers.')
@minValue(0)
@maxValue(8)
param modelGpuCount int = 0

@description('Maximum model readiness wait in seconds after applying the manifest. Platform/catalog readiness has a separate ten-minute wait.')
@minValue(60)
@maxValue(3600)
param modelReadyTimeoutSeconds int = 1800

// Python startup and exec probes were CPU-starved under the chart's 250m auth limit.
var modelStoreAuthCpuRequest = '250m'
var modelStoreAuthCpuLimit = '1'

// Both scripts use the same verified clients and AKS credential propagation handling.
var aksClientSetupScript = '''
      set -Eeuo pipefail
      umask 077
      work_dir="$(mktemp -d)"
      export KUBECONFIG="$work_dir/kubeconfig"
      trap 'rm -f -- "$KUBECONFIG"' EXIT
      trap 'echo "Foundry deployment script failed at line $LINENO." >&2' ERR

      if ! [[ "$KUBECTL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "AKS Kubernetes version is not a full stable semantic version: $KUBECTL_VERSION" >&2
        exit 1
      fi

      mkdir "$work_dir/bin"
      export PATH="$work_dir/bin:$PATH"
      kubectl_url="https://dl.k8s.io/release/v$KUBECTL_VERSION/bin/linux/amd64/kubectl"
      curl --fail --silent --show-error --location --retry 3 "$kubectl_url" --output "$work_dir/bin/kubectl"
      curl --fail --silent --show-error --location --retry 3 "$kubectl_url.sha256" --output "$work_dir/kubectl.sha256"
      printf '%s  %s\n' "$(cat "$work_dir/kubectl.sha256")" "$work_dir/bin/kubectl" | sha256sum --check
      chmod 700 "$work_dir/bin/kubectl"

      helm_archive="helm-v3.22.1-linux-amd64.tar.gz"
      curl --fail --silent --show-error --location --retry 3 "https://get.helm.sh/$helm_archive" --output "$work_dir/$helm_archive"
      curl --fail --silent --show-error --location --retry 3 "https://get.helm.sh/$helm_archive.sha256sum" --output "$work_dir/$helm_archive.sha256sum"
      (cd "$work_dir" && sha256sum --check "$helm_archive.sha256sum")
      printf '%s\n' \
        'import shutil, sys, tarfile' \
        'with tarfile.open(sys.argv[1], "r:gz") as archive:' \
        '    with archive.extractfile("linux-amd64/helm") as source, open(sys.argv[2], "wb") as target:' \
        '        shutil.copyfileobj(source, target)' \
        | python3 - "$work_dir/$helm_archive" "$work_dir/bin/helm"
      chmod 700 "$work_dir/bin/helm"

      # Retry only known role-propagation failures; refresh the same identity's subscription cache when needed.
      for ((attempt=1; attempt<=30; attempt++)); do
        if az aks get-credentials --subscription "$AKS_SUBSCRIPTION" --resource-group "$AKS_RESOURCE_GROUP" \
          --name "$AKS_CLUSTER" --admin --file "$KUBECONFIG" --only-show-errors --output none \
          2>"$work_dir/credential-error"; then
          break
        fi
        credential_error="$(cat "$work_dir/credential-error")"
        subscription_not_found="Subscription '$AKS_SUBSCRIPTION' not found."
        if [[ "$credential_error" != *AuthorizationFailed* && "$credential_error" != *"does not have authorization"* && "$credential_error" != *"$subscription_not_found"* ]] || [ "$attempt" -eq 30 ]; then
          cat "$work_dir/credential-error" >&2
          exit 1
        fi
        echo "Waiting for AKS managed-identity credential access to propagate ($attempt/30)."
        if [[ "$credential_error" == *"$subscription_not_found"* ]]; then
          echo "Refreshing subscription discovery for the attached bootstrap identity."
          az login --identity --client-id "$AKS_IDENTITY_CLIENT_ID" --allow-no-subscriptions --only-show-errors --output none
        fi
        sleep 10
      done
      '''

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' existing = {
  name: connectClusterName
}

resource aksCluster 'Microsoft.ContainerService/managedClusters@2025-08-01' existing = {
  name: aksClusterName
}

resource bootstrapIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'foundry-bootstrap-${uniqueString(aksCluster.id)}'
  location: bootstrapLocation
}

// Scope credential access to AKS rather than granting Contributor on the resource group.
var aksAdminRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '0ab0b1a8-8aac-4efd-b8c2-3ee1fb270be8'
)

resource bootstrapAksAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aksCluster.id, bootstrapIdentity.id, aksAdminRoleId)
  scope: aksCluster
  properties: {
    principalId: bootstrapIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: aksAdminRoleId
  }
}

resource prerequisiteBootstrap 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'foundry-prerequisites-${uniqueString(aksCluster.id)}'
  location: bootstrapLocation
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${bootstrapIdentity.id}': {}
    }
  }
  dependsOn: [
    bootstrapAksAccess
  ]
  properties: {
    azCliVersion: '2.89.1'
    timeout: 'PT45M'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    forceUpdateTag: bootstrapRunTag
    environmentVariables: [
      {
        name: 'AKS_SUBSCRIPTION'
        value: subscription().subscriptionId
      }
      {
        name: 'AKS_IDENTITY_CLIENT_ID'
        value: bootstrapIdentity.properties.clientId
      }
      {
        name: 'AKS_RESOURCE_GROUP'
        value: resourceGroup().name
      }
      {
        name: 'AKS_CLUSTER'
        value: aksClusterName
      }
      {
        name: 'KUBECTL_VERSION'
        value: aksCluster.properties.currentKubernetesVersion
      }
      {
        name: 'GATEWAY_API_VERSION'
        value: gatewayApiVersion
      }
      {
        name: 'INFERENCE_EXTENSION_VERSION'
        value: inferenceExtensionVersion
      }
      {
        name: 'ISTIO_VERSION'
        value: istioVersion
      }
      {
        name: 'FOUNDRY_EXTENSION_NAME'
        value: foundryExtensionName
      }
      {
        name: 'MODEL_STORE_AUTH_CPU_REQUEST'
        value: modelStoreAuthCpuRequest
      }
      {
        name: 'MODEL_STORE_AUTH_CPU_LIMIT'
        value: modelStoreAuthCpuLimit
      }
    ]
    scriptContent: join(
      [
        aksClientSetupScript
        '''
      for version in "$GATEWAY_API_VERSION" "$INFERENCE_EXTENSION_VERSION" "$ISTIO_VERSION"; do
        if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          echo "A prerequisite version is not a full stable semantic version: $version" >&2
          exit 1
        fi
      done

      kubectl --request-timeout=30s get --raw=/readyz
      gateway_before="$(kubectl --request-timeout=30s get crd gateways.gateway.networking.k8s.io --ignore-not-found -o name)"
      inference_before="$(kubectl --request-timeout=30s get crd inferencepools.inference.networking.k8s.io --ignore-not-found -o name)"
      istiod_before="$(kubectl --request-timeout=30s get deployment istiod -n istio-system --ignore-not-found -o name)"

      curl --fail --silent --show-error --location --retry 3 \
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GATEWAY_API_VERSION/experimental-install.yaml" \
        --output "$work_dir/gateway.yaml"
      curl --fail --silent --show-error --location --retry 3 \
        "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v$INFERENCE_EXTENSION_VERSION/manifests.yaml" \
        --output "$work_dir/inference.yaml"
      kubectl --request-timeout=60s apply --server-side --field-manager=foundry-wo-bootstrap -f "$work_dir/gateway.yaml"
      kubectl --request-timeout=60s apply --server-side --field-manager=foundry-wo-bootstrap -f "$work_dir/inference.yaml"
      kubectl wait --for=condition=Established --timeout=180s -f "$work_dir/gateway.yaml"
      kubectl wait --for=condition=Established --timeout=180s -f "$work_dir/inference.yaml"

      helm upgrade --install istio-base base --repo https://blob.istio.io/istio-release/charts \
        --version "$ISTIO_VERSION" --namespace istio-system --create-namespace \
        --set defaultRevision=default --wait --timeout 10m
      helm upgrade --install istiod istiod --repo https://blob.istio.io/istio-release/charts \
        --version "$ISTIO_VERSION" --namespace istio-system \
        --set pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true --wait --timeout 10m
      if [ -n "$istiod_before" ] && { [ -z "$gateway_before" ] || [ -z "$inference_before" ]; }; then
        kubectl -n istio-system rollout restart deployment/istiod
      fi
      kubectl -n istio-system rollout status deployment/istiod --timeout=300s
      kubectl wait gatewayclass/istio --for=condition=Accepted --timeout=180s

      cert_manager="$(kubectl --request-timeout=30s get deployment cert-manager -n cert-manager --ignore-not-found -o name)"
      if [ -n "$cert_manager" ]; then
        # Refresh startup CRD discovery even when a previous bootstrap stopped after installing CRDs.
        kubectl -n cert-manager rollout restart deployment/cert-manager
        kubectl -n cert-manager rollout status deployment/cert-manager --timeout=300s
      else
        echo "Certificate management will be installed next by WO."
      fi

      # Recover an existing store before the extension's pre-upgrade maintenance hook runs.
      model_store="$(kubectl --request-timeout=30s -n foundry-local-operator get deployment \
        -l "app.kubernetes.io/instance=$FOUNDRY_EXTENSION_NAME,app.kubernetes.io/component=model-store,app.kubernetes.io/managed-by=Helm" -o name)"
      if [ -n "$model_store" ]; then
        if [[ "$model_store" == *$'\n'* ]]; then
          echo "Multiple model-store deployments match this Foundry extension; refusing ambiguous recovery." >&2
          exit 1
        fi
        kubectl --request-timeout=30s -n foundry-local-operator set resources "$model_store" \
          --containers=model-store-auth --requests="cpu=$MODEL_STORE_AUTH_CPU_REQUEST" --limits="cpu=$MODEL_STORE_AUTH_CPU_LIMIT"
        # A failed install can retain a stale progress deadline until the recovered pod is available.
        kubectl -n foundry-local-operator wait "$model_store" --for=condition=Available --timeout=600s
        kubectl -n foundry-local-operator rollout status "$model_store" --timeout=600s
      else
        echo "Model-store CPU settings will be applied by WO during the initial extension installation."
      fi

      operator_deployment="$(kubectl --request-timeout=30s -n foundry-local-operator get deployment \
        -l "app.kubernetes.io/instance=$FOUNDRY_EXTENSION_NAME,app.kubernetes.io/managed-by=Helm" -o json | python3 -c \
        'import json, sys; print("\n".join("deployment/" + d["metadata"]["name"] for d in json.load(sys.stdin)["items"] if d["spec"]["template"]["metadata"]["labels"].get("app.kubernetes.io/component") == "operator"))')"
      if [ -n "$operator_deployment" ]; then
        if [[ "$operator_deployment" == *$'\n'* ]]; then
          echo "Multiple operator deployments match this Foundry extension; refusing ambiguous recovery." >&2
          exit 1
        fi
        # Recover an unfinished surge rollout blocked by the RWO evaluation disk; Helm owns future strategy changes.
        kubectl --request-timeout=30s -n foundry-local-operator patch "$operator_deployment" \
          --type=merge --patch '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
        kubectl -n foundry-local-operator wait "$operator_deployment" --for=condition=Available --timeout=600s
        kubectl -n foundry-local-operator rollout status "$operator_deployment" --timeout=600s
      fi

      release_state="$(helm list --all -n foundry-local-operator -o json | python3 -c \
        'import json, sys; matches = [r for r in json.load(sys.stdin) if r["name"] == sys.argv[1]]; print(matches[0]["status"] if matches else "absent")' \
        "$FOUNDRY_EXTENSION_NAME")"
      case "$release_state" in
        absent|deployed|failed|superseded|uninstalled)
          echo "Existing Foundry release lifecycle: $release_state."
          ;;
        *)
          echo "Foundry release lifecycle is $release_state; resolve the existing extension operation before starting another WO deployment." >&2
          exit 1
          ;;
      esac

      printf '{"gatewayClass":"istio","gatewayApiVersion":"%s","inferenceExtensionVersion":"%s","istioVersion":"%s"}\n' \
        "$GATEWAY_API_VERSION" "$INFERENCE_EXTENSION_VERSION" "$ISTIO_VERSION" > "$AZ_SCRIPTS_OUTPUT_PATH"
      echo "Foundry Kubernetes prerequisites are ready; WO can deploy the extensions."
      '''
      ],
      '\n'
    )
  }
}

var defaultHierarchies = [
  {
    name: empty(hierarchyLevel) ? 'level-1' : hierarchyLevel
    description: 'Foundry Local deployment level.'
  }
]

resource managedContext 'Microsoft.Edge/contexts@2025-08-01' = if (empty(contextId)) {
  name: 'foundry-extension-${uniqueString(connectedCluster.id)}'
  location: location
  properties: {
    capabilities: [
      {
        name: capabilityName
        description: 'Capability for Foundry Local extension deployment.'
        state: 'active'
      }
    ]
    hierarchies: defaultHierarchies
  }
}

var resolvedContextId = empty(contextId) ? managedContext!.id : contextId

var selectedContext = empty(contextId)
  ? {
      location: location
      tags: {}
      properties: {
        capabilities: []
        hierarchies: []
      }
    }
  : reference(contextId, '2025-08-01', 'Full')
var existingCapabilities = selectedContext.properties.?capabilities ?? []
var existingHierarchies = selectedContext.properties.?hierarchies ?? []
var mergedCapabilities = contains(map(existingCapabilities, capability => capability.name), capabilityName)
  ? existingCapabilities
  : concat(existingCapabilities, [
      {
        name: capabilityName
        description: 'Capability for Foundry Local workloads.'
        state: 'active'
      }
    ])
var effectiveHierarchies = empty(existingHierarchies) ? defaultHierarchies : existingHierarchies
var effectiveHierarchyLevel = empty(hierarchyLevel) ? last(effectiveHierarchies).name : hierarchyLevel

// Outer-scoped literal templates retain the parent snapshot across the context's resource-group boundary.
resource contextRegistration 'Microsoft.Resources/deployments@2022-09-01' = if (!empty(contextId)) {
  name: '${uniqueString(connectedCluster.id)}-foundry-context'
  properties: {
    mode: 'Incremental'
    expressionEvaluationOptions: {
      scope: 'outer'
    }
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: [
        {
          type: 'Microsoft.Resources/deployments'
          apiVersion: '2022-09-01'
          name: '${uniqueString(connectedCluster.id)}-foundry-context-update'
          subscriptionId: split(resolvedContextId, '/')[2]
          resourceGroup: split(resolvedContextId, '/')[4]
          properties: {
            mode: 'Incremental'
            expressionEvaluationOptions: {
              scope: 'outer'
            }
            template: {
              '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
              contentVersion: '1.0.0.0'
              resources: [
                {
                  condition: length(mergedCapabilities) > length(existingCapabilities) || empty(existingHierarchies)
                  type: 'Microsoft.Edge/contexts'
                  apiVersion: '2025-08-01'
                  name: last(split(resolvedContextId, '/'))
                  location: selectedContext.location
                  tags: selectedContext.?tags ?? {}
                  properties: {
                    capabilities: mergedCapabilities
                    hierarchies: effectiveHierarchies
                  }
                }
              ]
            }
          }
        }
      ]
    }
  }
}

var modelScriptName = 'foundry-model-${uniqueString(aksCluster.id, solutionName)}'
var modelDeploymentScript = join(
  [
    aksClientSetupScript
    '''
      python3 - <<'PY'
import base64
from decimal import Decimal
import gzip
import hashlib
import json
import os
import re
import subprocess
import time

NAMESPACE = "foundry-local-operator"
OWNER_ANNOTATION = "foundrylocal.azure.com/wo-owner"

def kubectl(*args, stdin=None):
    result = subprocess.run(
        ["kubectl", "--request-timeout=30s", "-n", NAMESPACE, *args],
        input=stdin, text=True, stdout=subprocess.PIPE, check=True, timeout=45,
    )
    return json.loads(result.stdout) if result.stdout.strip() else None

def quantity(value):
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?|\.[0-9]+)([eE][+-]?[0-9]+|[numkKMGTPE]|[KMGTPE]i)?", value)
    if not match:
        raise ValueError("Invalid positive Kubernetes resource quantity.")
    number, suffix = Decimal(match[1]), match[2] or ""
    if suffix.endswith("i"):
        number *= Decimal(1024) ** ("KMGTPE".index(suffix[0]) + 1)
    elif suffix.startswith(("e", "E")) and len(suffix) > 1:
        number *= Decimal(10) ** int(suffix[1:])
    else:
        number *= Decimal(10) ** {"": 0, "n": -9, "u": -6, "m": -3, "k": 3, "K": 3, "M": 6, "G": 9, "T": 12, "P": 15, "E": 18}[suffix]
    return number

def asset_ids(value):
    if isinstance(value, dict):
        if isinstance(value.get("assetId"), str):
            yield value["assetId"]
        for child in value.values():
            yield from asset_ids(child)
    elif isinstance(value, list):
        for child in value:
            yield from asset_ids(child)

def resolve_asset(catalog, alias, version, runtime, compute):
    models = catalog.get("models") if isinstance(catalog, dict) else catalog
    if not isinstance(models, list) or any(not isinstance(model, dict) for model in models):
        raise ValueError("Alias resolution requires a catalog models list; use an explicit modelAssetId for an unsupported catalog layout.")
    candidates = set()
    available = set()
    for model in models:
        if not isinstance(model.get("alias"), str) or model["alias"].casefold() != alias.casefold():
            continue
        variants = model.get("variants") or [{}]
        if not isinstance(variants, list) or any(not isinstance(variant, dict) for variant in variants):
            raise ValueError("Selected catalog alias has an unsupported variants layout.")
        for variant in variants:
            asset = variant.get("assetId") or model.get("assetId")
            if not isinstance(asset, str) or not asset.strip() or asset != asset.strip() or len(asset) > 256:
                raise ValueError("Selected catalog alias has a missing or invalid full assetId.")
            versions = set()
            for value in (variant.get("modelVersion"), model.get("modelVersion")):
                if value is not None:
                    if isinstance(value, bool) or not isinstance(value, (str, int)):
                        raise ValueError("Selected catalog alias has an unsupported model version.")
                    versions.add(str(value))
            artifact_id = variant.get("id") or model.get("id")
            if isinstance(artifact_id, str) and ":" in artifact_id and "://" not in artifact_id:
                versions.add(artifact_id.rsplit(":", 1)[1])
            asset_version = re.fullmatch(r"azureml://registries/[^/]+/models/[^/]+/versions/([^/?#]+)", asset)
            if asset_version:
                versions.add(asset_version[1])
            if len(versions) > 1:
                raise ValueError("Selected catalog alias has conflicting modelVersion, artifact ID or asset ID versions.")
            entry_version = next(iter(versions), "")
            framework = variant.get("runtime") or variant.get("framework") or model.get("runtime") or model.get("framework") or ""
            entry_runtime = {"onnx": "onnx-genai", "onnx-genai": "onnx-genai", "vllm": "vllm"}.get(str(framework).casefold(), "")
            entry_compute = variant.get("compute") or model.get("compute")
            if not entry_compute:
                supported = variant.get("supportedCompute", model.get("supportedCompute"))
                if isinstance(supported, list) and len(supported) == 1:
                    entry_compute = supported[0]
            entry_compute = str(entry_compute or "").casefold()
            available.add((str(entry_version), entry_runtime or "unknown", entry_compute or "unknown"))
            if (str(entry_version), entry_runtime, entry_compute) == (version, runtime, compute):
                candidates.add(asset)
    if len(candidates) != 1:
        offerings = ", ".join("/".join(entry) for entry in sorted(available)) or "none"
        raise ValueError(
            "Catalog selection matched " + str(len(candidates)) + " distinct assets for alias=" + alias
            + ", version=" + version + ", runtime=" + runtime + ", compute=" + compute
            + ". Require exactly one asset; available version/runtime/compute entries: " + offerings
            + ". Review selectors or supply an explicit modelAssetId."
        )
    return candidates.pop()

def matches(desired, actual):
    if isinstance(desired, dict):
        return isinstance(actual, dict) and all(key in actual and matches(value, actual[key]) for key, value in desired.items())
    return type(desired) is type(actual) and desired == actual

def ready_internal_endpoint(status):
    # Do not let native fields mask incomplete or explicitly failed legacy readiness.
    if any(key in status for key in ("serviceReady", "endpointReady", "internalEndpoint")):
        ready = all(status.get(key) is True for key in ("serviceReady", "endpointReady"))
        endpoint = status.get("internalEndpoint")
    else:
        ready = all(status.get(key) is True for key in ("serviceCreated", "httpRouteReady", "tlsEnabled"))
        endpoint = status.get("endpoints", {}).get("internal")
    return endpoint if ready and isinstance(endpoint, str) and endpoint.startswith("https://") else None

def workload_ready(workload, uid, manifest):
    if not any(owner.get("uid") == uid and owner.get("kind") == "ModelDeployment" for owner in workload["metadata"].get("ownerReferences", [])):
        return False
    spec, status = workload["spec"], workload.get("status", {})
    replicas = manifest["spec"]["replicas"]
    if spec.get("replicas") != replicas or status.get("observedGeneration", 0) < workload["metadata"]["generation"]:
        return False
    if any(status.get(key, 0) != replicas for key in ("updatedReplicas", "readyReplicas", "availableReplicas")):
        return False
    if status.get("replicas") != replicas:
        return False
    expected = manifest["spec"]["resources"]
    for container in spec["template"]["spec"]["containers"]:
        resources = container.get("resources", {})
        if all(
            quantity(resources.get(group, {}).get(key, "0")) == quantity(value)
            for group in ("requests", "limits")
            for key, value in expected[group].items() if key != "gpu"
        ):
            if int(resources.get("limits", {}).get("nvidia.com/gpu", 0)) == expected["limits"].get("gpu", 0):
                return True
    return False

def main():
    name, asset = os.environ["MODEL_NAME"], os.environ["MODEL_ASSET_ID"]
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", name):
        raise ValueError("modelDeploymentName must be a lowercase DNS label of 1-63 characters.")
    if asset != asset.strip() or len(asset) > 256:
        raise ValueError("modelAssetId must be an unpadded full catalog ID of at most 256 characters.")
    alias, version, runtime = (os.environ[key] for key in ("MODEL_CATALOG_ALIAS", "MODEL_VERSION", "MODEL_RUNTIME"))
    if runtime not in ("", "onnx-genai", "vllm"):
        raise ValueError("modelRuntime must be empty, onnx-genai or vllm.")
    cpu, memory = os.environ["MODEL_CPU"], os.environ["MODEL_MEMORY"]
    cpu_value = quantity(cpu)
    if cpu_value <= 0 or quantity(memory) <= 0:
        raise ValueError("Model CPU and memory must be greater than zero.")
    if cpu_value * 1000 != (cpu_value * 1000).to_integral_value():
        raise ValueError("Model CPU must have at most millicore precision.")
    replicas, gpu = int(os.environ["MODEL_REPLICAS"]), int(os.environ["MODEL_GPU_COUNT"])
    compute, display_name = os.environ["MODEL_COMPUTE"], os.environ["MODEL_DISPLAY_NAME"]
    if compute not in ("", "cpu", "gpu"):
        raise ValueError("modelCompute must be empty, cpu or gpu.")
    if (compute == "cpu" and gpu != 0) or (compute == "gpu" and gpu == 0):
        raise ValueError("modelCompute cpu requires modelGpuCount 0; gpu requires modelGpuCount 1-8.")
    if not asset and (
        not alias.strip() or alias != alias.strip() or len(alias) > 256
        or not version.strip() or version != version.strip() or len(version) > 64
        or version.casefold() in ("latest", "all") or not runtime or not compute
    ):
        raise ValueError("An empty modelAssetId requires modelCatalogAlias, an exact modelVersion, modelRuntime and modelCompute.")
    if len(display_name) > 256:
        raise ValueError("modelDisplayName must contain at most 256 characters.")
    timeout = int(os.environ["MODEL_READY_TIMEOUT_SECONDS"])
    if not 1 <= replicas <= 100 or not 0 <= gpu <= 8 or not 60 <= timeout <= 3600:
        raise ValueError("Model replicas, GPU count or readiness timeout is outside its supported range.")
    platform_deadline = time.monotonic() + 600
    while True:
        releases = subprocess.run(
            ["helm", "list", "--all", "-n", NAMESPACE, "-o", "json"],
            text=True, stdout=subprocess.PIPE, check=True, timeout=45,
        )
        release = next((r for r in json.loads(releases.stdout) if r["name"] == os.environ["FOUNDRY_EXTENSION_NAME"]), None)
        state = release["status"] if release else "absent"
        if state not in ("absent", "deployed", "pending-install", "pending-upgrade", "pending-rollback"):
            raise RuntimeError("Foundry native release is not healthy: " + state)
        crd = kubectl("get", "crd", "modeldeployments.foundrylocal.azure.com", "--ignore-not-found", "-o", "json")
        if state == "deployed" and crd and any(c.get("type") == "Established" and c.get("status") == "True" for c in crd.get("status", {}).get("conditions", [])):
            deployments = kubectl("get", "deployment", "-l", "app.kubernetes.io/instance=" + os.environ["FOUNDRY_EXTENSION_NAME"] + ",app.kubernetes.io/managed-by=Helm", "-o", "json")["items"]
            components = {}
            for deployment in deployments:
                component = deployment["spec"]["template"]["metadata"].get("labels", {}).get("app.kubernetes.io/component")
                if component in ("operator", "model-store"):
                    if component in components:
                        raise RuntimeError("Ambiguous Foundry platform deployment: " + component)
                    components[component] = deployment
            if set(components) == {"operator", "model-store"} and all(
                d.get("status", {}).get("observedGeneration", 0) >= d["metadata"]["generation"]
                and d.get("status", {}).get("updatedReplicas", 0) == d["spec"].get("replicas", 1)
                and d.get("status", {}).get("readyReplicas", 0) == d["spec"].get("replicas", 1)
                and d.get("status", {}).get("availableReplicas", 0) == d["spec"].get("replicas", 1)
                and d.get("status", {}).get("replicas", 0) == d["spec"].get("replicas", 1)
                and d["spec"].get("replicas", 1) > 0 for d in components.values()
            ):
                break
        if time.monotonic() >= platform_deadline:
            raise TimeoutError("Foundry native release, ModelDeployment CRD, operator or model store did not become ready in 600 seconds.")
        print("Waiting for Foundry platform readiness; release state: " + state, flush=True)
        time.sleep(10)

    versions = [v for v in crd["spec"]["versions"] if v["name"] == "v1" and v.get("served")]
    if len(versions) != 1:
        raise RuntimeError("Installed ModelDeployment CRD does not serve foundrylocal.azure.com/v1.")
    schema = versions[0]["schema"]["openAPIV3Schema"]["properties"]
    properties = schema["spec"]["properties"]
    key_status = schema.get("status", {}).get("properties", {}).get("authentication", {}).get("properties", {}).get("keysSecretName", {})
    if "assetId" not in properties.get("model", {}).get("properties", {}) or key_status.get("type") != "string":
        raise RuntimeError("Installed ModelDeployment schema must support model.assetId and native API-key Secret-name status.")
    legacy_auth = properties.get("authentication")
    if legacy_auth is not None and legacy_auth.get("properties", {}).get("enabled", {}).get("type") != "boolean":
        raise RuntimeError("Installed legacy authentication schema does not support an explicit enabled flag.")
    while True:
        catalog_cm = kubectl("get", "configmap", "foundry-local-catalog", "--ignore-not-found", "-o", "json")
        compressed = (catalog_cm or {}).get("binaryData", {}).get("catalog.json.gz")
        if compressed:
            catalog = json.loads(gzip.decompress(base64.b64decode(compressed, validate=True)))
            if any(asset_ids(catalog)):
                break
        if time.monotonic() >= platform_deadline:
            raise TimeoutError("Installed catalog did not become populated within the platform readiness timeout.")
        print("Waiting for the installed Foundry catalog to become populated.", flush=True)
        time.sleep(10)
    if not asset:
        asset = resolve_asset(catalog, alias, version, runtime, compute)
        print("Resolved installed catalog asset: " + asset, flush=True)
    if asset not in set(asset_ids(catalog)):
        raise ValueError("modelAssetId is absent from the installed catalog. Copy the full ID of a supported model version and variant.")
    owner = os.environ["MODEL_OWNER"]
    field_manager = "foundry-wo-model-" + hashlib.sha256(owner.encode()).hexdigest()[:12]
    manifest = {
        "apiVersion": "foundrylocal.azure.com/v1", "kind": "ModelDeployment",
        "metadata": {"name": name, "namespace": NAMESPACE, "annotations": {OWNER_ANNOTATION: owner}},
        "spec": {
            "model": {"assetId": asset}, "workloadType": "generative", "port": 5000,
            "replicas": replicas,
            "endpoint": {"exposure": "internal"},
            "resources": {"requests": {"cpu": cpu, "memory": memory}, "limits": {"cpu": cpu, "memory": memory}},
        },
    }
    # Current operators generate API keys natively; authenticationMethods only opts in to SAT.
    if legacy_auth is not None:
        manifest["spec"]["authentication"] = {"enabled": True}
    if gpu:
        manifest["spec"]["resources"]["limits"]["gpu"] = gpu
    if compute:
        manifest["spec"]["compute"] = compute
    if runtime:
        manifest["spec"]["runtime"] = runtime
    if display_name:
        manifest["spec"]["displayName"] = display_name
    existing = kubectl("get", "modeldeployments.foundrylocal.azure.com", name, "--ignore-not-found", "-o", "json")
    if existing and existing["metadata"].get("annotations", {}).get(OWNER_ANNOTATION) != owner:
        raise RuntimeError("The model name already exists outside this WO solution; choose a new name. Automatic adoption is not supported.")
    previous_status = existing.get("status", {}) if existing else {}
    encoded = json.dumps(manifest)
    preview = kubectl("apply", "--server-side", "--field-manager=" + field_manager, "--dry-run=server", "-f", "-", "-o", "json", stdin=encoded)
    if not matches(manifest["spec"], preview["spec"]):
        raise RuntimeError("The installed CRD pruned or changed required model fields during server validation; refusing deployment.")
    applied = kubectl("apply", "--server-side", "--field-manager=" + field_manager, "-f", "-", "-o", "json", stdin=encoded)
    uid = applied["metadata"]["uid"]

    deadline = time.monotonic() + timeout
    while True:
        current = kubectl("get", "modeldeployments.foundrylocal.azure.com", name, "-o", "json")
        if current["metadata"]["uid"] != uid or current["metadata"].get("annotations", {}).get(OWNER_ANNOTATION) != owner or not matches(manifest["spec"], current["spec"]):
            raise RuntimeError("The model was replaced or its desired configuration changed during readiness checks.")
        status = current.get("status", {})
        if status.get("state") == "Error" and status != previous_status:
            raise RuntimeError("Foundry reported model state Error. Inspect the ModelDeployment status and events.")
        endpoint = ready_internal_endpoint(status)
        deployments = kubectl("get", "deployment", "-o", "json")["items"]
        if (
            status.get("state") == "Running"
            and status.get("resolvedModel", {}).get("assetId") == asset
            and (not compute or status.get("resolvedModel", {}).get("compute") == compute)
            and (not runtime or status.get("resolvedModel", {}).get("runtime") == runtime)
            and status.get("deploymentReady") is True
            and status.get("authentication", {}).get("keysSecretName")
            and endpoint
            and any(workload_ready(d, uid, manifest) for d in deployments)
        ):
            with open(os.environ["AZ_SCRIPTS_OUTPUT_PATH"], "w") as output:
                json.dump({
                    "namespace": NAMESPACE, "modelDeploymentName": name, "modelAssetId": asset,
                    "modelVersion": status.get("resolvedModel", {}).get("version"),
                    "modelCompute": status.get("resolvedModel", {}).get("compute"),
                    "modelRuntime": status.get("resolvedModel", {}).get("runtime"),
                    "state": "Running", "internalEndpoint": endpoint,
                }, output)
            print("ModelDeployment is Running with current ready replicas, authenticated serving configuration and an internal endpoint.", flush=True)
            return
        if time.monotonic() >= deadline:
            raise TimeoutError("Model did not reach current workload and endpoint readiness within the configured timeout. Inspect model status, pods, PVCs and events.")
        print("Waiting for model and current workload readiness; model state: " + str(status.get("state", "Pending")), flush=True)
        time.sleep(10)

if __name__ == "__main__":
    main()
PY
  '''
  ],
  '\n'
)

// Keep ARM expressions literal here: WO supplies these parameters when deploying the Template Spec.
var extensionTemplate = {
  '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
  contentVersion: '1.0.0.0'
  parameters: {
    connectClusterName: {
      type: 'string'
      minLength: 1
    }
    entraTenantId: {
      type: 'string'
      minLength: 1
    }
    entraClientId: {
      type: 'string'
      defaultValue: ''
    }
    certManagerExtensionName: {
      type: 'string'
      minLength: 1
    }
    foundryExtensionName: {
      type: 'string'
      minLength: 1
    }
    deployModel: {
      type: 'bool'
      defaultValue: false
    }
    modelDeploymentName: {
      type: 'string'
      minLength: 1
      maxLength: 63
    }
    modelAssetId: {
      type: 'string'
      maxLength: 256
    }
    modelCatalogAlias: {
      type: 'string'
      defaultValue: ''
      maxLength: 256
    }
    modelVersion: {
      type: 'string'
      defaultValue: ''
      maxLength: 64
    }
    modelRuntime: {
      type: 'string'
      defaultValue: ''
      allowedValues: [
        ''
        'onnx-genai'
        'vllm'
      ]
    }
    modelDisplayName: {
      type: 'string'
      maxLength: 256
    }
    modelCompute: {
      type: 'string'
      allowedValues: [
        ''
        'cpu'
        'gpu'
      ]
    }
    modelReplicas: {
      type: 'int'
      minValue: 1
      maxValue: 100
    }
    modelCpu: {
      type: 'string'
      minLength: 1
    }
    modelMemory: {
      type: 'string'
      minLength: 1
    }
    modelGpuCount: {
      type: 'int'
      minValue: 0
      maxValue: 8
    }
    modelReadyTimeoutSeconds: {
      type: 'int'
      minValue: 60
      maxValue: 3600
    }
  }
  resources: [
    {
      type: 'Microsoft.KubernetesConfiguration/extensions'
      apiVersion: '2022-03-01'
      scope: '[resourceId(\'Microsoft.Kubernetes/connectedClusters\', parameters(\'connectClusterName\'))]'
      name: '[parameters(\'certManagerExtensionName\')]'
      identity: {
        type: 'SystemAssigned'
      }
      properties: {
        extensionType: 'Microsoft.CertManagement'
        autoUpgradeMinorVersion: true
        releaseTrain: 'stable'
        scope: {
          cluster: {
            releaseNamespace: 'cert-manager'
          }
        }
        configurationSettings: {
          'config.enableGatewayAPI': 'true'
          'cert-manager.crds.keep': 'true'
          'trust-manager.defaultPackage.enabled': 'false'
          'trust-manager.secretTargets.enabled': 'true'
          'trust-manager.secretTargets.authorizedSecretsAll': 'true'
        }
      }
    }
    {
      type: 'Microsoft.KubernetesConfiguration/extensions'
      apiVersion: '2022-03-01'
      scope: '[resourceId(\'Microsoft.Kubernetes/connectedClusters\', parameters(\'connectClusterName\'))]'
      name: '[parameters(\'foundryExtensionName\')]'
      dependsOn: [
        '[extensionResourceId(resourceId(\'Microsoft.Kubernetes/connectedClusters\', parameters(\'connectClusterName\')), \'Microsoft.KubernetesConfiguration/extensions\', parameters(\'certManagerExtensionName\'))]'
      ]
      properties: {
        extensionType: 'Microsoft.Foundry'
        autoUpgradeMinorVersion: true
        releaseTrain: 'stable'
        scope: {
          cluster: {
            releaseNamespace: 'foundry-local-operator'
          }
        }
        configurationSettings: {
          'api.exposure': 'internal'
          'satAuth.enabled': 'true'
          'model-store.registry.auth.resources.requests.cpu': modelStoreAuthCpuRequest
          'model-store.registry.auth.resources.limits.cpu': modelStoreAuthCpuLimit
          'entraAuth.enabled': '[if(empty(trim(parameters(\'entraClientId\'))), \'false\', \'true\')]'
          'entraAuth.tenantId': '[parameters(\'entraTenantId\')]'
          'entraAuth.clientId': '[trim(parameters(\'entraClientId\'))]'
        }
      }
    }
    {
      condition: '[parameters(\'deployModel\')]'
      type: 'Microsoft.Resources/deploymentScripts'
      apiVersion: '2023-08-01'
      name: modelScriptName
      location: bootstrapLocation
      kind: 'AzureCLI'
      identity: {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${bootstrapIdentity.id}': {}
        }
      }
      dependsOn: [
        '[extensionResourceId(resourceId(\'Microsoft.Kubernetes/connectedClusters\', parameters(\'connectClusterName\')), \'Microsoft.KubernetesConfiguration/extensions\', parameters(\'foundryExtensionName\'))]'
      ]
      properties: {
        azCliVersion: '2.89.1'
        timeout: 'PT90M'
        cleanupPreference: 'OnSuccess'
        retentionInterval: 'P1D'
        forceUpdateTag: bootstrapRunTag
        environmentVariables: [
          {
            name: 'AKS_SUBSCRIPTION'
            value: subscription().subscriptionId
          }
          {
            name: 'AKS_IDENTITY_CLIENT_ID'
            value: bootstrapIdentity.properties.clientId
          }
          {
            name: 'AKS_RESOURCE_GROUP'
            value: resourceGroup().name
          }
          {
            name: 'AKS_CLUSTER'
            value: aksClusterName
          }
          {
            name: 'KUBECTL_VERSION'
            value: aksCluster.properties.currentKubernetesVersion
          }
          {
            name: 'FOUNDRY_EXTENSION_NAME'
            value: '[parameters(\'foundryExtensionName\')]'
          }
          {
            name: 'MODEL_NAME'
            value: '[parameters(\'modelDeploymentName\')]'
          }
          {
            name: 'MODEL_ASSET_ID'
            value: '[parameters(\'modelAssetId\')]'
          }
          {
            name: 'MODEL_CATALOG_ALIAS'
            value: '[parameters(\'modelCatalogAlias\')]'
          }
          {
            name: 'MODEL_VERSION'
            value: '[parameters(\'modelVersion\')]'
          }
          {
            name: 'MODEL_RUNTIME'
            value: '[parameters(\'modelRuntime\')]'
          }
          {
            name: 'MODEL_DISPLAY_NAME'
            value: '[parameters(\'modelDisplayName\')]'
          }
          {
            name: 'MODEL_COMPUTE'
            value: '[parameters(\'modelCompute\')]'
          }
          {
            name: 'MODEL_REPLICAS'
            value: '[string(parameters(\'modelReplicas\'))]'
          }
          {
            name: 'MODEL_CPU'
            value: '[parameters(\'modelCpu\')]'
          }
          {
            name: 'MODEL_MEMORY'
            value: '[parameters(\'modelMemory\')]'
          }
          {
            name: 'MODEL_GPU_COUNT'
            value: '[string(parameters(\'modelGpuCount\'))]'
          }
          {
            name: 'MODEL_READY_TIMEOUT_SECONDS'
            value: '[string(parameters(\'modelReadyTimeoutSeconds\'))]'
          }
          {
            name: 'MODEL_OWNER'
            value: '${resourceGroup().id}/providers/Microsoft.Edge/solutionTemplates/${solutionName}'
          }
        ]
        scriptContent: modelDeploymentScript
      }
    }
  ]
}

resource templateSpec 'Microsoft.Resources/templateSpecs@2022-02-01' = {
  name: templateSpecName
  location: location
  properties: {
    description: 'Install Foundry Local through Azure Arc extensions and optionally deploy a catalog model.'
  }

  resource version 'versions@2022-02-01' = {
    name: templateSpecVersion
    location: location
    properties: {
      mainTemplate: extensionTemplate
    }
  }
}

// A cloud target lets WO deploy ARM resources without a Kubernetes Helm binding or custom location.
resource cloudTarget 'Microsoft.Edge/targets@2026-05-01-preview' = {
  name: targetName
  location: location
  dependsOn: [
    contextRegistration
  ]
  properties: {
    capabilities: [
      capabilityName
    ]
    contextId: resolvedContextId
    description: 'Cloud target for Foundry Local Arc extension deployment'
    displayName: 'Foundry Local Extension Target'
    hierarchyLevel: effectiveHierarchyLevel
  }
}

resource solutionTemplate 'Microsoft.Edge/solutionTemplates@2026-05-01-preview' = {
  name: solutionName
  location: location
  dependsOn: [
    cloudTarget
  ]
  properties: {
    description: 'Deploy the Foundry Local Arc extension using an ARM Template Spec'
    capabilities: [
      capabilityName
    ]
  }

  resource version 'versions@2026-05-01-preview' = {
    name: solutionTemplateVersion
    properties: {
      configurations: {
        configs: {
          connectClusterName: connectClusterName
          entraTenantId: entraTenantId
          entraClientId: entraClientId
          certManagerExtensionName: certManagerExtensionName
          foundryExtensionName: foundryExtensionName
          deployModel: deployModel
          modelDeploymentName: modelDeploymentName
          modelAssetId: modelAssetId
          modelCatalogAlias: modelCatalogAlias
          modelVersion: modelVersion
          modelRuntime: modelRuntime
          modelDisplayName: modelDisplayName
          modelCompute: modelCompute
          modelReplicas: modelReplicas
          modelCpu: modelCpu
          modelMemory: modelMemory
          modelGpuCount: modelGpuCount
          modelReadyTimeoutSeconds: modelReadyTimeoutSeconds
        }
      }
      specification: {
        components: [
          {
            name: 'foundry-local-extension'
            type: 'armtemplate'
            properties: {
              template: {
                subscriptionId: subscription().subscriptionId
                resourceGroupName: resourceGroup().name
                name: templateSpec.name
                version: templateSpec::version.name
              }
            }
          }
        ]
      }
    }
  }
}

resource solutionDeployment 'Microsoft.Edge/solutionDeployments@2026-05-01-preview' = {
  name: solutionDeploymentName
  location: location
  dependsOn: [
    prerequisiteBootstrap
  ]
  properties: {
    solutionTemplateProperties: {
      name: solutionTemplate.name
      version: solutionTemplate::version.name
    }
    targetProperties: {
      targetIds: [
        cloudTarget.id
      ]
    }
  }
}

output contextResourceId string = resolvedContextId
output targetHierarchyLevel string = effectiveHierarchyLevel
output targetId string = cloudTarget.id
output templateSpecVersionId string = templateSpec::version.id
output solutionDeploymentId string = solutionDeployment.id
output prerequisiteBootstrapId string = prerequisiteBootstrap.id
output foundryExtensionId string = extensionResourceId(
  connectedCluster.id,
  'Microsoft.KubernetesConfiguration/extensions',
  foundryExtensionName
)
output entraAuthenticationEnabled bool = !empty(trim(entraClientId))
output modelDeploymentRequested bool = deployModel
output modelResourceName string = deployModel ? modelDeploymentName : ''
output modelDeploymentScriptId string = deployModel
  ? resourceId('Microsoft.Resources/deploymentScripts', modelScriptName)
  : ''
