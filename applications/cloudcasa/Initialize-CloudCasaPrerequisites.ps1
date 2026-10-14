[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$KubeConfigPath,
    [Parameter(Mandatory)][string]$KubeContext,
    [Parameter(Mandatory)][string]$LicensePath,
    [string]$RegistryServer = 'cloudcasa.azurecr.io',
    [string]$ServerNamespace = 'cloudcasa-server',
    [string]$MongoNamespace = 'cloudcasa-mongo',
    [string]$ImagePullSecretName = 'myregistrykey',
    [string]$LicenseSecretName = 'cc-user-license-key',
    [switch]$EnableLocalAuthentication,
    [string]$LocalAuthenticationSecretName = 'cloudcasa-local-auth',
    [string]$LocalAdminUsername = 'cloudcasa-admin',
    [string]$LocalAdminEmail,
    [switch]$CreateSelfSignedIssuer,
    [string]$IssuerName = 'cloudcasa-selfsigned-issuer'
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$registryPassword = $null
$localAdminPassword = $null

function Invoke-Kubectl {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & kubectl --kubeconfig $KubeConfigPath --context $KubeContext @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed."
    }
}

function Apply-Manifest {
    param([Parameter(Mandatory)][hashtable]$Manifest)

    $applyArguments = @(
        '--kubeconfig', $KubeConfigPath,
        '--context', $KubeContext,
        'apply',
        '-f', '-'
    )
    if ($Manifest.kind -eq 'Secret') {
        $applyArguments += @(
            '--server-side',
            '--field-manager', 'cloudcasa-bootstrap'
        )
    }

    $Manifest |
        ConvertTo-Json -Depth 20 -Compress |
        kubectl @applyArguments

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply $($Manifest.kind) $($Manifest.metadata.name)."
    }
}

function ConvertFrom-SecureValue {
    param([Parameter(Mandatory)][Security.SecureString]$SecureValue)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl is required.'
}
if (-not (Test-Path -LiteralPath $KubeConfigPath -PathType Leaf)) {
    throw "Kubeconfig file was not found: $KubeConfigPath"
}
if (-not (Test-Path -LiteralPath $LicensePath -PathType Leaf)) {
    throw "CloudCasa license file was not found: $LicensePath"
}
if ($EnableLocalAuthentication -and [string]::IsNullOrWhiteSpace($LocalAdminEmail)) {
    throw 'LocalAdminEmail is required when local authentication is enabled.'
}

Invoke-Kubectl -Arguments @('get', 'nodes', '--request-timeout=10s', '--output', 'name')

