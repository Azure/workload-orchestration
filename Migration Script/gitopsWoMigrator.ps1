[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('flux', 'argo')]
    [string]$Platform,

    [Parameter(Mandatory)]
    [string]$Repo,

    [string]$App,

    [Parameter(Mandatory)]
    [string]$AppFile,

    [string]$OutputFile,

    [string]$SolutionVersion = '1.0.0',

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
trap {
    [Console]::Error.WriteLine("Migration failed: $($_.Exception.Message)")
    exit 1
}

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Assert-PathUnderRoot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $relative = [System.IO.Path]::GetRelativePath($Root, $Path)
    if (
        [System.IO.Path]::IsPathRooted($relative) -or
        $relative -eq '..' -or
        $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")
    ) {
        throw "Application file must remain inside the repository root: $Path"
    }
}

function Get-DirectApplicationName {
    param(
        [Parameter(Mandatory)][string]$Yaml,
        [Parameter(Mandatory)][string]$Kind
    )

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($document in [regex]::Split($Yaml, '(?m)^---[ \t]*\r?$')) {
        if ($document -notmatch "(?m)^kind:\s*['`"]?$([regex]::Escape($Kind))['`"]?\s*(?:#.*)?$") {
            continue
        }

        $lines = @($document -split "`r?`n")
        $metadataIndent = $null
        foreach ($line in $lines) {
            if ($null -eq $metadataIndent) {
                if ($line -match '^(\s*)metadata:\s*(?:#.*)?$') {
                    $metadataIndent = $Matches[1].Length
                }
                continue
            }

            if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') {
                continue
            }
            $indent = ([regex]::Match($line, '^\s*')).Value.Length
            if ($indent -le $metadataIndent) {
                break
            }
            if ($line -match '^\s*name:\s*[''"]?([^''"#\s]+)[''"]?\s*(?:#.*)?$') {
                $names.Add($Matches[1])
                break
            }
        }
    }

    if ($names.Count -ne 1) {
        throw "Expected one $Kind in the supplied application file; found $($names.Count). Use -App to select one application by metadata.name."
    }
    return $names[0]
}

function Get-PropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function Test-Property {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found."
    }
}

function ConvertFrom-YamlDocument {
    param([Parameter(Mandatory)][string]$Yaml)

    if ([string]::IsNullOrWhiteSpace($Yaml)) {
        return $null
    }

    Assert-Command 'kubectl'
    $indented = (($Yaml -split "`r?`n") | ForEach-Object { "  $_" }) -join "`n"
    $wrapper = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitops-wo-yaml-parser
payload:
$indented
"@
    $inputFile = [System.IO.Path]::GetTempFileName()
    $errorFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($inputFile, $wrapper, [System.Text.UTF8Encoding]::new($false))
        $json = & kubectl apply --dry-run=client --validate=false -f $inputFile -o json 2> $errorFile
        if ($LASTEXITCODE -ne 0) {
            $detail = [System.IO.File]::ReadAllText($errorFile).Trim()
            throw "Failed to parse YAML: $detail"
        }
        return (($json -join "`n") | ConvertFrom-Json -Depth 100).payload
    }
    finally {
        Remove-Item -LiteralPath $inputFile, $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-YamlDocuments {
    param([Parameter(Mandatory)][string]$Yaml)

    return @(
        foreach ($document in [regex]::Split($Yaml, '(?m)^---[ \t]*\r?$')) {
            if (-not [string]::IsNullOrWhiteSpace($document)) {
                $parsed = ConvertFrom-YamlDocument $document
                if ($null -ne $parsed) {
                    $parsed
                }
            }
        }
    )
}

function ConvertTo-Data {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($entry in $Value.GetEnumerator()) {
            $result[[string]$entry.Key] = ConvertTo-Data $entry.Value
        }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-Data $property.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return ,@($Value | ForEach-Object { ConvertTo-Data $_ })
    }
    return $Value
}

function Merge-Map {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Base,
        [Parameter(Mandatory)][object]$Overlay
    )

    $data = ConvertTo-Data $Overlay
    if ($data -isnot [System.Collections.IDictionary]) {
        throw 'Helm values must be a YAML object.'
    }
    foreach ($key in $data.Keys) {
        if (
            $Base.Contains($key) -and
            $Base[$key] -is [System.Collections.IDictionary] -and
            $data[$key] -is [System.Collections.IDictionary]
        ) {
            Merge-Map -Base $Base[$key] -Overlay $data[$key]
        }
        else {
            $Base[$key] = $data[$key]
        }
    }
}

