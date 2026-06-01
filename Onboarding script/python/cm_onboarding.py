#!/usr/bin/env python3
"""CM (Configuration Manager) onboarding script - Python equivalent of cm_onboarding.ps1."""

import argparse
import json
import os
import subprocess
import sys

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

# On Windows cmd.exe, single quotes are NOT string delimiters; use double quotes.
Q = '"' if sys.platform == "win32" else "'"

# ---------------------------------------------------------------------------
# Core command runner
# ---------------------------------------------------------------------------
def run_az(command: str, check: bool = True) -> str:
    """Run a shell command, return stdout. Raise on non-zero if *check*."""
    print_gray(f"Executing: {command}")
    result = subprocess.run(command, shell=True, capture_output=True, text=True)
    if result.returncode != 0 and check:
        raise RuntimeError(f"Command failed: {command}\nstderr: {result.stderr}")
    out = (result.stdout or "")
    # Strip UTF-8 BOM that az CLI may emit on Windows
    bom = chr(0xFEFF)
    if out.startswith(bom):
        out = out[len(bom):]
    return out.strip()

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="CM onboarding script")
    parser.add_argument("onboarding_file", help="Path to the onboarding JSON file (e.g. mock-data.json)")
    parser.add_argument("--skip-resource-group-creation", action="store_true", default=False)
    args = parser.parse_args()

    # Resolve onboarding file path relative to CWD
    onboarding_file = os.path.abspath(args.onboarding_file)
    with open(onboarding_file, "r", encoding="utf-8-sig") as f:
        data = json.load(f)

    common = data.get("common", {})
    cm_data = data.get("cmOnboarding", {})
    if not cm_data:
        print_red("cmOnboarding section is required in the onboarding file")
        sys.exit(1)

    # Resolve resourceGroup (cmOnboarding takes precedence, then common)
    resource_group = cm_data.get("resourceGroup") or common.get("resourceGroup")
    if not resource_group:
        print_red("Resource group is required in the onboarding file")
        sys.exit(1)

    # Resolve subscriptionId
    subscription_id = cm_data.get("subscriptionId") or common.get("subscriptionId")
    if not subscription_id:
        print_red("Subscription ID is required in the onboarding file")
        sys.exit(1)

    # Resolve location
    location = cm_data.get("location") or common.get("location")
    if not location:
        print_yellow("Location is not specified. Defaulting to eastus.")
        location = "eastus"

    print_green("Configuration Manager Onboarding")
    print_green(f"  Resource Group:   {resource_group}")
    print_green(f"  Subscription ID:  {subscription_id}")
    print_green(f"  Location:         {location}")

    # --- Resource Group creation ---
    if not args.skip_resource_group_creation:
        print_green(f"Creating resource group {resource_group}...")
        try:
            run_az(f"az group create --name {resource_group} --location {location}")
        except RuntimeError:
            print_yellow("Resource group creation failed or already exists. Continuing...")

    # --- Schemas ---
    for schema in cm_data.get("schemas", []):
        s_name = schema["name"]
        s_version = schema["version"]
        s_file = schema["schemaFile"]

        print_green(f"Creating schema: {s_name}")
        cmd = (
            f"az workload-orchestration schema create"
            f" --resource-group {Q}{resource_group}{Q}"
            f" --subscription {Q}{subscription_id}{Q}"
            f" --schema-name {Q}{s_name}{Q}"
            f" --version {Q}{s_version}{Q}"
            f" --schema-file {Q}{s_file}{Q}"
            f" --location {Q}{location}{Q}"
        )
        print_green(f"Executing: {cmd}")
        run_az(cmd)

    # --- Config Templates ---
    for config in cm_data.get("configs", []):
        c_name = config["name"]
        c_version = config["versionName"]
        c_file = config["configFile"]

        print_green(f"Creating config-template: {c_name}")
        cmd = (
            f"az workload-orchestration config-template create"
            f" --config-template-name {Q}{c_name}{Q}"
            f" --description {Q}This is {c_name} Configuration{Q}"
            f" --configuration-template-file {Q}{c_file}{Q}"
            f" --version {Q}{c_version}{Q}"
            f" --resource-group {Q}{resource_group}{Q}"
            f" --location {Q}{location}{Q}"
            f" --subscription {Q}{subscription_id}{Q}"
        )
        print_green(f"Executing: {cmd}")
        run_az(cmd)

    # --- Solutions ---
    for solution in cm_data.get("solutions", []):
        sol_name = solution["name"]
        sol_desc = solution.get("description", "")
        sol_version = solution["version"]
        sol_template = solution["solutionTemplate"]
        sol_spec_file = solution.get("specificationFile", "")
        sol_caps = solution.get("capabilities", [])

        print_green(f"Creating solution: {sol_name}")
        print_yellow(f"capabilities: {sol_caps}")

        # Build capabilities parameter
        if not sol_caps:
            caps_param = f'{Q}{Q}'
        elif len(sol_caps) == 1:
            caps_param = f"{Q}{sol_caps[0]}{Q}"
        else:
            caps_param = Q + json.dumps(sol_caps, separators=(",", ":")) + Q

        cmd = (
            f"az workload-orchestration solution-template create"
            f" --solution-template-name {Q}{sol_name}{Q}"
            f" --description {Q}{sol_desc}{Q}"
            f" --capabilities {caps_param}"
            f" --configuration-template-file {Q}{sol_template}{Q}"
        )
        if sol_spec_file:
            cmd += f" --specification {Q}@{sol_spec_file}{Q}"
        cmd += (
            f" --resource-group {Q}{resource_group}{Q}"
            f" --location {Q}{location}{Q}"
            f" --version {Q}{sol_version}{Q}"
            f" --subscription {Q}{subscription_id}{Q}"
        )
        print_green(f"Executing: {cmd}")
        run_az(cmd)

    print_green("Configuration Manager onboarding completed successfully!")


if __name__ == "__main__":
    main()