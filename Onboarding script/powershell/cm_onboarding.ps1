param (
    [string]$onboardingFile,
    [bool]$skipResourceGroupCreation = $False
)

class RBAC {
    [string]$role
    [string]$userGroup

    RBAC([string]$role, [string]$userGroup) {
        $this.role = $role
        $this.userGroup = $userGroup
    }
}

class Target {
    [string]$name
    [string]$displayName
    [array]$capabilities
    [string]$hierarchyLevel
    [RBAC]$rbac
    [string]$namespace
    [string]$customLocationFile
    [string]$targetSpecFile

    Target([string]$name, [string]$displayName, [array]$capabilities = $null, [string]$hierarchyLevel = $null, [RBAC]$rbac = $null, [string]$namespace = $null, [string]$customLocationFile = $null, [string]$targetSpecFile = $null) {
        $this.name = $name
        $this.displayName = $displayName
        $this.capabilities = $capabilities
        $this.hierarchyLevel = $hierarchyLevel
        $this.rbac = $rbac
        $this.namespace = $namespace
        $this.customLocationFile = $customLocationFile
        $this.targetSpecFile = $targetSpecFile
    }
}

class DeploymentTarget {
    [array]$targets
    [array]$capabilities
    [string]$hierarchyLevel
    [RBAC]$rbac
    [string]$namespace
    [string]$customLocationFile  # Add this property
    [string]$targetSpecFile      # Add this property

    DeploymentTarget([array]$targets, [array]$capabilities = $null, [string]$hierarchyLevel = $null, [RBAC]$rbac = $null, [string]$namespace = $null, [string]$customLocationFile = $null, [string]$targetSpecFile = $null) {
        $this.targets = $targets
        $this.capabilities = $capabilities
        $this.hierarchyLevel = $hierarchyLevel
        $this.rbac = $rbac
        $this.namespace = $namespace
        $this.customLocationFile = $customLocationFile  # Set the property
        $this.targetSpecFile = $targetSpecFile          # Set the property
    }
}

class CapabilityList {
    [string]$name
    [array]$capabilities

    CapabilityList([string]$name, [array]$capabilities) {
        $this.name = $name
        $this.capabilities = $capabilities
    }
}

class HierarchyLevels {
    [string]$name
    [array]$levels

    HierarchyLevels([string]$name, [array]$levels) {
        $this.name = $name
        $this.levels = $levels
    }
}

class Schema {
    [string]$name
    [string]$version
    [string]$schemaFile

    Schema([string]$name, [string]$version, [string]$schemaFile) {
        $this.name = $name
        $this.version = $version
        $this.schemaFile = $schemaFile
    }
}

class Config {
    [string]$name
    [string]$versionName
    [string]$configFile

    Config([string]$name, [string]$versionName, [string]$configFile) {
        $this.name = $name
        $this.versionName = $versionName
        $this.configFile = $configFile
    }
}

class Solution {
    [string]$name
    [string]$description
    [array]$capabilities
    [string]$version
    [string]$solutionTemplate
    [string]$specificationFile  # Add this property

    Solution([string]$name, [string]$description, [array]$capabilities, [string]$version, [string]$solutionTemplate, [string]$specificationFile = $null) {
        $this.name = $name
        $this.description = $description
        $this.capabilities = $capabilities
        $this.version = $version
        $this.solutionTemplate = $solutionTemplate
        $this.specificationFile = $specificationFile  # Set the property
    }
}

class Onboarding {
    [string]$resourceGroup
    [string]$subscriptionId
    [string]$location
    [array]$deploymentTargets
    [CapabilityList]$capabilityList
    [HierarchyLevels]$hierarchyLevels
    [array]$schemas
    [array]$configs
    [array]$solutions
    [string]$namespace

    Onboarding([string]$resourceGroup, [string]$subscriptionId, [string]$location, [array]$deploymentTargets, [CapabilityList]$capabilityList = $null, [HierarchyLevels]$hierarchyLevels = $null, [array]$schemas, [array]$configs, [array]$solutions, [string]$namespace = $null) {
        $this.resourceGroup = $resourceGroup
        $this.subscriptionId = $subscriptionId
        $this.location = $location
        $this.deploymentTargets = $deploymentTargets
        $this.capabilityList = $capabilityList
        $this.hierarchyLevels = $hierarchyLevels
        $this.schemas = $schemas
        $this.configs = $configs
        $this.solutions = $solutions
        $this.namespace = $namespace
    }
}

$data = Get-Content -Path $onboardingFile -Raw | ConvertFrom-Json
$fullData = $data

$common = $data.common
$data = $data.cmOnboarding

if ($data.resourceGroup) {
    $resourceGroup = $data.resourceGroup
} elseif ($common.resourceGroup) {
    $resourceGroup = $common.resourceGroup
} else {
    Write-Host "Resource group is required in the onboarding file" -ForegroundColor Red
    exit 1
}

if ($data.subscriptionId) {
    $subscriptionId = $data.subscriptionId
} elseif ($common.subscriptionId) {
    $subscriptionId = $common.subscriptionId
} else {
    Write-Host "Subscription ID is required in the onboarding file" -ForegroundColor Red
    exit 1
}

if ($data.location) {
    $location = $data.location
} elseif ($common.location) {
    $location = $common.location
} else {
    Write-Host "Location is not specified. Defaulting to eastus." -ForegroundColor Yellow
    $location = "eastus"
}

$customLocationFile = $common.customLocationFile

