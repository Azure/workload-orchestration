#!/usr/bin/env bash
# Infrastructure onboarding script - Bash equivalent of infra_onboarding.ps1
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

# Source helper functions
source "$SCRIPT_DIR/site_onboarding_helper.sh"

# -----------------------------------------------------------------------
# Convert Windows backslash paths to forward-slash for Git Bash
# -----------------------------------------------------------------------
win_to_unix_path() {
    local p="$1"
    # Replace backslashes with forward slashes
    p="${p//\\//}"
    # Convert C:/ to /c/
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
SKIP_AZ_LOGIN=true
SKIP_AZ_EXTENSIONS=false
SKIP_RESOURCE_GROUP_CREATION=false
SKIP_AKS_CREATION=false
SKIP_TCO_DEPLOYMENT=false
SKIP_CUSTOM_LOCATION_CREATION=false
SKIP_CONNECTED_REGISTRY_DEPLOYMENT=true
SKIP_SITE_CREATION=false
SKIP_AUTO_PARSING=false
SKIP_RELATIONSHIP_CREATION=false
ENABLE_WO_DIAGNOSTICS=false
ENABLE_CONTAINER_INSIGHTS=false
ONBOARDING_FILE=""

# -----------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------
usage() {
    echo "Usage: $0 <onboarding_file.json> [options]"
    echo "Options:"
    echo "  --skip-az-login / --no-skip-az-login"
    echo "  --skip-az-extensions"
    echo "  --skip-resource-group-creation"
    echo "  --skip-aks-creation"
    echo "  --skip-tco-deployment"
    echo "  --skip-custom-location-creation"
    echo "  --skip-connected-registry-deployment / --no-skip-connected-registry-deployment"
    echo "  --skip-site-creation"
    echo "  --skip-auto-parsing"
    echo "  --skip-relationship-creation"
    echo "  --enable-wo-diagnostics"
    echo "  --enable-container-insights"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-az-login)               SKIP_AZ_LOGIN=true;  shift ;;
        --no-skip-az-login)            SKIP_AZ_LOGIN=false; shift ;;
        --skip-az-extensions)          SKIP_AZ_EXTENSIONS=true; shift ;;
        --skip-resource-group-creation) SKIP_RESOURCE_GROUP_CREATION=true; shift ;;
        --skip-aks-creation)           SKIP_AKS_CREATION=true; shift ;;
        --skip-tco-deployment)         SKIP_TCO_DEPLOYMENT=true; shift ;;
        --skip-custom-location-creation) SKIP_CUSTOM_LOCATION_CREATION=true; shift ;;
        --skip-connected-registry-deployment) SKIP_CONNECTED_REGISTRY_DEPLOYMENT=true; shift ;;
        --no-skip-connected-registry-deployment) SKIP_CONNECTED_REGISTRY_DEPLOYMENT=false; shift ;;
        --skip-site-creation)          SKIP_SITE_CREATION=true; shift ;;
        --skip-auto-parsing)           SKIP_AUTO_PARSING=true; shift ;;
        --skip-relationship-creation)  SKIP_RELATIONSHIP_CREATION=true; shift ;;
        --enable-wo-diagnostics)       ENABLE_WO_DIAGNOSTICS=true; shift ;;
        --enable-container-insights)   ENABLE_CONTAINER_INSIGHTS=true; shift ;;
        --help|-h)                     usage ;;
        -*)                            echo "Unknown option: $1"; usage ;;
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
    # If jq fails due to BOM, strip it first
    DATA=$(sed '1s/^\xEF\xBB\xBF//' "$ONBOARDING_FILE" | "$JQ" '.')
}

AUTO_EXTRACTED_FILE_PATH="$(pwd)/autoExtractedCustomLocation.json"

# -----------------------------------------------------------------------
# Helper: read a JSON field from DATA
# -----------------------------------------------------------------------
jq_data() {
    echo "$DATA" | "$JQ" -r "$1"
}

