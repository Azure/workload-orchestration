<#
.SYNOPSIS
    Provisions the namespace-isolation external validator on Azure.

.DESCRIPTION
    Builds the container image in ACR and deploys a container-based Azure Function App
    (Event Grid triggered). Uses managed identity for ACR pull and grants the identity
    AcrPull + Reader. Mirrors the manual steps used to stand up the original test.

.NOTES
    Requires: az CLI logged in. Elastic Premium (EP) plans need VM quota in the chosen
    region; if quota is 0, pick another region or use Azure Container Apps.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = "nsvalidator-rg",
    [string]$AcrName       = "nsvalidatoracr",         # ACR names: alphanumeric only, 5-50 chars, globally unique
    [string]$Location      = "eastus2",                # ACR + storage region
    [string]$PlanLocation  = "centralus",              # Function plan region (EP quota-dependent)
    [string]$PlanName      = "nsvalidator-plan",
    [string]$FunctionApp   = "nsvalidator-func",
    [string]$Image         = "namespace-validator:latest"
)

$ErrorActionPreference = "Stop"
$env:PYTHONIOENCODING = "utf-8"

$storage = "nsvalidatorsa" + (Get-Random -Minimum 1000 -Maximum 9999)
$acrLogin = "$AcrName.azurecr.io"

Write-Host "==> Resource group $ResourceGroup ($Location)"
az group create --name $ResourceGroup --location $Location -o none

Write-Host "==> ACR $AcrName"
az acr create --resource-group $ResourceGroup --name $AcrName --sku Basic --admin-enabled false -o none

Write-Host "==> Building image $Image in ACR (server-side)"
Push-Location "$PSScriptRoot/namespace-validator"
az acr build -r $AcrName -t $Image .
Pop-Location

Write-Host "==> Storage account $storage"
az storage account create --name $storage --resource-group $ResourceGroup --location $Location --sku Standard_LRS -o none

Write-Host "==> Elastic Premium plan $PlanName ($PlanLocation)"
az functionapp plan create --name $PlanName --resource-group $ResourceGroup --location $PlanLocation --sku EP1 --is-linux -o none

Write-Host "==> Function App $FunctionApp"
az functionapp create --name $FunctionApp --resource-group $ResourceGroup --storage-account $storage `
    --plan $PlanName `
    --image "$acrLogin/$Image" `
    --registry-server $acrLogin `
    --assign-identity "[system]" `
    --functions-version 4 -o none

Write-Host "==> Granting managed identity AcrPull + Reader"
$principal = az functionapp identity show -n $FunctionApp -g $ResourceGroup --query principalId -o tsv
$acrId = az acr show -n $AcrName --query id -o tsv
$rgId  = az group show -n $ResourceGroup --query id -o tsv
az role assignment create --assignee-object-id $principal --assignee-principal-type ServicePrincipal --role AcrPull --scope $acrId -o none
az role assignment create --assignee-object-id $principal --assignee-principal-type ServicePrincipal --role Reader  --scope $rgId  -o none

Write-Host "==> Enabling managed-identity image pull"
$appId = az functionapp show -n $FunctionApp -g $ResourceGroup --query id -o tsv
az resource update --ids "$appId/config/web" --set properties.acrUseManagedIdentityCreds=true -o none
az functionapp config container set -n $FunctionApp -g $ResourceGroup --image "$acrLogin/$Image" --registry-server "https://$acrLogin" -o none

Write-Host "==> App settings"
# AZURE_TENANT_ID is required by the ACR OAuth2 token exchange (helm registry login).
$tenantId = az account show --query tenantId -o tsv
az functionapp config appsettings set -n $FunctionApp -g $ResourceGroup --settings `
    HELM_TIMEOUT_SECONDS=45 `
    AZURE_TENANT_ID=$tenantId -o none

az functionapp restart -n $FunctionApp -g $ResourceGroup
Write-Host "==> Done. Host: https://$FunctionApp.azurewebsites.net"
Write-Host "    Next: create an Event Grid subscription from your Context topic to this function."