function New-NormalizedApplication {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ReleaseName,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$ChartRepository,
        [Parameter(Mandatory)][string]$ChartName,
        [Parameter(Mandatory)][string]$ChartVersion,
        [AllowNull()][object]$Values
    )

    if ($ChartVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        throw "Chart version '$ChartVersion' must be an exact semantic version."
    }
    return [ordered]@{
        schemaVersion = '1.0'
        name = $Name
        release = [ordered]@{
            name = $ReleaseName
            namespace = $Namespace
        }
        chart = [ordered]@{
            repository = $ChartRepository
            name = $ChartName
            version = $ChartVersion
        }
        values = ConvertTo-Data $Values
    }
}

function Get-AdjacentYamlDocuments {
    param([Parameter(Mandatory)][string]$ApplicationPath)

    return @(
        foreach ($file in @(
            Get-ChildItem -LiteralPath (Split-Path -Parent $ApplicationPath) -File |
                Where-Object { $_.Extension -in @('.yaml', '.yml') } |
                Sort-Object Name
        )) {
            ConvertFrom-YamlDocuments ([System.IO.File]::ReadAllText($file.FullName))
        }
    )
}

function Get-FluxDirectApplication {
    param(
        [Parameter(Mandatory)][string]$ApplicationPath,
        [Parameter(Mandatory)][string]$ApplicationName
    )

    $applicationDocuments = @(ConvertFrom-YamlDocuments ([System.IO.File]::ReadAllText($ApplicationPath)))
    $releases = @(
        $applicationDocuments | Where-Object {
            (Get-PropertyValue $_ 'kind') -eq 'HelmRelease' -and
            (Get-PropertyValue (Get-PropertyValue $_ 'metadata') 'name') -eq $ApplicationName
        }
    )
    if ($releases.Count -ne 1) {
        throw "Expected one HelmRelease '$ApplicationName' in the supplied file; found $($releases.Count)."
    }

    $release = $releases[0]
    $metadata = Get-PropertyValue $release 'metadata'
    $spec = Get-PropertyValue $release 'spec'
    $unsupported = @(
        @('chartRef', 'kubeConfig', 'postRenderers', 'valuesFrom', 'serviceAccountName') |
            Where-Object { Test-Property $spec $_ }
    )
    if ((Get-PropertyValue $spec 'suspend' $false) -eq $true) {
        $unsupported += 'suspend'
    }
    if ($unsupported.Count -gt 0) {
        throw "Application '$ApplicationName' uses unsupported Flux configuration: $($unsupported -join ', ')."
    }

    $chartSpec = Get-PropertyValue (Get-PropertyValue $spec 'chart') 'spec'
    $sourceRef = Get-PropertyValue $chartSpec 'sourceRef'
    if ((Get-PropertyValue $sourceRef 'kind') -ne 'HelmRepository') {
        throw "Application '$ApplicationName' must use a HelmRepository source."
    }

    $releaseNamespace = [string](Get-PropertyValue $metadata 'namespace' 'default')
    $sourceNamespace = [string](Get-PropertyValue $sourceRef 'namespace' $releaseNamespace)
    $sourceName = [string](Get-PropertyValue $sourceRef 'name')
    $repositories = @(
        Get-AdjacentYamlDocuments $ApplicationPath | Where-Object {
            (Get-PropertyValue $_ 'kind') -eq 'HelmRepository' -and
            (Get-PropertyValue (Get-PropertyValue $_ 'metadata') 'name') -eq $sourceName -and
            (Get-PropertyValue (Get-PropertyValue $_ 'metadata') 'namespace' 'default') -eq $sourceNamespace
        }
    )
    if ($repositories.Count -ne 1) {
        throw "Expected one HelmRepository '$sourceNamespace/$sourceName' beside the supplied application; found $($repositories.Count)."
    }
    $repositorySpec = Get-PropertyValue $repositories[0] 'spec'
    if (Test-Property $repositorySpec 'secretRef') {
        throw "Application '$ApplicationName' uses private Helm repository authentication, which is not supported."
    }

    $targetNamespace = [string](Get-PropertyValue $spec 'targetNamespace' $releaseNamespace)
    $releaseName = [string](Get-PropertyValue $spec 'releaseName')
    if ([string]::IsNullOrWhiteSpace($releaseName)) {
        $releaseName = if (Test-Property $spec 'targetNamespace') {
            "$targetNamespace-$ApplicationName"
        }
        else {
            $ApplicationName
        }
    }
    return New-NormalizedApplication `
        -Name $ApplicationName `
        -ReleaseName $releaseName `
        -Namespace $targetNamespace `
        -ChartRepository ([string](Get-PropertyValue $repositorySpec 'url')) `
        -ChartName ([string](Get-PropertyValue $chartSpec 'chart')) `
        -ChartVersion ([string](Get-PropertyValue $chartSpec 'version')) `
        -Values (Get-PropertyValue $spec 'values' ([ordered]@{}))
}

function Get-ArgoDirectApplication {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ApplicationPath,
        [Parameter(Mandatory)][string]$ApplicationName
    )

    $documents = @(ConvertFrom-YamlDocuments ([System.IO.File]::ReadAllText($ApplicationPath)))
    $applications = @(
        $documents | Where-Object {
            (Get-PropertyValue $_ 'kind') -eq 'Application' -and
            (Get-PropertyValue (Get-PropertyValue $_ 'metadata') 'name') -eq $ApplicationName
        }
    )
    if ($applications.Count -ne 1) {
        throw "Expected one Argo Application '$ApplicationName' in the supplied file; found $($applications.Count)."
    }

    $spec = Get-PropertyValue $applications[0] 'spec'
    $destination = Get-PropertyValue $spec 'destination'
    $server = [string](Get-PropertyValue $destination 'server')
    if ($server -ne 'https://kubernetes.default.svc') {
        throw "Application '$ApplicationName' uses unsupported remote destination '$server'."
    }
    $sources = if (Test-Property $spec 'sources') {
        @(Get-PropertyValue $spec 'sources')
    }
    elseif (Test-Property $spec 'source') {
        @(Get-PropertyValue $spec 'source')
    }
    else {
        @()
    }
    if (@($sources | Where-Object { Test-Property $_ 'path' }).Count -gt 0) {
        throw "Application '$ApplicationName' contains unsupported Git path sources."
    }
    $chartSources = @(
        $sources | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $_ 'chart'))
        }
    )
    if ($chartSources.Count -ne 1) {
        throw "Application '$ApplicationName' must define exactly one external Helm chart source."
    }

    $chartSource = $chartSources[0]
    $helm = Get-PropertyValue $chartSource 'helm' ([ordered]@{})
    $unsupported = @(
        @(
            'parameters', 'fileParameters', 'values', 'valuesObject', 'passCredentials',
            'skipCrds', 'skipSchemaValidation'
        ) | Where-Object { Test-Property $helm $_ }
    )
    if ($unsupported.Count -gt 0) {
        throw "Application '$ApplicationName' uses unsupported Argo Helm configuration: $($unsupported -join ', ')."
    }
    $releaseName = [string](Get-PropertyValue $helm 'releaseName')
    if ([string]::IsNullOrWhiteSpace($releaseName)) {
        throw "Application '$ApplicationName' must set helm.releaseName."
    }

    $valueFiles = @(Get-PropertyValue $helm 'valueFiles' @())
    $valuesSources = @($sources | Where-Object { (Get-PropertyValue $_ 'ref') -eq 'values' })
    if ($valueFiles.Count -gt 0 -and $valuesSources.Count -ne 1) {
        throw "Application '$ApplicationName' must define exactly one source with ref 'values'."
    }
    $values = [ordered]@{}
    foreach ($valueFile in $valueFiles) {
        $valueFile = [string]$valueFile
        if (-not $valueFile.StartsWith('$values/')) {
            throw "Application '$ApplicationName' uses a non-local Helm values file: $valueFile"
        }
        $valuePath = Get-FullPath (Join-Path $RepositoryRoot $valueFile.Substring('$values/'.Length))
        Assert-PathUnderRoot -Root $RepositoryRoot -Path $valuePath
        if (-not (Test-Path -LiteralPath $valuePath -PathType Leaf)) {
            throw "Application '$ApplicationName' Helm values file was not found: $valueFile"
        }
        $content = [System.IO.File]::ReadAllText($valuePath)
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            Merge-Map -Base $values -Overlay (ConvertFrom-YamlDocument $content)
        }
    }

    return New-NormalizedApplication `
        -Name $ApplicationName `
        -ReleaseName $releaseName `
        -Namespace ([string](Get-PropertyValue $destination 'namespace')) `
        -ChartRepository ([string](Get-PropertyValue $chartSource 'repoURL')) `
        -ChartName ([string](Get-PropertyValue $chartSource 'chart')) `
        -ChartVersion ([string](Get-PropertyValue $chartSource 'targetRevision')) `
        -Values $values
}

