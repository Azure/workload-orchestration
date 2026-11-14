#!/usr/bin/env bash
set -euo pipefail
umask 077
script_file="$(mktemp)"
cleanup() {
  if command -v shred >/dev/null 2>&1; then
    shred -u "$script_file" 2>/dev/null || rm -f "$script_file"
  else
    rm -f "$script_file"
  fi
}
trap cleanup EXIT
chmod 600 "$script_file"
printf '%s' "$POST_CONFIG_SCRIPT" >"$script_file"
az storage blob upload \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --auth-mode key \
  --container-name "$ASSET_CONTAINER_NAME" \
  --name "$SCRIPT_BLOB_NAME" \
  --file "$script_file" \
  --overwrite true \
  --only-show-errors
