#!/usr/bin/env python3
"""Infrastructure onboarding script - Python equivalent of infra_onboarding.ps1."""

import argparse
import json
import os
import random
import re
import shutil
import string
import subprocess
import sys
import time

# Ensure the tools directory is on the path so we can import the helper
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from site_onboarding_helper import (
    validate_site_hierarchy,
    create_sites_and_relationships,
    create_relationship,
)

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
def _c(code: int, msg: str) -> str:
    return f"\033[{code}m{msg}\033[0m"

def print_green(msg):   print(_c(32, msg))
def print_yellow(msg):  print(_c(33, msg))
def print_red(msg):     print(_c(31, msg))
def print_cyan(msg):    print(_c(36, msg))
def print_gray(msg):    print(_c(90, msg))
def print_dgreen(msg):  print(_c(32, msg))   # dark-green approximation

# On Windows cmd.exe, single quotes are NOT string delimiters; use double quotes.
Q = '"' if sys.platform == "win32" else "'"

def _extended_location_shorthand(file_path: str) -> str:
    """Read an extended-location JSON file and return az CLI shorthand syntax.

    The file is expected to contain {"name": "...", "type": "..."}.
    Returns: name="..." type="..."  (quoted for the current platform)
    """
    with open(file_path, "r", encoding="utf-8-sig") as fh:
        el = json.load(fh)
    name_val = el.get("name", "")
    type_val = el.get("type", "CustomLocation")
    return f'name={Q}{name_val}{Q} type={Q}{type_val}{Q}'

# ---------------------------------------------------------------------------
# Core command runner
# ---------------------------------------------------------------------------
def run_az(command: str, check: bool = True) -> str:
    """Run a shell command, return stdout. Raise on non-zero if *check*.
    Automatically retries on HTTP 429 throttling errors."""
    max_retries = 3
    for attempt in range(1, max_retries + 1):
        result = subprocess.run(command, shell=True, capture_output=True, text=True)
        if result.returncode != 0 and check:
            stderr_lower = result.stderr.lower()
            if "(429)" in result.stderr and "throttled" in stderr_lower and attempt < max_retries:
                # Extract retry-after hint if available, default to 5 seconds
                import re as _re
                m = _re.search(r'retry after (\d+)', stderr_lower)
                wait = int(m.group(1)) if m else 5
                print_yellow(f"Throttled (429). Retrying in {wait}s... (attempt {attempt}/{max_retries})")
                time.sleep(wait)
                continue
            raise RuntimeError(f"Command failed: {command}\nstderr: {result.stderr}")
        out = (result.stdout or "")
        # Strip UTF-8 BOM that az CLI may emit on Windows
        bom = chr(0xFEFF)
        if out.startswith(bom):
            out = out[len(bom):]
        return out.strip()
    # Should not reach here, but just in case
    out = (result.stdout or "")
    bom = chr(0xFEFF)
    if out.startswith(bom):
        out = out[len(bom):]
    return out.strip()

def run_az_json(command: str, check: bool = True):
    """Run a command and parse the JSON output."""
    out = run_az(command, check=check)
    if not out:
        return None
    return json.loads(out)

# ---------------------------------------------------------------------------
# WO extension installer (uses list-based subprocess for proper empty-string handling)
# ---------------------------------------------------------------------------
def _install_wo_extension(resource_group: str, cluster_name: str, extension_name: str):
    """Install the workload-orchestration k8s extension.
    Wraps empty storageClass value in double quotes for Windows CMD compatibility."""
    cmd = (
        f'az k8s-extension create'
        f' --resource-group {resource_group}'
        f' --cluster-name {cluster_name}'
        f' --cluster-type connectedClusters'
        f' --name {extension_name}'
        f' --extension-type Microsoft.workloadorchestration'
        f' --scope cluster'
        f' --config "redis.persistentVolume.storageClass="'
        f' --config redis.persistentVolume.size=20Gi'
    )
    print_gray(f"Executing: {cmd}")
    return run_az(cmd)

# ---------------------------------------------------------------------------
# VM SKU helpers
# ---------------------------------------------------------------------------
def get_non_arm_vm_skus(subscription_id: str, location: str) -> list:
    query = "[?capabilities[?name=='CpuArchitectureType' && value!='Arm64']].{name:name, family:family, memoryGB:join(', ', capabilities[?name=='MemoryGB'].value), vCPUsAvailable:join(', ', capabilities[?name=='vCPUsAvailable'].value), location:locations}"
    cmd = f'az vm list-skus --location "{location}" --resource-type virtualMachines --subscription "{subscription_id}" --query "{query}" --output json'
    return run_az_json(cmd) or []

def get_vm_usage_quota(subscription_id: str, location: str) -> list:
    cmd = f'az vm list-usage --location "{location}" --subscription "{subscription_id}" --output json'
    return run_az_json(cmd) or []

def test_sku_for_aks(sku: dict, required_vcpus: int, required_memory_gb: int) -> dict:
    vcpus = float(str(sku.get("vCPUsAvailable", "0")).split(",")[0].strip())
    memory = float(str(sku.get("memoryGB", "0")).split(",")[0].strip())
    return {
        "IsSuitable": vcpus >= required_vcpus and memory >= required_memory_gb,
        "VCPUs": vcpus,
        "MemoryGB": memory,
    }