function ConvertTo-BicepName {
    param([Parameter(Mandatory)][string]$Value)

    $parts = @($Value -split '[^A-Za-z0-9]+' | Where-Object { $_ })
    $name = ($parts | ForEach-Object {
        if ($_.Length -eq 1) { $_.ToUpperInvariant() }
        else { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }
    }) -join ''
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Application '$Value' cannot be converted to a WO resource name."
    }
    if ($name[0] -match '[0-9]') {
        $name = "App$name"
    }
    return $name
}

function ConvertTo-YamlScalar {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if (
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]
    ) {
        return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return ($Value | ConvertTo-Json -Compress)
}

function ConvertTo-YamlKey {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -match '^[A-Za-z0-9_.-]+$') {
        return $Value
    }
    return ConvertTo-YamlScalar $Value
}

function ConvertTo-YamlLines {
    param(
        [AllowNull()][object]$Value,
        [int]$Indent = 0
    )

    $prefix = ' ' * $Indent
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        if ($Value -is [System.Collections.IDictionary]) {
            [object[]]$properties = @($Value.GetEnumerator() | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value }
            })
        }
        else {
            [object[]]$properties = @($Value.PSObject.Properties | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Value = $_.Value }
            })
        }
        if ($properties.Count -eq 0) {
            return @("${prefix}{}")
        }
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($property in $properties) {
            $child = $property.Value
            if (
                $child -is [System.Collections.IDictionary] -or
                $child -is [pscustomobject] -or
                ($child -is [System.Collections.IEnumerable] -and $child -isnot [string])
            ) {
                $lines.Add("${prefix}$(ConvertTo-YamlKey $property.Name):")
                foreach ($line in @(ConvertTo-YamlLines -Value $child -Indent ($Indent + 2))) {
                    $lines.Add($line)
                }
            }
            else {
                $lines.Add("${prefix}$(ConvertTo-YamlKey $property.Name): $(ConvertTo-YamlScalar $child)")
            }
        }
        return $lines.ToArray()
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            return @("${prefix}[]")
        }
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $items) {
            if (
                $item -is [System.Collections.IDictionary] -or
                $item -is [pscustomobject] -or
                ($item -is [System.Collections.IEnumerable] -and $item -isnot [string])
            ) {
                $lines.Add("${prefix}-")
                foreach ($line in @(ConvertTo-YamlLines -Value $item -Indent ($Indent + 2))) {
                    $lines.Add($line)
                }
            }
            else {
                $lines.Add("${prefix}- $(ConvertTo-YamlScalar $item)")
            }
        }
        return $lines.ToArray()
    }
    return @("${prefix}$(ConvertTo-YamlScalar $Value)")
}

