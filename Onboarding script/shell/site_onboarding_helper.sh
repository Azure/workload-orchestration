#!/usr/bin/env bash
# Site onboarding helper - creates sites and relationships in Azure
# This file is sourced by infra_onboarding.sh

BASE_SG_URL="https://eastus2euap.management.azure.com"
DRY_RUN=false

# -----------------------------------------------------------------------
# Colour helpers
# -----------------------------------------------------------------------
print_green()  { echo -e "\033[32m$*\033[0m"; }
print_yellow() { echo -e "\033[33m$*\033[0m"; }
print_red()    { echo -e "\033[31m$*\033[0m"; }
print_cyan()   { echo -e "\033[36m$*\033[0m"; }
print_gray()   { echo -e "\033[90m$*\033[0m"; }

# -----------------------------------------------------------------------
# run_az  - run a command, return stdout via $RUN_AZ_OUT.
#           Retries on 429 throttle. Exits on error if check=true (default).
# Usage:  run_az "az ..." [check=true|false]
# -----------------------------------------------------------------------
run_az() {
    local cmd="$1"
    local check="${2:-true}"
    local max_retries=3
    local attempt

    for (( attempt=1; attempt<=max_retries; attempt++ )); do
        local stdout stderr rc
        set +e
        stdout=$(eval "$cmd" 2>_az_stderr.tmp)
        rc=$?
        set -e
        stderr=$(cat _az_stderr.tmp 2>/dev/null || true)
        rm -f _az_stderr.tmp

        if [[ $rc -ne 0 ]]; then
            if [[ "$check" == "true" ]]; then
                local stderr_lower
                stderr_lower=$(echo "$stderr" | tr '[:upper:]' '[:lower:]')
                if echo "$stderr" | grep -q "(429)" && echo "$stderr_lower" | grep -q "throttled" && (( attempt < max_retries )); then
                    local wait=5
                    local match
                    match=$(echo "$stderr_lower" | grep -oP 'retry after \K\d+' || true)
                    [[ -n "$match" ]] && wait=$match
                    print_yellow "Throttled (429). Retrying in ${wait}s... (attempt ${attempt}/${max_retries})"
                    sleep "$wait"
                    continue
                fi
                print_red "Command failed: $cmd"
                print_red "stderr: $stderr"
                return 1
            else
                # check=false: don't error out, but return non-zero so caller can detect
                RUN_AZ_OUT=""
                return 1
            fi
        fi

        # Strip UTF-8 BOM
        stdout="${stdout#$''}"
        # Trim whitespace
        stdout=$(echo "$stdout" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        RUN_AZ_OUT="$stdout"
        return 0
    done

    # Fallback (should not reach here)
    RUN_AZ_OUT=""
    return 0
}

# -----------------------------------------------------------------------
# run_az_json - run a command and store parsed JSON in $RUN_AZ_JSON_OUT
# -----------------------------------------------------------------------
run_az_json() {
    run_az "$1" "${2:-true}" || return 1
    if [[ -z "$RUN_AZ_OUT" ]]; then
        RUN_AZ_JSON_OUT=""
        return 0
    fi
    RUN_AZ_JSON_OUT="$RUN_AZ_OUT"
    return 0
}

# -----------------------------------------------------------------------
# invoke_web_request_with_polling
# Uses curl for the initial call, then polls Azure-AsyncOperation
# -----------------------------------------------------------------------
invoke_web_request_with_polling() {
    local uri="$1"
    local method="${2:-GET}"
    local body_file="${3:-}"

    print_green "##[debug] Invoking web request $uri"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_gray "Skipping resource creation for Dry Run"
        return 0
    fi

    # Get access token
    run_az 'az account get-access-token --query accessToken -o tsv'
    local token="$RUN_AZ_OUT"

    # Make the REST call
    local response_headers
    response_headers=$(mktemp)
    local response_body
    response_body=$(mktemp)

    local curl_args=(-s -w "%{http_code}" -D "$response_headers" -o "$response_body" -X "$method")
    curl_args+=(-H "Authorization: Bearer $token" -H "Content-Type: application/json")
    if [[ -n "$body_file" ]]; then
        curl_args+=(-d "@$body_file")
    fi
    curl_args+=("$uri")

    local http_code
    http_code=$(curl "${curl_args[@]}")

    if [[ "$http_code" -ge 400 ]]; then
        print_red "##[debug] Error: HTTP $http_code"
        cat "$response_body" >&2
        rm -f "$response_headers" "$response_body"
        print_red "##[debug] An error occurred while executing $uri"
        return 1
    fi

    # Extract Azure-AsyncOperation header
    local async_op
    async_op=$(grep -i 'Azure-AsyncOperation' "$response_headers" | head -1 | sed 's/.*: //' | tr -d '\r\n' || true)
    rm -f "$response_headers" "$response_body"

    if [[ -z "$async_op" ]]; then
        print_yellow "##[debug] No Azure-AsyncOperation header in response."
        return 0
    fi

    print_yellow "##[debug] Waiting for request to complete for AzureAsyncOperation"
    local start_time
    start_time=$(date +%s)

    while true; do
        local poll_body
        poll_body=$(curl -s -H "Authorization: Bearer $token" "$async_op")
        local status
        status=$(echo "$poll_body" | "$JQ" -r '.status // "Unknown"')
        local elapsed=$(( $(date +%s) - start_time ))
        print_yellow "##[debug] Elapsed time: ${elapsed} seconds, Status: $status"

        if [[ "$status" == "Succeeded" ]]; then
            break
        fi
        if [[ $elapsed -gt 30 || "$status" == "Failed" ]]; then
            print_yellow "##[debug] Request is taking too long or failing, skipping it, please check manually for ARMID: $uri"
            print_yellow "##[debug] To know failure reason, try GET on this AzureAsyncOperation: $async_op"
            return 0
        fi
        sleep 5
    done
}

# -----------------------------------------------------------------------
# validate_site_hierarchy - validate no duplicate site members
# -----------------------------------------------------------------------
validate_site_hierarchy() {
    local hierarchy_json="$1"
    local count
    count=$(echo "$hierarchy_json" | "$JQ" 'length')
    declare -A global_hash

    for (( i=0; i<count; i++ )); do
        local site_name
        site_name=$(echo "$hierarchy_json" | "$JQ" -r ".[$i].siteName // \"\"")
        print_yellow "Validating site: $site_name"

        local members_count
        members_count=$(echo "$hierarchy_json" | "$JQ" ".[$i].siteMembers // [] | length")
        for (( j=0; j<members_count; j++ )); do
            local member
            member=$(echo "$hierarchy_json" | "$JQ" -r ".[$i].siteMembers[$j]")
            if [[ -n "${global_hash[$member]+_}" ]]; then
                print_red "Duplicate site member found: $member, in site '$site_name' and site '${global_hash[$member]}'"
                return 1
            fi
            global_hash["$member"]="$site_name"
        done
    done
}

# -----------------------------------------------------------------------
# create_sites_and_relationships
# -----------------------------------------------------------------------
create_sites_and_relationships() {
    local data_file="$1"
    local resource_group="$2"
    local skip_site_creation="${3:-false}"
    local skip_relationship_creation="${4:-false}"

    print_yellow "Creating sites and relationships..."

    local subscription_id
    subscription_id=$("$JQ" -r '.common.subscriptionId // empty' "$data_file")

    run_az "az account list --output json"
    local tenant_id
    tenant_id=$(echo "$RUN_AZ_OUT" | "$JQ" -r '[.[] | select(.isDefault == true) | .tenantId] | .[0] // empty')
    if [[ -z "$tenant_id" ]]; then
        # Fallback: try to get from data file
        tenant_id=$("$JQ" -r '.common.tenantId // empty' "$data_file")
    fi
    if [[ -z "$tenant_id" ]]; then
        print_red "Could not determine tenant ID"
        return 1
    fi
    print_yellow "Using tenant ID: $tenant_id"

    local hierarchy_json
    hierarchy_json=$("$JQ" '.infraOnboarding.siteHierarchy // []' "$data_file")
    local count
    count=$(echo "$hierarchy_json" | "$JQ" 'length')

    for (( i=0; i<count; i++ )); do
        local site_name site_level is_rg_site
        site_name=$(echo "$hierarchy_json" | "$JQ" -r ".[$i].siteName // \"${resource_group}-Site\"")
        site_level=$(echo "$hierarchy_json" | "$JQ" -r ".[$i].level // \"\"")
        is_rg_site=$(echo "$hierarchy_json" | "$JQ" -r ".[$i].isRGSite // false")

        if [[ "$skip_site_creation" != "true" ]]; then
            if [[ "$is_rg_site" == "true" ]]; then
                # Resource Group-based site: no Service Group, no parent
                print_yellow "Creating RG-based Site $site_name..."
                local rg_site_uri="https://management.azure.com/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.Edge/sites/${site_name}?api-version=2025-03-01-preview"

                local site_body_file
                site_body_file=$(mktemp --suffix=.json)
                "$JQ" -n --arg dn "$site_name" --arg lvl "$site_level" \
                    '{"properties":{"displayName":$dn,"description":$dn,"labels":{"level":$lvl}}}' > "$site_body_file"

                if run_az "az rest --method GET --url \"$rg_site_uri\" --resource https://management.azure.com" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
                    print_yellow "Site $site_name already exists. Skipping creation."
                else
                    run_az "az rest --method PUT --url \"$rg_site_uri\" --body @$site_body_file --resource https://management.azure.com"
                    print_green "Created RG-based Site $site_name"
                fi
                rm -f "$site_body_file"
                print_green "ARM ID : /subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.Edge/sites/${site_name}"
            else
                # Service Group-based site: create SG then site under it
                local parent_site site_parent
                parent_site=$(echo "$hierarchy_json" | "$JQ" -r ".[$i].parentSite // empty")

                if [[ -z "$parent_site" || "$parent_site" == "null" ]]; then
                    site_parent="/providers/Microsoft.Management/serviceGroups/$tenant_id"
                else
                    site_parent="/providers/Microsoft.Management/serviceGroups/$parent_site"
                fi

                # Create Service Group
                print_yellow "Creating Service Group $site_name..."
                local sg_body_file
                sg_body_file=$(mktemp --suffix=.json)
                "$JQ" -n --arg dn "$site_name" --arg parent "$site_parent" \
                    '{"properties":{"displayName":$dn,"parent":{"resourceId":$parent}}}' > "$sg_body_file"
                local sg_uri="${BASE_SG_URL}/providers/Microsoft.Management/serviceGroups/${site_name}?api-version=2024-02-01-preview"
                invoke_web_request_with_polling "$sg_uri" "PUT" "$sg_body_file"
                rm -f "$sg_body_file"
                print_green "Created Service Group $site_name"
                print_green "ARM ID : /providers/Microsoft.Management/serviceGroups/$site_name"

                # Wait for Service Group provisioning to propagate before creating site
                print_yellow "Waiting 5 seconds for Service Group provisioning to propagate..."
                sleep 5

                # Create Site (skip if already exists)
                print_yellow "Creating Site $site_name..."
                local site_uri="${BASE_SG_URL}/providers/Microsoft.Management/serviceGroups/${site_name}/providers/Microsoft.Edge/sites/${site_name}?api-version=2025-03-01-preview"

                if run_az "az rest --method GET --uri \"$site_uri\" --resource https://management.azure.com" "false" && [[ -n "$RUN_AZ_OUT" ]]; then
                    print_yellow "Site $site_name already exists. Skipping creation."
                else
                    local site_body_file
                    site_body_file=$(mktemp --suffix=.json)
                    "$JQ" -n --arg dn "$site_name" --arg lvl "$site_level" \
                        '{"properties":{"displayName":$dn,"description":$dn,"labels":{"level":$lvl}}}' > "$site_body_file"
                    run_az "az rest --method PUT --uri \"$site_uri\" --body @$site_body_file --resource https://management.azure.com"
                    rm -f "$site_body_file"
                    print_green "Created Site $site_name"
                fi
                print_green "ARM ID : /providers/Microsoft.Management/serviceGroups/${site_name}/providers/Microsoft.Edge/sites/${site_name}"
            fi
        fi
    done
}

# -----------------------------------------------------------------------
# create_relationship - create a service group member relationship
# -----------------------------------------------------------------------
create_relationship() {
    local site_name="$1"
    local member="$2"

    print_yellow "Creating relationship for $site_name..."
    local body_file
    body_file=$(mktemp --suffix=.json)
    "$JQ" -n --arg tid "/providers/Microsoft.Management/serviceGroups/$site_name" \
        '{"properties":{"targetId":$tid}}' > "$body_file"

    local rel_uri="${member}/providers/Microsoft.Relationships/serviceGroupMember/${site_name}?api-version=2023-09-01-preview"
    run_az "az rest --method PUT --uri \"$rel_uri\" --body @$body_file --resource https://management.azure.com"
    rm -f "$body_file"

    print_green "Created relationship for $site_name"
    print_green "ARM ID : ${BASE_SG_URL}/${member}/providers/Microsoft.Relationships/serviceGroupMember/${site_name}"
}