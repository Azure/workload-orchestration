param (
    [string]$onboardingFile,
    [bool]$skipAzLogin = $True,
    [bool]$skipAzExtensions = $False,
    [bool]$skipResourceGroupCreation = $False,
    [bool]$skipAksCreation = $False,
    [bool]$skipTcoDeployment = $False,
    [bool]$skipCustomLocationCreation = $False,
    [bool]$skipConnectedRegistryDeployment = $True,
    [bool]$skipSiteCreation = $False,
    [bool]$skipAutoParsing = $False,
    [bool]$skipRelationshipCreation = $False,
    [bool]$enableWODiagnostics = $False,
    [bool]$enableContainerInsights = $False
)

$ErrorActionPreference = "Stop"
$data = Get-Content -Path $onboardingFile -Raw | ConvertFrom-Json
$autoExtractedFilePath = Join-Path -Path (Get-Location) -ChildPath "autoExtractedCustomLocation.json"
function Invoke-AzCommand {
    param (
        [string]$command
    )
    $result = Invoke-Expression $command
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $command"
    }
    return $result
}

function Get-NonArmVMSkus {
    param (
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory=$true)]
        [string]$Location
    )
    
    $query = "[?capabilities[?name=='CpuArchitectureType' && value!='Arm64']].{name:name, family:family, memoryGB:join(', ', capabilities[?name=='MemoryGB'].value), vCPUsAvailable:join(', ', capabilities[?name=='vCPUsAvailable'].value), location:locations}"

    $azCommand = "az vm list-skus --location `"$Location`" --resource-type virtualMachines --subscription `"$SubscriptionId`" --query `"$query`" --output json"
    $result = Invoke-AzCommand $azCommand
    
    # Convert JSON result to PowerShell objects
    $nonArmSkus = $result | ConvertFrom-Json
    
    return $nonArmSkus
}

function Get-VMUsageQuota {
    param (
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory=$true)]
        [string]$Location
    )
    
    $azCommand = "az vm list-usage --location `"$Location`" --subscription `"$SubscriptionId`" --output json"
    $result = Invoke-AzCommand $azCommand
    
    # Convert JSON result to PowerShell objects
    $usageQuota = $result | ConvertFrom-Json
    
    return $usageQuota
}

function Test-SkuForAKS {
    param (
        [Parameter(Mandatory=$true)]
        [object]$Sku,
        
        [Parameter(Mandatory=$true)]
        [int]$RequiredVCPUs,
        
        [Parameter(Mandatory=$true)]
        [int]$RequiredMemoryGB
    )
    
    # Parse vCPUs and memory from the SKU
    $vCPUs = [int]($Sku.vCPUsAvailable -split ',')[0]
    $memoryGB = [int]($Sku.memoryGB -split ',')[0]
    
    # Check if SKU meets minimum requirements
    $hasEnoughVCPUs = $vCPUs -ge $RequiredVCPUs
    $hasEnoughMemory = $memoryGB -ge $RequiredMemoryGB
    
    return @{
        IsSuitable = $hasEnoughVCPUs -and $hasEnoughMemory
        VCPUs = $vCPUs
        MemoryGB = $memoryGB
        HasEnoughVCPUs = $hasEnoughVCPUs
        HasEnoughMemory = $hasEnoughMemory
    }
}

function Find-SuitableVMForAKS {
    param (
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory=$true)]
        [string]$Location,
        
        [Parameter(Mandatory=$false)]
        [int]$RequiredVCPUs = 2,
        
        [Parameter(Mandatory=$false)]
        [int]$RequiredMemoryGB = 4,
        
        [int]$NodeCount = 1
    )
    
    Write-Host "Finding suitable non-ARM VM SKUs for AKS..." -ForegroundColor Green
    
    # Get non-ARM VM SKUs
    $nonArmSkus = Get-NonArmVMSkus -SubscriptionId $SubscriptionId -Location $Location
    
    # Get usage quota
    $usageQuota = Get-VMUsageQuota -SubscriptionId $SubscriptionId -Location $Location
    
    $suitableSkus = @()
    
    foreach ($sku in $nonArmSkus) {
        # Test if SKU meets AKS requirements
        $skuTest = Test-SkuForAKS -Sku $sku -RequiredVCPUs $RequiredVCPUs -RequiredMemoryGB $RequiredMemoryGB
        
        if ($skuTest.IsSuitable) {
            # Check quota availability - vcpu
            $quotaInfo = $usageQuota | Where-Object { $_.name.value -eq $sku.family }
            
            if ($quotaInfo) {
                $currentUsage = $quotaInfo.currentValue
                $limit = $quotaInfo.limit
                $available = $limit - $currentUsage
                
                if ($available -ge ($NodeCount * $RequiredVCPUs)) {
                    $suitableSkus += [PSCustomObject]@{
                        Name = $sku.name
                        Family = $sku.family
                        VCPUs = $skuTest.VCPUs
                        MemoryGB = $skuTest.MemoryGB
                        AvailableQuota = $available
                        CurrentUsage = $currentUsage
                        Limit = $limit
                        Sku = $sku
                    }
                }
            }
        }
    }
    
    # Sort by VCPUs and Memory (prefer smaller instances for cost optimization)
    $suitableSkus = $suitableSkus | Sort-Object VCPUs, MemoryGB

    Write-Host "Suitable SKUs: $($suitableSkus.Count)" -ForegroundColor Green
    # Print at most top 5 SKUs
    $suitableSkus | Select-Object -First 5 | Format-Table -AutoSize | Out-String | Write-Host -ForegroundColor Green

    return $suitableSkus
}