def find_suitable_vm_for_aks(subscription_id, location, required_vcpus=2, required_memory_gb=4, node_count=1):
    print_green("Finding suitable non-ARM VM SKUs for AKS...")
    skus = get_non_arm_vm_skus(subscription_id, location)
    usage = get_vm_usage_quota(subscription_id, location)
    usage_map = {u["name"]["value"]: u for u in usage}

    suitable = []
    for sku in skus:
        t = test_sku_for_aks(sku, required_vcpus, required_memory_gb)
        if t["IsSuitable"]:
            qi = usage_map.get(sku.get("family"))
            if qi:
                avail = int(qi["limit"]) - int(qi["currentValue"])
                if avail >= node_count * required_vcpus:
                    suitable.append({
                        "Name": sku["name"], "Family": sku["family"],
                        "VCPUs": t["VCPUs"], "MemoryGB": t["MemoryGB"],
                        "AvailableQuota": avail, "CurrentUsage": qi["currentValue"],
                        "Limit": qi["limit"], "Sku": sku,
                    })
    suitable.sort(key=lambda s: (s["VCPUs"], s["MemoryGB"]))
    print_green(f"Suitable SKUs: {len(suitable)}")
    for s in suitable[:5]:
        print_green(f"  {s['Name']:20s} {s['Family']:25s} vcpus={s['VCPUs']} mem={s['MemoryGB']}GB avail={s['AvailableQuota']}")
    return suitable

# ---------------------------------------------------------------------------
# AKS cluster creation
# ---------------------------------------------------------------------------
def create_aks_cluster(subscription_id, location, rg, cluster_name, identity=None, required_vcpus=2, required_memory_gb=4, node_count=1):
    print_green("Creating AKS cluster with non-ARM nodes...")
    suitable = find_suitable_vm_for_aks(subscription_id, location, required_vcpus, required_memory_gb, node_count)
    if not suitable:
        raise RuntimeError("No suitable non-ARM VM SKUs found that meet the requirements and have available quota.")
    sel = suitable[0]
    print_yellow(f"Selected VM SKU: {sel['Name']} (vCPUs: {sel['VCPUs']}, Memory: {sel['MemoryGB']}GB)")
    print_yellow(f"Available quota: {sel['AvailableQuota']} vCPUs")

    # Check if cluster already exists
    try:
        existing = run_az(f'az aks show --resource-group "{rg}" --name "{cluster_name}" --subscription "{subscription_id}" --output json')
        if existing:
            print_yellow(f"AKS cluster '{cluster_name}' already exists. Skipping creation.")
            return existing
    except RuntimeError:
        print_green(f"AKS cluster '{cluster_name}' not found. Proceeding with creation.")

    cmd = f'az aks create --resource-group "{rg}" --name "{cluster_name}" --location "{location}" --subscription "{subscription_id}" --node-vm-size "{sel["Name"]}" --node-count {node_count} --generate-ssh-keys'
    if identity:
        cmd += f' --assign-identity "{identity}"'
    print_green("Executing AKS creation command...")
    print_gray(f"Command: {cmd}")
    result = run_az(cmd)
    print_green(f"AKS cluster '{cluster_name}' created successfully!")
    return result

# ---------------------------------------------------------------------------
# Diagnostics helpers
# ---------------------------------------------------------------------------
def create_log_analytics_workspace(rg, workspace_name, location=None):
    print_yellow(f"Creating Log Analytics Workspace {workspace_name}...")
    cmd = f"az monitor log-analytics workspace create --resource-group {rg} --workspace-name {workspace_name} --sku PerGB2018"
    if location:
        cmd += f" --location {location}"
    run_az(cmd)
    print_dgreen(f"Created Log Analytics Workspace {workspace_name}")
    ws_id = run_az(f"az monitor log-analytics workspace show --resource-group {rg} --workspace-name {workspace_name} --query id -o tsv")
    print_dgreen(f"Log Analytics Workspace ID: {ws_id}")
    return ws_id

def create_wo_diagnostics_resource(subscription_id, rg, diag_name, custom_loc_file, location):
    print_yellow(f"Creating WODiagnostics Resource with name {diag_name}...")
    el_shorthand = _extended_location_shorthand(custom_loc_file)
    cmd = (
        f"az workload-orchestration diagnostic create "
        f"--resource-group {rg} --location {location} --subscription {subscription_id} "
        f"--name {Q}{diag_name}{Q} --extended-location {el_shorthand}"
    )
    print_yellow(f"Executing: {cmd}")
    run_az(cmd)
    print_dgreen(f"Created WODiagnostics Resource with name {diag_name}")
    return run_az(f"az workload-orchestration diagnostic show --subscription {subscription_id} --resource-group {rg} --name {diag_name} --query id -o tsv")

def create_wo_diagnostic_setting(diag_resource_id, workspace_id, setting_name="default"):
    print_yellow(f"Creating Diagnostic Setting for {diag_resource_id}...")
    logs = '[{"category":"UserAudits","enabled":true},{"category":"UserDiagnostics","enabled":true}]'
    cmd = f"az monitor diagnostic-settings create --resource {diag_resource_id} --workspace {workspace_id} --name {setting_name} --logs '{logs}'"
    run_az(cmd)
    print_dgreen(f"Created Diagnostic Setting for {diag_resource_id}")