# -----------------------------------------------------------------------
# VM SKU helpers
# -----------------------------------------------------------------------
find_suitable_vm_for_aks() {
    local sub_id="$1" location="$2"
    local required_vcpus="${3:-2}" required_memory_gb="${4:-4}" node_count="${5:-1}"

    print_green "Finding suitable non-ARM VM SKUs for AKS..."

    # Write large az outputs directly to temp files to avoid shell variable size limits
    # NOTE: We skip --query because bash interprets && in JMESPath as a shell operator.
    #       Instead we fetch raw data and filter with jq.
    local skus_file usage_file
    skus_file=$(mktemp)
    usage_file=$(mktemp)
    az vm list-skus --location "$location" --resource-type virtualMachines --subscription "$sub_id" --output json 2>/dev/null | cat > "$skus_file"
    az vm list-usage --location "$location" --subscription "$sub_id" --output json 2>/dev/null | cat > "$usage_file"

    # Strip UTF-8 BOM (0xEF 0xBB 0xBF) if present - Azure CLI on Windows adds BOM
    sed -i '1s/^\xEF\xBB\xBF//' "$skus_file" "$usage_file"

    # First, filter raw SKUs to non-ARM with extracted fields (equivalent of the JMESPath query)
    local filtered_skus_file
    filtered_skus_file=$(mktemp)
    "$JQ" '[.[] | select(.capabilities[]? | .name == "CpuArchitectureType" and .value != "Arm64") | {name: .name, family: .family, memoryGB: ([.capabilities[] | select(.name == "MemoryGB") | .value] | join(", ")), vCPUsAvailable: ([.capabilities[] | select(.name == "vCPUsAvailable") | .value] | join(", "))}] | unique_by(.name)' "$skus_file" > "$filtered_skus_file"
    rm -f "$skus_file"

    local suitable
    suitable=$("$JQ" --slurpfile usage "$usage_file" \
        --argjson req_vcpu "$required_vcpus" --argjson req_mem "$required_memory_gb" --argjson nc "$node_count" '
        [.[] |
            (.vCPUsAvailable | split(",")[0] | gsub("\\s+";"") | tonumber) as $vcpu |
            (.memoryGB | split(",")[0] | gsub("\\s+";"") | tonumber) as $mem |
            select($vcpu >= $req_vcpu and $mem >= $req_mem) |
            . as $sku |
            ($usage[0] | map(select(.name.value == $sku.family)) | first // null) as $qi |
            select($qi != null) |
            (($qi.limit | tonumber) - ($qi.currentValue | tonumber)) as $avail |
            select($avail >= ($nc * $req_vcpu)) |
            {Name: .name, Family: .family, VCPUs: $vcpu, MemoryGB: $mem, AvailableQuota: $avail}
        ] | sort_by(.VCPUs, .MemoryGB)' "$filtered_skus_file")
    rm -f "$filtered_skus_file" "$usage_file"

    local count
    count=$(echo "$suitable" | "$JQ" 'length')
    print_green "Suitable SKUs: $count"

    # Print first 5
    for (( idx=0; idx<5 && idx<count; idx++ )); do
        local sname sfam svcpu smem savail
        sname=$(echo "$suitable" | "$JQ" -r ".[$idx].Name")
        sfam=$(echo "$suitable" | "$JQ" -r ".[$idx].Family")
        svcpu=$(echo "$suitable" | "$JQ" -r ".[$idx].VCPUs")
        smem=$(echo "$suitable" | "$JQ" -r ".[$idx].MemoryGB")
        savail=$(echo "$suitable" | "$JQ" -r ".[$idx].AvailableQuota")
        printf "  %-20s %-25s vcpus=%s mem=%sGB avail=%s\n" "$sname" "$sfam" "$svcpu" "$smem" "$savail"
    done

    SUITABLE_VMS="$suitable"
}

# -----------------------------------------------------------------------
# AKS cluster creation
# -----------------------------------------------------------------------
create_aks_cluster() {
    local sub_id="$1" location="$2" rg="$3" cluster_name="$4"
    local identity="${5:-}" required_vcpus="${6:-2}" required_memory_gb="${7:-4}" node_count="${8:-1}"

    print_green "Creating AKS cluster with non-ARM nodes..."
    find_suitable_vm_for_aks "$sub_id" "$location" "$required_vcpus" "$required_memory_gb" "$node_count"

    local count
    count=$(echo "$SUITABLE_VMS" | "$JQ" 'length')
    if [[ "$count" -eq 0 ]]; then
        print_red "No suitable non-ARM VM SKUs found that meet the requirements and have available quota."
        exit 1
    fi

    local sel_name sel_vcpu sel_mem sel_avail
    sel_name=$(echo "$SUITABLE_VMS" | "$JQ" -r '.[0].Name')
    sel_vcpu=$(echo "$SUITABLE_VMS" | "$JQ" -r '.[0].VCPUs')
    sel_mem=$(echo "$SUITABLE_VMS" | "$JQ" -r '.[0].MemoryGB')
    sel_avail=$(echo "$SUITABLE_VMS" | "$JQ" -r '.[0].AvailableQuota')
    print_yellow "Selected VM SKU: $sel_name (vCPUs: $sel_vcpu, Memory: ${sel_mem}GB)"
    print_yellow "Available quota: $sel_avail vCPUs"

    # Check if cluster already exists
    if run_az "az aks show --resource-group \"$rg\" --name \"$cluster_name\" --subscription \"$sub_id\" --output json" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
        print_yellow "AKS cluster '$cluster_name' already exists. Skipping creation."
        return 0
    fi
    print_green "AKS cluster '$cluster_name' not found. Proceeding with creation."

    local cmd="az aks create --resource-group \"$rg\" --name \"$cluster_name\" --location \"$location\" --subscription \"$sub_id\" --node-vm-size \"$sel_name\" --node-count $node_count --generate-ssh-keys"
    if [[ -n "$identity" ]]; then
        cmd+=" --assign-identity \"$identity\""
    fi
    print_green "Executing AKS creation command..."
    print_gray "Command: $cmd"
    run_az "$cmd"
    print_green "AKS cluster '$cluster_name' created successfully!"
}

# -----------------------------------------------------------------------
# WO extension installer
# -----------------------------------------------------------------------
install_wo_extension() {
    local rg="$1" cluster="$2" ext_name="$3"
    local cmd="az k8s-extension create --resource-group $rg --cluster-name $cluster --cluster-type connectedClusters --name $ext_name --extension-type Microsoft.workloadorchestration --scope cluster --config redis.persistentVolume.storageClass= --config redis.persistentVolume.size=20Gi"
    print_gray "Executing: $cmd"
    run_az "$cmd"
}

# -----------------------------------------------------------------------
# Diagnostics helpers
# -----------------------------------------------------------------------
create_log_analytics_workspace() {
    local rg="$1" ws_name="$2" location="${3:-}"
    print_yellow "Creating Log Analytics Workspace $ws_name..."
    local cmd="az monitor log-analytics workspace create --resource-group $rg --workspace-name $ws_name --sku PerGB2018"
    [[ -n "$location" ]] && cmd+=" --location $location"
    run_az "$cmd"
    print_green "Created Log Analytics Workspace $ws_name"
    run_az "az monitor log-analytics workspace show --resource-group $rg --workspace-name $ws_name --query id -o tsv"
    LOG_ANALYTICS_WS_ID="$RUN_AZ_OUT"
    print_green "Log Analytics Workspace ID: $LOG_ANALYTICS_WS_ID"
}

# ===================================================================
# MAIN
# ===================================================================

# --- Azure login ---
if [[ "$SKIP_AZ_LOGIN" != "true" ]]; then
    print_yellow "Logging in to Azure..."
    run_az "az login"
else
    print_gray "Skipping Azure login."
fi

# --- Az extensions ---
if [[ "$SKIP_AZ_EXTENSIONS" != "true" ]]; then
    print_yellow "Installing/updating az extensions..."
    run_az "az extension add --name connectedk8s" "false" || true
    run_az "az extension add --name k8s-extension" "false" || true
    run_az "az extension add --name customlocation" "false" || true
    run_az "az extension update --name connectedk8s" "false" || true
    run_az "az extension update --name k8s-extension" "false" || true
    run_az "az extension update --name customlocation" "false" || true
fi

# --- Validate required fields ---
SUBSCRIPTION_ID=$(jq_data '.common.subscriptionId // .infraOnboarding.subscriptionId // empty')
RESOURCE_GROUP=$(jq_data '.common.resourceGroup // .infraOnboarding.resourceGroup // empty')
LOCATION=$(jq_data '.common.location // .infraOnboarding.location // "eastus"')
ARC_LOCATION=$(jq_data '.infraOnboarding.arcLocation // "eastus"')
EXTENSION_NAME="symphonytest"

if [[ -z "$SUBSCRIPTION_ID" ]]; then
    print_red "SubscriptionId is required for infraOnboarding"; exit 1
fi
if [[ -z "$RESOURCE_GROUP" ]]; then
    print_red "ResourceGroup is required for infraOnboarding"; exit 1
fi

run_az "az account set --subscription $SUBSCRIPTION_ID"

# --- Resource group ---
if [[ "$SKIP_RESOURCE_GROUP_CREATION" != "true" ]]; then
    run_az "az group create --location $LOCATION --name $RESOURCE_GROUP"
fi

# --- Workload-orchestration CLI extension ---
print_yellow "Installing workload-orchestration extension..."
run_az "az extension remove --name workload-orchestration" "false" || true
run_az "az extension add --name workload-orchestration"
print_green "Installed workload-orchestration extension"

# --- AKS cluster ---
AKS_CLUSTER_NAME=$(jq_data '.infraOnboarding.aksClusterName // empty')
[[ -z "$AKS_CLUSTER_NAME" ]] && AKS_CLUSTER_NAME="${RESOURCE_GROUP}-Cluster"

if [[ "$SKIP_AKS_CREATION" != "true" ]]; then
    AKS_IDENTITY_NAME=$(jq_data '.infraOnboarding.aksClusterIdentity // empty')
    [[ -z "$AKS_IDENTITY_NAME" ]] && AKS_IDENTITY_NAME="${RESOURCE_GROUP}-Cluster-Identity"

    # Create identity if it doesn't exist
    if run_az "az identity show --resource-group $RESOURCE_GROUP --name $AKS_IDENTITY_NAME --query id -o tsv" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
        print_yellow "Managed identity '$AKS_IDENTITY_NAME' already exists. Skipping creation."
    else
        run_az "az identity create --resource-group $RESOURCE_GROUP --name $AKS_IDENTITY_NAME"
    fi

    run_az "az identity show --resource-group $RESOURCE_GROUP --name $AKS_IDENTITY_NAME --query id --output tsv"
    AKS_IDENTITY_ID="$RUN_AZ_OUT"
    print_yellow "Selecting non-arm vm size to create aks cluster $AKS_CLUSTER_NAME..."
    create_aks_cluster "$SUBSCRIPTION_ID" "$LOCATION" "$RESOURCE_GROUP" "$AKS_CLUSTER_NAME" "$AKS_IDENTITY_ID" 2 7 2
    print_green "Created aks cluster $AKS_CLUSTER_NAME"
fi

# --- Deploy TCO onto AKS ---
if [[ "$SKIP_TCO_DEPLOYMENT" != "true" ]]; then
    run_az "az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --overwrite-existing"

    # Arc connect
    ARC_CONNECTED=false
    if run_az "az connectedk8s show -g $RESOURCE_GROUP -n $AKS_CLUSTER_NAME --query connectivityStatus -o tsv" "false"; then
        local_status=$(echo "$RUN_AZ_OUT" | tr -d '"')
        if [[ "$local_status" == "Connected" ]]; then
            print_yellow "Cluster '$AKS_CLUSTER_NAME' is already Arc-connected. Skipping connect."
            ARC_CONNECTED=true
        fi
    fi
    if [[ "$ARC_CONNECTED" != "true" ]]; then
        print_yellow "Cluster '$AKS_CLUSTER_NAME' is not Arc-connected. Connecting..."
        run_az "az connectedk8s connect -g $RESOURCE_GROUP -n $AKS_CLUSTER_NAME --location $ARC_LOCATION"
    fi

    # Resolve Custom Location RP OID for enable-features
    # Try from config first, then Azure AD lookup, then fall back to well-known Microsoft tenant OID
    CUSTOM_LOCATION_OID=$(jq_data '.infraOnboarding.customLocationOid // empty')
    if [[ -z "$CUSTOM_LOCATION_OID" ]]; then
        print_yellow "Attempting to resolve Custom Location RP OID from Azure AD..."
        if run_az "az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
            CUSTOM_LOCATION_OID="$RUN_AZ_OUT"
            print_green "Resolved Custom Location RP OID: $CUSTOM_LOCATION_OID"
        else
            print_yellow "Could not resolve Custom Location RP OID via Azure AD (insufficient privileges). Will use well-known default OID as fallback."
            CUSTOM_LOCATION_OID="51dfe1e8-70c6-4de5-a08e-e18aff23d815"
            print_yellow "Using default Custom Location RP OID: $CUSTOM_LOCATION_OID"
        fi
    fi

    # Enable features with retry
    print_yellow "Enabling cluster-connect and custom-locations features (this may take several minutes)..."
    MAX_RETRIES=5
    RETRY_DELAY=60
    FEATURES_SUCCESS=false
    FEATURES_CMD="az connectedk8s enable-features -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP --features cluster-connect custom-locations"
    if [[ -n "$CUSTOM_LOCATION_OID" ]]; then
        FEATURES_CMD+=" --custom-locations-oid \"$CUSTOM_LOCATION_OID\""
    fi
    for (( attempt=1; attempt<=MAX_RETRIES; attempt++ )); do
        if run_az "$FEATURES_CMD" "false"; then
            FEATURES_SUCCESS=true
            break
        else
            if (( attempt < MAX_RETRIES )); then
                print_yellow "Attempt $attempt/$MAX_RETRIES failed. Retrying in ${RETRY_DELAY}s..."
                sleep "$RETRY_DELAY"
            fi
        fi
    done
    if [[ "$FEATURES_SUCCESS" != "true" ]]; then
        print_red "Failed to enable features after $MAX_RETRIES attempts."
        exit 1
    fi

    run_az "az account set --subscription $SUBSCRIPTION_ID"

    # cert-manager
    print_yellow "Installing cert-manager..."
    if run_az "az k8s-extension show --resource-group $RESOURCE_GROUP --cluster-name $AKS_CLUSTER_NAME --name aio-certmgr --cluster-type connectedClusters --query provisioningState -o tsv" "false"; then
        CERT_STATE=$(echo "$RUN_AZ_OUT" | tr -d '"')
        if [[ "$CERT_STATE" == "Succeeded" ]]; then
            print_yellow "cert-manager extension already installed (state: $CERT_STATE). Skipping."
        elif [[ "$CERT_STATE" == "Failed" || "$CERT_STATE" == "Canceled" ]]; then
            print_yellow "cert-manager extension is in a failed state (state: $CERT_STATE). Attempting reinstallation."
            run_az "az k8s-extension delete --resource-group $RESOURCE_GROUP --cluster-name $AKS_CLUSTER_NAME --name aio-certmgr --cluster-type connectedClusters --yes"
            run_az "az k8s-extension create --resource-group $RESOURCE_GROUP --cluster-name $AKS_CLUSTER_NAME --name aio-certmgr --cluster-type connectedClusters --extension-type microsoft.iotoperations.platform --scope cluster --release-namespace cert-manager"
            print_green "Successfully reinstalled cert-manager"
        fi
    else
        run_az "az k8s-extension create --resource-group $RESOURCE_GROUP --cluster-name $AKS_CLUSTER_NAME --name aio-certmgr --cluster-type connectedClusters --extension-type microsoft.iotoperations.platform --scope cluster --release-namespace cert-manager"
        print_green "Successfully installed cert-manager"
    fi

    # Workload orchestration k8s extension
    print_yellow "Installing workload orchestration extension..."
    if run_az "az k8s-extension show --resource-group $RESOURCE_GROUP --cluster-name $AKS_CLUSTER_NAME --name $EXTENSION_NAME --cluster-type connectedClusters --query provisioningState -o tsv" "false"; then
        WO_STATE=$(echo "$RUN_AZ_OUT" | tr -d '"')
        if [[ "$WO_STATE" == "Succeeded" ]]; then
            print_yellow "Workload orchestration extension already installed (state: $WO_STATE). Skipping."
        elif [[ "$WO_STATE" == "Failed" || "$WO_STATE" == "Canceled" ]]; then
            print_yellow "Workload orchestration extension is in a failed state (state: $WO_STATE). Attempting reinstallation."
            run_az "az k8s-extension delete --resource-group $RESOURCE_GROUP --cluster-name $AKS_CLUSTER_NAME --name $EXTENSION_NAME --cluster-type connectedClusters --yes"
            install_wo_extension "$RESOURCE_GROUP" "$AKS_CLUSTER_NAME" "$EXTENSION_NAME"
            print_green "Successfully reinstalled workload orchestration extension"
        fi
    else
        install_wo_extension "$RESOURCE_GROUP" "$AKS_CLUSTER_NAME" "$EXTENSION_NAME"
        print_green "Successfully installed workload orchestration extension"
    fi
fi

# --- Custom Location ---
CUSTOM_LOCATION_NAME=$(jq_data '.infraOnboarding.customLocationName // empty')
[[ -z "$CUSTOM_LOCATION_NAME" ]] && CUSTOM_LOCATION_NAME="${RESOURCE_GROUP}-Location"
CUSTOM_LOCATION_NAMESPACE=$(jq_data '.infraOnboarding.customLocationNamespace // empty')
[[ -z "$CUSTOM_LOCATION_NAMESPACE" ]] && CUSTOM_LOCATION_NAMESPACE="mehoopany"

if [[ "$SKIP_CUSTOM_LOCATION_CREATION" != "true" ]]; then
    print_yellow "Creating custom location $CUSTOM_LOCATION_NAME..."
    ARC_CLUSTER_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Kubernetes/connectedClusters/$AKS_CLUSTER_NAME"
    EXTENSION_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Kubernetes/connectedClusters/$AKS_CLUSTER_NAME/providers/Microsoft.KubernetesConfiguration/extensions/$EXTENSION_NAME"

    CLUSTER_EXT_IDS=""
    if run_az "az customlocation show --name $CUSTOM_LOCATION_NAME --resource-group $RESOURCE_GROUP --query clusterExtensionIds -o json" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
        # Check if extension_id is already in the list
        if echo "$RUN_AZ_OUT" | "$JQ" -e --arg eid "$EXTENSION_ID" 'map(select(. == $eid)) | length > 0' &>/dev/null; then
            CLUSTER_EXT_IDS="$RUN_AZ_OUT"
        else
            CLUSTER_EXT_IDS=$(echo "$RUN_AZ_OUT" | "$JQ" --arg eid "$EXTENSION_ID" '. + [$eid]')
        fi
    else
        print_yellow "Custom location $CUSTOM_LOCATION_NAME does not exist. Creating a new one."
        CLUSTER_EXT_IDS="[\"$EXTENSION_ID\"]"
    fi

    # Build space-separated list of extension IDs
    IDS_PARAM=$(echo "$CLUSTER_EXT_IDS" | "$JQ" -r '.[]' | tr '\n' ' ')

    CL_CMD="az customlocation create -n $CUSTOM_LOCATION_NAME -g $RESOURCE_GROUP --namespace $CUSTOM_LOCATION_NAMESPACE --host-resource-id \"$ARC_CLUSTER_ID\" --cluster-extension-ids $IDS_PARAM --location $ARC_LOCATION"
    print_yellow "Executing: $CL_CMD"

    # Try creating the custom location; if it fails with UnauthorizedNamespaceError,
    # re-enable custom-locations feature with the OID and retry
    if run_az "$CL_CMD" "false"; then
        CL_OUTPUT="$RUN_AZ_OUT"
    else
        if echo "$RUN_AZ_OUT" | grep -qi "UnauthorizedNamespaceError"; then
            print_yellow "Custom location creation failed with UnauthorizedNamespaceError. Re-enabling custom-locations feature with OID..."
            if [[ -z "$CUSTOM_LOCATION_OID" ]]; then
                if run_az "az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
                    CUSTOM_LOCATION_OID="$RUN_AZ_OUT"
                else
                    CUSTOM_LOCATION_OID="51dfe1e8-70c6-4de5-a08e-e18aff23d815"
                fi
            fi
            print_yellow "Using Custom Location RP OID: $CUSTOM_LOCATION_OID"
            run_az "az connectedk8s enable-features -n $AKS_CLUSTER_NAME -g $RESOURCE_GROUP --features cluster-connect custom-locations --custom-locations-oid \"$CUSTOM_LOCATION_OID\""
            print_yellow "Retrying custom location creation..."
            run_az "$CL_CMD"
            CL_OUTPUT="$RUN_AZ_OUT"
        else
            print_red "Custom location creation failed."
            exit 1
        fi
    fi

    if [[ "$SKIP_AUTO_PARSING" != "true" ]]; then
        CL_ID=$(echo "$CL_OUTPUT" | "$JQ" -r '.id // empty')
        if [[ -z "$CL_ID" ]]; then
            print_red "Failed to extract 'id' from custom location creation output."
            exit 1
        fi

        "$JQ" -n --arg name "$CL_ID" '{"name":$name,"type":"CustomLocation"}' > "$AUTO_EXTRACTED_FILE_PATH"

        # Update onboarding file with customLocationFile
        DATA=$(echo "$DATA" | "$JQ" --arg clf "$AUTO_EXTRACTED_FILE_PATH" '.common.customLocationFile = $clf')
        echo "$DATA" | "$JQ" '.' > "$ONBOARDING_FILE"

        print_green "Created $AUTO_EXTRACTED_FILE_PATH and updated $ONBOARDING_FILE with customLocationFile: $AUTO_EXTRACTED_FILE_PATH"
    fi

    print_green "Successfully created Custom Location: $CUSTOM_LOCATION_NAME"
fi

# --- Connected Registry ---
if [[ "$SKIP_CONNECTED_REGISTRY_DEPLOYMENT" != "true" ]]; then
    ACR_NAME=$(jq_data '.infraOnboarding.acrName // empty')
    if [[ -z "$ACR_NAME" ]]; then
        ACR_NAME="acrstaging$(cat /dev/urandom | tr -dc 'a-z' | head -c 4)"
    fi

    print_yellow "Checking if ACR $ACR_NAME already exists in resource group $RESOURCE_GROUP..."
    if run_az_json "az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP" "false" && [[ -n "$RUN_AZ_JSON_OUT" ]]; then
        print_green "ACR $ACR_NAME already exists in resource group $RESOURCE_GROUP"
        ACR_SKU=$(echo "$RUN_AZ_JSON_OUT" | "$JQ" -r '.sku.name // ""')
        if [[ "$ACR_SKU" == "Premium" ]]; then
            print_green "ACR $ACR_NAME is already Premium SKU"
        else
            print_yellow "ACR $ACR_NAME is $ACR_SKU SKU, upgrading to Premium..."
            run_az "az acr update --name $ACR_NAME --resource-group $RESOURCE_GROUP --sku Premium"
        fi
        DATA_EP=$(echo "$RUN_AZ_JSON_OUT" | "$JQ" -r '.dataEndpointEnabled // false')
        if [[ "$DATA_EP" == "true" ]]; then
            print_green "Data endpoint is already enabled for ACR $ACR_NAME"
        else
            print_yellow "Enabling data endpoint for ACR $ACR_NAME..."
            run_az "az acr update --name $ACR_NAME --resource-group $RESOURCE_GROUP --data-endpoint-enabled"
        fi
    else
        print_yellow "ACR $ACR_NAME does not exist, validating name..."
        run_az_json "az acr check-name --name $ACR_NAME"
        NAME_AVAIL=$(echo "$RUN_AZ_JSON_OUT" | "$JQ" -r '.nameAvailable')
        if [[ "$NAME_AVAIL" != "true" ]]; then
            print_red "ACR name $ACR_NAME is not available"
            exit 1
        fi
        run_az "az acr create --resource-group $RESOURCE_GROUP --name $ACR_NAME --sku Premium"
        run_az "az acr update --name $ACR_NAME --resource-group $RESOURCE_GROUP --data-endpoint-enabled"
        print_green "Successfully created ACR $ACR_NAME with Premium SKU"
    fi

    # Check/import image
    if run_az_json "az acr repository show-manifests --name $ACR_NAME --repository tmp/hello-world" "false" && [[ -n "$RUN_AZ_JSON_OUT" ]]; then
        print_green "Image tmp/hello-world already exists in ACR $ACR_NAME"
    else
        print_yellow "Image tmp/hello-world does not exist, importing..."
        run_az "az acr import --name $ACR_NAME --source mcr.microsoft.com/hello-world:latest --image tmp/hello-world:latest"
    fi

    CONN_REG_NAME=$(jq_data '.infraOnboarding.connectedRegistryName // empty')
    [[ -z "$CONN_REG_NAME" ]] && CONN_REG_NAME="conected$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 4)"

    CONN_EXISTS=false
    if run_az "az acr connected-registry show --registry $ACR_NAME --name $CONN_REG_NAME --query connectionState -o tsv" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
        print_yellow "Connected registry '$CONN_REG_NAME' already exists (state: $RUN_AZ_OUT). Skipping creation."
        CONN_EXISTS=true
    fi
    if [[ "$CONN_EXISTS" != "true" ]]; then
        run_az "az acr connected-registry create --registry $ACR_NAME --name $CONN_REG_NAME --repository tmp/hello-world --mode ReadOnly --log-level Debug --yes"
        print_green "Successfully created connected registry: $CONN_REG_NAME"
    fi
    run_az "az acr connected-registry list --registry $ACR_NAME --output table"

    run_az "az acr connected-registry get-settings --name $CONN_REG_NAME --registry $ACR_NAME --parent-protocol https --generate-password 1 --query ACR_REGISTRY_CONNECTION_STRING --subscription $SUBSCRIPTION_ID --output tsv --yes"
    CONN_STR="$RUN_AZ_OUT"
    CONN_STR="${CONN_STR//$'\r'/}"
    if [[ -z "$CONN_STR" ]]; then
        print_red "Failed to retrieve connection string for connected registry $CONN_REG_NAME"
        exit 1
    fi
    "$JQ" -n --arg cs "$CONN_STR" '{"connectionString":$cs}' > protected-settings-extension.json
    echo "Wrote connection registry connection string to protected-settings-extension.json"

    CONN_REG_IP=$(jq_data '.infraOnboarding.connectedRegistryIp // empty')
    if [[ -z "$CONN_REG_IP" ]]; then
        print_red "connected Registry IP is required for ConnectedRegistryDeployment"
        exit 1
    fi
    STORAGE_SIZE=$(jq_data '.infraOnboarding.storageSizeRequest // empty')
    [[ -z "$STORAGE_SIZE" ]] && STORAGE_SIZE="250Gi"

    print_yellow "Installing connected registry extension..."
    if run_az "az k8s-extension show --cluster-name $AKS_CLUSTER_NAME --cluster-type connectedClusters --name $CONN_REG_NAME --resource-group $RESOURCE_GROUP --query provisioningState -o tsv" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
        print_yellow "Connected registry extension already installed (state: $RUN_AZ_OUT). Skipping."
    else
        run_az "az k8s-extension create --cluster-name $AKS_CLUSTER_NAME --cluster-type connectedClusters --extension-type Microsoft.ContainerRegistry.ConnectedRegistry --name $CONN_REG_NAME --resource-group $RESOURCE_GROUP --config service.clusterIP=$CONN_REG_IP --config pvc.storageRequest=$STORAGE_SIZE --config cert-manager.install=false --config-protected-file protected-settings-extension.json"
        print_green "Successfully installed connected registry extension."
    fi

    print_yellow "Creating client token for connected registry..."
    if run_az "az acr scope-map show --name all-repos-read --registry $ACR_NAME --query name -o tsv" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
        print_yellow "Scope-map 'all-repos-read' already exists. Skipping creation."
    else
        run_az "az acr scope-map create --name all-repos-read --registry $ACR_NAME --repository '*' content/read metadata/read --description 'Scope map for pulling from ACR.'"
    fi

    CLIENT_TOKEN_NAME="all-repos-pull-token"
    TOKEN_EXISTS=false
    if run_az "az acr token show --name $CLIENT_TOKEN_NAME --registry $ACR_NAME --query name -o tsv" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
        print_yellow "Token '$CLIENT_TOKEN_NAME' already exists. Regenerating password."
        TOKEN_EXISTS=true
    fi

    if [[ "$TOKEN_EXISTS" != "true" ]]; then
        run_az_json "az acr token create --name $CLIENT_TOKEN_NAME --registry $ACR_NAME --scope-map all-repos-read"
        CLIENT_TOKEN_VALUE=$(echo "$RUN_AZ_JSON_OUT" | "$JQ" -r '.credentials.passwords[0].value')
    else
        run_az_json "az acr token credential generate --name $CLIENT_TOKEN_NAME --registry $ACR_NAME --password1"
        CLIENT_TOKEN_VALUE=$(echo "$RUN_AZ_JSON_OUT" | "$JQ" -r '.passwords[0].value')
    fi

    run_az "az acr connected-registry update --name $CONN_REG_NAME --registry $ACR_NAME --add-client-token $CLIENT_TOKEN_NAME"
    SECRET_NAME=$(jq_data '.infraOnboarding.connectedRegistryClientToken // empty')
    [[ -z "$SECRET_NAME" ]] && SECRET_NAME="acr-client-token"

    print_yellow "Validate kubectl..."
    if command -v kubectl &>/dev/null; then
        print_green "kubectl is already installed."
    else
        print_yellow "kubectl not found. Please install kubectl manually."
    fi
    kubectl create secret generic "$SECRET_NAME" --from-literal=username="$CLIENT_TOKEN_NAME" --from-literal=password="$CLIENT_TOKEN_VALUE" -n "$CUSTOM_LOCATION_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
fi

# ---------------------------------------------------------------
# Site hierarchy & deployment targets
# ---------------------------------------------------------------
SITE_HIERARCHY=$(jq_data '.infraOnboarding.siteHierarchy // empty')
HAS_INFRA=$(jq_data '.infraOnboarding // empty')

if [[ -n "$HAS_INFRA" && -n "$SITE_HIERARCHY" && "$SITE_HIERARCHY" != "null" ]]; then
    HIERARCHY_JSON=$(echo "$DATA" | "$JQ" '.infraOnboarding.siteHierarchy')

    print_green "Processing Site Hierarchy..."
    validate_site_hierarchy "$HIERARCHY_JSON"
    create_sites_and_relationships "$ONBOARDING_FILE" "$RESOURCE_GROUP" "false" "$SKIP_RELATIONSHIP_CREATION"

    print_green "Processing Site Hierarchy for Deployment Targets..."
    CONTEXT_ID=""

    SITE_COUNT=$(echo "$HIERARCHY_JSON" | "$JQ" 'length')
    for (( si=0; si<SITE_COUNT; si++ )); do
        SITE_NODE=$(echo "$HIERARCHY_JSON" | "$JQ" ".[$si]")
        SITE_NAME=$(echo "$SITE_NODE" | "$JQ" -r '.siteName')

        # Capability list
        CAP_LIST=$(echo "$SITE_NODE" | "$JQ" '.capabilityList // empty')
        if [[ -n "$CAP_LIST" && "$CAP_LIST" != "null" ]]; then
            print_green "Setting up capabilities"
            CONTEXT_SUB=$(jq_data '.infraOnboarding.contextSubscriptionId // .common.subscriptionId // empty')
            CONTEXT_RG=$(jq_data '.infraOnboarding.contextResourceGroup // empty')
            [[ -z "$CONTEXT_RG" ]] && CONTEXT_RG="Mehoopany"
            CONTEXT_NAME=$(jq_data '.infraOnboarding.contextName // empty')
            [[ -z "$CONTEXT_NAME" ]] && CONTEXT_NAME="Mehoopany-Context"
            CONTEXT_LOCATION=$(jq_data '.infraOnboarding.contextLocation // empty')
            [[ -z "$CONTEXT_LOCATION" ]] && CONTEXT_LOCATION="eastus2euap"
            CONTEXT_ID="/subscriptions/$CONTEXT_SUB/resourceGroups/$CONTEXT_RG/providers/Microsoft.Edge/contexts/$CONTEXT_NAME"

            print_yellow "Using context: $CONTEXT_NAME in resource group: $CONTEXT_RG, subscription: $CONTEXT_SUB, location: $CONTEXT_LOCATION"

            CONTEXT_EXISTS=false
            CONTEXT_JSON=""
            if run_az "az workload-orchestration context show --subscription $CONTEXT_SUB --resource-group $CONTEXT_RG --name $CONTEXT_NAME" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
                CONTEXT_JSON="$RUN_AZ_OUT"
                CONTEXT_EXISTS=true
            fi

            if [[ "$CONTEXT_EXISTS" == "true" && -n "$CONTEXT_JSON" ]]; then
                print_yellow "Updating existing context with new capabilities"
                # Build new capabilities from capabilityList
                NEW_CAPS=$(echo "$SITE_NODE" | "$JQ" '[.capabilityList.capabilities[] | {description: ., name: .}]')
                EXISTING_CAPS=$(echo "$CONTEXT_JSON" | "$JQ" '.properties.capabilities // []')

                # Merge and deduplicate
                ALL_CAPS=$(echo "[$EXISTING_CAPS, $NEW_CAPS]" | "$JQ" '.[0] + .[1] | unique_by(.name) | [.[] | {name: .name, description: (.description // .name)}]')
                echo "$ALL_CAPS" > context-capabilities.json

                # Hierarchy levels
                HIERARCHY_PARAMS=""
                HIER_LEVELS=$(echo "$SITE_NODE" | "$JQ" -r '.hierarchyLevels.levels // [] | .[]' 2>/dev/null || true)
                if [[ -n "$HIER_LEVELS" ]]; then
                    print_yellow "Including hierarchy levels in context"
                    idx=0
                    while IFS= read -r level; do
                        HIERARCHY_PARAMS+=" --hierarchies [$idx].name=$level [$idx].description=$level"
                        idx=$((idx + 1))
                    done <<< "$HIER_LEVELS"
                fi

                CTX_CMD="az workload-orchestration context create --subscription $CONTEXT_SUB --resource-group $CONTEXT_RG --location $CONTEXT_LOCATION --name $CONTEXT_NAME --capabilities \"@context-capabilities.json\"$HIERARCHY_PARAMS"
                print_yellow "Executing: $CTX_CMD"
                run_az "$CTX_CMD"
            else
                        print_yellow "Cannot find context $CONTEXT_NAME in resource group $CONTEXT_RG, subscription $CONTEXT_SUB. Create new context via instructions."
                        exit 0
            fi

            print_green "Capabilities setup completed"

            # Site reference
            SITE_REF_NAME="$SITE_NAME"
            IS_RG_SITE=$(echo "$SITE_NODE" | "$JQ" -r '.isRGSite // false')
            if [[ "$IS_RG_SITE" == "true" ]]; then
                SITE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Edge/sites/$SITE_NAME"
            else
                SITE_ID="/providers/Microsoft.Management/serviceGroups/$SITE_NAME/providers/Microsoft.Edge/sites/$SITE_NAME"
            fi
            print_yellow "Creating site reference '$SITE_REF_NAME' for context '$CONTEXT_NAME'..."
            SITE_REF_EXISTS=false
            if run_az "az workload-orchestration context site-reference show --subscription $CONTEXT_SUB --resource-group $CONTEXT_RG --context-name $CONTEXT_NAME --name $SITE_REF_NAME --query name -o tsv" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
                print_yellow "Site reference '$SITE_REF_NAME' already exists. Skipping."
                SITE_REF_EXISTS=true
            fi
            if [[ "$SITE_REF_EXISTS" != "true" ]]; then
                SR_CMD="az workload-orchestration context site-reference create --subscription $CONTEXT_SUB --resource-group $CONTEXT_RG --context-name $CONTEXT_NAME --name $SITE_REF_NAME --site-id \"$SITE_ID\""
                print_yellow "Executing: $SR_CMD"
                run_az "$SR_CMD"
            fi
        fi

        # Deployment targets
        DT=$(echo "$SITE_NODE" | "$JQ" '.deploymentTargets // empty')
        if [[ -n "$DT" && "$DT" != "null" ]]; then
            print_cyan "Found deployment targets for site: $SITE_NAME"
            TARGETS_COUNT=$(echo "$DT" | "$JQ" '.targets // [] | length')
            if [[ "$TARGETS_COUNT" -gt 0 ]]; then
                for (( ti=0; ti<TARGETS_COUNT; ti++ )); do
                    TARGET_INFO=$(echo "$DT" | "$JQ" ".targets[$ti]")
                    T_NAME=$(echo "$TARGET_INFO" | "$JQ" -r '.name')
                    print_cyan "Processing Target: $T_NAME"

                    # Resolve properties with fallback
                    RESOLVED_CAPS=$(echo "$TARGET_INFO" | "$JQ" '.capabilities // empty')
                    if [[ -z "$RESOLVED_CAPS" || "$RESOLVED_CAPS" == "null" ]]; then
                        RESOLVED_CAPS=$(echo "$DT" | "$JQ" '.capabilities // []')
                    fi
                    RESOLVED_LEVEL=$(echo "$TARGET_INFO" | "$JQ" -r '.hierarchyLevel // empty')
                    [[ -z "$RESOLVED_LEVEL" ]] && RESOLVED_LEVEL=$(echo "$DT" | "$JQ" -r '.hierarchyLevel // empty')

                    RESOLVED_CL_FILE=$(echo "$TARGET_INFO" | "$JQ" -r '.customLocationFile // empty')
                    [[ -z "$RESOLVED_CL_FILE" ]] && RESOLVED_CL_FILE=$(echo "$DT" | "$JQ" -r '.customLocationFile // empty')
                    [[ -z "$RESOLVED_CL_FILE" ]] && RESOLVED_CL_FILE="$AUTO_EXTRACTED_FILE_PATH"

                    RESOLVED_SPEC=$(echo "$TARGET_INFO" | "$JQ" -r '.targetSpecFile // empty')
                    [[ -z "$RESOLVED_SPEC" ]] && RESOLVED_SPEC=$(echo "$DT" | "$JQ" -r '.targetSpecFile // empty')

                    if [[ -z "$RESOLVED_SPEC" ]]; then
                        print_yellow "targetSpecFile is required for target $T_NAME. Skipping this target."
                        continue
                    fi

                    # Convert Windows paths to Unix for Git Bash
                    RESOLVED_SPEC_UNIX=$(win_to_unix_path "$RESOLVED_SPEC")
                    RESOLVED_CL_FILE_UNIX=$(win_to_unix_path "$RESOLVED_CL_FILE")

                    print_yellow "Target $T_NAME resolved capabilities: $RESOLVED_CAPS"

                    # Build capabilities param
                    CAPS_LEN=$(echo "$RESOLVED_CAPS" | "$JQ" 'length')
                    if [[ "$CAPS_LEN" -eq 0 ]]; then
                        CAPS_PARAM='""'
                    elif [[ "$CAPS_LEN" -eq 1 ]]; then
                        SINGLE_CAP=$(echo "$RESOLVED_CAPS" | "$JQ" -r '.[0]')
                        CAPS_PARAM="\"$SINGLE_CAP\""
                    else
                        CAPS_PARAM="\"$(echo "$RESOLVED_CAPS" | "$JQ" -c '.')\""
                    fi

                    # Check if target exists
                    COMMON_RG=$(jq_data '.common.resourceGroup // empty')
                    [[ -z "$COMMON_RG" ]] && COMMON_RG="$RESOURCE_GROUP"
                    COMMON_SUB=$(jq_data '.common.subscriptionId // empty')
                    [[ -z "$COMMON_SUB" ]] && COMMON_SUB="$SUBSCRIPTION_ID"
                    COMMON_LOC=$(jq_data '.common.location // empty')
                    [[ -z "$COMMON_LOC" ]] && COMMON_LOC="$LOCATION"

                    TARGET_EXISTS=false
                    if run_az "az workload-orchestration target show --resource-group $COMMON_RG --name $T_NAME --subscription $COMMON_SUB --query name -o tsv" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
                        print_yellow "Target '$T_NAME' already exists. Skipping creation."
                        TARGET_EXISTS=true
                    fi

                    if [[ "$TARGET_EXISTS" != "true" ]]; then
                        T_DISPLAY=$(echo "$TARGET_INFO" | "$JQ" -r '.displayName // empty')
                        [[ -z "$T_DISPLAY" ]] && T_DISPLAY="$T_NAME"

                        # If target spec path has spaces, copy to a temp file (az CLI @file
                        # shorthand cannot handle whitespace in paths)
                        SPEC_TMP=""
                        if [[ "$RESOLVED_SPEC_UNIX" == *" "* ]]; then
                            SPEC_TMP="$(pwd)/_tmp_targetspec_$$.json"
                            cp "$RESOLVED_SPEC_UNIX" "$SPEC_TMP"
                            SPEC_FOR_CMD="$SPEC_TMP"
                        else
                            SPEC_FOR_CMD="$RESOLVED_SPEC_UNIX"
                        fi
                        # Convert file path to Windows format so az CLI can find it
                        # even when MSYS_NO_PATHCONV=1 prevents automatic conversion
                        if command -v cygpath &>/dev/null; then
                            SPEC_FOR_CMD=$(cygpath -w "$SPEC_FOR_CMD")
                        fi

                        # MSYS_NO_PATHCONV=1 is needed because --extended-location contains
                        # /subscriptions/... paths embedded in name="..." which MSYS2_ARG_CONV_EXCL
                        # cannot protect (it only matches argument-start patterns).
                        T_CMD="MSYS_NO_PATHCONV=1 az workload-orchestration target create"
                        T_CMD+=" --resource-group $COMMON_RG"
                        T_CMD+=" --location $COMMON_LOC"
                        T_CMD+=" --subscription $COMMON_SUB"
                        T_CMD+=" --name \"$T_NAME\""
                        T_CMD+=" --display-name \"$T_DISPLAY\""
                        T_CMD+=" --hierarchy-level $RESOLVED_LEVEL"
                        T_CMD+=" --capabilities $CAPS_PARAM"
                        T_CMD+=" --solution-scope \"default\""
                        T_CMD+=" --description \"Target for $T_DISPLAY\""
                        T_CMD+=" --target-specification \"@$SPEC_FOR_CMD\""
                        # Read extended-location JSON and pass as inline shorthand
                        EL_NAME=$("$JQ" -r '.name // ""' "$RESOLVED_CL_FILE_UNIX")
                        EL_TYPE=$("$JQ" -r '.type // "CustomLocation"' "$RESOLVED_CL_FILE_UNIX")
                        T_CMD+=" --extended-location name=\"$EL_NAME\" type=\"$EL_TYPE\""
                        T_CMD+=" --context-id $CONTEXT_ID"

                        print_yellow "Executing: $T_CMD"
                        run_az "$T_CMD"
                        [[ -n "$SPEC_TMP" ]] && rm -f "$SPEC_TMP"
                    fi

                    run_az "az workload-orchestration target show --resource-group $COMMON_RG --name $T_NAME --query id --output tsv"
                    TARGET_ID="$RUN_AZ_OUT"

                    # RG-based sites don't use serviceGroupMember relationships
                    IS_RG_SITE_DT=$(echo "$SITE_NODE" | "$JQ" -r '.isRGSite // false')
                    if [[ "$IS_RG_SITE_DT" != "true" ]]; then
                        create_relationship "$SITE_NAME" "$TARGET_ID"
                    fi

                    # RBAC
                    RESOLVED_RBAC=$(echo "$TARGET_INFO" | "$JQ" '.rbac // empty')
                    [[ -z "$RESOLVED_RBAC" || "$RESOLVED_RBAC" == "null" ]] && RESOLVED_RBAC=$(echo "$DT" | "$JQ" '.rbac // empty')
                    if [[ -n "$RESOLVED_RBAC" && "$RESOLVED_RBAC" != "null" ]]; then
                        print_green "Assigning RBAC role to deployment target: $T_NAME"
                        RBAC_USER_GROUP=$(echo "$RESOLVED_RBAC" | "$JQ" -r '.userGroup')
                        RBAC_ROLE=$(echo "$RESOLVED_RBAC" | "$JQ" -r '.role')
                        run_az_json "az workload-orchestration target show --name \"$T_NAME\" -g $COMMON_RG --subscription $COMMON_SUB -o json"
                        TID=$(echo "$RUN_AZ_JSON_OUT" | "$JQ" -r '.id')
                        if [[ -n "$TID" ]]; then
                            run_az "az role assignment create --assignee $RBAC_USER_GROUP --role \"$RBAC_ROLE\" --scope \"$TID\"" "false"
                            print_green "RBAC assigned successfully."
                        else
                            print_red "Failed to retrieve ID for target $T_NAME"
                        fi
                    fi
                done
            else
                print_yellow "No 'targets' array found within deploymentTargets for site: $SITE_NAME"
            fi
        else
            print_gray "No deployment targets defined for site: $SITE_NAME"
        fi
    done

    print_green "Deployment Target Creation from Site Hierarchy finished."
else
    print_yellow "No infraOnboarding.siteHierarchy found in onboarding file. Skipping target creation from hierarchy."
fi

# ---------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------
if [[ "$ENABLE_WO_DIAGNOSTICS" == "true" || "$ENABLE_CONTAINER_INSIGHTS" == "true" ]]; then
    print_yellow "Enabling diagnostics..."
    DIAG_WS_ID=$(jq_data '.infraOnboarding.diagInfo.diagnosticWorkspaceId // empty')

    if [[ -z "$DIAG_WS_ID" ]]; then
        WS_NAME="${RESOURCE_GROUP}-diag-workspace"
        create_log_analytics_workspace "$RESOURCE_GROUP" "$WS_NAME" "$ARC_LOCATION"
        DIAG_WS_ID="$LOG_ANALYTICS_WS_ID"
    fi

    if [[ -z "$DIAG_WS_ID" ]]; then
        print_red "diagnosticWorkspaceId is required for enabling diagnostics"
        exit 1
    fi

    if [[ "$ENABLE_WO_DIAGNOSTICS" == "true" ]]; then
        print_yellow "Enabling diagnostics..."
        CL_FILE=$(jq_data '.common.customLocationFile // empty')
        if [[ -z "$CL_FILE" ]]; then
            print_red "customLocationFile is required for enabling diagnostics"
            exit 1
        fi
        DIAG_NAME=$(jq_data '.infraOnboarding.diagInfo.diagnosticResourceName // "default"')
        print_yellow "Enabling workload orchestration diagnostics settings..."

        # Create WO diagnostics resource
        print_yellow "Creating WODiagnostics Resource with name $DIAG_NAME..."
        # Read extended-location JSON and pass as inline shorthand
        DIAG_EL_NAME=$("$JQ" -r '.name // ""' "$CL_FILE")
        DIAG_EL_TYPE=$("$JQ" -r '.type // "CustomLocation"' "$CL_FILE")
        # Disable MSYS path conversion so /subscriptions/... in extended-location isn't mangled
        run_az "MSYS_NO_PATHCONV=1 az workload-orchestration diagnostic create --resource-group $RESOURCE_GROUP --location $ARC_LOCATION --subscription $SUBSCRIPTION_ID --name \"$DIAG_NAME\" --extended-location name=\"$DIAG_EL_NAME\" type=\"$DIAG_EL_TYPE\""
        print_green "Created WODiagnostics Resource with name $DIAG_NAME"
        run_az "az workload-orchestration diagnostic show --subscription $SUBSCRIPTION_ID --resource-group $RESOURCE_GROUP --name $DIAG_NAME --query id -o tsv"
        DIAG_RID="$RUN_AZ_OUT"

        SETTING_NAME=$(jq_data '.infraOnboarding.diagInfo.diagnosticSettingName // "default"')
        print_yellow "Creating Diagnostic Setting for $DIAG_RID..."
        LOGS='[{"category":"UserAudits","enabled":true},{"category":"UserDiagnostics","enabled":true}]'
        run_az "az monitor diagnostic-settings create --resource $DIAG_RID --workspace $DIAG_WS_ID --name $SETTING_NAME --logs '$LOGS'"
        print_green "Created Diagnostic Setting for $DIAG_RID"
        print_green "Workload orchestration diagnostics settings enabled successfully."
    fi

    if [[ "$ENABLE_CONTAINER_INSIGHTS" == "true" ]]; then
        print_yellow "Enabling Container Insights..."
        run_az "az k8s-extension create --name azuremonitor-containers --cluster-name $AKS_CLUSTER_NAME --resource-group $RESOURCE_GROUP --cluster-type connectedClusters --extension-type Microsoft.AzureMonitor.Containers --configuration-settings logAnalyticsWorkspaceResourceID=$DIAG_WS_ID"
        print_green "Container Insights installed successfully."
    fi

    print_green "Diagnostics enabled successfully."
fi

print_green "Infrastructure onboarding completed successfully!"