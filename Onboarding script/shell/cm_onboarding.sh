#!/usr/bin/env bash
# CM (Configuration Manager) onboarding script - Bash equivalent of cm_onboarding.ps1
set -euo pipefail

# Prevent MSYS/Git Bash from converting /subscriptions/... and /providers/...
# arguments to Windows paths (e.g. C:/Program Files/Git/subscriptions/...)
export MSYS2_ARG_CONV_EXCL="/subscriptions/;/providers/"

# -----------------------------------------------------------------------
# Resolve script directory and set up jq
# -----------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Try to find jq - check script dir, parent tools dir, then PATH
TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$SCRIPT_DIR/jq.exe" ]]; then
    JQ="$SCRIPT_DIR/jq.exe"
elif [[ -f "$TOOLS_DIR/jq.exe" ]]; then
    JQ="$TOOLS_DIR/jq.exe"
elif command -v jq &>/dev/null; then
    JQ="jq"
else
    echo "ERROR: jq is required but not found. Place jq.exe in $SCRIPT_DIR or $TOOLS_DIR or install it on PATH."
    exit 1
fi
export JQ

# -----------------------------------------------------------------------
# Colour helpers
# -----------------------------------------------------------------------
print_green()  { echo -e "\033[32m$*\033[0m"; }
print_yellow() { echo -e "\033[33m$*\033[0m"; }
print_red()    { echo -e "\033[31m$*\033[0m"; }
print_cyan()   { echo -e "\033[36m$*\033[0m"; }
print_gray()   { echo -e "\033[90m$*\033[0m"; }

# -----------------------------------------------------------------------
# Core command runner
# -----------------------------------------------------------------------
RUN_AZ_OUT=""

run_az() {
    local cmd="$1"
    local check="${2:-true}"
    RUN_AZ_OUT=""
    print_gray "Executing: $cmd"
    local output
    if output=$(eval "$cmd" 2>&1); then
        # Strip UTF-8 BOM if present
        output="${output#$'\xef\xbb\xbf'}"
        RUN_AZ_OUT="$output"
        return 0
    else
        local rc=$?
        output="${output#$'\xef\xbb\xbf'}"
        RUN_AZ_OUT="$output"
        if [[ "$check" == "true" ]]; then
            print_red "Command failed (exit $rc): $cmd"
            print_red "$output"
            return $rc
        fi
        return $rc
    fi
}

# -----------------------------------------------------------------------
# Convert Windows backslash paths to forward-slash for Git Bash
# -----------------------------------------------------------------------
win_to_unix_path() {
    local p="$1"
    p="${p//\\//}"
    if [[ "$p" =~ ^([A-Za-z]):/(.*) ]]; then
        local drive="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}"
        drive=$(echo "$drive" | tr '[:upper:]' '[:lower:]')
        p="/$drive/$rest"
    fi
    echo "$p"
}

# -----------------------------------------------------------------------
# Default flag values
# -----------------------------------------------------------------------
SKIP_RESOURCE_GROUP_CREATION=false
ONBOARDING_FILE=""

# -----------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------
usage() {
    echo "Usage: $0 <onboarding_file.json> [options]"
    echo "Options:"
    echo "  --skip-resource-group-creation   Skip creating the resource group"
    echo "  --help, -h                       Show this help"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-resource-group-creation) SKIP_RESOURCE_GROUP_CREATION=true; shift ;;
        --help|-h)                      usage ;;
        -*)                             echo "Unknown option: $1"; usage ;;
        *)
            if [[ -z "$ONBOARDING_FILE" ]]; then
                ONBOARDING_FILE="$1"
            else
                echo "Unexpected argument: $1"; usage
            fi
            shift ;;
    esac
done

if [[ -z "$ONBOARDING_FILE" ]]; then
    echo "ERROR: onboarding file is required."
    usage
fi