# add subscriptionId and resourceGroup to the data object
if ($null -eq $data.subscriptionId) {
    $data | Add-Member -MemberType NoteProperty -Name "subscriptionId" -Value $null
}
if ($null -eq $data.resourceGroup) {
    $data | Add-Member -MemberType NoteProperty -Name "resourceGroup" -Value $null
}
if ($null -eq $data.location) {
    $data | Add-Member -MemberType NoteProperty -Name "location" -Value $null
}
if ($null -eq $data.customLocationFile) {
    $data | Add-Member -MemberType NoteProperty -Name "customLocationFile" -Value $null
}

$data.subscriptionId = $subscriptionId
$data.resourceGroup = $resourceGroup
$data.customLocationFile = $customLocationFilePath
$data.location = $location

if (-not $skipResourceGroupCreation) {
    Write-Host "Creating resource group" -ForegroundColor Green
    az group create --name $($data.resourceGroup) --location $($data.location)
    if ($LASTEXITCODE -ne 0) { exit 0 }
}

try {
    if ($data.capabilityList) {
        $capabilityList = [CapabilityList]::new($($data.capabilityList.name), $($data.capabilityList.capabilities))
    }
    else {
        $capabilityList = $null
    }

    if ($data.hierarchyList) {
        $hierarchyLevels = [HierarchyLevels]::new($($data.hierarchyList.name), $($data.hierarchyList.levels))
    }
    else {
        $hierarchyLevels = $null
    }

    $deploymentTargets = @()
    foreach ($dt in $data.deploymentTargets) {
        $targets = @()
        foreach ($target in $dt.targets) {
            $rbac = if ($target.rbac) { [RBAC]::new($($target.rbac.role), $($target.rbac.userGroup)) } else { $null }
            $targets += [Target]::new($($target.name), $($target.displayName), $($target.capabilities), $($target.hierarchyLevel), $rbac, $($target.namespace), $($target.customLocationFile), $($target.targetSpecFile))
        }
        $rbac = if ($dt.rbac) { [RBAC]::new($($dt.rbac.role), $($dt.rbac.userGroup)) } else { $null }
        $deploymentTargets += [DeploymentTarget]::new(
            $targets, 
            $($dt.capabilities), 
            $($dt.hierarchyLevel), 
            $rbac, 
            $($dt.namespace), 
            $($dt.customLocationFile), 
            $($dt.targetSpecFile)    
        )    
    }

    $schemas = @()
    foreach ($schema in $data.schemas) {
        $schemas += [Schema]::new($($schema.name), $($schema.version), $($schema.schemaFile))
    }

    $configs = @()
    foreach ($config in $data.configs) {
        $configs += [Config]::new($($config.name), $($config.versionName), $($config.configFile))
    }

    $solutions = @()
    foreach ($solution in $data.solutions) {
        $solutions += [Solution]::new($($solution.name), $($solution.description), $($solution.capabilities), $($solution.version), $($solution.solutionTemplate), $($solution.specificationFile))
    }

    $input = [Onboarding]::new($($data.resourceGroup), $($data.subscriptionId), $($data.location), $deploymentTargets, $capabilityList, $hierarchyLevels, $schemas, $configs, $solutions, $($data.namespace))
}
catch {
    Write-Host "Error processing the onboarding file content: $_" -ForegroundColor Red
    exit 1
}


foreach ($schema in $input.schemas) {
    Write-Host "Creating schema: $($schema.name)" -ForegroundColor Green
    
    $schemaCommand = "az workload-orchestration schema create " +
    "--resource-group $($input.resourceGroup) " +
    "--subscription $($input.subscriptionId) " +
    "--schema-name '$($schema.name)' " +
    "--version '$($schema.version)' " +
    "--schema-file '$($schema.schemaFile)' " +
    "--location $($input.location)"
    
    Write-Host "Executing: $schemaCommand" -ForegroundColor Green
    Invoke-Expression $schemaCommand
}

foreach ($config in $input.configs) {
    Write-Host "Creating config-template: $($config.name)" -ForegroundColor Green
    $configTemplateCommand = "az workload-orchestration config-template create " +
    "--config-template-name '$($config.name)' " +
    "--description 'This is $($config.name) Configuration' " +
    "--configuration-template-file '$($config.configFile)' " +
    "--version '$($config.versionName)' " +
    "--resource-group '$($input.resourceGroup)' " +
    "--location '$($input.location)' " +
    "--subscription '$($input.subscriptionId)'"

    Write-Host "Executing: $configTemplateCommand" -ForegroundColor Green
    Invoke-Expression $configTemplateCommand
}

foreach ($solution in $input.solutions) {
    Write-Host "Creating solution: $($solution.name)" -ForegroundColor Green

    $prefixedCapabilities = $solution.capabilities | ForEach-Object { "$_" }
    Write-Host "capabilities: $($prefixedCapabilities)" -ForegroundColor Yellow
    $capabilitiesParam = if ($prefixedCapabilities.Count -eq 1) {
        "'$($prefixedCapabilities)'"
    }
    else {
        "'" + (ConvertTo-Json -InputObject $prefixedCapabilities -Compress) + "'"
    }

    $solutionTemplateCommand = "az workload-orchestration solution-template create " +
    "--solution-template-name '$($solution.name)' " +
    "--description '$($solution.description)' " +
    "--capabilities $capabilitiesParam " +
    "--configuration-template-file '$($solution.solutionTemplate)' " +
    "--specification '@$($solution.specificationFile)' " +
    "--resource-group '$($input.resourceGroup)' " +
    "--location '$($input.location)' " +
    "--version '$($solution.version)' " +
    "--subscription '$($input.subscriptionId)'"

    Write-Host "Executing: $solutionTemplateCommand" -ForegroundColor Green
    Invoke-Expression $solutionTemplateCommand
}

