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

@description('ARM Template Spec version. Increment when changing the embedded extension template.')
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

// Python startup and exec probes were CPU-starved under the chart's 250m auth limit.
var modelStoreAuthCpuRequest = '250m'
var modelStoreAuthCpuLimit = '1'

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
    scriptContent: '''
      set -Eeuo pipefail
      umask 077
      work_dir="$(mktemp -d)"
      export KUBECONFIG="$work_dir/kubeconfig"
      trap 'rm -f -- "$KUBECONFIG"' EXIT
      trap 'echo "Foundry prerequisite bootstrap failed at line $LINENO." >&2' ERR

      for version in "$KUBECTL_VERSION" "$GATEWAY_API_VERSION" "$INFERENCE_EXTENSION_VERSION" "$ISTIO_VERSION"; do
        if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          echo "A prerequisite version is not a full stable semantic version: $version" >&2
          exit 1
        fi
      done

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

      # Retry only propagation-related authorization failures, never unrelated credential errors.
      for ((attempt=1; attempt<=30; attempt++)); do
        if az aks get-credentials --subscription "$AKS_SUBSCRIPTION" --resource-group "$AKS_RESOURCE_GROUP" \
          --name "$AKS_CLUSTER" --admin --file "$KUBECONFIG" --only-show-errors --output none \
          2>"$work_dir/credential-error"; then
          break
        fi
        credential_error="$(cat "$work_dir/credential-error")"
        if { [[ "$credential_error" != *AuthorizationFailed* ]] && [[ "$credential_error" != *"does not have authorization"* ]]; } || [ "$attempt" -eq 30 ]; then
          cat "$work_dir/credential-error" >&2
          exit 1
        fi
        echo "Waiting for AKS-scoped credential permission to propagate ($attempt/30)."
        sleep 10
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
  ]
}

resource templateSpec 'Microsoft.Resources/templateSpecs@2022-02-01' = {
  name: templateSpecName
  location: location
  properties: {
    description: 'Install Foundry Local through Azure Arc extensions.'
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
