param(
    [Parameter(Mandatory=$true)]
    [Alias("rg")]
    [string]$resourceGroupName,
    [Parameter(Mandatory=$true)]
     [Alias("sub")]
    [string]$subscriptionId
)
$output = az rest --method GET --uri "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Edge/workflows?api-version=2025-08-15-preview"
 $jsonResult = $output | ConvertFrom-Json
 if ($jsonResult.value.Count -eq 0) {
    Write-Output "No workflows found in resource group: $resourceGroupName"
 } else {
    foreach ($workflow in $jsonResult.value) {
        $workflowId = $workflow.id
        $uri =  $workflowId+"?api-version=2025-08-15-preview";
        Write-Output "Deleting workflow with ID: $workflowId"
        az rest --method DELETE --uri "$uri"
    }
}