function Escape-BicepString {
    param([Parameter(Mandatory)][string]$Value)
    return $Value.Replace("'", "''")
}

function Get-DisplayPath {
    param([Parameter(Mandatory)][string]$Path)

    $currentDirectory = [System.IO.Path]::GetFullPath((Get-Location).Path)
    $relative = [System.IO.Path]::GetRelativePath($currentDirectory, $Path)
    if ([System.IO.Path]::IsPathRooted($relative)) {
        return $Path
    }
    if ($relative.StartsWith('.')) {
        return $relative
    }
    return ".\$relative"
}

function Resolve-Chart {
    param([Parameter(Mandatory)][object]$Application)

    $chart = Get-PropertyValue $Application 'chart'
    $repository = [string](Get-PropertyValue $chart 'repository')
    $name = [string](Get-PropertyValue $chart 'name')
    if ($repository.StartsWith('oci://')) {
        $trimmed = $repository.TrimEnd('/')
        if ($trimmed.EndsWith("/$name")) {
            $coordinate = $trimmed
        }
        else {
            $coordinate = "$trimmed/$name"
        }
        return [ordered]@{
            repository = $coordinate
            mapped = $true
            warning = $null
        }
    }
    $sourceCoordinate = "$($repository.TrimEnd('/'))/$name"
    return [ordered]@{
        repository = $sourceCoordinate
        mapped = $false
        warning = "Chart '$sourceCoordinate' is not an OCI coordinate required by Workload Orchestration. The source chart reference is retained as a draft value; replace it with the correct OCI chart coordinate before deployment."
    }
}

