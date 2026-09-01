# Deploy AIO infrastructor components

This folder contains everything you need to deploy a **Mongo Db community server** instance
— referred to as **mongo db setup** — onto an **Arc enabled K8s cluster** cluster using Azure
**Workload Orchestration** (the `Microsoft.Edge` provider) and a single, consolidated Bicep template.

You do **not** need to read the Bicep source to deploy. This README gives you the exact commands,
the order to run them in, and a full description of every parameter.

---

## 1. What gets deployed

The deployment provisions Mongo Db community server:

| # | Resource | Purpose |
|---|----------|---------|
| 1 | **mongo db**  | Mongo db server |



These are packaged as a Workload Orchestration **Edge Target → Solution Template → Solution
Deployment** (`mongodb-setup.bicep`)

---

## 2. Files in this folder

| File | Description |
|------|-------------|
| `k8s/mongodb-setup.bicep` | **Entry point.** Deploys the Workload Orchestration Edge Target, Solution Template (+version) and Solution Deployment. This is what you deploy. |
| `k8s/mongodb-setup.bicepparam` | Parameter file for `mongodb-setup.bicep` |
| `k8s/mongodb-community-0.1.0.tgz` | The helm chart of mongodb server which needs to be pushed to Azure Container Registry |
---

## 3. Prerequisites

Before you start, make sure you have:

- **Azure CLI** installed, with the Bicep tooling:
  ```powershell
  az --version
  az bicep install
  ```
- **Sign in and select your subscription**
```powershell
az login
az account set --subscription "<your-subscription-id>"
```
- **Permissions** to create resources in the target subscription/resource group and to publish
  a template spec.
- An **ARC enable K8s cluster** that is Arc-enabled Kubernetes cluster
- An **Azure Container Registry** to store mongodb helm chart
   ```
- Push mongodb-community-0.1.0.tgz to ACR
  ```powershell
  // Makesure docker desktop is running
  az acr login --name <acrname>
  helm push mongodb-community-0.1.0.tgz oci://<acrname>.azurecr.io/helm
  ```
  ---

## 4. Step-by-step deployment

### Step 1 — Update mongodb-setup.bicepparam with necessary values

### Step 2 — deploy mongodb-setup.bicep
```powershell
az deployment group create --name <name> --subscription <subid> --resource-group <rg name> --template-file mongodb-setup.bicep --parameters mongodb-setup.bicepparam
```
### Step 3 — Verify
#### 1. Install kubectl (if you have not installed already)
```powershel
az aks install-cli 
kubectl version --client
```
#### 2. Get the pod
```powershell
kubectl get pods  mongo-db-mongodb-community-0 
``` 
---
