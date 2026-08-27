#!/usr/bin/env bash
# =============================================================================
# post-config.sh  -  GHES on Azure Local on-box post-configuration (Phase 2b).
#
# Runs ON the GitHub Enterprise Server appliance, as root, via the Azure Arc
# managed Run Command (Microsoft.HybridCompute/machines/runCommands). It drives
# the documented Manage API surface + native ghe-* CLI - the same surface the
# PowerShell toolkit uses - so no external bootstrap VM/SSH is required:
#
#   POST /manage/v1/config/init      multipart: license=@<file>, password=<mgmt>   -> 202
#   PUT  /manage/v1/config/settings  basic auth api_key:<mgmt>, JSON body          -> stage
#   ghe-config-apply                 on-box, root                                  -> apply
#
# Linux Run Command contract: named parameters/protectedParameters are exposed
# to this script as ENVIRONMENT VARIABLES (by their 'name'). Secrets arrive via
# protectedParameters and are never echoed.
#
# SCOPE (Option 1, validation): license + management-console password, core
# settings (hostname, subdomain isolation), config-apply, and an on-box endpoint
# self-verify (curl localhost) after the apply.
# NOT done here (kept MANUAL by decision): Active Directory objects, DNS records,
# and LDAP auth-mode wiring. Configure those out-of-band before/after this runs.
# =============================================================================
set -uo pipefail

# ---- Inputs (environment variables from Run Command parameters) -------------
GHES_HOSTNAME="${GHES_HOSTNAME:-}"                       # required, e.g. githubenterpriselocal.<domain>
GHES_MGMT_PASSWORD="${GHES_MGMT_PASSWORD:-}"            # required (protected)
GHES_LICENSE_B64="${GHES_LICENSE_B64:-}"               # required (protected) - base64 of the .ghl
GHES_SUBDOMAIN_ISOLATION="${GHES_SUBDOMAIN_ISOLATION:-true}"
GHES_SIGNUP_ENABLED="${GHES_SIGNUP_ENABLED:-false}"
GHES_PUBLIC_PAGES="${GHES_PUBLIC_PAGES:-false}"
GHES_MANAGE_PORT="${GHES_MANAGE_PORT:-8443}"
GHES_APPLY_TIMEOUT_MIN="${GHES_APPLY_TIMEOUT_MIN:-120}"  # cap on ghe-config-apply
GHES_READY_TIMEOUT_MIN="${GHES_READY_TIMEOUT_MIN:-30}"   # wait for Manage API + initial apply
GHES_SKIP_APPLY="${GHES_SKIP_APPLY:-false}"              # stage settings only (no apply)
GHES_VERIFY="${GHES_VERIFY:-true}"                       # run on-box endpoint self-verify after apply
GHES_VERIFY_STRICT="${GHES_VERIFY_STRICT:-false}"        # make a failed self-verify fatal (default: warn only)

LIC_FILE="$(mktemp /tmp/ghes-license.XXXXXX.ghl)"
PW_FILE="$(mktemp /tmp/ghes-pw.XXXXXX)"
INIT_OUT="$(mktemp /tmp/ghes-init.XXXXXX.out)"
SETTINGS_OUT="$(mktemp /tmp/ghes-settings.XXXXXX.out)"

