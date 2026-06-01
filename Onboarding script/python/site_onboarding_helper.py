"""Site onboarding helper - creates sites and relationships in Azure based on provided JSON data."""

import json
import subprocess
import sys
import time

BASE_SG_URL = "https://eastus2euap.management.azure.com"
DRY_RUN = False

def run_az_command(command: str, check: bool = True, capture_output: bool = True) -> str:
    """Run an az CLI command and return stdout. Raises on non-zero exit."""
    if DRY_RUN:
        print("\033[90mSkipping resource creation for Dry Run\033[0m")
        return ""
    result = subprocess.run(command, shell=True, capture_output=capture_output, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"Command failed: {command}\nstderr: {result.stderr}")
    return (result.stdout or "").strip()

def invoke_web_request_with_polling(uri: str, method: str = "GET", body: str = ""):
    """Invoke a web request and poll Azure-AsyncOperation until completion."""
    import requests as _requests

    print(f"\033[32m##[debug] Invoking web request {uri}\033[0m")
    token = json.loads(run_az_command("az account get-access-token"))["accessToken"]
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

    try:
        resp = _requests.request(method, uri, headers=headers, data=body)
        resp.raise_for_status()
    except Exception as e:
        print(f"\033[31m##[debug] Error: {e}\033[0m")
        print(f"\033[31m##[debug] An error occurred while executing {uri}\033[0m")
        sys.exit(1)

    async_op = resp.headers.get("Azure-AsyncOperation", "")
    if not async_op:
        # No async header — not fatal, just informational
        print(f"\033[33m##[debug] No Azure-AsyncOperation header in response.\033[0m")
        return

    print("\033[33m##[debug] Waiting for request to complete for AzureAsyncOperation\033[0m")
    start = time.time()
    while True:
        poll_resp = _requests.get(async_op, headers={"Authorization": f"Bearer {token}"})
        status = poll_resp.json().get("status", "Unknown")
        elapsed = time.time() - start
        print(f"\033[33m##[debug] Elapsed time: {elapsed:.1f} seconds, Status: {status}\033[0m")
        if status == "Succeeded":
            break
        if elapsed > 30 or status == "Failed":
            print(f"\033[33m##[debug] Request is taking too long or failing, skipping it, please check manually for ARMID: {uri}\033[0m")
            print(f"\033[33m##[debug] To know failure reason, try GET on this AzureAsyncOperation: {async_op}\033[0m")
            return
        time.sleep(5)

def validate_site_hierarchy(site_hierarchy: list):
    """Validate that no duplicate site members exist across sites."""
    global_hash = {}
    for site_obj in site_hierarchy:
        site_name = site_obj.get("siteName", "")
        print(f"\033[33mValidating site: {site_name}\033[0m")
        for member in site_obj.get("siteMembers", []):
            if member in global_hash:
                raise RuntimeError(
                    f"Duplicate site member found: {member}, in site '{site_name}' and site '{global_hash[member]}'"
                )
            global_hash[member] = site_name

