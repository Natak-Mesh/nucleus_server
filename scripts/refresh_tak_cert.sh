#!/usr/bin/env bash
# ============================================================================
# Nucleus Server - Stage TAK certificates for the web app
#
# The web app (running as a non-root user) builds client data packages on the
# fly, which must embed the TAK *intermediate CA truststore* (public). That
# truststore lives in /opt/tak/certs/files/ owned by the `tak` user with mode
# 0600, so the web app cannot read it directly.
#
# This script stages two files into the target user's ~/certs/:
#
#   caCert.p12    (0644) - the PUBLIC intermediate truststore. Served openly
#                          by the web app so clients can trust this server.
#   webadmin.p12  (0600) - the PRIVATE web-admin client identity. Served ONLY
#                          from behind the operator PIN, hence 0600.
#
# It NEVER copies the CA signing keystore or any raw private key.
#
# Re-run this any time the TAK CA is (re)generated.
#
# Usage (run as root):
#   sudo bash refresh_tak_cert.sh [target-user]
# ============================================================================

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    echo "Usage: sudo bash $0 [target-user]"
    exit 1
fi

# ---- Determine the non-root target user ----
TARGET_USER="${1:-${SUDO_USER:-}}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER=$(logname 2>/dev/null || echo "")
fi
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER=$(awk -F: '$3 >= 1000 && $1 != "nobody" { print $1; exit }' /etc/passwd)
fi
if [ -z "$TARGET_USER" ]; then
    echo "ERROR: Could not determine the target non-root user."
    echo "Pass the username as an argument: sudo bash $0 <username>"
    exit 1
fi

TARGET_HOME=$(eval echo "~${TARGET_USER}")
TARGET_GROUP=$(id -gn "$TARGET_USER")

TAK_CERTS_DIR="/opt/tak/certs/files"
DEST_DIR="${TARGET_HOME}/certs"
DEST_FILE="${DEST_DIR}/caCert.p12"
WEBADMIN_SRC="${TAK_CERTS_DIR}/webadmin.p12"
WEBADMIN_DEST="${DEST_DIR}/webadmin.p12"

echo "===> Staging TAK intermediate CA truststore"
echo "  -> Target user : $TARGET_USER"
echo "  -> Source dir  : $TAK_CERTS_DIR"
echo "  -> Destination : $DEST_FILE"

if [ ! -d "$TAK_CERTS_DIR" ]; then
    echo "ERROR: $TAK_CERTS_DIR not found — TAK server not configured yet."
    exit 1
fi

# ---- Locate the intermediate truststore ----
# Naming convention: truststore-<INT-NAME>.p12, where <INT-NAME> is the
# intermediate CA name chosen at TAK setup. Exclude the root truststore.
INT_TRUSTSTORE=""
shopt -s nullglob
for f in "$TAK_CERTS_DIR"/truststore-*.p12; do
    base=$(basename "$f")
    if [ "$base" = "truststore-root.p12" ]; then
        continue
    fi
    INT_TRUSTSTORE="$f"
    break
done
shopt -u nullglob

if [ -z "$INT_TRUSTSTORE" ]; then
    echo "ERROR: No intermediate truststore (truststore-*.p12, excluding"
    echo "       truststore-root.p12) found in $TAK_CERTS_DIR."
    exit 1
fi

echo "  -> Found intermediate truststore: $(basename "$INT_TRUSTSTORE")"

# Safety: make absolutely sure we never stage a private signing keystore.
case "$(basename "$INT_TRUSTSTORE")" in
    *signing*|*.jks|*.key)
        echo "ERROR: Refusing to stage '$INT_TRUSTSTORE' — looks like a private"
        echo "       key/keystore. Only public truststore-*.p12 may be staged."
        exit 1
        ;;
esac

# ---- Copy it into place with safe ownership/permissions ----
mkdir -p "$DEST_DIR"
chown "${TARGET_USER}:${TARGET_GROUP}" "$DEST_DIR"
install -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0644 "$INT_TRUSTSTORE" "$DEST_FILE"

echo "  -> Staged to $DEST_FILE (owner ${TARGET_USER}, mode 0644)"

# ---- Verify it is a valid p12 readable with the standard TAK password ----
# Note: TAK .p12 files are produced by Java/keytool using legacy encryption
# (RC2/3DES). OpenSSL 3.x refuses to read those unless given the -legacy flag,
# so we try -legacy first and fall back to a plain read for older OpenSSL that
# does not understand the flag. Without this, a perfectly valid truststore
# would falsely report a password failure on modern Debian (trixie+).
if command -v openssl &>/dev/null; then
    if sudo -u "$TARGET_USER" openssl pkcs12 -info -in "$DEST_FILE" \
        -nokeys -legacy -passin pass:atakatak >/dev/null 2>&1 \
       || sudo -u "$TARGET_USER" openssl pkcs12 -info -in "$DEST_FILE" \
        -nokeys -passin pass:atakatak >/dev/null 2>&1; then
        echo "  -> Verified: $TARGET_USER can read the truststore (password OK)."
    else
        echo "  -> WARNING: could not verify the truststore with password 'atakatak'."
        echo "     If this unit used a custom CA password, the data package's"
        echo "     caPassword will need to match it."
    fi
fi

echo "===> TAK CA truststore staged successfully."

# ---- Stage the webadmin client identity (admin-only download) ----
# Unlike the truststore above, webadmin.p12 IS a private client identity: it
# grants full TAK admin. It is staged 0600 (not 0644 like the CA) and the web
# app only serves it from behind the operator PIN. Always named webadmin.p12.
echo "===> Staging webadmin certificate"
if [ -f "$WEBADMIN_SRC" ]; then
    install -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0600 "$WEBADMIN_SRC" "$WEBADMIN_DEST"
    echo "  -> Staged to $WEBADMIN_DEST (owner ${TARGET_USER}, mode 0600)"
else
    echo "  -> NOTE: $WEBADMIN_SRC not found; skipping."
    echo "     The WebAdmin download stays hidden until this cert exists."
fi