log()  { printf '%s [post-config] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { log "ERROR: $*"; cleanup; exit 1; }
cleanup() { rm -f "$LIC_FILE" "$PW_FILE" "$INIT_OUT" "$SETTINGS_OUT" 2>/dev/null || true; }
trap cleanup EXIT

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---- Preconditions ----------------------------------------------------------
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "must run as root (Arc Linux Run Command runs as root by default)."
command -v curl >/dev/null 2>&1 || die "curl not found on the appliance."
command -v ghe-config-apply >/dev/null 2>&1 || die "ghe-config-apply not found - this does not look like a GHES appliance."
[[ -n "$GHES_HOSTNAME" ]]      || die "GHES_HOSTNAME is required."
[[ -n "$GHES_MGMT_PASSWORD" ]] || die "GHES_MGMT_PASSWORD is required (protected parameter)."
[[ -n "$GHES_LICENSE_B64" ]]   || die "GHES_LICENSE_B64 is required (protected parameter)."

SUBDOM="$(lc "$GHES_SUBDOMAIN_ISOLATION")"; [[ "$SUBDOM" == "true"   || "$SUBDOM" == "false" ]]   || SUBDOM="true"
SIGNUP="$(lc "$GHES_SIGNUP_ENABLED")";      [[ "$SIGNUP" == "true"   || "$SIGNUP" == "false" ]]   || SIGNUP="false"
PUBPAGES="$(lc "$GHES_PUBLIC_PAGES")";      [[ "$PUBPAGES" == "true" || "$PUBPAGES" == "false" ]] || PUBPAGES="false"
PORT="$GHES_MANAGE_PORT"
BASE="https://127.0.0.1:${PORT}"

log "hostname=${GHES_HOSTNAME} port=${PORT} subdomain_isolation=${SUBDOM} signup_enabled=${SIGNUP} public_pages=${PUBPAGES}"

# Decode the license (strip any whitespace/newlines first), lock it down.
printf '%s' "$GHES_LICENSE_B64" | tr -d '[:space:]' | base64 -d > "$LIC_FILE" 2>/dev/null \
    || die "failed to base64-decode GHES_LICENSE_B64."
[[ -s "$LIC_FILE" ]] || die "decoded license file is empty."
chmod 600 "$LIC_FILE"

# Stage the management-console password in a 0600 temp file so it never appears on any process
# command line (/proc/<pid>/cmdline is world-readable); curl reads it from the file / a stdin config.
printf '%s' "$GHES_MGMT_PASSWORD" > "$PW_FILE"
chmod 600 "$PW_FILE"

# Emit a curl config (on stdin, via `curl -K -`) carrying the Basic-auth credential, so it stays
# off argv. Backslash/quote are escaped for curl's quoted-value syntax.
auth_config() {
    local esc=${GHES_MGMT_PASSWORD//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf 'user = "api_key:%s"\n' "$esc"
}

# ---- Helpers ----------------------------------------------------------------
# GET the settings endpoint; prints the HTTP code. 200 => Manage API is answering.
manage_api_code() {
    auth_config | curl -K - -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 \
        "${BASE}/manage/v1/config/settings" 2>/dev/null || echo 000
}

apply_in_progress() { pgrep -f 'ghe-config-apply' >/dev/null 2>&1; }


# ---- 1) First-boot init: upload license + set management-console password ----
init_ghes() {
    local code
    log "initializing via ${BASE}/manage/v1/config/init"
    code=$(curl -k -sS -o "$INIT_OUT" -w '%{http_code}' --connect-timeout 15 --max-time 120 \
        -X POST -F "license=@${LIC_FILE}" -F "password=<${PW_FILE}" \
        "${BASE}/manage/v1/config/init" 2>/dev/null || echo 000)
    case "$code" in
        202) log "init accepted (HTTP 202)."; return 0 ;;
        400) if grep -qiE 'password[[:space:]]+already[[:space:]]+set' "$INIT_OUT" 2>/dev/null; then
                 log "instance already initialized (password already set) - continuing."; return 0
             fi ;;
    esac
    log "manage init returned HTTP ${code}; trying legacy /setup/api/start."
    code=$(curl -k -sS -o "$INIT_OUT" -w '%{http_code}' --connect-timeout 15 --max-time 120 \
        -X POST -F "license=@${LIC_FILE}" -F "password=<${PW_FILE}" \
        "${BASE}/setup/api/start" 2>/dev/null || echo 000)
    case "$code" in
        200|201|202) log "legacy init accepted (HTTP ${code})."; return 0 ;;
        400) if grep -qiE 'password[[:space:]]+already[[:space:]]+set' "$INIT_OUT" 2>/dev/null; then
                 log "instance already initialized - continuing."; return 0
             fi ;;
    esac
    log "init response body (first 300 chars): $(head -c 300 "$INIT_OUT" 2>/dev/null)"
    return 1
}

# ---- 2) Wait for the initial (init-triggered) apply to settle ---------------
wait_ready() {
    local deadline code
    deadline=$(( $(date +%s) + GHES_READY_TIMEOUT_MIN * 60 ))
    log "waiting up to ${GHES_READY_TIMEOUT_MIN}m for Manage API + initial apply to settle."
    while (( $(date +%s) < deadline )); do
        code=$(manage_api_code)
        if [[ "$code" == "200" ]] && ! apply_in_progress; then
            log "Manage API ready (HTTP 200) and no apply in progress."
            return 0
        fi
        log "not ready yet (manage_api=${code}, apply_running=$(apply_in_progress && echo yes || echo no)); retrying in 30s."
        sleep 30
    done
    return 1
}