def create_sites_and_relationships(
    data: dict,
    resource_group: str,
    skip_site_creation: bool = False,
    skip_relationship_creation: bool = False,
):
    """Create service groups, sites, and relationships."""
    print("\033[33mCreating sites and relationships...\033[0m")

    subscription_id = data.get("common", {}).get("subscriptionId", "")
    tenant_id = run_az_command(
        'az account list --query "[?isDefault].tenantId | [0]" --output tsv'
    )

    infra = data.get("infraOnboarding", {})
    for site_obj in infra.get("siteHierarchy", []):
        site_name = site_obj.get("siteName") or f"{resource_group}-Site"
        site_level = site_obj.get("level", "")
        is_rg_site = site_obj.get("isRGSite", False) is True

        if not skip_site_creation:
            site_body_dict = {
                "properties": {
                    "displayName": site_name,
                    "description": site_name,
                    "labels": {"level": site_level},
                }
            }

            if is_rg_site:
                # Resource Group-based site: no Service Group, no parent
                print(f"\033[33mCreating RG-based Site {site_name}...\033[0m")
                rg_site_uri = f"https://management.azure.com/subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/Microsoft.Edge/sites/{site_name}?api-version=2025-03-01-preview"
                try:
                    run_az_command(
                        f'az rest --method GET --url "{rg_site_uri}" --resource https://management.azure.com'
                    )
                    print(f"\033[33mSite {site_name} already exists. Skipping creation.\033[0m")
                except RuntimeError:
                    import tempfile, os
                    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, dir=".") as tf:
                        json.dump(site_body_dict, tf)
                        body_file = tf.name
                    try:
                        run_az_command(
                            f'az rest --method PUT --url "{rg_site_uri}" --body @{body_file} --resource https://management.azure.com'
                        )
                    finally:
                        try:
                            os.unlink(body_file)
                        except OSError:
                            pass
                    print(f"\033[32mCreated RG-based Site {site_name}\033[0m")
                print(
                    f"\033[32mARM ID : /subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/Microsoft.Edge/sites/{site_name}\033[0m"
                )
            else:
                # Service Group-based site: create SG then site under it
                parent_site = site_obj.get("parentSite")
                if not parent_site:
                    site_parent = f"/providers/Microsoft.Management/serviceGroups/{tenant_id}"
                else:
                    site_parent = f"/providers/Microsoft.Management/serviceGroups/{parent_site}"

                # Create Service Group
                print(f"\033[33mCreating Service Group {site_name}...\033[0m")
                body = json.dumps({
                    "properties": {
                        "displayName": site_name,
                        "parent": {"resourceId": site_parent},
                    }
                })
                uri = f"{BASE_SG_URL}/providers/Microsoft.Management/serviceGroups/{site_name}?api-version=2024-02-01-preview"
                invoke_web_request_with_polling(uri=uri, method="PUT", body=body)
                print(f"\033[32mCreated Service Group {site_name}\033[0m")
                print(f"\033[32mARM ID : /providers/Microsoft.Management/serviceGroups/{site_name}\033[0m")

                # Wait for Service Group provisioning to propagate before creating site
                print(f"\033[33mWaiting 5 seconds for Service Group provisioning to propagate...\033[0m")
                time.sleep(5)

                # Create Site (skip if already exists)
                print(f"\033[33mCreating Site {site_name}...\033[0m")
                site_uri = f"{BASE_SG_URL}/providers/Microsoft.Management/serviceGroups/{site_name}/providers/Microsoft.Edge/sites/{site_name}?api-version=2025-03-01-preview"
                try:
                    run_az_command(
                        f'az rest --method GET --uri "{site_uri}" --resource https://management.azure.com'
                    )
                    print(f"\033[33mSite {site_name} already exists. Skipping creation.\033[0m")
                except RuntimeError:
                    import tempfile, os
                    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, dir=".") as tf:
                        json.dump(site_body_dict, tf)
                        body_file = tf.name
                    try:
                        run_az_command(
                            f'az rest --method PUT --uri "{site_uri}" --body @{body_file} --resource https://management.azure.com'
                        )
                    finally:
                        try:
                            os.unlink(body_file)
                        except OSError:
                            pass
                    print(f"\033[32mCreated Site {site_name}\033[0m")

                print(
                    f"\033[32mARM ID : /providers/Microsoft.Management/serviceGroups/{site_name}/providers/Microsoft.Edge/sites/{site_name}\033[0m"
                )

def create_relationship(site_name: str, member: str):
    """Create a service group member relationship."""
    import tempfile
    import os
    print(f"\033[33mCreating relationship for {site_name}...\033[0m")
    body_dict = {"properties": {"targetId": f"/providers/Microsoft.Management/serviceGroups/{site_name}"}}
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, dir=".") as tf:
        json.dump(body_dict, tf)
        body_file = tf.name
    rel_uri = f"{member}/providers/Microsoft.Relationships/serviceGroupMember/{site_name}?api-version=2023-09-01-preview"
    try:
        run_az_command(
            f'az rest --method PUT --uri "{rel_uri}" --body @{body_file} --resource https://management.azure.com'
        )
    finally:
        try:
            os.unlink(body_file)
        except OSError:
            pass
    print(f"\033[32mCreated relationship for {site_name}\033[0m")
    print(f"\033[32mARM ID : {BASE_SG_URL}/{member}/providers/Microsoft.Relationships/serviceGroupMember/{site_name}\033[0m")