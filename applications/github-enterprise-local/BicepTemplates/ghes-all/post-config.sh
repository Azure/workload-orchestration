#!/usr/bin/env bash
set -uo pipefail
umask 077

GHES_HOSTNAME="${GHES_HOSTNAME:-}"
GHES_MGMT_PASSWORD="${GHES_MGMT_PASSWORD:-}"
GHES_LICENSE_B64_PART1="${GHES_LICENSE_B64_PART1:-}"
GHES_LICENSE_B64_PART2="${GHES_LICENSE_B64_PART2:-}"

GHES_SUBDOMAIN_ISOLATION="${GHES_SUBDOMAIN_ISOLATION:-true}"
GHES_SIGNUP_ENABLED="${GHES_SIGNUP_ENABLED:-false}"
GHES_PUBLIC_PAGES="${GHES_PUBLIC_PAGES:-false}"

GHES_MANAGE_PORT="${GHES_MANAGE_PORT:-8443}"
GHES_APPLY_TIMEOUT_MIN="${GHES_APPLY_TIMEOUT_MIN:-120}"
GHES_READY_TIMEOUT_MIN="${GHES_READY_TIMEOUT_MIN:-30}"

GHES_SKIP_APPLY="${GHES_SKIP_APPLY:-false}"
GHES_VERIFY="${GHES_VERIFY:-true}"
GHES_VERIFY_STRICT="${GHES_VERIFY_STRICT:-false}"

LIC_FILE="$(mktemp /tmp/ghes-license.XXXXXX.ghl)"
PW_FILE="$(mktemp /tmp/ghes-pw.XXXXXX)"
INIT_OUT="$(mktemp /tmp/ghes-init.XXXXXX.out)"
LEGACY_INIT_OUT="$(mktemp /tmp/ghes-legacy-init.XXXXXX.out)"
SETTINGS_OUT="$(mktemp /tmp/ghes-settings.XXXXXX.out)"

