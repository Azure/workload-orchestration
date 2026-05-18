# This script is used to create sites and relationships in Azure based on the provided JSON data.
    
$DryRun = $false
$baseSGURL = "https://eastus2euap.management.azure.com";
    
function Invoke-AzCommand {
    param (
        [string]$command
    )
    
    if ($DryRun -eq $false) {
        $result = Invoke-Expression $command
    }
    else {
        Write-Host "Skipping resource creation for Dry Run" -ForegroundColor DarkGray
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $command"
    }
    return $result
}

# Function to invoke web request and poll Azure-Async operation
function Invoke-WebRequestWithPolling {
    param (
        [string]$uri,
        [string]$method = "GET",
        [string]$body
    )
    Write-Host "##[debug] Invoking web request $uri" -ForegroundColor Green
    $authToken = (az account get-access-token | ConvertFrom-Json).accessToken
    try {
        # Perform the POST request using Invoke-WebRequest
        $response = Invoke-WebRequest -Uri "$uri" -Method $method -Headers @{ "Authorization" = "Bearer $authToken" } -Body $body -ContentType 'application/json' -UseBasicParsing
    }
    catch {
        Write-Host "##[debug] Error: $_" -ForegroundColor Red
        Write-Host "##[debug] An error occurred while executing $uri" -ForegroundColor Red
        exit 1
    }

    $azureAsyncOperation = $response.Headers["Azure-AsyncOperation"]
    if ($null -eq $azureAsyncOperation -or $azureAsyncOperation -eq "") {
    $body = $response -split "\r\n\r\n", 2 | Select-Object -Last 1
        Write-Host "##[debug] Error: $body" -ForegroundColor Yellow
        Write-Host "##[debug] An error occurred while executing $uri" -ForegroundColor Yellow
        return
    }
    Write-Host "##[debug] Waiting for request to complete for AzureAsyncOperation" -ForegroundColor Yellow
    $status = (curl.exe -s -H "Authorization: Bearer $authToken" "$azureAsyncOperation" | ConvertFrom-Json).status
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($status -ne "Succeeded") {
        Start-Sleep -Seconds 5
        $status = (curl.exe -s -H "Authorization: Bearer $authToken" "$azureAsyncOperation" | ConvertFrom-Json).status
        Write-Host "##[debug] Elapsed time: $($timer.Elapsed.TotalSeconds) seconds, Status: $status" -ForegroundColor Yellow
        if ($timer.Elapsed.TotalSeconds -gt 30 -or $status -eq "Failed") {
            Write-Host "##[debug] Request is taking too long or failing, skipping it, please check manually for ARMID: $uri" -ForegroundColor Yellow
            Write-Host "##[debug] To know failure reason, try GET on this AzureAsyncOperation: $azureAsyncOperation" -ForegroundColor Yellow
            $timer.Stop()
            return
        }
    }
    $timer.Stop()
    Write-Host "##[debug] Elapsed time: $($timer.Elapsed.TotalSeconds) seconds, Status: $status" -ForegroundColor Yellow
        
}
    
#Validate properties 

function Validate-SiteHierarchy {
    param (
        [array]$siteHierarchy
    )
    $globalHashSet = @{}
    foreach ($siteObj in $siteHierarchy) {
        Write-Host "Validating site: $($siteObj.siteName)" -ForegroundColor Yellow
        foreach ($member in $siteObj.siteMembers) {
            if ($globalHashSet.ContainsKey($member)) {
                throw "Duplicate site member found : $($member) , in site '$($siteObj.siteName)' and site '$($globalHashSet[$member])'"
            }
            $globalHashSet[$member] = $siteObj.siteName
        }
    }
}


