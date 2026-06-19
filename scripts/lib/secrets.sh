#!/usr/bin/env bash
# ============================================================================
# Nucleus Server - Secrets helper library
#
# Sourced by setup scripts to manage per-unit secrets in a single root-only
# store. The guiding rule is PERSISTENCE: secrets are generated exactly once
# and never overwritten on re-run, so re-provisioning a unit never loses (or
# changes) its Mumble password, dashboard PIN, etc.
#
# Store format: simple KEY=value lines (one per secret) at:
#     /etc/nucleus/secrets        (dir 0700, file 0600, owner root)
#
# Usage (from a root-run script):
#     source "${SCRIPT_DIR}/lib/secrets.sh"
#     MUMBLE_PW="$(secret_get_or_create MUMBLE_SUPERUSER_PW gen_password)"
#     ADMIN_PIN="$(secret_get_or_create ADMIN_PIN gen_pin)"
#     secret_get SOME_KEY            # prints value or empty
# ============================================================================

NUCLEUS_SECRETS_DIR="${NUCLEUS_SECRETS_DIR:-/etc/nucleus}"
NUCLEUS_SECRETS_FILE="${NUCLEUS_SECRETS_FILE:-${NUCLEUS_SECRETS_DIR}/secrets}"

# Ensure the secrets store exists with locked-down permissions.
_secrets_ensure_store() {
    if [ ! -d "$NUCLEUS_SECRETS_DIR" ]; then
        mkdir -p "$NUCLEUS_SECRETS_DIR"
    fi
    chmod 0700 "$NUCLEUS_SECRETS_DIR"
    chown root:root "$NUCLEUS_SECRETS_DIR" 2>/dev/null || true
    if [ ! -f "$NUCLEUS_SECRETS_FILE" ]; then
        touch "$NUCLEUS_SECRETS_FILE"
    fi
    chmod 0600 "$NUCLEUS_SECRETS_FILE"
    chown root:root "$NUCLEUS_SECRETS_FILE" 2>/dev/null || true
}

# Generate a strong alphanumeric password (default 20 chars).
gen_password() {
    local len="${1:-20}"
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$len"
}

# Generate a numeric PIN (default 6 digits).
gen_pin() {
    local len="${1:-6}"
    local pin=""
    while [ "${#pin}" -lt "$len" ]; do
        pin+=$(tr -dc '0-9' < /dev/urandom | head -c "$len")
    done
    echo "${pin:0:$len}"
}

# Print the value for KEY (empty string if unset). Exact-key match.
secret_get() {
    local key="$1"
    _secrets_ensure_store
    # Last assignment wins; strip the KEY= prefix.
    grep -E "^${key}=" "$NUCLEUS_SECRETS_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

# Set/replace KEY=value in the store (overwrites if present).
secret_set() {
    local key="$1"
    local value="$2"
    _secrets_ensure_store
    if grep -qE "^${key}=" "$NUCLEUS_SECRETS_FILE" 2>/dev/null; then
        # Replace existing line. Use a delimiter unlikely to appear in values.
        sed -i "s|^${key}=.*|${key}=${value}|" "$NUCLEUS_SECRETS_FILE"
    else
        echo "${key}=${value}" >> "$NUCLEUS_SECRETS_FILE"
    fi
    chmod 0600 "$NUCLEUS_SECRETS_FILE"
}

# Return KEY's value, creating it via GENERATOR (+ args) only if missing.
# This is the persistence primitive: generate-once, never-overwrite.
#   secret_get_or_create ADMIN_PIN gen_pin 6
secret_get_or_create() {
    local key="$1"
    shift
    local generator="$1"
    shift
    local existing
    existing="$(secret_get "$key")"
    if [ -n "$existing" ]; then
        echo "$existing"
        return 0
    fi
    local value
    value="$("$generator" "$@")"
    secret_set "$key" "$value"
    echo "$value"
}