# ---- 3) Stage core settings via the Manage API ------------------------------
stage_settings() {
    local body code
    body=$(printf '{"github_hostname":"%s","subdomain_isolation":%s,"signup_enabled":%s,"public_pages":%s}' \
        "$GHES_HOSTNAME" "$SUBDOM" "$SIGNUP" "$PUBPAGES")
    log "staging settings via PUT ${BASE}/manage/v1/config/settings"
    code=$(auth_config | curl -K - -k -sS -o "$SETTINGS_OUT" -w '%{http_code}' --connect-timeout 15 --max-time 120 \
        -H 'Content-Type: application/json' \
        -X PUT --data "$body" "${BASE}/manage/v1/config/settings" 2>/dev/null || echo 000)
    if [[ "$code" =~ ^2 ]]; then
        log "settings staged (HTTP ${code})."
        return 0
    fi
    log "settings response body (first 300 chars): $(head -c 300 "$SETTINGS_OUT" 2>/dev/null)"
    die "settings PUT failed (HTTP ${code})."
}

# ---- 4) Apply configuration on-box (canonical, runs as root) ----------------
apply_config() {
    local logf rc
    logf="/data/user/common/ghe-config-apply.$(date -u +%Y%m%d%H%M%S).log"
    log "running ghe-config-apply (timeout ${GHES_APPLY_TIMEOUT_MIN}m); log: ${logf}"
    if command -v timeout >/dev/null 2>&1; then
        timeout "${GHES_APPLY_TIMEOUT_MIN}m" ghe-config-apply >"$logf" 2>&1 && rc=0 || rc=$?
    else
        ghe-config-apply >"$logf" 2>&1 && rc=0 || rc=$?
    fi
    log "ghe-config-apply exit code: ${rc}"
    log "--- last 20 lines of apply log ---"
    tail -n 20 "$logf" 2>/dev/null || true
    log "----------------------------------"
    return "$rc"
}

# ---- 5) On-box endpoint self-verify (post-apply health) ---------------------
verify_endpoints() {
    [[ "$(lc "$GHES_VERIFY")" == "true" ]] || { log "endpoint self-verify skipped (GHES_VERIFY=false)."; return 0; }

    local failures=0
    check_code() {  # $1=desc  $2=url  $3=expected-regex  [extra curl args...]
        local desc="$1" url="$2" expected="$3"; shift 3
        local code
        code=$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 "$@" "$url" 2>/dev/null || echo 000)
        if [[ "$code" =~ ^($expected)$ ]]; then
            log "verify PASS: ${desc} (HTTP ${code})"
        else
            log "verify FAIL: ${desc} (expected ${expected}, got ${code})"
            failures=$((failures + 1))
        fi
    }

    log "verifying appliance endpoints (Host: ${GHES_HOSTNAME})."
    check_code "web root -> redirect to /login" "https://127.0.0.1/"             '301|302' -H "Host: ${GHES_HOSTNAME}"
    check_code "login page reachable"           "https://127.0.0.1/login"        '200'     -H "Host: ${GHES_HOSTNAME}"
    check_code "manage API requires auth"       "${BASE}/manage/v1/config/apply" '401'

    if (( failures > 0 )); then
        if [[ "$(lc "$GHES_VERIFY_STRICT")" == "true" ]]; then
            die "endpoint self-verify failed (${failures} check(s)) and GHES_VERIFY_STRICT=true."
        fi
        log "WARNING: endpoint self-verify reported ${failures} failure(s) (non-fatal; set GHES_VERIFY_STRICT=true to fail)."
    else
        log "endpoint self-verify: all checks passed."
    fi
    return 0
}

# ---- Orchestration ----------------------------------------------------------
init_ghes    || die "GHES first-boot initialization failed."
wait_ready   || die "GHES Manage API did not become ready within ${GHES_READY_TIMEOUT_MIN}m."
stage_settings

if [[ "$(lc "$GHES_SKIP_APPLY")" == "true" ]]; then
    log "GHES_SKIP_APPLY=true - settings staged but skipping ghe-config-apply."
    log "post-config completed (staged only)."
    exit 0
fi

if apply_config; then
    log "post-config completed successfully."
    verify_endpoints
    log "REMINDER: Active Directory objects, DNS records, and LDAP auth-mode remain MANUAL."
    exit 0
else
    die "ghe-config-apply reported a non-zero exit; see the apply log above."
fi