log() {
    printf '%s [post-config] %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

secure_remove() {
    local path="$1"

    if command -v shred >/dev/null 2>&1; then
        shred -u "$path" 2>/dev/null || rm -f "$path"
    else
        rm -f "$path"
    fi
}

cleanup() {
    secure_remove "$LIC_FILE"
    secure_remove "$PW_FILE"
    secure_remove "$INIT_OUT"
    secure_remove "$LEGACY_INIT_OUT"
    secure_remove "$SETTINGS_OUT"
}

die() {
    log "ERROR: $*"
    cleanup
    exit 1
}

trap cleanup EXIT

lc() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

response_diagnostic() {
    local path="$1"

    [[ -s "$path" ]] || {
        printf '%s' '<empty>'
        return
    }

    awk -v password_file="$PW_FILE" '
        BEGIN {
            if ((getline password < password_file) < 0) {
                password = ""
            }
            close(password_file)
            limit = 1000
            emitted = 0
        }

        function redact_literal(text, secret, replacement, pos) {
            if (secret == "") {
                return text
            }

            while ((pos = index(text, secret)) > 0) {
                text = substr(text, 1, pos - 1) replacement substr(text, pos + length(secret))
            }

            return text
        }

        function redact_url_queries(text, output, token, query_pos) {
            output = ""

            while (match(text, /https?:\/\/[^[:space:]"]+\?[^[:space:]"]*/)) {
                token = substr(text, RSTART, RLENGTH)
                query_pos = index(token, "?")
                output = output substr(text, 1, RSTART - 1) \
                    substr(token, 1, query_pos) "[REDACTED]"
                text = substr(text, RSTART + RLENGTH)
            }

            return output text
        }

        function redact_sensitive_json_values(text, output, lower, prefix, rest, quote_pos) {
            output = ""
            lower = tolower(text)

            while (match(lower, /"(password|license|license_uri|license_url|sas|token)"[[:space:]]*:[[:space:]]*"/)) {
                prefix = substr(text, 1, RSTART + RLENGTH - 1)
                rest = substr(text, RSTART + RLENGTH)
                quote_pos = index(rest, "\"")

                if (quote_pos == 0) {
                    output = output prefix "[REDACTED]"
                    text = ""
                } else {
                    output = output prefix "[REDACTED]\""
                    text = substr(rest, quote_pos + 1)
                }

                lower = tolower(text)
            }

            return output text
        }

        {
            line = $0
            gsub(/[[:cntrl:]]/, " ", line)
            line = redact_literal(line, password, "[REDACTED]")
            line = redact_url_queries(line)
            line = redact_sensitive_json_values(line)
            line = line " "

            remaining = limit - emitted
            if (remaining > 0) {
                printf "%s", substr(line, 1, remaining)
                emitted += length(substr(line, 1, remaining))
            }

            if (emitted >= limit) {
                exit
            }
        }
    ' "$path"
}

already_initialized_response() {
    local path="$1"

    grep -qiE \
        '(already[[:space:]]+(been[[:space:]]+)?initialized|initialization[[:space:]]+already[[:space:]]+(complete|completed)|password[^[:cntrl:]]{0,80}already[[:space:]]+(been[[:space:]]+)?set)' \
        "$path" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Prerequisite validation
# ---------------------------------------------------------------------------

[[ "${EUID:-$(id -u)}" -eq 0 ]] ||
    die "must run as root (Arc Linux Run Command runs as root by default)."

command -v curl >/dev/null 2>&1 ||
    die "curl not found on the appliance."

command -v ghe-config-apply >/dev/null 2>&1 ||
    die "ghe-config-apply not found - this does not look like a GHES appliance."

[[ -n "$GHES_HOSTNAME" ]] ||
    die "GHES_HOSTNAME is required."

[[ -n "$GHES_MGMT_PASSWORD" ]] ||
    die "GHES_MGMT_PASSWORD is required (protected parameter)."

[[ -n "$GHES_LICENSE_B64_PART1" ]] ||
    die "GHES_LICENSE_B64_PART1 is required (protected parameter)."

[[ -n "$GHES_LICENSE_B64_PART2" ]] ||
    die "GHES_LICENSE_B64_PART2 is required (protected parameter)."

# ---------------------------------------------------------------------------
# Normalize settings
# ---------------------------------------------------------------------------

SUBDOM="$(lc "$GHES_SUBDOMAIN_ISOLATION")"
[[ "$SUBDOM" == "true" || "$SUBDOM" == "false" ]] || SUBDOM="true"

SIGNUP="$(lc "$GHES_SIGNUP_ENABLED")"
[[ "$SIGNUP" == "true" || "$SIGNUP" == "false" ]] || SIGNUP="false"

PUBPAGES="$(lc "$GHES_PUBLIC_PAGES")"
[[ "$PUBPAGES" == "true" || "$PUBPAGES" == "false" ]] || PUBPAGES="false"

PORT="$GHES_MANAGE_PORT"
BASE="https://127.0.0.1:${PORT}"

log "hostname=${GHES_HOSTNAME} port=${PORT} subdomain_isolation=${SUBDOM} signup_enabled=${SIGNUP} public_pages=${PUBPAGES}"

# ---------------------------------------------------------------------------
# Reconstruct GHES license
# ---------------------------------------------------------------------------

if ! printf '%s%s' "$GHES_LICENSE_B64_PART1" "$GHES_LICENSE_B64_PART2" | base64 -d > "$LIC_FILE"; then
    die "failed to base64-decode the GHES license."
fi

if [[ ! -s "$LIC_FILE" ]]; then
    die "decoded GHES license file is empty."
fi

chmod 600 "$LIC_FILE"

unset GHES_LICENSE_B64_PART1 GHES_LICENSE_B64_PART2

printf '%s' "$GHES_MGMT_PASSWORD" >"$PW_FILE"
chmod 600 "$PW_FILE"

# ---------------------------------------------------------------------------
# Authentication helper
# ---------------------------------------------------------------------------

auth_config() {
    local esc=${GHES_MGMT_PASSWORD//\\/\\\\}
    esc=${esc//\"/\\\"}

    printf 'user = "api_key:%s"\n' "$esc"
}

manage_api_code() {
    local code

    code=$(
        auth_config |
            curl \
                -K - \
                -k \
                -sS \
                -o /dev/null \
                -w '%{http_code}' \
                --connect-timeout 10 \
                --max-time 30 \
                "${BASE}/manage/v1/config/settings" \
                2>/dev/null ||
            echo 000
    )

    printf '%s' "${code: -3}"
}

apply_in_progress() {
    pgrep -f 'ghe-config-apply' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Initialize GHES
# ---------------------------------------------------------------------------

init_ghes() {
    local code
    local diagnostic

    code=$(manage_api_code)
    if [[ "$code" == "200" ]]; then
        log "Manage API is already authenticated (HTTP 200); initialization is complete."
        return 0
    fi

    log "initializing via ${BASE}/manage/v1/config/init"

    code=$(
        curl \
            -k \
            -sS \
            -o "$INIT_OUT" \
            -w '%{http_code}' \
            --connect-timeout 15 \
            --max-time 120 \
            -X POST \
            -F "license=@${LIC_FILE}" \
            -F "password=<${PW_FILE}" \
            "${BASE}/manage/v1/config/init" \
            2>/dev/null ||
            echo 000
    )
    code="${code: -3}"

    case "$code" in
        200|201|202)
            log "manage init accepted (HTTP ${code})."
            return 0
            ;;
        400)
            if [[ "$(manage_api_code)" == "200" ]]; then
                log "manage init returned HTTP 400, but authenticated Manage API is now available; initialization is complete."
                return 0
            fi

            if already_initialized_response "$INIT_OUT"; then
                log "manage init reports the instance is already initialized; continuing."
                return 0
            fi
            ;;
    esac

    if [[ ! "$code" =~ ^(404|405|410)$ ]]; then
        diagnostic=$(response_diagnostic "$INIT_OUT")
        log "initialization failed at /manage/v1/config/init (HTTP ${code}); response: ${diagnostic}"
        return 1
    fi

    diagnostic=$(response_diagnostic "$INIT_OUT")
    log "manage init endpoint unavailable (HTTP ${code}); response: ${diagnostic}; trying legacy /setup/api/start."

    code=$(
        curl \
            -k \
            -sS \
            -o "$LEGACY_INIT_OUT" \
            -w '%{http_code}' \
            --connect-timeout 15 \
            --max-time 120 \
            -X POST \
            -F "license=@${LIC_FILE}" \
            -F "password=<${PW_FILE}" \
            "${BASE}/setup/api/start" \
            2>/dev/null ||
            echo 000
    )
    code="${code: -3}"

    case "$code" in
        200|201|202)
            log "legacy init accepted (HTTP ${code})."
            return 0
            ;;
        400)
            if [[ "$(manage_api_code)" == "200" ]]; then
                log "legacy init returned HTTP 400, but authenticated Manage API is now available; initialization is complete."
                return 0
            fi

            if already_initialized_response "$LEGACY_INIT_OUT"; then
                log "legacy init reports the instance is already initialized; continuing."
                return 0
            fi
            ;;
    esac

    diagnostic=$(response_diagnostic "$LEGACY_INIT_OUT")
    log "initialization failed at /setup/api/start (HTTP ${code}); response: ${diagnostic}"
    return 1
}

# ---------------------------------------------------------------------------
# Wait for Manage API
# ---------------------------------------------------------------------------

wait_ready() {
    local deadline
    local code

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

# ---------------------------------------------------------------------------
# Stage GHES settings
# ---------------------------------------------------------------------------

stage_settings() {
    local body
    local code

    body=$(
        printf \
            '{"github_hostname":"%s","subdomain_isolation":%s,"signup_enabled":%s,"public_pages":%s}' \
            "$GHES_HOSTNAME" \
            "$SUBDOM" \
            "$SIGNUP" \
            "$PUBPAGES"
    )

    log "staging settings via PUT ${BASE}/manage/v1/config/settings"

    code=$(
        auth_config |
            curl \
                -K - \
                -k \
                -sS \
                -o "$SETTINGS_OUT" \
                -w '%{http_code}' \
                --connect-timeout 15 \
                --max-time 120 \
                -H 'Content-Type: application/json' \
                -X PUT \
                --data "$body" \
                "${BASE}/manage/v1/config/settings" \
                2>/dev/null ||
            echo 000
    )

    if [[ "$code" =~ ^2 ]]; then
        log "settings staged (HTTP ${code})."
        return 0
    fi

    die "settings PUT failed (HTTP ${code}); response body suppressed."
}

# ---------------------------------------------------------------------------
# Apply GHES configuration
# ---------------------------------------------------------------------------

apply_config() {
    local logf
    local rc

    logf="/data/user/common/ghe-config-apply.$(date -u +%Y%m%d%H%M%S).log"

    log "running ghe-config-apply (timeout ${GHES_APPLY_TIMEOUT_MIN}m); log: ${logf}"

    if command -v timeout >/dev/null 2>&1; then
        timeout "${GHES_APPLY_TIMEOUT_MIN}m" \
            ghe-config-apply >"$logf" 2>&1 &&
            rc=0 ||
            rc=$?
    else
        ghe-config-apply >"$logf" 2>&1 &&
            rc=0 ||
            rc=$?
    fi

    log "ghe-config-apply exit code: ${rc}"
    log "--- last 20 lines of apply log ---"

    tail -n 20 "$logf" 2>/dev/null || true

    log "----------------------------------"

    return "$rc"
}

# ---------------------------------------------------------------------------
# Verify endpoints
# ---------------------------------------------------------------------------

verify_endpoints() {
    [[ "$(lc "$GHES_VERIFY")" == "true" ]] || {
        log "endpoint self-verify skipped (GHES_VERIFY=false)."
        return 0
    }

    local failures=0

    check_code() {
        local desc="$1"
        local url="$2"
        local expected="$3"
        local code

        shift 3

        code=$(
            curl \
                -k \
                -sS \
                -o /dev/null \
                -w '%{http_code}' \
                --connect-timeout 10 \
                --max-time 30 \
                "$@" \
                "$url" \
                2>/dev/null ||
                echo 000
        )

        if [[ "$code" =~ ^($expected)$ ]]; then
            log "verify PASS: ${desc} (HTTP ${code})"
        else
            log "verify FAIL: ${desc} (expected ${expected}, got ${code})"
            failures=$((failures + 1))
        fi
    }

    log "verifying appliance endpoints (Host: ${GHES_HOSTNAME})."

    check_code \
        "web root -> redirect to /login" \
        "https://127.0.0.1/" \
        '301|302' \
        -H "Host: ${GHES_HOSTNAME}"

    check_code \
        "login page reachable" \
        "https://127.0.0.1/login" \
        '200' \
        -H "Host: ${GHES_HOSTNAME}"

    check_code \
        "manage API requires auth" \
        "${BASE}/manage/v1/config/apply" \
        '401'

    if (( failures > 0 )); then
        if [[ "$(lc "$GHES_VERIFY_STRICT")" == "true" ]]; then
            die "endpoint self-verify failed (${failures} check(s)) and GHES_VERIFY_STRICT=true."
        fi

        log "WARNING: endpoint self-verify reported ${failures} failure(s) (non-fatal; set GHES_VERIFY_STRICT=true to fail)."
    else
        log "endpoint self-verify: all checks passed."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

init_ghes ||
    die "GHES first-boot initialization failed."

wait_ready ||
    die "GHES Manage API did not become ready within ${GHES_READY_TIMEOUT_MIN}m."

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
fi

die "ghe-config-apply reported a non-zero exit; see the apply log above."