def install_container_insights(rg, arc_cluster, workspace_id):
    print_yellow(f"Installing Microsoft.AzureMonitor.Containers extension on arc cluster: {arc_cluster}")
    cmd = (
        f"az k8s-extension create --name azuremonitor-containers --cluster-name {arc_cluster} "
        f"--resource-group {rg} --cluster-type connectedClusters --extension-type Microsoft.AzureMonitor.Containers "
        f"--configuration-settings logAnalyticsWorkspaceResourceID={workspace_id}"
    )
    run_az(cmd)
    print_dgreen(f"Installed Microsoft.AzureMonitor.Containers extension on arc cluster: {arc_cluster}")

# ---------------------------------------------------------------------------
# ACR helpers
# ---------------------------------------------------------------------------
def acr_image_exists(acr_name, image_name):
    try:
        out = run_az_json(f"az acr repository show-manifests --name {acr_name} --repository {image_name}")
        return bool(out)
    except RuntimeError:
        return False

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Infrastructure onboarding script")
    parser.add_argument("onboarding_file", help="Path to the onboarding JSON file (e.g. mock-data.json)")
    parser.add_argument("--skip-az-login", action="store_true", default=True)
    parser.add_argument("--no-skip-az-login", dest="skip_az_login", action="store_false")
    parser.add_argument("--skip-az-extensions", action="store_true", default=False)
    parser.add_argument("--skip-resource-group-creation", action="store_true", default=False)
    parser.add_argument("--skip-aks-creation", action="store_true", default=False)
    parser.add_argument("--skip-tco-deployment", action="store_true", default=False)
    parser.add_argument("--skip-custom-location-creation", action="store_true", default=False)
    parser.add_argument("--skip-connected-registry-deployment", action="store_true", default=True)
    parser.add_argument("--no-skip-connected-registry-deployment", dest="skip_connected_registry_deployment", action="store_false")
    parser.add_argument("--skip-site-creation", action="store_true", default=False)
    parser.add_argument("--skip-auto-parsing", action="store_true", default=False)
    parser.add_argument("--skip-relationship-creation", action="store_true", default=False)
    parser.add_argument("--enable-wo-diagnostics", action="store_true", default=False)
    parser.add_argument("--enable-container-insights", action="store_true", default=False)
    args = parser.parse_args()

    # Resolve onboarding file path relative to CWD
    onboarding_file = os.path.abspath(args.onboarding_file)
    with open(onboarding_file, "r", encoding="utf-8-sig") as f:
        data = json.load(f)

    auto_extracted_file_path = os.path.join(os.getcwd(), "autoExtractedCustomLocation.json")

    try:
        # --- Azure login ---
        if not args.skip_az_login:
            print_yellow("Logging in to Azure...")
            run_az("az login")
        else:
            print_gray("Skipping Azure login.")

        # --- Az extensions ---
        if not args.skip_az_extensions:
            print_yellow("Installing/updating az extensions...")
            run_az("az extension add --name connectedk8s")
            run_az("az extension add --name k8s-extension")
            run_az("az extension add --name customlocation")
            run_az("az extension update --name connectedk8s")
            run_az("az extension update --name k8s-extension")
            run_az("az extension update --name customlocation")

        # --- Validate required fields ---
        infra = data.get("infraOnboarding")
        common = data.get("common", {})
        if not infra:
            raise RuntimeError("infraOnboarding section is required in the input file")

        subscription_id = common.get("subscriptionId") or infra.get("subscriptionId")
        if not subscription_id:
            raise RuntimeError("SubscriptionId is required for infraOnboarding")

        resource_group = common.get("resourceGroup") or infra.get("resourceGroup")
        if not resource_group:
            raise RuntimeError("ResourceGroup is required for infraOnboarding")

        location = common.get("location") or infra.get("location") or "eastus"
        if not common.get("location") and not infra.get("location"):
            print_yellow("Location is not specified. Defaulting to eastus.")

        arc_location = infra.get("arcLocation") or "eastus"
        extension_name = "symphonytest"

        run_az(f"az account set --subscription {subscription_id}")

        # --- Resource group ---
        if not args.skip_resource_group_creation:
            run_az(f"az group create --location {location} --name {resource_group}")

        # --- Workload-orchestration CLI extension ---
        print_yellow("Installing workload-orchestration extension...")
        try:
            run_az("az extension remove --name workload-orchestration")
        except RuntimeError:
            print_gray("workload-orchestration extension not found, continuing...")
        run_az("az extension add --name workload-orchestration")
        print_dgreen("Installed workload-orchestration extension")

        # --- AKS cluster ---
        aks_cluster_name = infra.get("aksClusterName") or f"{resource_group}-Cluster"
        if not args.skip_aks_creation:
            aks_identity_name = infra.get("aksClusterIdentity") or f"{resource_group}-Cluster-Identity"
            # Create identity if it doesn't exist
            try:
                run_az(f"az identity show --resource-group {resource_group} --name {aks_identity_name} --query id -o tsv")
                print_yellow(f"Managed identity '{aks_identity_name}' already exists. Skipping creation.")
            except RuntimeError:
                run_az(f"az identity create --resource-group {resource_group} --name {aks_identity_name}")

            aks_identity_id = run_az(f"az identity show --resource-group {resource_group} --name {aks_identity_name} --query id --output tsv")
            print_yellow(f"Selecting non-arm vm size to create aks cluster {aks_cluster_name}...")
            create_aks_cluster(subscription_id, location, resource_group, aks_cluster_name, identity=aks_identity_id, required_vcpus=2, required_memory_gb=7, node_count=2)
            print_dgreen(f"Created aks cluster {aks_cluster_name}")

        # --- Deploy TCO onto AKS ---
        if not args.skip_tco_deployment:
            run_az(f"az aks get-credentials --resource-group {resource_group} --name {aks_cluster_name} --overwrite-existing")

            # Arc connect
            arc_connected = False
            try:
                arc_status = run_az(f"az connectedk8s show -g {resource_group} -n {aks_cluster_name} --query connectivityStatus -o tsv")
                if arc_status.strip().strip('"') == "Connected":
                    print_yellow(f"Cluster '{aks_cluster_name}' is already Arc-connected. Skipping connect.")
                    arc_connected = True
            except RuntimeError:
                print_yellow(f"Cluster '{aks_cluster_name}' is not Arc-connected. Connecting...")
            if not arc_connected:
                run_az(f"az connectedk8s connect -g {resource_group} -n {aks_cluster_name} --location {arc_location}")

            # Resolve Custom Location RP OID for enable-features
            # Try from config first, then Azure AD lookup, then fall back to well-known Microsoft tenant OID
            custom_location_oid = infra.get("customLocationOid")
            if not custom_location_oid:
                print_yellow("Attempting to resolve Custom Location RP OID from Azure AD...")
                try:
                    custom_location_oid = run_az("az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv")
                    if custom_location_oid:
                        print_green(f"Resolved Custom Location RP OID: {custom_location_oid}")
                except RuntimeError:
                    print_yellow("Could not resolve Custom Location RP OID via Azure AD (insufficient privileges). Will use well-known default OID as fallback.")
                    custom_location_oid = "51dfe1e8-70c6-4de5-a08e-e18aff23d815"
                    print_yellow(f"Using default Custom Location RP OID: {custom_location_oid}")

            # Enable features with retry
            print_yellow("Enabling cluster-connect and custom-locations features (this may take several minutes)...")
            max_retries = 5
            retry_delay = 60
            success = False
            cmd = f"az connectedk8s enable-features -n {aks_cluster_name} -g {resource_group} --features cluster-connect custom-locations"
            if custom_location_oid:
                cmd += f' --custom-locations-oid "{custom_location_oid}"'
            for attempt in range(1, max_retries + 1):
                try:
                    run_az(cmd)
                    success = True
                    break
                except RuntimeError as e:
                    if attempt < max_retries and "another operation" in str(e).lower() and "is in progress" in str(e).lower():
                        print_yellow(f"Attempt {attempt}/{max_retries} failed: another Helm operation is in progress. Retrying in {retry_delay}s...")
                        time.sleep(retry_delay)
                    else:
                        raise
            if not success:
                raise RuntimeError(f"Failed to enable features after {max_retries} attempts.")

            run_az(f"az account set --subscription {subscription_id}")

            # cert-manager
            print_yellow("Installing cert-manager...")
            try:
                state = run_az(f"az k8s-extension show --resource-group {resource_group} --cluster-name {aks_cluster_name} --name aio-certmgr --cluster-type connectedClusters --query provisioningState -o tsv")
                state = state.strip().strip('"')
                if state == "Succeeded":
                    print_yellow(f"cert-manager extension already installed (state: {state}). Skipping.")
                elif state in ("Failed", "Canceled"):
                    print_yellow(f"cert-manager extension is in a failed state (state: {state}). Attempting reinstallation.")
                    run_az(f"az k8s-extension delete --resource-group {resource_group} --cluster-name {aks_cluster_name} --name aio-certmgr --cluster-type connectedClusters --yes")
                    run_az(f"az k8s-extension create --resource-group {resource_group} --cluster-name {aks_cluster_name} --name aio-certmgr --cluster-type connectedClusters --extension-type microsoft.iotoperations.platform --scope cluster --release-namespace cert-manager")
                    print_dgreen("Successfully reinstalled cert-manager")
            except RuntimeError:
                run_az(f"az k8s-extension create --resource-group {resource_group} --cluster-name {aks_cluster_name} --name aio-certmgr --cluster-type connectedClusters --extension-type microsoft.iotoperations.platform --scope cluster --release-namespace cert-manager")
                print_dgreen("Successfully installed cert-manager")

            # Workload orchestration k8s extension
            print_yellow("Installing workload orchestration extension...")
            try:
                state = run_az(f"az k8s-extension show --resource-group {resource_group} --cluster-name {aks_cluster_name} --name {extension_name} --cluster-type connectedClusters --query provisioningState -o tsv")
                state = state.strip().strip('"')
                if state == "Succeeded":
                    print_yellow(f"Workload orchestration extension already installed (state: {state}). Skipping.")
                elif state in ("Failed", "Canceled"):
                    print_yellow(f"Workload orchestration extension is in a failed state (state: {state}). Attempting reinstallation.")
                    run_az(f"az k8s-extension delete --resource-group {resource_group} --cluster-name {aks_cluster_name} --name {extension_name} --cluster-type connectedClusters --yes")
                    _install_wo_extension(resource_group, aks_cluster_name, extension_name)
                    print_dgreen("Successfully reinstalled workload orchestration extension")
            except RuntimeError:
                _install_wo_extension(resource_group, aks_cluster_name, extension_name)
                print_dgreen("Successfully installed workload orchestration extension")

        # --- Custom Location ---
        custom_location_name = infra.get("customLocationName") or f"{resource_group}-Location"
        custom_location_namespace = infra.get("customLocationNamespace") or "mehoopany"

        onboarding_file_content = None  # will be populated if auto-parsing runs

        if not args.skip_custom_location_creation:
            print_yellow(f"Creating custom location {custom_location_name}...")
            arc_cluster_id = f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/Microsoft.Kubernetes/connectedClusters/{aks_cluster_name}"
            extension_id = f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/Microsoft.Kubernetes/connectedClusters/{aks_cluster_name}/providers/Microsoft.KubernetesConfiguration/extensions/{extension_name}"

            cluster_extension_ids = []
            try:
                run_az(f"az customlocation show --name {custom_location_name} --resource-group {resource_group} --query id -o tsv")
                existing_ids = run_az_json(f"az customlocation show --name {custom_location_name} --resource-group {resource_group} --query clusterExtensionIds -o json") or []
                cluster_extension_ids = list(existing_ids)
                if extension_id not in cluster_extension_ids:
                    cluster_extension_ids.append(extension_id)
            except RuntimeError:
                print_yellow(f"Custom location {custom_location_name} does not exist. Creating a new one.")
                cluster_extension_ids = [extension_id]

            ids_param = " ".join(cluster_extension_ids)
            cl_cmd = f'az customlocation create -n {custom_location_name} -g {resource_group} --namespace {custom_location_namespace} --host-resource-id "{arc_cluster_id}" --cluster-extension-ids {ids_param} --location {arc_location}'
            print_yellow(f"Executing: {cl_cmd}")

            # Try creating the custom location; if it fails with UnauthorizedNamespaceError,
            # re-enable custom-locations feature with the OID and retry
            try:
                cl_output = run_az(cl_cmd)
            except RuntimeError as e:
                if "UnauthorizedNamespaceError" in str(e):
                    print_yellow("Custom location creation failed with UnauthorizedNamespaceError. Re-enabling custom-locations feature with OID...")
                    if not custom_location_oid:
                        try:
                            custom_location_oid = run_az("az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv")
                        except RuntimeError:
                            custom_location_oid = "51dfe1e8-70c6-4de5-a08e-e18aff23d815"
                    print_yellow(f"Using Custom Location RP OID: {custom_location_oid}")
                    run_az(f'az connectedk8s enable-features -n {aks_cluster_name} -g {resource_group} --features cluster-connect custom-locations --custom-locations-oid "{custom_location_oid}"')
                    print_yellow("Retrying custom location creation...")
                    cl_output = run_az(cl_cmd)
                else:
                    raise

            if not args.skip_auto_parsing:
                try:
                    cl_json = json.loads(cl_output)
                    cl_id = cl_json.get("id")
                    if not cl_id:
                        raise RuntimeError("Failed to extract 'id' from custom location creation output.")

                    auto_content = {"name": cl_id, "type": "CustomLocation"}
                    with open(auto_extracted_file_path, "w", encoding="utf-8") as f:
                        json.dump(auto_content, f, indent=2)

                    with open(onboarding_file, "r", encoding="utf-8-sig") as f:
                        onboarding_file_content = json.load(f)
                    onboarding_file_content.setdefault("common", {})["customLocationFile"] = auto_extracted_file_path
                    with open(onboarding_file, "w", encoding="utf-8") as f:
                        json.dump(onboarding_file_content, f, indent=2)

                    print_dgreen(f"Created {auto_extracted_file_path} and updated {onboarding_file} with customLocationFile: {auto_extracted_file_path}")
                except Exception as e:
                    print_red(f"An error occurred while processing custom location output: {e}")
                    raise

            print_dgreen(f"Successfully created Custom Location: {custom_location_name}")

        # --- Connected Registry ---
        if not args.skip_connected_registry_deployment:
            acr_name = infra.get("acrName")
            if not acr_name:
                acr_name = "acrstaging" + "".join(random.choices(string.ascii_lowercase, k=4))

            print_yellow(f"Checking if ACR {acr_name} already exists in resource group {resource_group}...")
            try:
                existing_acr = run_az_json(f"az acr show --name {acr_name} --resource-group {resource_group}")
                print_green(f"ACR {acr_name} already exists in resource group {resource_group}")
                if existing_acr.get("sku", {}).get("name") == "Premium":
                    print_green(f"ACR {acr_name} is already Premium SKU")
                else:
                    print_yellow(f"ACR {acr_name} is {existing_acr.get('sku',{}).get('name')} SKU, upgrading to Premium...")
                    run_az(f"az acr update --name {acr_name} --resource-group {resource_group} --sku Premium")
                if existing_acr.get("dataEndpointEnabled"):
                    print_green(f"Data endpoint is already enabled for ACR {acr_name}")
                else:
                    print_yellow(f"Enabling data endpoint for ACR {acr_name}...")
                    run_az(f"az acr update --name {acr_name} --resource-group {resource_group} --data-endpoint-enabled")
            except RuntimeError:
                print_yellow(f"ACR {acr_name} does not exist, validating name...")
                name_check = run_az_json(f"az acr check-name --name {acr_name}")
                if not name_check.get("nameAvailable"):
                    raise RuntimeError(f"ACR name {acr_name} is not available: {name_check.get('message')}")
                run_az(f"az acr create --resource-group {resource_group} --name {acr_name} --sku Premium")
                run_az(f"az acr update --name {acr_name} --resource-group {resource_group} --data-endpoint-enabled")
                print_green(f"Successfully created ACR {acr_name} with Premium SKU")

            if acr_image_exists(acr_name, "tmp/hello-world"):
                print_green(f"Image tmp/hello-world already exists in ACR {acr_name}")
            else:
                print_yellow("Image tmp/hello-world does not exist, importing...")
                run_az(f"az acr import --name {acr_name} --source mcr.microsoft.com/hello-world:latest --image tmp/hello-world:latest")

            conn_reg_name = infra.get("connectedRegistryName")
            if not conn_reg_name:
                conn_reg_name = "conected" + "".join(random.choices(string.ascii_lowercase + string.digits, k=4))

            conn_exists = False
            try:
                st = run_az(f"az acr connected-registry show --registry {acr_name} --name {conn_reg_name} --query connectionState -o tsv")
                if st:
                    print_yellow(f"Connected registry '{conn_reg_name}' already exists (state: {st}). Skipping creation.")
                    conn_exists = True
            except RuntimeError:
                print_yellow(f"Connected registry '{conn_reg_name}' does not exist. Creating...")
            if not conn_exists:
                run_az(f"az acr connected-registry create --registry {acr_name} --name {conn_reg_name} --repository tmp/hello-world --mode ReadOnly --log-level Debug --yes")
                print_dgreen(f"Successfully created connected registry: {conn_reg_name}")
            run_az(f"az acr connected-registry list --registry {acr_name} --output table")

            conn_str = run_az(f"az acr connected-registry get-settings --name {conn_reg_name} --registry {acr_name} --parent-protocol https --generate-password 1 --query ACR_REGISTRY_CONNECTION_STRING --subscription {subscription_id} --output tsv --yes")
            conn_str = conn_str.replace("\r", "")
            if not conn_str:
                raise RuntimeError(f"Failed to retrieve connection string for connected registry {conn_reg_name}")
            with open("protected-settings-extension.json", "w") as f:
                json.dump({"connectionString": conn_str}, f)
            print("Wrote connection registry connection string to protected-settings-extension.json")

            conn_reg_ip = infra.get("connectedRegistryIp")
            if not conn_reg_ip:
                raise RuntimeError("connected Registry IP is required for ConnectedRegistryDeployment")
            storage_size = infra.get("storageSizeRequest") or "250Gi"

            print_yellow("Installing connected registry extension...")
            try:
                ext_state = run_az(f"az k8s-extension show --cluster-name {aks_cluster_name} --cluster-type connectedClusters --name {conn_reg_name} --resource-group {resource_group} --query provisioningState -o tsv")
                if ext_state:
                    print_yellow(f"Connected registry extension already installed (state: {ext_state}). Skipping.")
            except RuntimeError:
                run_az(f"az k8s-extension create --cluster-name {aks_cluster_name} --cluster-type connectedClusters --extension-type Microsoft.ContainerRegistry.ConnectedRegistry --name {conn_reg_name} --resource-group {resource_group} --config service.clusterIP={conn_reg_ip} --config pvc.storageRequest={storage_size} --config cert-manager.install=false --config-protected-file protected-settings-extension.json")
                print_dgreen("Successfully installed connected registry extension.")

            print_yellow("Creating client token for connected registry...")
            try:
                run_az(f"az acr scope-map show --name all-repos-read --registry {acr_name} --query name -o tsv")
                print_yellow("Scope-map 'all-repos-read' already exists. Skipping creation.")
            except RuntimeError:
                run_az(f"az acr scope-map create --name all-repos-read --registry {acr_name} --repository '*' content/read metadata/read --description 'Scope map for pulling from ACR.'")

            client_token_name = "all-repos-pull-token"
            token_exists = False
            try:
                et = run_az(f"az acr token show --name {client_token_name} --registry {acr_name} --query name -o tsv")
                if et:
                    print_yellow(f"Token '{client_token_name}' already exists. Regenerating password.")
                    token_exists = True
            except RuntimeError:
                print_yellow(f"Token '{client_token_name}' does not exist. Creating...")

            if not token_exists:
                tok_out = run_az_json(f'az acr token create --name {client_token_name} --registry {acr_name} --scope-map all-repos-read')
                client_token_value = tok_out["credentials"]["passwords"][0]["value"]
            else:
                tok_out = run_az_json(f"az acr token credential generate --name {client_token_name} --registry {acr_name} --password1")
                client_token_value = tok_out["passwords"][0]["value"]

            run_az(f"az acr connected-registry update --name {conn_reg_name} --registry {acr_name} --add-client-token {client_token_name}")
            secret_name = infra.get("connectedRegistryClientToken") or "acr-client-token"

            print_yellow("Validate kubectl...")
            if not shutil.which("kubectl"):
                print_yellow("kubectl not found. Please install kubectl manually.")
            else:
                print_green("kubectl is already installed.")
            # Idempotent secret creation
            run_az(f"kubectl create secret generic {secret_name} --from-literal=username={client_token_name} --from-literal=password={client_token_value} -n {custom_location_namespace} --dry-run=client -o yaml | kubectl apply -f -")

        # ---------------------------------------------------------------
        # Site hierarchy & deployment targets
        # ---------------------------------------------------------------
        site_hierarchy = infra.get("siteHierarchy")
        if infra and site_hierarchy:
            print_green("Processing Site Hierarchy...")
            validate_site_hierarchy(site_hierarchy)
            create_sites_and_relationships(
                data, common.get("resourceGroup", resource_group),
                skip_site_creation=False,
                skip_relationship_creation=args.skip_relationship_creation,
            )

            print_green("Processing Site Hierarchy for Deployment Targets...")
            context_id = ""

            for site_node in site_hierarchy:
                capability_list = site_node.get("capabilityList")
                if capability_list:
                    print_green("Setting up capabilities")
                    context_sub = infra.get("contextSubscriptionId") or common.get("subscriptionId")
                    context_rg = infra.get("contextResourceGroup") or "Mehoopany"
                    context_name = infra.get("contextName") or "Mehoopany-Context"
                    context_location = infra.get("contextLocation") or "eastus2euap"
                    context_id = f"/subscriptions/{context_sub}/resourceGroups/{context_rg}/providers/Microsoft.Edge/contexts/{context_name}"
                    print_yellow(f"Using context: {context_name} in resource group: {context_rg}, subscription: {context_sub}, location: {context_location}")

                    context_exists = False
                    context = None
                    try:
                        ctx_out = run_az(f"az workload-orchestration context show --subscription {context_sub} --resource-group {context_rg} --name {context_name}", check=False)
                        if ctx_out:
                            context = json.loads(ctx_out)
                            context_exists = True
                    except Exception:
                        context_exists = False

                    if context_exists and context:
                        print_yellow("Updating existing context with new capabilities")
                        new_caps = [{"description": c, "name": c} for c in capability_list.get("capabilities", [])]
                        existing_caps = context.get("properties", {}).get("capabilities", [])
                        all_caps = existing_caps + new_caps
                        # De-duplicate by name
                        seen = set()
                        unique_caps = []
                        for cap in all_caps:
                            if cap["name"] not in seen:
                                seen.add(cap["name"])
                                unique_caps.append({"name": cap["name"], "description": cap.get("description", cap["name"])})

                        with open("context-capabilities.json", "w") as f:
                            json.dump(unique_caps, f)

                        hierarchy_params = ""
                        hier_levels = site_node.get("hierarchyLevels", {}).get("levels", [])
                        if hier_levels:
                            print_yellow("Including hierarchy levels in context")
                            parts = []
                            for i, level in enumerate(hier_levels):
                                parts.append(f"[{i}].name={level}")
                                parts.append(f"[{i}].description={level}")
                            hierarchy_params = " --hierarchies " + " ".join(parts)

                        ctx_cmd = (
                            f"az workload-orchestration context create "
                            f"--subscription {context_sub} "
                            f"--resource-group {context_rg} "
                            f"--location {context_location} "
                            f"--name {context_name} "
                            f'--capabilities "@context-capabilities.json"'
                            f"{hierarchy_params}"
                        )
                        print_yellow(f"Executing: {ctx_cmd}")
                        run_az(ctx_cmd)
                    else:
                        print_yellow(f"Cannot find context {context_name} in resource group {context_rg}, subscription {context_sub}. Create new context via instructions.")
                        sys.exit(0)

                    print_green("Capabilities setup completed")

                    # Site reference
                    site_ref_name = site_node["siteName"]
                    # Construct the site ID based on site type
                    if site_node.get("isRGSite") is True:
                        site_id = f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/Microsoft.Edge/sites/{site_node['siteName']}"
                    else:
                        site_id = f"/providers/Microsoft.Management/serviceGroups/{site_node['siteName']}/providers/Microsoft.Edge/sites/{site_node['siteName']}"
                    print_yellow(f"Creating site reference '{site_ref_name}' for context '{context_name}'...")
                    site_ref_exists = False
                    try:
                        sr = run_az(
                            f"az workload-orchestration context site-reference show --subscription {context_sub} --resource-group {context_rg} --context-name {context_name} --name {site_ref_name} --query name -o tsv",
                            check=False,
                        )
                        if sr and sr.strip():
                            print_yellow(f"Site reference '{site_ref_name}' already exists. Skipping.")
                            site_ref_exists = True
                    except Exception:
                        pass
                    if not site_ref_exists:
                        sr_cmd = (
                            f"az workload-orchestration context site-reference create "
                            f"--subscription {context_sub} --resource-group {context_rg} "
                            f"--context-name {context_name} --name {site_ref_name} "
                            f'--site-id "{site_id}"'
                        )
                        print_yellow(f"Executing: {sr_cmd}")
                        run_az(sr_cmd)

                # Deployment targets
                dt = site_node.get("deploymentTargets")
                if dt:
                    print_cyan(f"Found deployment targets for site: {site_node['siteName']}")
                    targets = dt.get("targets", [])
                    if targets:
                        for target_info in targets:
                            t_name = target_info["name"]
                            print_cyan(f"Processing Target: {t_name}")

                            # Resolve properties with fallback
                            resolved_caps = target_info.get("capabilities") or dt.get("capabilities") or []
                            resolved_level = target_info.get("hierarchyLevel") or dt.get("hierarchyLevel")
                            resolved_rbac = target_info.get("rbac") or dt.get("rbac")
                            resolved_cl_file = target_info.get("customLocationFile") or dt.get("customLocationFile") or auto_extracted_file_path
                            resolved_spec = target_info.get("targetSpecFile") or dt.get("targetSpecFile")

                            if not resolved_spec:
                                print_yellow(f"targetSpecFile is required for target {t_name}. Skipping this target.")
                                continue

                            print_yellow(f"Target {t_name} resolved capabilities: {resolved_caps}")
                            if not resolved_caps:
                                caps_param = '""'
                            elif len(resolved_caps) == 1:
                                caps_param = f'"{resolved_caps[0]}"'
                            else:
                                caps_param = '"' + json.dumps(resolved_caps, separators=(",", ":")) + '"'

                            # Check if target exists
                            target_exists = False
                            try:
                                et = run_az(
                                    f"az workload-orchestration target show --resource-group {common.get('resourceGroup', resource_group)} --name {t_name} --subscription {common.get('subscriptionId', subscription_id)} --query name -o tsv",
                                    check=False,
                                )
                                if et and et.strip():
                                    print_yellow(f"Target '{t_name}' already exists. Skipping creation.")
                                    target_exists = True
                            except Exception:
                                pass

                            if not target_exists:
                                el_shorthand = _extended_location_shorthand(resolved_cl_file)

                                # If target spec path has spaces, copy to a temp file
                                # (az CLI @file shorthand cannot handle whitespace in paths)
                                spec_tmp = None
                                if ' ' in resolved_spec:
                                    import tempfile as _tempfile
                                    fd, spec_tmp = _tempfile.mkstemp(suffix='.json')
                                    os.close(fd)
                                    shutil.copy2(resolved_spec, spec_tmp)
                                    spec_for_cmd = spec_tmp
                                else:
                                    spec_for_cmd = resolved_spec

                                t_cmd = (
                                    f"az workload-orchestration target create "
                                    f"--resource-group {common.get('resourceGroup', resource_group)} "
                                    f"--location {common.get('location', location)} "
                                    f"--subscription {common.get('subscriptionId', subscription_id)} "
                                    f'--name "{t_name}" '
                                    f'--display-name "{target_info.get("displayName", t_name)}" '
                                    f"--hierarchy-level {resolved_level} "
                                    f"--capabilities {caps_param} "
                                    f'--solution-scope "default" '
                                    f'--description "Target for {target_info.get("displayName", t_name)}" '
                                    f'--target-specification "@{spec_for_cmd}" '
                                    f"--extended-location {el_shorthand}"
                                    f" --context-id {context_id}"
                                )
                                print_yellow(f"Executing: {t_cmd}")
                                try:
                                    run_az(t_cmd)
                                finally:
                                    if spec_tmp and os.path.exists(spec_tmp):
                                        os.unlink(spec_tmp)

                            target_id = run_az(
                                f"az workload-orchestration target show --resource-group {common.get('resourceGroup', resource_group)} --name {t_name} --query id --output tsv"
                            )

                            # RG-based sites don't use serviceGroupMember relationships
                            if not site_node.get("isRGSite"):
                                create_relationship(site_name=site_node["siteName"], member=target_id)

                            if resolved_rbac:
                                print_green(f"Assigning RBAC role to deployment target: {t_name}")
                                try:
                                    tid_json = run_az_json(
                                        f"az workload-orchestration target show --name '{t_name}' -g {common.get('resourceGroup', resource_group)} --subscription {common.get('subscriptionId', subscription_id)} -o json"
                                    )
                                    tid = tid_json.get("id")
                                    if not tid:
                                        raise RuntimeError(f"Failed to retrieve ID for target {t_name}")
                                    run_az(f"az role assignment create --assignee {resolved_rbac['userGroup']} --role '{resolved_rbac['role']}' --scope '{tid}'")
                                    print_green("RBAC assigned successfully.")
                                except Exception as e:
                                    print_red(f"Failed to assign RBAC for target {t_name}: {e}")
                    else:
                        print_yellow(f"No 'targets' array found within deploymentTargets for site: {site_node['siteName']}")
                else:
                    print_gray(f"No deployment targets defined for site: {site_node.get('siteName')}")

            print_green("Deployment Target Creation from Site Hierarchy finished.")
        else:
            print_yellow("No infraOnboarding.siteHierarchy found in onboarding file. Skipping target creation from hierarchy.")

        # ---------------------------------------------------------------
        # Diagnostics
        # ---------------------------------------------------------------
        if args.enable_wo_diagnostics or args.enable_container_insights:
            print_yellow("Enabling diagnostics...")
            diag_info = infra.get("diagInfo", {})

            if not diag_info.get("diagnosticWorkspaceId"):
                ws_name = f"{resource_group}-diag-workspace"
                diag_info["diagnosticWorkspaceId"] = create_log_analytics_workspace(resource_group, ws_name, arc_location)

            if not diag_info.get("diagnosticWorkspaceId"):
                raise RuntimeError("diagnosticWorkspaceId is required for enabling diagnostics")

            if args.enable_wo_diagnostics:
                print_yellow("Enabling diagnostics...")
                if not onboarding_file_content:
                    with open(onboarding_file, "r") as f:
                        onboarding_file_content = json.load(f)
                cl_file = onboarding_file_content.get("common", {}).get("customLocationFile")
                if not cl_file:
                    raise RuntimeError("customLocationFile is required for enabling diagnostics")

                diag_name = diag_info.get("diagnosticResourceName") or "default"
                print_yellow("Enabling workload orchestration diagnostics settings...")
                diag_rid = create_wo_diagnostics_resource(subscription_id, resource_group, diag_name, cl_file, arc_location)
                setting_name = diag_info.get("diagnosticSettingName") or "default"
                create_wo_diagnostic_setting(diag_rid, diag_info["diagnosticWorkspaceId"], setting_name)
                print_dgreen("Workload orchestration diagnostics settings enabled successfully.")

            if args.enable_container_insights:
                print_yellow("Enabling Container Insights...")
                install_container_insights(resource_group, aks_cluster_name, diag_info["diagnosticWorkspaceId"])
                print_dgreen("Container Insights installed successfully.")

            print_dgreen("Diagnostics enabled successfully.")

    except Exception as e:
        print_red(f"An error occurred: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()