#Resource creation
function Create-SitesAndRelationships {
    param (
        [object]$data,
        [string]$resourceGroup,
        [bool]$skipSiteCreation,
        [bool]$skipRelationshipCreation
    )
    Write-Host "Creating sites and relationships..." -ForegroundColor Yellow

    $subscriptionId = $data.common.subscriptionId
    $tenant_id = az account list --query "[?isDefault].tenantId | [0]" --output tsv
    foreach ($siteObj in $data.infraOnboarding.siteHierarchy) {
        # read siteName from infraOnboarding or assign default value if not present
        $siteName = $siteObj.siteName
        $siteLevel = $siteObj.level
        if (-not $siteName) {
            $siteName = $resourceGroup + "-Site"
        }

        $isRGSite = $siteObj.isRGSite -eq $true

        # Create Site.
        if (-not $skipSiteCreation) {
            $siteBody = "{'properties':{'displayName':'$siteName','description':'$siteName', 'labels': { 'level': '${siteLevel}'} }}"

            if ($isRGSite) {
                # Resource Group-based site: no Service Group, no parent
                Write-Host "Creating RG-based Site $siteName..." -ForegroundColor Yellow
                $rgSiteUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Edge/sites/$siteName`?api-version=2025-03-01-preview"
                try {
                    Invoke-AzCommand "az rest --method GET --url '$rgSiteUri' --resource https://management.azure.com"
                    Write-Host "Site $siteName already exists. Skipping creation." -ForegroundColor Yellow
                }
                catch {
                    Invoke-AzCommand "az rest --method PUT --url '$rgSiteUri' --body `"$siteBody`" --resource https://management.azure.com"
                    Write-Host "Created RG-based Site $siteName" -ForegroundColor DarkGreen
                }
                Write-Host "ARM ID : /subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Edge/sites/$siteName" -ForegroundColor DarkGreen
            }
            else {
                # Service Group-based site: create SG then site under it
                # read parent and assign default value if not present
                $siteParent = $siteObj.parentSite
                if (-not $siteParent) {
                    $siteParent = "/providers/Microsoft.Management/serviceGroups/$tenant_id"
                }
                else {
                    $siteParent = "/providers/Microsoft.Management/serviceGroups/$siteParent"
                }

                # Create Service Group
                Write-Host "Creating Service Group $siteName..." -ForegroundColor Yellow
                $body = 
                @{
                    properties = @{
                        displayName = $siteName
                        parent      = @{
                            resourceId = $siteParent
                        }
                    }
                } | ConvertTo-Json
                $uri = "$baseSGURL/providers/Microsoft.Management/serviceGroups/$siteName`?api-version=2024-02-01-preview"
                Invoke-WebRequestWithPolling -uri $uri -method "PUT" -body $body

                Write-Host "Created Service Group $siteName" -ForegroundColor DarkGreen
                Write-Host "ARM ID : /providers/Microsoft.Management/serviceGroups/$siteName" -ForegroundColor DarkGreen

                # Wait for Service Group provisioning to propagate before creating site
                Write-Host "Waiting 5 seconds for Service Group provisioning to propagate..." -ForegroundColor Yellow
                Start-Sleep -Seconds 5

                # Create Site (skip if already exists)
                Write-Host "Creating Site $siteName..." -ForegroundColor Yellow
                try {
                    Invoke-AzCommand "az rest --method GET --uri '$baseSGURL/providers/Microsoft.Management/serviceGroups/$siteName/providers/Microsoft.Edge/sites/$siteName`?api-version=2025-03-01-preview' --resource https://management.azure.com"
                    Write-Host "Site $siteName already exists. Skipping creation." -ForegroundColor Yellow
                }
                catch {
                    Invoke-AzCommand "az rest --method PUT --uri '$baseSGURL/providers/Microsoft.Management/serviceGroups/$siteName/providers/Microsoft.Edge/sites/$siteName`?api-version=2025-03-01-preview' --body `"$siteBody`" --resource https://management.azure.com"
                    Write-Host "Created Site $siteName" -ForegroundColor DarkGreen
                }
                Write-Host "ARM ID : /providers/Microsoft.Management/serviceGroups/$siteName/providers/Microsoft.Edge/sites/$siteName" -ForegroundColor DarkGreen
            }
        }

           
    }
}

function Create-Relationship {
    param (
        [string]$siteName,
        [string]$member)

    Write-Host "Creating relationship for $siteName..." -ForegroundColor Yellow
    Invoke-AzCommand "az rest --method PUT --uri '$member/providers/Microsoft.Relationships/serviceGroupMember/$siteName`?api-version=2023-09-01-preview' --body `"{'properties':{ 'targetId': '/providers/Microsoft.Management/serviceGroups/$siteName'}}`" --resource https://management.azure.com"
    Write-Host "Created relationship for $siteName" -ForegroundColor DarkGreen
    Write-Host "ARM ID : $baseSGURL/$member/providers/Microsoft.Relationships/serviceGroupMember/$siteName" -ForegroundColor DarkGreen
}
       
function Test-ValidateAndCreate {
    $data = Get-Content -Path mock-data.json -Raw | ConvertFrom-Json
    Validate-SiteHierarchy -siteHierarchy $data.infraOnboarding.siteHierarchy

    $resourceGroup = $data.infraOnboarding.resourceGroup
    $baseSGURL = "https://eastus2euap.management.azure.com";
    $skipResourceCreation = $False

    $DryRun = $true
    $startTime = Get-Date
    Create-SitesAndRelationships -data $data -resourceGroup $resourceGroup -baseSGURL $baseSGURL -skipSiteCreation $skipResourceCreation -skipRelationshipCreation $skipResourceCreation
    $endTime = Get-Date
    $timeTaken = ($endTime - $startTime).TotalMinutes
    Write-Host "Time taken: $timeTaken minutes" -ForegroundColor Cyan

}