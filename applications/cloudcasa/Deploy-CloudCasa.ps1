[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$PrerequisiteParameterFile = '.\prerequisites.params.bicepparam',
    [string]$ApplicationParameterFile = '.\main.params.bicepparam',
    [string]$KubeConfigPath,
    [string]$KubeContext,
    [string]$LicensePath,
    [switch]$UseExistingTarget,
    [switch]$PrerequisitesOnly,
    [switch]$SkipKubernetesBootstrap,
    [switch]$EnableLocalAuthentication,
    [string]$LocalAdminEmail,
    [switch]$CreateSelfSignedIssuer
)

$ErrorActionPreference = 'Stop'

if (-not $SkipKubernetesBootstrap -and -not $PrerequisitesOnly) {
    if ([string]::IsNullOrWhiteSpace($KubeConfigPath)) {
        throw 'KubeConfigPath is required unless SkipKubernetesBootstrap is specified.'
    }
    if ([string]::IsNullOrWhiteSpace($KubeContext)) {
        throw 'KubeContext is required unless SkipKubernetesBootstrap is specified.'
    }
    if ([string]::IsNullOrWhiteSpace($LicensePath)) {
        throw 'LicensePath is required unless SkipKubernetesBootstrap is specified.'
    }
}
if ($EnableLocalAuthentication -and [string]::IsNullOrWhiteSpace($LocalAdminEmail)) {
    throw 'LocalAdminEmail is required when local authentication is enabled.'
}
if ($UseExistingTarget -and $PrerequisitesOnly) {
    throw 'UseExistingTarget and PrerequisitesOnly cannot be used together.'
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

function Get-ApplicationParameters {
    param(
        [Parameter(Mandatory)][string]$ParameterFile
    )

    $compiledOutput = & az bicep build-params `
        --file $ParameterFile `
        --stdout `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile application parameter file '$ParameterFile'."
    }

    $compiled = $compiledOutput | ConvertFrom-Json
    $deploymentParameters = $compiled.parametersJson | ConvertFrom-Json
    return $deploymentParameters.parameters
}

function Get-ParameterValue {
    param(
        [Parameter(Mandatory)]$Parameters,
        [Parameter(Mandatory)][string]$Name
    )

    $parameter = $Parameters.PSObject.Properties[$Name]
    if ($null -eq $parameter) {
        throw "Application parameter '$Name' is missing."
    }

    return $parameter.Value.value
}

function Initialize-SolutionTemplateVersion {
    param(
        [Parameter(Mandatory)]$Parameters
    )

    $templateName = Get-ParameterValue -Parameters $Parameters -Name 'solutionTemplateName'
    $templateVersion = Get-ParameterValue -Parameters $Parameters -Name 'solutionTemplateVersion'
    $localAuthenticationEnabled = Get-ParameterValue -Parameters $Parameters -Name 'localAuthenticationEnabled'

    if (-not $localAuthenticationEnabled) {
        throw @"
CloudCasa requires at least one Dex authentication connector. Local authentication is disabled,
and this deployment parameter model does not configure an external identity provider. Enable
localAuthenticationEnabled and create the local-auth Secret, or add an external OIDC/LDAP/Microsoft
connector using a new immutable solution-template version.
"@
    }

    $null = & az workload-orchestration solution-template version show `
        --subscription $SubscriptionId `
        --resource-group $ResourceGroupName `
        --solution-template-name $templateName `
        --version $templateVersion `
        --only-show-errors `
        --output none 2>$null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "CloudCasa solution-template version '$templateVersion' already exists."
        return
    }

    $location = Get-ParameterValue -Parameters $Parameters -Name 'location'
    $capabilityNames = @(Get-ParameterValue -Parameters $Parameters -Name 'capabilityNames')
    $chartRepository = Get-ParameterValue -Parameters $Parameters -Name 'chartRepository'
    $chartVersion = Get-ParameterValue -Parameters $Parameters -Name 'chartVersion'
    $releaseName = Get-ParameterValue -Parameters $Parameters -Name 'releaseName'
    $chartTimeout = Get-ParameterValue -Parameters $Parameters -Name 'chartTimeout'
    $imagePullSecretName = Get-ParameterValue -Parameters $Parameters -Name 'imagePullSecretName'
    $storageClassName = Get-ParameterValue -Parameters $Parameters -Name 'storageClassName'
    $cloudCasaFqdn = Get-ParameterValue -Parameters $Parameters -Name 'cloudCasaFqdn'
    $serviceType = Get-ParameterValue -Parameters $Parameters -Name 'serviceType'
    $loadBalancerIdleTimeoutMinutes = Get-ParameterValue -Parameters $Parameters -Name 'loadBalancerIdleTimeoutMinutes'
    $loadBalancerDnsLabelName = Get-ParameterValue -Parameters $Parameters -Name 'loadBalancerDnsLabelName'
    $certificateIssuerName = Get-ParameterValue -Parameters $Parameters -Name 'certificateIssuerName'
    $certificateIssuerType = Get-ParameterValue -Parameters $Parameters -Name 'certificateIssuerType'
    $mongoNamespace = Get-ParameterValue -Parameters $Parameters -Name 'mongoNamespace'
    $mongoStorageSize = Get-ParameterValue -Parameters $Parameters -Name 'mongoStorageSize'
    $logsStorageSize = Get-ParameterValue -Parameters $Parameters -Name 'logsStorageSize'
    $allowedUsers = @(Get-ParameterValue -Parameters $Parameters -Name 'allowedUsers')
    $allowedUserGroups = @(Get-ParameterValue -Parameters $Parameters -Name 'allowedUserGroups')
    $siteAdminUsers = @(Get-ParameterValue -Parameters $Parameters -Name 'siteAdminUsers')
    $siteAdminUserGroups = @(Get-ParameterValue -Parameters $Parameters -Name 'siteAdminUserGroups')
    $localAuthenticationSecretName = Get-ParameterValue -Parameters $Parameters -Name 'localAuthenticationSecretName'

    $serviceAnnotations = [ordered]@{
        'service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout' = [string]$loadBalancerIdleTimeoutMinutes
    }
    if (-not [string]::IsNullOrWhiteSpace($loadBalancerDnsLabelName)) {
        $serviceAnnotations['service.beta.kubernetes.io/azure-dns-label-name'] = $loadBalancerDnsLabelName
    }

    $auth = [ordered]@{
        allowedUsers = $allowedUsers -join ','
        allowedUserGroups = $allowedUserGroups -join ','
        siteadminUsers = $siteAdminUsers -join ','
        siteadminUserGroups = $siteAdminUserGroups -join ','
    }
    if ($localAuthenticationEnabled) {
        $auth['local'] = [ordered]@{
            enabled = $true
            existingSecret = $localAuthenticationSecretName
            users = @()
        }
    }

    $configuration = [ordered]@{
        configs = [ordered]@{
            imagePullSecretName = $imagePullSecretName
            storageClassName = $storageClassName
            license = [ordered]@{
                createSecret = $false
            }
            licenseKey = ''
            remoteLicenseServerAPIKey = ''
            serviceType = $serviceType
            serviceAnnotations = $serviceAnnotations
            localAuthenticationEnabled = $localAuthenticationEnabled
            localAuthenticationSecretName = $localAuthenticationSecretName
            amdsEnvoyUrl = $cloudCasaFqdn
            amdsEnvoyPort = 443
            amdsEnvoyPortName = 'grpc-port'
            certificates = [ordered]@{
                createTlsSecrets = $true
                issuerName = $certificateIssuerName
                issuerType = $certificateIssuerType
                issuerGroup = 'cert-manager.io'
            }
            mongo = [ordered]@{
                createStatefulset = $true
                statefulsetNamespace = $mongoNamespace
                createNamespace = $false
                pv = [ordered]@{
                    size = $mongoStorageSize
                }
            }
            logs = [ordered]@{
                pv = [ordered]@{
                    size = $logsStorageSize
                }
            }
            auth = $auth
        }
    }

    $specification = [ordered]@{
        components = @(
            [ordered]@{
                name = 'cloudcasa-server'
                type = 'helm.v3'
                properties = [ordered]@{
                    releaseName = $releaseName
                    chart = [ordered]@{
                        repo = $chartRepository
                        version = $chartVersion
                        wait = $true
                        timeout = $chartTimeout
                    }
                }
            }
        )
    }

    $temporaryDirectory = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        "cloudcasa-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $temporaryDirectory

    try {
        $configurationFile = Join-Path $temporaryDirectory 'configuration.json'
        $specificationFile = Join-Path $temporaryDirectory 'specification.json'

        $configuration | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configurationFile -Encoding utf8
        $specification | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $specificationFile -Encoding utf8

        $createArguments = @(
            'workload-orchestration'
            'solution-template'
            'create'
            '--subscription'
            $SubscriptionId
            '--resource-group'
            $ResourceGroupName
            '--location'
            $location
            '--name'
            $templateName
            '--version'
            $templateVersion
            '--description'
            'CloudCasa self-hosted server'
            '--capabilities'
        ) + $capabilityNames + @(
            '--configuration-template-file'
            $configurationFile
            '--specification'
            "@$specificationFile"
            '--state'
            'active'
            '--only-show-errors'
            '--output'
            'none'
        )

        & az @createArguments

        if ($LASTEXITCODE -ne 0) {
            throw "CloudCasa solution-template version '$templateVersion' creation failed."
        }

        $provisioningState = & az workload-orchestration solution-template version show `
            --subscription $SubscriptionId `
            --resource-group $ResourceGroupName `
            --solution-template-name $templateName `
            --version $templateVersion `
            --query properties.provisioningState `
            --output tsv `
            --only-show-errors

        if ($LASTEXITCODE -ne 0 -or $provisioningState -ne 'Succeeded') {
            throw "CloudCasa solution-template version '$templateVersion' is not ready. Provisioning state: '$provisioningState'."
        }

        Write-Host "CloudCasa solution-template version '$templateVersion' is ready."
    }
    finally {
        if (Test-Path -LiteralPath $temporaryDirectory) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    }
}

