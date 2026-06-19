#!/usr/bin/env bash
# ============================================================================
# Nucleus Server - Reticulum MeshChatX Installer
#
# Deploys MeshChatX (https://github.com/Quad4-Software/MeshChatX) as a headless
# web UI for the existing Reticulum stack. MeshChatX is installed from its
# prebuilt Python wheel (which bundles the built web frontend — no Node/pnpm
# build step needed) into a dedicated venv at /opt/meshchatx, and run by a
# systemd service on port 8000.
#
# Because it is pointed at the target user's ~/.reticulum config (which has
# `share_instance = Yes`), MeshChatX attaches to the already-running shared
# rnsd instance instead of opening its own interfaces — no second stack, no
# config changes.
#
# Version policy: tracks the LATEST GitHub release (no pin). Re-running the
# installer pulls whatever the current latest wheel is. For offline/field
# builds, drop a wheel at <repo>/vendor/ and it will be used if the download
# fails.
#
# Run as root:
#   sudo bash /home/natak/nucleus_server/scripts/install_meshchatx.sh
# ============================================================================

set -euo pipefail

# --- Configuration ---
APP_NAME="meshchatx"
DEPLOY_DIR="/opt/${APP_NAME}"
STORAGE_DIR="${DEPLOY_DIR}/storage"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
LISTEN_PORT="8000"
GH_REPO="Quad4-Software/MeshChatX"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# --- Must be root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    echo "Usage: sudo bash $0"
    exit 1
fi

# --- Determine the user the service should run as ---
RUN_USER="${SUDO_USER:-}"
if [ -z "$RUN_USER" ] || [ "$RUN_USER" = "root" ]; then
    RUN_USER=$(awk -F: '$3 >= 1000 && $1 != "nobody" { print $1; exit }' /etc/passwd)
fi
# Allow overriding via command-line argument
if [ $# -ge 1 ]; then
    RUN_USER="$1"
fi
RUN_HOME=$(eval echo "~${RUN_USER}")
RETICULUM_CONFIG_DIR="${RUN_HOME}/.reticulum"
echo "==> Service will run as user: $RUN_USER"
echo "==> Reticulum config dir    : $RETICULUM_CONFIG_DIR"

# --- Ensure python3 venv support is available ---
if ! python3 -m venv --help >/dev/null 2>&1; then
    echo "==> Installing python3-venv ..."
    apt update -y
    apt install -y python3-venv
fi
# curl is needed to query the GitHub API / download the wheel.
if ! command -v curl &>/dev/null; then
    echo "==> Installing curl ..."
    apt install -y curl
fi

# --- Resolve the latest release wheel URL via the GitHub API ---
echo "==> Querying latest ${GH_REPO} release ..."
API_JSON="$(curl -fsSL "https://api.github.com/repos/${GH_REPO}/releases/latest" || true)"

# Pull the browser_download_url of the *.whl asset (no jq dependency).
WHEEL_URL="$(printf '%s\n' "$API_JSON" \
    | grep -oE '"browser_download_url": *"[^"]*\.whl"' \
    | head -n1 \
    | sed -E 's/.*"(https[^"]+\.whl)".*/\1/')"

# --- Acquire the wheel (download, else offline vendor fallback) ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
WHEEL_PATH=""

if [ -n "$WHEEL_URL" ]; then
    WHEEL_NAME="$(basename "$WHEEL_URL")"
    echo "==> Downloading wheel: $WHEEL_NAME"
    if curl -fsSL "$WHEEL_URL" -o "${TMPDIR}/${WHEEL_NAME}"; then
        WHEEL_PATH="${TMPDIR}/${WHEEL_NAME}"
        echo "==> Download complete."
    else
        echo "==> WARNING: wheel download failed; will try offline vendor fallback."
    fi
else
    echo "==> WARNING: could not determine wheel URL from GitHub API;"
    echo "    will try offline vendor fallback."
fi