$repoRoot = Get-FullPath $Repo
$appPath = Get-FullPath (Join-Path $repoRoot $AppFile)
Assert-PathUnderRoot -Root $repoRoot -Path $appPath
if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
    throw "Application file not found: $appPath"
}
if ($SolutionVersion -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "Invalid solution version '$SolutionVersion'."
}

$appFileContent = [System.IO.File]::ReadAllText($appPath)
$expectedKind = if ($Platform -eq 'flux') { 'HelmRelease' } else { 'Application' }
$effectiveApp = $App
if ([string]::IsNullOrWhiteSpace($effectiveApp)) {
    $effectiveApp = Get-DirectApplicationName -Yaml $appFileContent -Kind $expectedKind
}

try {
    $application = if ($Platform -eq 'flux') {
        Get-FluxDirectApplication -ApplicationPath $appPath -ApplicationName $effectiveApp
    }
    else {
        Get-ArgoDirectApplication `
            -RepositoryRoot $repoRoot `
            -ApplicationPath $appPath `
            -ApplicationName $effectiveApp
    }
}
catch {
    $reason = $_.Exception.Message
    $prefix = "^Application '$([regex]::Escape($effectiveApp))'\s*"
    $reason = [regex]::Replace($reason, $prefix, '').Trim()
    throw "Application '$effectiveApp' could not be migrated: $reason"
}

$chart = Get-PropertyValue $application 'chart'
$values = Get-PropertyValue $application 'values' ([ordered]@{})
$chartResolution = Resolve-Chart -Application $application

$woValues = [ordered]@{}
if ($values -is [System.Collections.IDictionary]) {
    foreach ($entry in $values.GetEnumerator()) {
        $woValues[[string]$entry.Key] = $entry.Value
    }
}
else {
    foreach ($property in @($values.PSObject.Properties)) {
        $woValues[$property.Name] = $property.Value
    }
}
$configuration = ConvertTo-YamlLines -Value ([ordered]@{ configs = $woValues }) -Indent 6
$configurationYaml = $configuration -join "`n"
$solutionName = ConvertTo-BicepName $effectiveApp
$safeSolutionName = Escape-BicepString $solutionName
$safeVersion = Escape-BicepString $SolutionVersion
$safeRepository = Escape-BicepString ([string]$chartResolution.repository)
$safeChartVersion = Escape-BicepString ([string](Get-PropertyValue $chart 'version'))

$comments = [System.Collections.Generic.List[string]]::new()
$comments.Add('// Generated by gitopsWoMigrator.ps1.')
$comments.Add("// Source: $Platform $($AppFile.Replace('\', '/'))")
$comments.Add('// Review before deployment.')
if (-not $chartResolution.mapped) {
    $comments.Add('//')
    $comments.Add('// MIGRATION INCOMPLETE: Manual action is required before deployment.')
    $comments.Add("// Reason: $($chartResolution.warning)")
}

$bicep = @"
$($comments -join "`n")

targetScope = 'resourceGroup'

param location string = resourceGroup().location

resource solutionTemplate 'Microsoft.Edge/solutionTemplates@2026-03-01' = {
  name: '$safeSolutionName'
  location: location
  properties: {
    description: '$safeSolutionName migrated to Workload Orchestration'
    capabilities: ['web']
  }
}

resource solutionTemplateVersion 'Microsoft.Edge/solutionTemplates/versions@2026-03-01' = {
  parent: solutionTemplate
  name: '$safeVersion'
  properties: {
    configurations: `$$'''
$configurationYaml
    '''
    specification: {
      components: [
        {
          name: 'helmcomponent'
          type: 'helm.v3'
          properties: {
            chart: {
              repo: '$safeRepository'
              version: '$safeChartVersion'
              wait: true
              timeout: '5m'
            }
          }
        }
      ]
    }
  }
}

output solutionTemplateId string = solutionTemplate.id
output solutionTemplateVersionId string = solutionTemplateVersion.id
"@

$destination = if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    Join-Path (Split-Path -Parent $appPath) "$effectiveApp.solutionTemplate.bicep"
}
else {
    Get-FullPath $OutputFile
}
if ((Test-Path -LiteralPath $destination) -and -not $Force) {
    throw "Output file already exists: $destination. Use -Force to replace it."
}
[System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
[System.IO.File]::WriteAllText($destination, $bicep, [System.Text.UTF8Encoding]::new($false))
if (-not $chartResolution.mapped) {
    Write-Warning "Migration incomplete. Review the generated Bicep before deployment."
}
Write-Host "Generated standalone Solution Template Bicep: $(Get-DisplayPath $destination)"