try {
    $registryUsername = Read-Host 'CloudCasa registry username'
    $registryPasswordSecure = Read-Host 'CloudCasa registry password' -AsSecureString
    $registryPassword = ConvertFrom-SecureValue -SecureValue $registryPasswordSecure

    if ([string]::IsNullOrWhiteSpace($registryUsername)) {
        throw 'The CloudCasa registry username is empty.'
    }
    if ([string]::IsNullOrWhiteSpace($registryPassword)) {
        throw 'The CloudCasa registry password is empty.'
    }

    $basicAuthorization = [Convert]::ToBase64String(
        $utf8.GetBytes("$registryUsername`:$registryPassword")
    )
    $scope = [Uri]::EscapeDataString(
        'repository:catalogicsoftware/amds-dex-selfhosted:pull'
    )
    $tokenUri = "https://$RegistryServer/oauth2/token?service=$RegistryServer&scope=$scope"
    try {
        $tokenResponse = Invoke-RestMethod `
            -Uri $tokenUri `
            -Headers @{ Authorization = "Basic $basicAuthorization" } `
            -Method Get `
            -ErrorAction Stop
    }
    catch {
        throw @"
CloudCasa vendor-registry authentication failed for '$registryUsername' at '$RegistryServer'.
The credentials must be the CloudCasa ACR or Helm-repository credentials supplied by CloudCasa/Catalogic.
This is separate from the WO identity AcrPull assignment on the customer registry.
No Kubernetes namespaces or Secrets were created.
"@
    }

    $tokenReturned =
        -not [string]::IsNullOrWhiteSpace($tokenResponse.access_token) -or
        -not [string]::IsNullOrWhiteSpace($tokenResponse.token)
    if (-not $tokenReturned) {
        throw 'CloudCasa registry authentication did not return a pull token.'
    }

    $registryAuth = [Convert]::ToBase64String(
        $utf8.GetBytes("$registryUsername`:$registryPassword")
    )
    $auths = [ordered]@{}
    $auths[$RegistryServer] = [ordered]@{
        username = $registryUsername
        password = $registryPassword
        auth = $registryAuth
    }
    $auths["https://$RegistryServer"] = [ordered]@{
        username = $registryUsername
        password = $registryPassword
        auth = $registryAuth
    }
    $dockerConfig = [ordered]@{ auths = $auths } |
        ConvertTo-Json -Depth 8 -Compress
    $dockerConfigBase64 = [Convert]::ToBase64String(
        $utf8.GetBytes($dockerConfig)
    )

    foreach ($namespace in @($ServerNamespace, $MongoNamespace)) {
        Apply-Manifest -Manifest @{
            apiVersion = 'v1'
            kind = 'Namespace'
            metadata = @{ name = $namespace }
        }

        $secretData = @{}
        $secretData['.dockerconfigjson'] = $dockerConfigBase64
        Apply-Manifest -Manifest @{
            apiVersion = 'v1'
            kind = 'Secret'
            metadata = @{
                name = $ImagePullSecretName
                namespace = $namespace
            }
            type = 'kubernetes.io/dockerconfigjson'
            data = $secretData
        }
    }

    Apply-Manifest -Manifest @{
        apiVersion = 'v1'
        kind = 'Secret'
        metadata = @{
            name = $LicenseSecretName
            namespace = $ServerNamespace
        }
        type = 'Opaque'
        data = @{
            userLicense = [Convert]::ToBase64String(
                [IO.File]::ReadAllBytes($LicensePath)
            )
        }
    }

    if ($EnableLocalAuthentication) {
        $localAdminPasswordSecure = Read-Host `
            'CloudCasa local administrator password' `
            -AsSecureString
        $localAdminPassword = ConvertFrom-SecureValue `
            -SecureValue $localAdminPasswordSecure
        if ([string]::IsNullOrWhiteSpace($localAdminPassword)) {
            throw 'The local administrator password is empty.'
        }

        Apply-Manifest -Manifest @{
            apiVersion = 'v1'
            kind = 'Secret'
            metadata = @{
                name = $LocalAuthenticationSecretName
                namespace = $ServerNamespace
            }
            type = 'Opaque'
            data = @{
                username = [Convert]::ToBase64String(
                    $utf8.GetBytes($LocalAdminUsername)
                )
                email = [Convert]::ToBase64String(
                    $utf8.GetBytes($LocalAdminEmail)
                )
                password = [Convert]::ToBase64String(
                    $utf8.GetBytes($localAdminPassword)
                )
            }
        }
    }

    if ($CreateSelfSignedIssuer) {
        Apply-Manifest -Manifest @{
            apiVersion = 'cert-manager.io/v1'
            kind = 'Issuer'
            metadata = @{
                name = $IssuerName
                namespace = $ServerNamespace
            }
            spec = @{ selfSigned = @{} }
        }
    }

    foreach ($namespace in @($ServerNamespace, $MongoNamespace)) {
        Invoke-Kubectl -Arguments @(
            'get', 'secret', $ImagePullSecretName,
            '--namespace', $namespace,
            '--output',
            'custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,TYPE:.type'
        )
    }
    Invoke-Kubectl -Arguments @(
        'get', 'secret', $LicenseSecretName,
        '--namespace', $ServerNamespace,
        '--output',
        'custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,TYPE:.type'
    )

    Write-Host 'CloudCasa Kubernetes prerequisites are ready.'
}
finally {
    $registryUsername = $null
    $registryPassword = $null
    $registryPasswordSecure = $null
    $localAdminPassword = $null
    $localAdminPasswordSecure = $null
    $basicAuthorization = $null
    $tokenResponse = $null
    $registryAuth = $null
    $auths = $null
    $dockerConfig = $null
    $dockerConfigBase64 = $null
    [GC]::Collect()
}