# Offline fallback: newest *.whl placed under <repo>/vendor/
if [ -z "$WHEEL_PATH" ]; then
    VENDOR_WHEEL="$(ls -1t "${REPO_DIR}/vendor/"reticulum_meshchatx-*.whl 2>/dev/null | head -n1 || true)"
    if [ -n "$VENDOR_WHEEL" ]; then
        echo "==> Using vendored wheel: $VENDOR_WHEEL"
        WHEEL_PATH="$VENDOR_WHEEL"
    fi
fi

if [ -z "$WHEEL_PATH" ]; then
    echo "ERROR: Could not obtain a MeshChatX wheel (download failed and no"
    echo "       vendored wheel found at ${REPO_DIR}/vendor/reticulum_meshchatx-*.whl)."
    exit 1
fi

# --- Create deploy + storage dirs ---
echo "==> Preparing $DEPLOY_DIR ..."
mkdir -p "$DEPLOY_DIR" "$STORAGE_DIR"

# --- Create / reuse the venv and install the wheel ---
if [ ! -d "$DEPLOY_DIR/.venv" ]; then
    echo "==> Creating Python venv ..."
    python3 -m venv "$DEPLOY_DIR/.venv"
fi
echo "==> Installing MeshChatX wheel into the venv ..."
"$DEPLOY_DIR/.venv/bin/pip" install --upgrade pip >/dev/null
# --force-reinstall so re-running upgrades to the latest wheel in place.
"$DEPLOY_DIR/.venv/bin/pip" install --upgrade --force-reinstall "$WHEEL_PATH"

# Resolve the installed entrypoint (prefer the console script).
MESHCHATX_BIN="$DEPLOY_DIR/.venv/bin/meshchatx"
if [ -x "$MESHCHATX_BIN" ]; then
    EXEC_CMD="${MESHCHATX_BIN}"
else
    # Fall back to invoking the module if the console script name differs.
    EXEC_CMD="${DEPLOY_DIR}/.venv/bin/python -m meshchatx.meshchat"
    echo "==> NOTE: 'meshchatx' console script not found; using module entrypoint."
fi

# --- Ownership ---
chown -R "$RUN_USER":"$RUN_USER" "$DEPLOY_DIR"

# --- Write the systemd service ---
echo "==> Writing systemd service: $SERVICE_FILE ..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Reticulum MeshChatX (headless web UI)
# Start after the shared Reticulum daemon so MeshChatX attaches to the existing
# shared instance instead of racing to create its own.
After=network.target rnsd.service
Wants=rnsd.service

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${DEPLOY_DIR}
# Headless web server on all interfaces (LAN/AP), port ${LISTEN_PORT}.
# --reticulum-config-dir points at the target user's shared rnsd config so
# MeshChatX joins the running instance rather than opening its own interfaces.
ExecStart=${EXEC_CMD} --headless --no-https --host 0.0.0.0 --port ${LISTEN_PORT} --reticulum-config-dir ${RETICULUM_CONFIG_DIR} --storage-dir ${STORAGE_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# --- Open the web UI port in UFW (LAN/AP access) ---
if command -v ufw &>/dev/null; then
    echo "==> Opening MeshChatX port in UFW (${LISTEN_PORT}/tcp) ..."
    ufw allow "${LISTEN_PORT}/tcp" comment "MeshChatX web UI"
else
    echo "==> WARNING: ufw not found; skipping firewall rule."
    echo "    Manually open ${LISTEN_PORT}/tcp if a firewall is in use."
fi

# --- Enable + start ---
echo "==> Enabling and starting ${APP_NAME} ..."
systemctl daemon-reload
systemctl enable "${APP_NAME}.service"
systemctl restart "${APP_NAME}.service"

# --- Status ---
sleep 2
systemctl status "${APP_NAME}.service" --no-pager || true

echo ""
echo "============================================"
echo "  MeshChatX installed."
echo "  Browse to (mDNS):  http://$(hostname).local:${LISTEN_PORT}"
echo ""
echo "  Or by IP:"
ip -o -4 addr show scope global 2>/dev/null \
    | awk -v p="${LISTEN_PORT}" '{ sub(/\/.*/, "", $4); print "    http://" $4 ":" p "  (" $2 ")" }'
echo "============================================"