Push-Location $PSScriptRoot
try {
    foreach ($parameterFile in @(
        $PrerequisiteParameterFile,
        $ApplicationParameterFile
    )) {
        if (
            -not [string]::IsNullOrWhiteSpace($parameterFile) -and
            (
                Test-Path `
                    -LiteralPath $parameterFile `
                    -PathType Leaf
            )
        ) {
            $parameterContent = Get-Content -LiteralPath $parameterFile -Raw
            if ($parameterContent -match '<replace-[^>]+>') {
                throw "Parameter file '$parameterFile' contains an unreplaced placeholder."
            }
        }
    }

    if (-not $UseExistingTarget) {
        Invoke-Deployment `
            -Name 'cloudcasa-prerequisites' `
            -TemplateFile '.\prerequisites.bicep' `
            -ParameterFile $PrerequisiteParameterFile
    }

    if ($PrerequisitesOnly) {
        Write-Host 'CloudCasa prerequisite deployment completed. Application deployment was skipped.'
        return
    }

    if (-not $SkipKubernetesBootstrap) {
        $bootstrapParameters = @{
            KubeConfigPath = $KubeConfigPath
            KubeContext = $KubeContext
            LicensePath = $LicensePath
        }
        if ($EnableLocalAuthentication) {
            $bootstrapParameters.EnableLocalAuthentication = $true
            $bootstrapParameters.LocalAdminEmail = $LocalAdminEmail
        }
        if ($CreateSelfSignedIssuer) {
            $bootstrapParameters.CreateSelfSignedIssuer = $true
        }

        & '.\Initialize-CloudCasaPrerequisites.ps1' @bootstrapParameters
    }

    $applicationParameters = Get-ApplicationParameters `
        -ParameterFile $ApplicationParameterFile
    Initialize-SolutionTemplateVersion `
        -Parameters $applicationParameters

    Invoke-Deployment `
        -Name 'cloudcasa-application' `
        -TemplateFile '.\main.bicep' `
        -ParameterFile $ApplicationParameterFile
}
finally {
    Pop-Location
}