function New-AKSClusterWithNonArmNodes {
    param (
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory=$true)]
        [string]$Location,
        
        [Parameter(Mandatory=$true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory=$true)]
        [string]$ClusterName,

        [Parameter(Mandatory=$false)]
        [string]$AksClusterIdentity,
        
        [Parameter(Mandatory=$false)]
        [int]$RequiredVCPUs = 2,
        
        [Parameter(Mandatory=$false)]
        [int]$RequiredMemoryGB = 4,
        
        [Parameter(Mandatory=$false)]
        [int]$NodeCount = 1
    )
    
    Write-Host "Creating AKS cluster with non-ARM nodes..." -ForegroundColor Green
    
    # Find suitable VM SKU
    $suitableSkus = Find-SuitableVMForAKS -SubscriptionId $SubscriptionId -Location $Location -RequiredVCPUs $RequiredVCPUs -RequiredMemoryGB $RequiredMemoryGB -NodeCount $NodeCount
    
    if ($suitableSkus.Count -eq 0) {
        throw "No suitable non-ARM VM SKUs found that meet the requirements and have available quota."
    }
    
    $selectedSku = $suitableSkus[0]
    Write-Host "Selected VM SKU: $($selectedSku.Name) (vCPUs: $($selectedSku.VCPUs), Memory: $($selectedSku.MemoryGB)GB)" -ForegroundColor Yellow
    Write-Host "Available quota: $($selectedSku.AvailableQuota) vCPUs" -ForegroundColor Yellow
    
    # Check if AKS cluster already exists
    try {
        $existingCluster = Invoke-AzCommand "az aks show --resource-group `"$ResourceGroupName`" --name `"$ClusterName`" --subscription `"$SubscriptionId`" --output json"
        if ($existingCluster) {
            Write-Host "AKS cluster '$ClusterName' already exists. Skipping creation." -ForegroundColor Yellow
            return $existingCluster
        }
    }
    catch {
        Write-Host "AKS cluster '$ClusterName' not found. Proceeding with creation." -ForegroundColor Green
    }

    # Build AKS create command
    $azCommand = "az aks create --resource-group `"$ResourceGroupName`" --name `"$ClusterName`" --location `"$Location`" --subscription `"$SubscriptionId`" --node-vm-size `"$($selectedSku.Name)`" --node-count $NodeCount --generate-ssh-keys"

    if ($AksClusterIdentity) {
        $azCommand += " --assign-identity `"$AksClusterIdentity`""
    }
    
    Write-Host "Executing AKS creation command..." -ForegroundColor Green
    Write-Host "Command: $azCommand" -ForegroundColor Gray
    
    try {
        $result = Invoke-AzCommand $azCommand
        Write-Host "AKS cluster '$ClusterName' created successfully!" -ForegroundColor Green
        return $result
    }
    catch {
        Write-Error "Failed to create AKS cluster: $($_.Exception.Message)"
        throw
    }
}

function Create-LogAnalyticsWorkspace {
    param (
        [string]$workspaceName,
        [string]$resourceGroup,
        [string]$location
    )
    Write-Host "Creating Log Analytics Workspace $workspaceName..." -ForegroundColor Yellow
    $cmd = "az monitor log-analytics workspace create --resource-group $resourceGroup --workspace-name $workspaceName --sku PerGB2018"
    if (-not [string]::IsNullOrEmpty($location)) {
        $cmd += " --location $location"
    }
    Invoke-AzCommand $cmd | Out-Null
    Write-Host "Created Log Analytics Workspace $workspaceName" -ForegroundColor DarkGreen

    $logAnalyticsWorkspaceId = Invoke-AzCommand "az monitor log-analytics workspace show --resource-group $resourceGroup --workspace-name $workspaceName --query id -o tsv"
    Write-Host "Log Analytics Workspace ID: $logAnalyticsWorkspaceId" -ForegroundColor DarkGreen
    return $logAnalyticsWorkspaceId
}

function New-WODiagnosticsResource {
    param (
        [string]$subscriptionId,
        [string]$resourceGroup,
        [string]$diagnosticResourceName,
        [string]$resolvedCustomLocationFile,
        [string]$location
    )
    Write-Host "Creating WODiagnostics Resource with name $diagnosticResourceName ..." -ForegroundColor Yellow
    # Construct command using resolved values
    $diagCommand = "az workload-orchestration diagnostic create " +
    "--resource-group $($resourceGroup) " + 
    "--location $($location) " + 
    "--subscription $($subscriptionId) " + 
    "--name '$($diagnosticResourceName)' " + 
    "--extended-location '@$resolvedCustomLocationFile'"   # Use resolved value

    Write-Host "Executing: $diagCommand" -ForegroundColor Yellow
    # Use Invoke-AzCommand if available in this script, otherwise Invoke-Expression
    Invoke-AzCommand $diagCommand | Out-Null

    Write-Host "Created WODiagnostics Resource with name $diagnosticResourceName" -ForegroundColor DarkGreen
    $diagResourceId = Invoke-AzCommand "az workload-orchestration diagnostic show --subscription $subscriptionId --resource-group $resourceGroup --name $diagnosticResourceName --query id -o tsv"
    return $diagResourceId
}

function New-WODiagnosticSetting {
    param (
        [string]$diagnosticResourceId,
        [string]$logAnalyticsWorkspaceId,
        [string]$diagnosticSettingName = "default"
    )
    Write-Host "Creating Diagnostic Setting for $diagnosticResourceId..." -ForegroundColor Yellow
    $cmd = "az monitor diagnostic-settings create --resource $diagnosticResourceId --workspace $logAnalyticsWorkspaceId --name $diagnosticSettingName --logs '[{`"category`":`"UserAudits`",`"enabled`":true},{`"category`":`"UserDiagnostics`",`"enabled`":true}]'"
    Invoke-AzCommand $cmd
    Write-Host "Created Diagnostic Setting for $diagnosticResourceId" -ForegroundColor DarkGreen
}

function Install-ContainerInsights {
    param (
        [string]$resourceGroup,
        [string]$arcClusterName,
        [string]$logAnalyticsWorkspaceId
    )
    Write-Host "Installed Microsoft.AzureMonitor.Containers extension on arc cluster: $arcClusterName in resource group: $resourceGroup" -ForegroundColor Yellow
    $cmd = "az k8s-extension create --name azuremonitor-containers --cluster-name $arcClusterName --resource-group $resourceGroup --cluster-type connectedClusters --extension-type Microsoft.AzureMonitor.Containers --configuration-settings logAnalyticsWorkspaceResourceID=$logAnalyticsWorkspaceId"
    Invoke-AzCommand $cmd
    Write-Host "Installed Microsoft.AzureMonitor.Containers extension on arc cluster: $arcClusterName in resource group: $resourceGroup" -ForegroundColor DarkGreen
}
function Install-Kubectl {
    # Check if kubectl is installed
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Write-Host "kubectl not found. Installing..."

        $version = Invoke-RestMethod -Uri "https://dl.k8s.io/release/stable.txt"
        $url = "https://dl.k8s.io/release/$version/bin/windows/amd64/kubectl.exe"
        $output = "$env:USERPROFILE\kubectl.exe"

        Invoke-WebRequest -Uri $url -OutFile $output

        # Optionally add to PATH
        $env:Path += ";$env:USERPROFILE"
        Write-Host "kubectl installed successfully."
    } else {
        Write-Host "kubectl is already installed."
    }
}

function Test-AcrImageExists {
    param(
        [string]$acrName,
        [string]$imageName
    )
    
    try {
        $manifests = Invoke-AzCommand "az acr repository show-manifests --name $acrName --repository $imageName" | ConvertFrom-Json
        if ($manifests -and $manifests.Count -gt 0) {
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

try {
    if (-not $skipAzLogin) {
        Write-Host "Logging in to Azure..." -ForegroundColor Yellow
        # Wait for interactive az login
        Invoke-AzCommand "az login"
    }
    else {
        Write-Host "Skipping Azure login." -ForegroundColor DarkGray
    }
    

    if (-not $skipAzExtensions) {
        Write-Host "Installing/updating az extensions..." -ForegroundColor Yellow
        # 2.7.0 Causes problems for TO extension install, so disabling it for now
        # Invoke-AzCommand "az upgrade"
        Invoke-AzCommand "az extension add --name connectedk8s"
        Invoke-AzCommand "az extension add --name k8s-extension"
        Invoke-AzCommand "az extension add --name customlocation"
        Invoke-AzCommand "az extension update --name connectedk8s"
        Invoke-AzCommand "az extension update --name k8s-extension"
        Invoke-AzCommand "az extension update --name customlocation"
    }

    if (-not $data.infraOnboarding) {
        throw "infraOnboarding section is required in the input file"
    }

    # Throw error if subscriptionId is null
    if (-not $data.infraOnboarding.subscriptionId -and -not $data.common.subscriptionId) {
        throw "SubscriptionId is required for infraOnboarding"
    }
    if ($data.common.subscriptionId) {
        $subscriptionId = $data.common.subscriptionId
    }
    else {
        $subscriptionId = $data.infraOnboarding.subscriptionId
    }

    # Read resourceGroup from infraOnboarding
    # throw error if resourceGroup is null
    if (-not $data.infraOnboarding.resourceGroup -and -not $data.common.resourceGroup) {
        throw "ResourceGroup is required for infraOnboarding"
    }
    if ($data.common.resourceGroup) {
        $resourceGroup = $data.common.resourceGroup
    }
    else {
        $resourceGroup = $data.infraOnboarding.resourceGroup
    }

    # Read location from infraOnboarding
    $location = $data.infraOnboarding.location
    if (-not $data.infraOnboarding.location -and -not $data.common.location) {
        $location = "eastus"
        Write-Host "Location is not specified. Defaulting to eastus." -ForegroundColor Yellow
    }
    if ($data.common.location) {
        $location = $data.common.location
    }
    elseif ($data.infraOnboarding.location) {
        $location = $data.infraOnboarding.location
    }

    $arcLocation = $data.infraOnboarding.arcLocation
    if (-not $data.infraOnboarding.arcLocation) {
        $arcLocation = "eastus"
    }

    $extensionName = "symphonytest"

    Invoke-AzCommand "az account set --subscription $subscriptionId"
    if (-not $skipResourceGroupCreation) {
        Invoke-AzCommand "az group create --location $location --name $resourceGroup"
    }

    Write-Host "Installing workload-orchestration extension..." -ForegroundColor Yellow
    # Remove earlier version of workload-orchestration extension
    try 
    {
        Invoke-AzCommand "az extension remove --name workload-orchestration"
    }
    catch {
        Write-Host "workload-orchestration extension not found, continuing..." -ForegroundColor DarkGray
    }
    Invoke-AzCommand "az extension add --name workload-orchestration"
    Write-Host "Installed workload-orchestration extension" -ForegroundColor DarkGreen

    # Read aksClusterName from infraOnboarding or assign default value if not present
    $aksClusterName = $data.infraOnboarding.aksClusterName
    if (-not $aksClusterName) {
        $aksClusterName = $resourceGroup + "-Cluster"
    }
    if (-not $skipAksCreation) {
        # Read aksClusterIdentity from infraOnboarding or assign default value if not present
        $aksClusterIdentity = $data.infraOnboarding.aksClusterIdentity
        if (-not $aksClusterIdentity) {
            $aksClusterIdentity = $resourceGroup + "-Cluster-Identity"
        }
        if (-not $skipAksCreation) {
            # Create identity only if it doesn't already exist
            try {
                Invoke-AzCommand "az identity show --resource-group $resourceGroup --name $aksClusterIdentity --query id -o tsv" | Out-Null
                Write-Host "Managed identity '$aksClusterIdentity' already exists. Skipping creation." -ForegroundColor Yellow
            }
            catch {
                Invoke-AzCommand "az identity create --resource-group $resourceGroup --name $aksClusterIdentity"
            }
        }
        $aksClusterIdentity = Invoke-AzCommand "az identity show --resource-group $resourceGroup --name $aksClusterIdentity --query id --output tsv"

        Write-Host "Selecting non-arm vm size to create aks cluster $aksClusterName..." -ForegroundColor Yellow

        New-AKSClusterWithNonArmNodes -SubscriptionId $subscriptionId -Location $location -ResourceGroupName $resourceGroup -ClusterName $aksClusterName -AksClusterIdentity $aksClusterIdentity -RequiredVCPUs 2 -RequiredMemoryGB 7 -NodeCount 2

        Write-Host "Created aks cluster $aksClusterName" -ForegroundColor DarkGreen
    }
    
    # Deploy TCO onto AKS Cluster
    if (-not $skipTcoDeployment) {
        Invoke-AzCommand "az aks get-credentials --resource-group $resourceGroup --name $aksClusterName --overwrite-existing"

        # Check if cluster is already Arc-connected before connecting
        $arcConnected = $false
        try {
            $arcStatus = Invoke-AzCommand "az connectedk8s show -g $resourceGroup -n $aksClusterName --query connectivityStatus -o tsv"
            if ($arcStatus -eq "Connected") {
                Write-Host "Cluster '$aksClusterName' is already Arc-connected. Skipping connect." -ForegroundColor Yellow
                $arcConnected = $true
            }
        }
        catch {
            Write-Host "Cluster '$aksClusterName' is not Arc-connected. Connecting..." -ForegroundColor Yellow
        }
        if (-not $arcConnected) {
            Invoke-AzCommand "az connectedk8s connect -g $resourceGroup -n $aksClusterName --location $arcLocation"
        }

        # enable-features is idempotent but slow (~5 min); no API to check feature status
        Write-Host "Enabling cluster-connect and custom-locations features (this may take several minutes)..." -ForegroundColor Yellow

        # Resolve Custom Location RP OID for enable-features
        # Try from config first, then Azure AD lookup, then fall back to well-known Microsoft tenant OID
        $customLocationOid = $data.infraOnboarding.customLocationOid
        if (-not $customLocationOid) {
            Write-Host "Attempting to resolve Custom Location RP OID from Azure AD..." -ForegroundColor Yellow
            try {
                $customLocationOid = Invoke-AzCommand "az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv"
                if ($customLocationOid) {
                    Write-Host "Resolved Custom Location RP OID: $customLocationOid" -ForegroundColor Green
                }
            }
            catch {
                Write-Host "Could not resolve Custom Location RP OID via Azure AD (insufficient privileges). Will use well-known default OID as fallback." -ForegroundColor Yellow
                # Well-known OID for Microsoft.ExtendedLocation RP in Microsoft tenant
                $customLocationOid = "51dfe1e8-70c6-4de5-a08e-e18aff23d815"
                Write-Host "Using default Custom Location RP OID: $customLocationOid" -ForegroundColor Yellow
            }
        }

        $maxRetries = 5
        $retryDelay = 60  # seconds
        $enableFeaturesSuccess = $false
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                $command = "az connectedk8s enable-features -n $aksClusterName -g $resourceGroup --features cluster-connect custom-locations"
                if ($customLocationOid) {
                    $command += " --custom-locations-oid `"$customLocationOid`""
                }
                $result = Invoke-Expression $command
                $enableFeaturesSuccess = $true
                break
            }
            catch {
                $errorMessage = $_.Exception.Message
                if ($attempt -lt $maxRetries -and $errorMessage -match "another operation .* is in progress") {
                    Write-Host "Attempt $attempt/$maxRetries failed: another Helm operation is in progress. Retrying in $retryDelay seconds..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $retryDelay
                }
                else {
                    throw "Command failed: $command. Error: $errorMessage"
                }
            }
        }
        if (-not $enableFeaturesSuccess) {
            throw "Failed to enable features after $maxRetries attempts."
        }

        Invoke-AzCommand "az account set --subscription $subscriptionId"
    
        # Install cert-manager via IoT Operations extension (skip if already installed)
        Write-Host "Installing cert-manager..." -ForegroundColor Yellow
        try {
            $existingCertMgr = Invoke-AzCommand "az k8s-extension show --resource-group $resourceGroup --cluster-name $aksClusterName --name 'aio-certmgr' --cluster-type connectedClusters --query provisioningState -o tsv"
            if ($existingCertMgr -eq "Succeeded") {
                Write-Host "cert-manager extension already installed (state: $existingCertMgr). Skipping." -ForegroundColor Yellow
            }
            elseif ($existingCertMgr -eq "Failed" -or $existingCertMgr -eq "Canceled") {
                Write-Host "cert-manager extension is in a failed state (state: $existingCertMgr). Attempting reinstallation." -ForegroundColor Yellow
                Invoke-AzCommand "az k8s-extension delete --resource-group $resourceGroup --cluster-name $aksClusterName --name 'aio-certmgr' --cluster-type connectedClusters --yes"
                Invoke-AzCommand "az k8s-extension create --resource-group $resourceGroup --cluster-name $aksClusterName --name 'aio-certmgr' --cluster-type connectedClusters --extension-type microsoft.iotoperations.platform --scope cluster --release-namespace cert-manager"
                Write-Host "Successfully reinstalled cert-manager" -ForegroundColor DarkGreen
            }
        }
        catch {
            Invoke-AzCommand "az k8s-extension create --resource-group $resourceGroup --cluster-name $aksClusterName --name 'aio-certmgr' --cluster-type connectedClusters --extension-type microsoft.iotoperations.platform --scope cluster --release-namespace cert-manager"
            Write-Host "Successfully installed cert-manager" -ForegroundColor DarkGreen
        }

        # Install workload orchestration extension (skip if already installed)
        Write-Host "Installing workload orchestration extension..." -ForegroundColor Yellow
        try {
            $existingWoExt = Invoke-AzCommand "az k8s-extension show --resource-group $resourceGroup --cluster-name $aksClusterName --name $extensionName --cluster-type connectedClusters --query provisioningState -o tsv"
            if ($existingWoExt -eq "Succeeded") {
                Write-Host "Workload orchestration extension already installed (state: $existingWoExt). Skipping." -ForegroundColor Yellow
            }
            elseif ($existingWoExt -eq "Failed" -or $existingWoExt -eq "Canceled") {
                Write-Host "Workload orchestration extension is in a failed state (state: $existingWoExt). Attempting reinstallation." -ForegroundColor Yellow
                Invoke-AzCommand "az k8s-extension delete --resource-group $resourceGroup --cluster-name $aksClusterName --name $extensionName --cluster-type connectedClusters --yes"
                Invoke-AzCommand "az k8s-extension create --resource-group $resourceGroup --cluster-name $aksClusterName --cluster-type connectedClusters --name $extensionName --extension-type Microsoft.workloadorchestration --scope cluster --config redis.persistentVolume.storageClass='' --config redis.persistentVolume.size=20Gi"
                Write-Host "Successfully reinstalled workload orchestration extension" -ForegroundColor DarkGreen
            }
        }
        catch {
            Invoke-AzCommand "az k8s-extension create --resource-group $resourceGroup --cluster-name $aksClusterName --cluster-type connectedClusters --name $extensionName --extension-type Microsoft.workloadorchestration --scope cluster --config redis.persistentVolume.storageClass='' --config redis.persistentVolume.size=20Gi"
            Write-Host "Successfully installed workload orchestration extension" -ForegroundColor DarkGreen
        }
    }

    # Turn AKS Cluster into a Custom Location

    # read customLocationName from infraOnboarding or assign default value if not present
    $customLocationName = $data.infraOnboarding.customLocationName
    if (-not $customLocationName) {
        $customLocationName = $resourceGroup + "-Location"
    }
    # read customLocationNamespace from infraOnboarding or assign default value if not present
    $customLocationNamespace = $data.infraOnboarding.customLocationNamespace
    if (-not $customLocationNamespace) {
        $customLocationNamespace = "Mehoopany".ToLower()
    }

   
    if (-not $skipCustomLocationCreation) {
        Write-Host "Creating custom location $customLocationName..." -ForegroundColor Yellow
    
        # Get Arc-enabled K8s cluster ID
        $arcClusterId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Kubernetes/connectedClusters/$aksClusterName"
        
        # Get extension ID
        $extensionId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Kubernetes/connectedClusters/$aksClusterName/providers/Microsoft.KubernetesConfiguration/extensions/$extensionName"
        
        # get custom location if exists
        $clusterExtensionIds = @()
        try {
            $existingCustomLocation = Invoke-AzCommand "az customlocation show --name $customLocationName --resource-group $resourceGroup --query id -o tsv"
            if ($existingCustomLocation) {
                $clusterExtensionIds = Invoke-AzCommand "az customlocation show --name $customLocationName --resource-group $resourceGroup --query 'clusterExtensionIds' -o json" | ConvertFrom-Json
                if ($clusterExtensionIds -notcontains $extensionId) {
                    $clusterExtensionIds += $extensionId
                }
            }
        }
        catch {
            Write-Host "Custom location $customLocationName does not exist. Creating a new one." -ForegroundColor Yellow
            $clusterExtensionIds = @($extensionId)
        }

        $clusterExtensionIdsParam = $clusterExtensionIds -join " "

        # Create the custom location with properly escaped quotes
        $customLocationCommand = "az customlocation create -n $customLocationName -g $resourceGroup --namespace $customLocationNamespace --host-resource-id `"$arcClusterId`" --cluster-extension-ids $clusterExtensionIdsParam --location $arcLocation"
        Write-Host "Executing: $customLocationCommand" -ForegroundColor Yellow

        # Try creating the custom location; if it fails with UnauthorizedNamespaceError,
        # re-enable custom-locations feature with the OID and retry
        $customLocationOutput = $null
        try {
            $customLocationOutput = Invoke-AzCommand $customLocationCommand
        }
        catch {
            $clError = $_.Exception.Message
            if ($clError -match "UnauthorizedNamespaceError") {
                Write-Host "Custom location creation failed with UnauthorizedNamespaceError. Re-enabling custom-locations feature with OID..." -ForegroundColor Yellow

                # Resolve OID if not already available
                if (-not $customLocationOid) {
                    try {
                        $customLocationOid = Invoke-AzCommand "az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv"
                    }
                    catch {
                        # Well-known OID for Microsoft.ExtendedLocation RP in Microsoft tenant
                        $customLocationOid = "51dfe1e8-70c6-4de5-a08e-e18aff23d815"
                    }
                }
                Write-Host "Using Custom Location RP OID: $customLocationOid" -ForegroundColor Yellow
                $enableFeaturesWithOid = "az connectedk8s enable-features -n $aksClusterName -g $resourceGroup --features cluster-connect custom-locations --custom-locations-oid `"$customLocationOid`""
                Invoke-AzCommand $enableFeaturesWithOid

                Write-Host "Retrying custom location creation..." -ForegroundColor Yellow
                $customLocationOutput = Invoke-AzCommand $customLocationCommand
            }
            else {
                throw
            }
        }
        
        if (-not $skipAutoParsing) {
            try {
                # Parse the output and extract the 'id'
                $customLocationJson = $customLocationOutput | ConvertFrom-Json
                if (-not $customLocationJson.id) {
                    throw "Failed to extract 'id' from custom location creation output."
                }
                $customLocationId = $customLocationJson.id

                # Create the new JSON file with the extracted 'id'
                $autoExtractedContent = @{
                    name = $customLocationId
                    type = "CustomLocation"
                }
                $autoExtractedContent | ConvertTo-Json -Depth 10 | Set-Content -Path $autoExtractedFilePath

                # Read the JSON file at $onboardingFile
                $onboardingFileContent = Get-Content -Path $onboardingFile -Raw | ConvertFrom-Json

                # Ensure 'common' is a hashtable
                if ($null -eq $onboardingFileContent.common) {
                    $onboardingFileContent | Add-Member -MemberType NoteProperty -Name "common" -Value @{}
                }

                # Ensure 'customLocationFile' property exists
                if (-not ($onboardingFileContent.common.PSObject.Properties.Name -contains "customLocationFile")) {
                    $onboardingFileContent.common | Add-Member -MemberType NoteProperty -Name "customLocationFile" -Value $null
                }
                $onboardingFileContent.common.customLocationFile = $autoExtractedFilePath
                # Save the updated JSON back to the onboarding file
                $onboardingFileContent | ConvertTo-Json -Depth 10 | Out-File -FilePath $onboardingFile -Encoding utf8

                Write-Host "Created $autoExtractedFilePath and updated $onboardingFile with customLocationFile: $autoExtractedFilePath" -ForegroundColor DarkGreen
            }
            catch {
                Write-Error "An error occurred while processing custom location creation output or updating the JSON file: $($_.Exception.Message)"
                throw
            }
        }

        Write-Host "Successfully created Custom Location: $customLocationName and added file path into onboarding common section" -ForegroundColor DarkGreen
    }


    if (-not $skipConnectedRegistryDeployment) {
        # Read acrName from infraOnboarding or assign default value if not present
        $acrName = $data.infraOnboarding.acrName
        if (-not $acrName) {
            $suffix=-join ((97..122) | Get-Random -Count 4 | ForEach-Object {[char]$_})
            # Connected registry name must be lowercase alphanumeric
            $acrName = "acrstaging" + $suffix
        }
        
        # Check if ACR already exists in the resource group. If not, validate the name and create it.
        Write-Host "Checking if ACR $acrName already exists in resource group $resourceGroup..." -ForegroundColor Yellow
        $existingAcr = $null
        try {
            $existingAcr = Invoke-AzCommand "az acr show --name $acrName --resource-group $resourceGroup" | ConvertFrom-Json
            Write-Host "ACR $acrName already exists in resource group $resourceGroup" -ForegroundColor Green
            
            # Check if it's Premium SKU
            if ($existingAcr.sku.name -eq "Premium") {
                Write-Host "ACR $acrName is already Premium SKU" -ForegroundColor Green
            } else {
                Write-Host "ACR $acrName is $($existingAcr.sku.name) SKU, upgrading to Premium..." -ForegroundColor Yellow
                Invoke-AzCommand "az acr update --name $acrName --resource-group $resourceGroup --sku Premium"
                Write-Host "Successfully upgraded ACR $acrName to Premium SKU" -ForegroundColor Green
            }
            
            # Check if data endpoint is enabled (required for connected registry)
            if ($existingAcr.dataEndpointEnabled -eq $true) {
                Write-Host "Data endpoint is already enabled for ACR $acrName" -ForegroundColor Green
            } else {
                Write-Host "Enabling data endpoint for ACR $acrName..." -ForegroundColor Yellow
                Invoke-AzCommand "az acr update --name $acrName --resource-group $resourceGroup --data-endpoint-enabled"
                Write-Host "Successfully enabled data endpoint for ACR $acrName" -ForegroundColor Green
            }
        } catch {
            Write-Host "ACR $acrName does not exist in resource group $resourceGroup, validating ACR name for creation..." -ForegroundColor Yellow
            
            $nameCheck = Invoke-AzCommand "az acr check-name --name $acrName" | ConvertFrom-Json          
            if ($nameCheck.nameAvailable -eq $true) {
                Write-Host "ACR name $acrName is available" -ForegroundColor Green
            } else {
                Write-Error "ACR name $acrName is not available. Reason: $($nameCheck.reason). Message: $($nameCheck.message)"
                throw
            }
            Invoke-AzCommand "az acr create --resource-group $resourceGroup --name $acrName --sku Premium"
            Invoke-AzCommand "az acr update --name $acrName --resource-group $resourceGroup --data-endpoint-enabled"
            Write-Host "Successfully created ACR $acrName with Premium SKU" -ForegroundColor Green
        }
    
        # add a repo to the ACR to enable connected registry creation
        $imageExists = Test-AcrImageExists -acrName $acrName -imageName "tmp/hello-world"
        if ($imageExists) {
            Write-Host "Image tmp/hello-world already exists in ACR $acrName" -ForegroundColor Green
        } else {
            Write-Host "Image tmp/hello-world does not exist, importing..." -ForegroundColor Yellow
            Invoke-AzCommand "az acr import --name $acrName --source mcr.microsoft.com/hello-world:latest --image tmp/hello-world:latest"
        }

        # Read connectedRegistryName from infraOnboarding or assign default value if not present
        $connectedRegistryName = $data.infraOnboarding.connectedRegistryName
        if (-not $connectedRegistryName) {
            # Connected registry name must be alphanumeric
            $suffix=-join ((97..122) + (48..57) | Get-Random -Count 4 | ForEach-Object {[char]$_})
            $connectedRegistryName = "conected" + $suffix
        }

        # Check if connected registry already exists
        $connRegExists = $false
        try {
            $existingConnReg = Invoke-AzCommand "az acr connected-registry show --registry $acrName --name $connectedRegistryName --query connectionState -o tsv"
            if ($existingConnReg) {
                Write-Host "Connected registry '$connectedRegistryName' already exists (state: $existingConnReg). Skipping creation." -ForegroundColor Yellow
                $connRegExists = $true
            }
        }
        catch {
            Write-Host "Connected registry '$connectedRegistryName' does not exist. Creating..." -ForegroundColor Yellow
        }
        if (-not $connRegExists) {
            Invoke-AzCommand "az acr connected-registry create --registry $acrName --name $connectedRegistryName --repository tmp/hello-world --mode ReadOnly --log-level Debug --yes"
            Write-Host "Successfully created connected registry: $connectedRegistryName" -ForegroundColor DarkGreen
        }
        Invoke-AzCommand "az acr connected-registry list --registry $acrName --output table"

        $connectionString = $(az acr connected-registry get-settings --name $connectedRegistryName --registry $acrName --parent-protocol https --generate-password 1 --query ACR_REGISTRY_CONNECTION_STRING  --subscription $subscriptionId --output tsv --yes)
        $connectionString = $connectionString -replace "`r", ""
        if (-not $connectionString) {
            throw "Failed to retrieve connection string for connected registry $connectedRegistryName"
        }
        $connData = @{ connectionString = $connectionString }
        $connData | ConvertTo-Json | Set-Content -Path "protected-settings-extension.json"
        Write-Output "Wrote connection registry connection string to protected-settings-extension.json"

        # TODO: dynamically detect the IP address later
        $connectedRegistryIp = $data.infraOnboarding.connectedRegistryIp
        if (-not $connectedRegistryIp) {
            throw "connected Registry IP is required for ConnectedRegistryDeployment"
        }

        $storageSizeRequest = $data.infraOnboarding.storageSizeRequest
        if (-not $storageSizeRequest) {
            $storageSizeRequest = "250Gi"
        }

        # Install connected registry extension (skip if already installed)
        Write-Host "Installing connected registry extension..." -ForegroundColor Yellow
        try {
            $existingConnRegExt = Invoke-AzCommand "az k8s-extension show --cluster-name $aksClusterName --cluster-type connectedClusters --name $connectedRegistryName --resource-group $resourceGroup --query provisioningState -o tsv"
            if ($existingConnRegExt) {
                Write-Host "Connected registry extension already installed (state: $existingConnRegExt). Skipping." -ForegroundColor Yellow
            }
        }
        catch {
            Invoke-AzCommand "az k8s-extension create --cluster-name $aksClusterName --cluster-type connectedClusters --extension-type Microsoft.ContainerRegistry.ConnectedRegistry --name $connectedRegistryName --resource-group $resourceGroup --config service.clusterIP=$connectedRegistryIp --config pvc.storageRequest=$storageSizeRequest --config cert-manager.install=false --config-protected-file protected-settings-extension.json"
            Write-Host "Successfully installed connected registry extension." -ForegroundColor DarkGreen
        }

        Write-Host "Creating client token for connected registry..." -ForegroundColor Yellow
        # Check if scope-map already exists
        try {
            Invoke-AzCommand "az acr scope-map show --name 'all-repos-read' --registry $acrName --query name -o tsv" | Out-Null
            Write-Host "Scope-map 'all-repos-read' already exists. Skipping creation." -ForegroundColor Yellow
        }
        catch {
            Invoke-AzCommand "az acr scope-map create --name 'all-repos-read' --registry $acrName --repository '*' content/read metadata/read --description 'Scope map for pulling from ACR.'"
        }

        $clientTokenName = 'all-repos-pull-token'
        # Check if token already exists
        $tokenExists = $false
        try {
            $existingToken = Invoke-AzCommand "az acr token show --name $clientTokenName --registry $acrName --query name -o tsv"
            if ($existingToken) {
                Write-Host "Token '$clientTokenName' already exists. Regenerating password." -ForegroundColor Yellow
                $tokenExists = $true
            }
        }
        catch {
            Write-Host "Token '$clientTokenName' does not exist. Creating..." -ForegroundColor Yellow
        }
        if (-not $tokenExists) {
            $clientTokenOutput = $(az acr token create --name $clientTokenName --registry $acrName --scope-map "all-repos-read") | ConvertFrom-Json
            $clientTokenValue = $clientTokenOutput.credentials.passwords[0].value
        }
        else {
            $clientTokenOutput = $(az acr token credential generate --name $clientTokenName --registry $acrName --password1) | ConvertFrom-Json
            $clientTokenValue = $clientTokenOutput.passwords[0].value
        }

        Invoke-AzCommand "az acr connected-registry update --name $connectedRegistryName --registry $acrName --add-client-token $clientTokenName"
        $secretName=$data.infraOnboarding.connectedRegistryClientToken
        if (-not $secretName) {
            $secretName = "acr-client-token"
        }
        
        Write-Host "Validate kubectl..." -ForegroundColor Yellow
        Install-Kubectl
        # Use --dry-run + apply to make secret creation idempotent
        kubectl create secret generic $secretName --from-literal=username=$clientTokenName --from-literal=password=$clientTokenValue -n $customLocationNamespace --dry-run=client -o yaml | kubectl apply -f -
    }
  

    . ([scriptblock]::Create((Get-Content -Path "$PSScriptRoot/site_onboarding_helper.ps1" -Raw)))

    if ($data.infraOnboarding -and $data.infraOnboarding.siteHierarchy) {
        ## Create Site Hierarchy and Relationships
        Write-Host "Processing Site Hierarchy..." -ForegroundColor Green
        #Site propertiesvalidation
        Validate-SiteHierarchy -siteHierarchy $data.infraOnboarding.siteHierarchy
        #Site Resource creation
        Create-SitesAndRelationships -data $data -resourceGroup $data.common.resourceGroup -skipSiteCreation $False -skipRelationshipCreation $skipRelationshipCreation
    
        Write-Host "Processing Site Hierarchy for Deployment Targets..." -ForegroundColor Green

        $contextId = ""
    
        # Iterate through each node in the site hierarchy
        foreach ($siteNode in $data.infraOnboarding.siteHierarchy) {
            if ($siteNode.capabilityList) {
                Write-Host "Setting up capabilities" -ForegroundColor Green
                $currentSite = $siteNode
                # Check if context already exists in MSFT tenant
                # Get all context information from onboarding file
                $contextSubscriptionId = if ($data.infraOnboarding.contextSubscriptionId) { $data.infraOnboarding.contextSubscriptionId } else { $data.common.subscriptionId }
                $contextResourceGroup = if ($data.infraOnboarding.contextResourceGroup) { $data.infraOnboarding.contextResourceGroup } else { "Mehoopany" }
                $contextName = if ($data.infraOnboarding.contextName) { $data.infraOnboarding.contextName } else { "Mehoopany-Context" }
                $contextLocation = if ($data.infraOnboarding.contextLocation) { $data.infraOnboarding.contextLocation } else { "eastus2euap" }
                $contextId = "/subscriptions/$contextSubscriptionId/resourceGroups/$contextResourceGroup/providers/Microsoft.Edge/contexts/$contextName"
                Write-Host "Using context: $contextName in resource group: $contextResourceGroup, subscription: $contextSubscriptionId, location: $contextLocation" -ForegroundColor Yellow
            
                $contextExists = $false
                try {
                    $context = $(az workload-orchestration context show --subscription $contextSubscriptionId --resource-group $contextResourceGroup --name $contextName 2>$null) | ConvertFrom-JSON
                    if ($context) {
                        $contextExists = $true
                    }
                }
                catch {
                    $contextExists = $false
                }
            
                if ($contextExists) {
                    # MSFT Tenant - Update existing context with new capabilities
                    Write-Host "Updating existing context with new capabilities" -ForegroundColor Yellow
                
                    # Add new capabilities
                    $newCapabilities = @()
                    foreach ($capName in $currentSite.capabilityList.capabilities) {
                        $newCapabilities += [PSCustomObject]@{
                            description = "$capName"; 
                            name        = "$capName"
                        }
                    }
                
                    $context.properties.capabilities = $context.properties.capabilities + $newCapabilities
                    $context.properties.capabilities = $context.properties.capabilities | Select-Object -Property name, description -Unique
                    $context.properties.capabilities | ConvertTo-JSON -Compress | Set-Content context-capabilities.json
                    $hierarchyParams = ""
                    if ($currentSite.hierarchyLevels -and $currentSite.hierarchyLevels.levels) {
                        Write-Host "Including hierarchy levels in context" -ForegroundColor Yellow
                        $hierarchyParamArray = @()
            
                        for ($i = 0; $i -lt $currentSite.hierarchyLevels.levels.Length; $i++) {
                            $level = $currentSite.hierarchyLevels.levels[$i]
                            $hierarchyParamArray += "[${i}].name=$level"
                            $hierarchyParamArray += "[${i}].description=$level"
                        }
            
                        $hierarchyParams = " --hierarchies " + ($hierarchyParamArray -join " ")
                    }
                    $contextCommand = "az workload-orchestration context create " +
                    "--subscription $contextSubscriptionId " +
                    "--resource-group $contextResourceGroup " +
                    "--location $contextLocation " +
                    "--name $contextName " +
                    "--capabilities `"@context-capabilities.json`"" +
                    $hierarchyParams
                
                    Write-Host "Executing: $contextCommand" -ForegroundColor Yellow
                    Invoke-AzCommand $contextCommand


                }
                else {
                    Write-Host "Cannot find context $contextName in resource group $contextResourceGroup, subscription $contextSubscriptionId. Create new context via instructions." -ForegroundColor Yellow
                    exit 0
                }
            

                Write-Host "Capabilities setup completed" -ForegroundColor Green

                # --- Assign Role to Service Principal ---
                # Write-Host "Assigning 'Service Group Contributor' role to provider service principal for site $($siteNode.siteName)..." -ForegroundColor Yellow
                # $providerAppId = $data.common.providerAppId
                # $providerOid = Invoke-AzCommand "az ad sp show --id $providerAppId --query id -o tsv"
                # if (-not $providerOid) {
                #     Write-Error "Failed to retrieve Object ID for provider App ID $providerAppId."
                #     # Decide if this failure should stop the script
                #     # exit 1
                # }
                # else {
                #     $roleAssignmentScope = "/providers/Microsoft.Management/serviceGroups/$($siteNode.siteName)" # Use site name directly as the service group name
                #     $roleAssignmentCommand = "az role assignment create --assignee `"$providerOid`" --role `"Service Group Contributor`" --scope `"$roleAssignmentScope`""
                #     Write-Host "Executing: $roleAssignmentCommand" -ForegroundColor Yellow
                #     Invoke-AzCommand $roleAssignmentCommand
                
                    
                # }
                # --- End Role Assignment ---

                # --- Add Site Reference ---
                # Assuming resourcePrefix should be the resource group name based on site creation logic
                $siteReferenceName = "$($siteNode.siteName)"
                # Construct the site ID based on site type
                if ($siteNode.isRGSite -eq $true) {
                    $siteId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Edge/sites/$($siteNode.siteName)"
                }
                else {
                    $siteId = "/providers/Microsoft.Management/serviceGroups/$($siteNode.siteName)/providers/Microsoft.Edge/sites/$($siteNode.siteName)"
                }
                
                Write-Host "Creating site reference '$siteReferenceName' for context '$contextName'..." -ForegroundColor Yellow
                # Check if site reference already exists
                $siteRefExists = $false
                try {
                    $existingSiteRef = $(az workload-orchestration context site-reference show --subscription $contextSubscriptionId --resource-group $contextResourceGroup --context-name $contextName --name $siteReferenceName --query name -o tsv 2>$null)
                    if ($existingSiteRef) {
                        Write-Host "Site reference '$siteReferenceName' already exists. Skipping." -ForegroundColor Yellow
                        $siteRefExists = $true
                    }
                }
                catch {
                    # Site reference does not exist
                }

                if (-not $siteRefExists) {
                    $siteRefCommand = "az workload-orchestration context site-reference create " +
                    "--subscription $contextSubscriptionId " +
                    "--resource-group $contextResourceGroup " + # Use context RG
                    "--context-name $contextName " +
                    "--name $siteReferenceName " +
                    "--site-id '$siteId'"
                    
                    Write-Host "Executing: $siteRefCommand" -ForegroundColor Yellow
                    Invoke-AzCommand $siteRefCommand
                }
                

            }
        

            # Check if this site node defines deployment targets
            if ($siteNode.PSObject.Properties.Name -contains 'deploymentTargets' -and $siteNode.deploymentTargets) {
                $dt = $siteNode.deploymentTargets # Parent deploymentTargets object
                Write-Host "Found deployment targets for site: $($siteNode.siteName)" -ForegroundColor Cyan
    
                # Check if the deploymentTargets object has a 'targets' array
                if ($dt.PSObject.Properties.Name -contains 'targets' -and $dt.targets) {
                    foreach ($targetInfo in $dt.targets) {
                        Write-Host "Processing Target: $($targetInfo.name)" -ForegroundColor Cyan

                        # --- Resolve properties for the CURRENT target ---
                        # Start with the target's own properties, then fallback to parent ($dt), then potentially common
                        $resolvedCapabilities = if ($targetInfo.PSObject.Properties.Name -contains 'capabilities') { $targetInfo.capabilities } elseif ($dt.PSObject.Properties.Name -contains 'capabilities') { $dt.capabilities } else { @() }
                        $resolvedHierarchyLevel = if ($targetInfo.PSObject.Properties.Name -contains 'hierarchyLevel') { $targetInfo.hierarchyLevel } elseif ($dt.PSObject.Properties.Name -contains 'hierarchyLevel') { $dt.hierarchyLevel } else { $null }
                        $resolvedRbac = if ($targetInfo.PSObject.Properties.Name -contains 'rbac') { $targetInfo.rbac } elseif ($dt.PSObject.Properties.Name -contains 'rbac') { $dt.rbac } else { $null }
                        # Namespace might not be directly used in target create command itself
                        # $resolvedNamespace = if ($targetInfo.PSObject.Properties.Name -contains 'namespace') { $targetInfo.namespace } elseif ($dt.PSObject.Properties.Name -contains 'namespace') { $dt.namespace } else { $null } 
                        $resolvedCustomLocationFile = if ($targetInfo.PSObject.Properties.Name -contains 'customLocationFile') { $targetInfo.customLocationFile } elseif ($dt.PSObject.Properties.Name -contains 'customLocationFile') { $dt.customLocationFile } else { $null }
                        $resolvedTargetSpecFile = if ($targetInfo.PSObject.Properties.Name -contains 'targetSpecFile') { $targetInfo.targetSpecFile } elseif ($dt.PSObject.Properties.Name -contains 'targetSpecFile') { $dt.targetSpecFile } else { $null }

                        # Fallback to common customLocationFile if still not resolved
                        if (-not $resolvedCustomLocationFile) {  
                            $resolvedCustomLocationFile = $autoExtractedFilePath
                        }

                        # Ensure targetSpecFile is resolved
                        if (-not $resolvedTargetSpecFile) {
                            Write-Host "targetSpecFile is required for target $($targetInfo.name). Skipping this target." -ForegroundColor Yellow
                            continue # Skip this target
                        }
                        # --- End Property Resolution ---

                        # Prepare capabilities parameter using resolved value
                        $prefixedCapabilities = $resolvedCapabilities | ForEach-Object { "$_" }
                        Write-Host "Target $($targetInfo.name) resolved capabilities: $($prefixedCapabilities)" -ForegroundColor Yellow
                        $capabilitiesParam = if ($prefixedCapabilities.Count -eq 0) {
                            "''" 
                        }
                        elseif ($prefixedCapabilities.Count -eq 1) {
                            "'$($prefixedCapabilities)'"
                        }
                        else {
                            "'" + (ConvertTo-Json -InputObject $prefixedCapabilities -Compress) + "'"
                        }
                
                        # Check if target already exists before creating
                        $targetExists = $false
                        try {
                            $existingTarget = $(az workload-orchestration target show --resource-group $($data.common.resourceGroup) --name $($targetInfo.name) --subscription $($data.common.subscriptionId) --query name -o tsv 2>$null)
                            if ($existingTarget) {
                                Write-Host "Target '$($targetInfo.name)' already exists. Skipping creation." -ForegroundColor Yellow
                                $targetExists = $true
                            }
                        }
                        catch {
                            # Target does not exist, proceed with creation
                        }

                        if (-not $targetExists) {
                            # Construct command using resolved values and $targetInfo for name/displayName
                            $targetCommand = "az workload-orchestration target create " +
                            "--resource-group $($data.common.resourceGroup) " + # Use common values directly
                            "--location $($data.common.location) " + # Use common values directly
                            "--subscription $($data.common.subscriptionId) " + # Use common values directly
                            "--name '$($targetInfo.name)' " + # Use targetInfo directly
                            "--display-name '$($targetInfo.displayName)' " + # Use targetInfo directly
                            "--hierarchy-level $resolvedHierarchyLevel " + # Use resolved value
                            "--capabilities $capabilitiesParam " + # Use resolved value
                            "--solution-scope 'default' " +
                            "--description 'Target for $($targetInfo.displayName)' " + 
                            "--target-specification '@$resolvedTargetSpecFile' " + # Use resolved value
                            "--extended-location '@$resolvedCustomLocationFile'" +  # Use resolved value
                            " --context-id $contextId" # Use contextId from earlier
                        
                            Write-Host "Executing: $targetCommand" -ForegroundColor Yellow
                            Invoke-AzCommand $targetCommand
                        }
                    
                        $targetId = $(az workload-orchestration target show --resource-group $data.common.resourceGroup --name $targetInfo.name --query id --output tsv)


                        # RG-based sites don't use serviceGroupMember relationships
                        if ($siteNode.isRGSite -ne $true) {
                            Create-Relationship -siteName $($siteNode.siteName) -member $targetId
                        }

                        # RBAC assignment using resolved RBAC object
                        if ($LASTEXITCODE -eq 0 -and $resolvedRbac) {
                            Write-Host "Assigning RBAC role to deployment target: $($targetInfo.name)" -ForegroundColor Green
                            try {
                                # Get ID using targetInfo.name and common RG/Sub
                                $targetIdJson = Invoke-AzCommand "az workload-orchestration target show --name '$($targetInfo.name)' -g $($data.common.resourceGroup) --subscription $($data.common.subscriptionId) -o json"
                                $targetIdObj = $targetIdJson | ConvertFrom-Json
                                $id = $targetIdObj.id
                                if (-not $id) { throw "Failed to retrieve ID for target $($targetInfo.name)" }
                                
                                # Assign role using resolved RBAC info
                                Invoke-AzCommand "az role assignment create --assignee $($resolvedRbac.userGroup) --role '$($resolvedRbac.role)' --scope '$id'"
                                Write-Host "RBAC assigned successfully." -ForegroundColor Green
                            }
                            catch {
                                Write-Error "Failed to assign RBAC for target $($targetInfo.name): $($_.Exception.Message)"
                            }
                        }
                     
                
                    } # End foreach targetInfo
                }
                else {
                    Write-Host "No 'targets' array found within deploymentTargets for site: $($siteNode.siteName)" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "No deployment targets defined for site: $($siteNode.siteName)" -ForegroundColor Gray
            }
        } # End foreach siteNode
        Write-Host "Deployment Target Creation from Site Hierarchy finished." -ForegroundColor Green
    }
    else {
        Write-Host "No infraOnboarding.siteHierarchy found in onboarding file. Skipping target creation from hierarchy." -ForegroundColor Yellow
    }

        if ($enableWODiagnostics -or $enableContainerInsights) {
        Write-Host "Enabling diagnostics..." -ForegroundColor Yellow

        # Initialize diagInfo if not present
        if (-not $data.infraOnboarding.PSObject.Properties.Name -contains 'diagInfo') {
            $data.infraOnboarding | Add-Member -MemberType NoteProperty -Name "diagInfo" -Value @{}
        }

        # Step 0: Ensure log analytics workspace is created
        if (-not $data.infraOnboarding.diagInfo.diagnosticWorkspaceId) {
            # Create a Log Analytics workspace if not provided
            # Generate a name for the workspace
            $diagnosticsWorkspaceName = $resourceGroup + "-diag-workspace"
            # Create and get the workspace ID
            $data.infraOnboarding.diagInfo.diagnosticWorkspaceId = Create-LogAnalyticsWorkspace -resourceGroup $resourceGroup -workspaceName $diagnosticsWorkspaceName -location $arcLocation
        }

        # Ensure the workspace ID is not null
        if (-not $data.infraOnboarding.diagInfo.diagnosticWorkspaceId) {
            throw "diagnosticWorkspaceId is required for enabling diagnostics"
        }

        # Enable diagnostics if specified
        if ($enableWODiagnostics) {
            Write-Host "Enabling diagnostics..." -ForegroundColor Yellow

            # Initialize onboardingFileContent if not present
            if (-not $onboardingFileContent) {
                $onboardingFileContent = @{}
            }
            if (-not $onboardingFileContent.common) {
                $onboardingFileContent | Add-Member -MemberType NoteProperty -Name "common" -Value @{}
            }

            if (-not $onboardingFileContent.common.customLocationFile) {
                throw "onboardingFileContent.common.customLocationFile is required for enabling diagnostics"
            }

            # Step 1: Enable WO level diagnostics settings
            if ([string]::IsNullOrEmpty($data.infraOnboarding.diagInfo.diagnosticResourceName)) {
                $data.infraOnboarding.diagInfo.diagnosticResourceName = "default"
            }
            Write-Host "Enabling workload orchestration diagnostics settings..." -ForegroundColor Yellow
            $diagResourceId = New-WODiagnosticsResource `
                                -subscriptionId $subscriptionId `
                                -resourceGroup $resourceGroup `
                                -diagnosticResourceName $data.infraOnboarding.diagInfo.diagnosticResourceName `
                                -resolvedCustomLocationFile $onboardingFileContent.common.customLocationFile `
                                -location $arcLocation
            
            if ([string]::IsNullOrEmpty($data.infraOnboarding.diagInfo.diagnosticSettingName)) {
                $data.infraOnboarding.diagInfo.diagnosticSettingName = "default"
            }

            New-WODiagnosticSetting `
                                -diagnosticResourceId $diagResourceId `
                                -logAnalyticsWorkspaceId $data.infraOnboarding.diagInfo.diagnosticWorkspaceId `
                                -diagnosticSettingName $data.infraOnboarding.diagInfo.diagnosticSettingName
            Write-Host "Workload orchestration diagnostics settings enabled successfully." -ForegroundColor DarkGreen
        }

        if ($enableContainerInsights) {
            Write-Host "Enabling Container Insights..." -ForegroundColor Yellow
            # Step 2: Install Container Insights on the Arc cluster
            Install-ContainerInsights -resourceGroup $resourceGroup -arcClusterName $aksClusterName -logAnalyticsWorkspaceId $data.infraOnboarding.diagInfo.diagnosticWorkspaceId

            Write-Host "Container Insights installed successfully." -ForegroundColor DarkGreen
        }

        Write-Host "Diagnostics enabled successfully." -ForegroundColor DarkGreen
    }
    
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    $ErrorActionPreference = "Continue"
    exit 1
}