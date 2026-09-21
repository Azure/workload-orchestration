[CmdletBinding()]
param(
    [string]$KubeConfigPath,
    [string]$KubeContext,
    [string]$WorkloadOrchestrationNamespace = 'workloadorchestration'
)

$ErrorActionPreference = 'Stop'

function Invoke-Kubectl {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $connection = @()
    if ($KubeConfigPath) {
        $connection += @('--kubeconfig', $KubeConfigPath)
    }
    if ($KubeContext) {
        $connection += @('--context', $KubeContext)
    }

    $output = & kubectl @connection @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed."
    }
    return ($output | Out-String)
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl is required.'
}
if ($KubeConfigPath -and -not (Test-Path -LiteralPath $KubeConfigPath -PathType Leaf)) {
    throw "Kubeconfig file was not found: $KubeConfigPath"
}

$policyName = 'symphony-namespace-deny'
$configMapName = 'symphony-namespace-deny-params'

$policy = Invoke-Kubectl -Arguments @(
    'get', 'validatingadmissionpolicy', $policyName, '--output', 'json'
) | ConvertFrom-Json

$scopePatch = @()
for ($index = 0; $index -lt $policy.spec.matchConstraints.resourceRules.Count; $index++) {
    if ($policy.spec.matchConstraints.resourceRules[$index].scope -ne 'Namespaced') {
        $scopePatch += @{
            op = 'replace'
            path = "/spec/matchConstraints/resourceRules/$index/scope"
            value = 'Namespaced'
        }
    }
}
if ($scopePatch.Count -gt 0) {
    Invoke-Kubectl -Arguments @(
        'patch', 'validatingadmissionpolicy', $policyName,
        '--type', 'json',
        '--patch', (ConvertTo-Json -InputObject @($scopePatch) -Compress)
    ) | Write-Host
}

$configMap = Invoke-Kubectl -Arguments @(
    'get', 'configmap', $configMapName,
    '--namespace', $WorkloadOrchestrationNamespace,
    '--output', 'json'
) | ConvertFrom-Json

$protectedNamespaces = @(
    ([string]$configMap.data.protectedNamespaces).Split(',') |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -ne 'cert-manager' }
)
$configMapPatch = @{
    data = @{
        protectedNamespaces = $protectedNamespaces -join ','
    }
} | ConvertTo-Json -Compress

Invoke-Kubectl -Arguments @(
    'patch', 'configmap', $configMapName,
    '--namespace', $WorkloadOrchestrationNamespace,
    '--type', 'merge',
    '--patch', $configMapPatch
) | Write-Host

$policy = Invoke-Kubectl -Arguments @(
    'get', 'validatingadmissionpolicy', $policyName, '--output', 'json'
) | ConvertFrom-Json
$configMap = Invoke-Kubectl -Arguments @(
    'get', 'configmap', $configMapName,
    '--namespace', $WorkloadOrchestrationNamespace,
    '--output', 'json'
) | ConvertFrom-Json

if (@($policy.spec.matchConstraints.resourceRules | Where-Object scope -ne 'Namespaced').Count) {
    throw 'The namespace policy still matches cluster-scoped resources.'
}
if ('cert-manager' -in @(
    ([string]$configMap.data.protectedNamespaces).Split(',') |
        ForEach-Object { $_.Trim() }
)) {
    throw 'cert-manager is still in protectedNamespaces.'
}

Write-Warning 'Applied the temporary Foundry Local admission-policy compatibility settings.'
