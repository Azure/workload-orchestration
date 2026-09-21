[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$ClusterName,
    [string]$KubeConfigPath,
    [string]$KubeContext,
    [int]$ProxyPort = 47011
)

$ErrorActionPreference = 'Stop'
$proxyProcess = $null
$proxyChildProcessIds = @()

if (-not $KubeContext) {
    $KubeContext = $ClusterName
}

function Invoke-Deployment {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TemplateFile,
        [Parameter(Mandatory)][string]$ParameterFile
    )

    & az deployment group create `
        --name $Name `
        --subscription $SubscriptionId `
        --resource-group $ResourceGroupName `
        --template-file $TemplateFile `
        --parameters $ParameterFile `
        --query properties.provisioningState `
        --output tsv

    if ($LASTEXITCODE -ne 0) {
        throw "Deployment '$Name' failed."
    }
}

Push-Location $PSScriptRoot
try {
    Invoke-Deployment `
        -Name 'foundry-local-prerequisites' `
        -TemplateFile '.\prerequisites.bicep' `
        -ParameterFile '.\prerequisites.params.bicepparam'

    if (Get-NetTCPConnection -State Listen -LocalPort 47010, $ProxyPort -ErrorAction SilentlyContinue) {
        throw "Arc proxy port 47010 or $ProxyPort is already in use."
    }

    $proxyArguments = @(
        'connectedk8s', 'proxy',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $ClusterName,
        '--port', $ProxyPort,
        '--kube-context', $KubeContext
    )
    if ($KubeConfigPath) {
        $proxyArguments += @('--file', $KubeConfigPath)
    }

    $proxyProcess = Start-Process `
        -FilePath 'az' `
        -ArgumentList $proxyArguments `
        -PassThru `
        -NoNewWindow

    $proxyDeadline = [DateTime]::UtcNow.AddMinutes(2)
    $kubectlConnection = @('--context', $KubeContext)
    if ($KubeConfigPath) {
        $kubectlConnection = @('--kubeconfig', $KubeConfigPath) + $kubectlConnection
    }
    while ($true) {
        & kubectl @kubectlConnection get nodes --request-timeout=5s --output name 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) {
            break
        }
        if ([DateTime]::UtcNow -ge $proxyDeadline) {
            throw "Timed out waiting for Kubernetes context '$KubeContext'."
        }
        Start-Sleep -Seconds 2
    }

    $proxyChildProcessIds = @(
        Get-NetTCPConnection -State Listen -LocalPort 47010, $ProxyPort |
            Select-Object -ExpandProperty OwningProcess -Unique
    )

    $policyParameters = @{}
    if ($KubeConfigPath) {
        $policyParameters.KubeConfigPath = $KubeConfigPath
    }
    if ($KubeContext) {
        $policyParameters.KubeContext = $KubeContext
    }
    & '.\Apply-FoundryPolicyCompatibility.ps1' @policyParameters

    Invoke-Deployment `
        -Name 'foundry-local-application' `
        -TemplateFile '.\main.bicep' `
        -ParameterFile '.\main.params.bicepparam'
}
finally {
    foreach ($processId in $proxyChildProcessIds) {
        if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
            Stop-Process -Id $processId
        }
    }
    if ($proxyProcess -and -not $proxyProcess.HasExited) {
        Stop-Process -Id $proxyProcess.Id
        $proxyProcess.WaitForExit()
    }
    Pop-Location
}