# Resolve the onboarding file path
if [[ ! "$ONBOARDING_FILE" = /* ]]; then
    ONBOARDING_FILE="$(pwd)/$ONBOARDING_FILE"
fi

# Strip UTF-8 BOM if present and parse
DATA=$("$JQ" '.' "$ONBOARDING_FILE") || {
    DATA=$(sed '1s/^//' "$ONBOARDING_FILE" | "$JQ" '.')
}

# -----------------------------------------------------------------------
# Helper: read a JSON field from DATA
# -----------------------------------------------------------------------
jq_data() {
    echo "$DATA" | "$JQ" -r "$1"
}

# -----------------------------------------------------------------------
# Extract common and cmOnboarding sections
# -----------------------------------------------------------------------
COMMON=$(echo "$DATA" | "$JQ" '.common // {}')
CM_DATA=$(echo "$DATA" | "$JQ" '.cmOnboarding // {}')

if [[ "$CM_DATA" == "{}" || "$CM_DATA" == "null" ]]; then
    print_red "cmOnboarding section is required in the onboarding file"
    exit 1
fi

# Resolve resourceGroup (cmOnboarding takes precedence, then common)
RESOURCE_GROUP=$(echo "$CM_DATA" | "$JQ" -r '.resourceGroup // empty')
if [[ -z "$RESOURCE_GROUP" ]]; then
    RESOURCE_GROUP=$(echo "$COMMON" | "$JQ" -r '.resourceGroup // empty')
fi
if [[ -z "$RESOURCE_GROUP" ]]; then
    print_red "Resource group is required in the onboarding file"
    exit 1
fi

# Resolve subscriptionId
SUBSCRIPTION_ID=$(echo "$CM_DATA" | "$JQ" -r '.subscriptionId // empty')
if [[ -z "$SUBSCRIPTION_ID" ]]; then
    SUBSCRIPTION_ID=$(echo "$COMMON" | "$JQ" -r '.subscriptionId // empty')
fi
if [[ -z "$SUBSCRIPTION_ID" ]]; then
    print_red "Subscription ID is required in the onboarding file"
    exit 1
fi

# Resolve location
LOCATION=$(echo "$CM_DATA" | "$JQ" -r '.location // empty')
if [[ -z "$LOCATION" ]]; then
    LOCATION=$(echo "$COMMON" | "$JQ" -r '.location // empty')
fi
if [[ -z "$LOCATION" ]]; then
    print_yellow "Location is not specified. Defaulting to eastus."
    LOCATION="eastus"
fi

CUSTOM_LOCATION_FILE=$(echo "$COMMON" | "$JQ" -r '.customLocationFile // empty')

print_green "Configuration Manager Onboarding"
print_green "  Resource Group:   $RESOURCE_GROUP"
print_green "  Subscription ID:  $SUBSCRIPTION_ID"
print_green "  Location:         $LOCATION"

# -----------------------------------------------------------------------
# Resource Group creation
# -----------------------------------------------------------------------
if [[ "$SKIP_RESOURCE_GROUP_CREATION" != "true" ]]; then
    print_green "Creating resource group $RESOURCE_GROUP..."
    if ! run_az "az group create --name $RESOURCE_GROUP --location $LOCATION"; then
        print_yellow "Resource group creation failed or already exists. Continuing..."
    fi
fi

# -----------------------------------------------------------------------
# Schemas
# -----------------------------------------------------------------------
SCHEMA_COUNT=$(echo "$CM_DATA" | "$JQ" '.schemas // [] | length')
for (( i=0; i<SCHEMA_COUNT; i++ )); do
    SCHEMA=$(echo "$CM_DATA" | "$JQ" ".schemas[$i]")
    S_NAME=$(echo "$SCHEMA" | "$JQ" -r '.name')
    S_VERSION=$(echo "$SCHEMA" | "$JQ" -r '.version')
    S_FILE=$(echo "$SCHEMA" | "$JQ" -r '.schemaFile')

    # Convert Windows paths for Git Bash
    S_FILE_UNIX=$(win_to_unix_path "$S_FILE")

    print_green "Creating schema: $S_NAME"
    SCHEMA_CMD="az workload-orchestration schema create"
    SCHEMA_CMD+=" --resource-group '$RESOURCE_GROUP'"
    SCHEMA_CMD+=" --subscription '$SUBSCRIPTION_ID'"
    SCHEMA_CMD+=" --schema-name '$S_NAME'"
    SCHEMA_CMD+=" --version '$S_VERSION'"
    SCHEMA_CMD+=" --schema-file '$S_FILE_UNIX'"
    SCHEMA_CMD+=" --location '$LOCATION'"

    print_green "Executing: $SCHEMA_CMD"
    run_az "$SCHEMA_CMD"
done

# -----------------------------------------------------------------------
# Config Templates
# -----------------------------------------------------------------------
CONFIG_COUNT=$(echo "$CM_DATA" | "$JQ" '.configs // [] | length')
for (( i=0; i<CONFIG_COUNT; i++ )); do
    CONFIG=$(echo "$CM_DATA" | "$JQ" ".configs[$i]")
    C_NAME=$(echo "$CONFIG" | "$JQ" -r '.name')
    C_VERSION=$(echo "$CONFIG" | "$JQ" -r '.versionName')
    C_FILE=$(echo "$CONFIG" | "$JQ" -r '.configFile')

    # Convert Windows paths for Git Bash
    C_FILE_UNIX=$(win_to_unix_path "$C_FILE")

    print_green "Creating config-template: $C_NAME"
    CONFIG_CMD="az workload-orchestration config-template create"
    CONFIG_CMD+=" --config-template-name '$C_NAME'"
    CONFIG_CMD+=" --description 'This is $C_NAME Configuration'"
    CONFIG_CMD+=" --configuration-template-file '$C_FILE_UNIX'"
    CONFIG_CMD+=" --version '$C_VERSION'"
    CONFIG_CMD+=" --resource-group '$RESOURCE_GROUP'"
    CONFIG_CMD+=" --location '$LOCATION'"
    CONFIG_CMD+=" --subscription '$SUBSCRIPTION_ID'"

    print_green "Executing: $CONFIG_CMD"
    run_az "$CONFIG_CMD"
done

# -----------------------------------------------------------------------
# Solutions
# -----------------------------------------------------------------------
SOLUTION_COUNT=$(echo "$CM_DATA" | "$JQ" '.solutions // [] | length')
for (( i=0; i<SOLUTION_COUNT; i++ )); do
    SOLUTION=$(echo "$CM_DATA" | "$JQ" ".solutions[$i]")
    SOL_NAME=$(echo "$SOLUTION" | "$JQ" -r '.name')
    SOL_DESC=$(echo "$SOLUTION" | "$JQ" -r '.description // ""')
    SOL_VERSION=$(echo "$SOLUTION" | "$JQ" -r '.version')
    SOL_CONFIG_TEMPLATE=$(echo "$SOLUTION" | "$JQ" -r '.solutionTemplate')
    SOL_SPEC_FILE=$(echo "$SOLUTION" | "$JQ" -r '.specificationFile // empty')
    SOL_CAPS=$(echo "$SOLUTION" | "$JQ" '.capabilities // []')

    # Convert Windows paths for Git Bash
    SOL_CONFIG_TEMPLATE_UNIX=$(win_to_unix_path "$SOL_CONFIG_TEMPLATE")
    if [[ -n "$SOL_SPEC_FILE" ]]; then
        SOL_SPEC_FILE_UNIX=$(win_to_unix_path "$SOL_SPEC_FILE")
    else
        SOL_SPEC_FILE_UNIX=""
    fi

    print_green "Creating solution: $SOL_NAME"

    # Build capabilities parameter
    CAPS_LEN=$(echo "$SOL_CAPS" | "$JQ" 'length')
    print_yellow "capabilities: $SOL_CAPS"
    if [[ "$CAPS_LEN" -eq 0 ]]; then
        CAPS_PARAM='""'
    elif [[ "$CAPS_LEN" -eq 1 ]]; then
        SINGLE_CAP=$(echo "$SOL_CAPS" | "$JQ" -r '.[0]')
        CAPS_PARAM="'$SINGLE_CAP'"
    else
        CAPS_PARAM="'$(echo "$SOL_CAPS" | "$JQ" -c '.')'"
    fi

    SOLUTION_CMD="az workload-orchestration solution-template create"
    SOLUTION_CMD+=" --solution-template-name '$SOL_NAME'"
    SOLUTION_CMD+=" --description '$SOL_DESC'"
    SOLUTION_CMD+=" --capabilities $CAPS_PARAM"
    SOLUTION_CMD+=" --configuration-template-file '$SOL_CONFIG_TEMPLATE_UNIX'"
    if [[ -n "$SOL_SPEC_FILE_UNIX" ]]; then
        SOLUTION_CMD+=" --specification '@$SOL_SPEC_FILE_UNIX'"
    fi
    SOLUTION_CMD+=" --resource-group '$RESOURCE_GROUP'"
    SOLUTION_CMD+=" --location '$LOCATION'"
    SOLUTION_CMD+=" --version '$SOL_VERSION'"
    SOLUTION_CMD+=" --subscription '$SUBSCRIPTION_ID'"

    print_green "Executing: $SOLUTION_CMD"
    run_az "$SOLUTION_CMD"
done

print_green "Configuration Manager onboarding completed successfully!"