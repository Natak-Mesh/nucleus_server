#!/usr/bin/env bash
# ============================================================================
# Nucleus Server - Info Web App Installer
#
# Deploys the Flask info app to /opt/nucleus-webapp, creates a Python venv,
# installs dependencies (flask + waitress), and installs/enables a systemd
# service that serves the page on port 80 (no port number needed in the URL).
#
# The service runs as an unprivileged user but is granted
# CAP_NET_BIND_SERVICE so it can bind the privileged port 80 without root.
#
# Run as root:
#   sudo bash /home/natak/nucleus_server/scripts/install_webapp.sh
# ============================================================================

set -euo pipefail

# --- Configuration ---
APP_NAME="nucleus-webapp"
DEPLOY_DIR="/opt/${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
# Source dir = the webapp/ folder next to this script's parent (the git repo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(dirname "$SCRIPT_DIR")/webapp"

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
echo "==> Service will run as user: $RUN_USER"

# --- Sanity check the source ---
if [ ! -f "$SRC_DIR/app.py" ]; then
    echo "ERROR: Could not find app.py in $SRC_DIR"
    exit 1
fi

# --- Deploy source to /opt ---
echo "==> Deploying source to $DEPLOY_DIR ..."
mkdir -p "$DEPLOY_DIR"
cp -r "$SRC_DIR/app.py" "$SRC_DIR/templates" "$SRC_DIR/requirements.txt" "$DEPLOY_DIR/"

# --- Create / update the venv ---
if [ ! -d "$DEPLOY_DIR/.venv" ]; then
    echo "==> Creating Python venv ..."
    python3 -m venv "$DEPLOY_DIR/.venv"
fi
echo "==> Installing dependencies (flask, waitress) ..."
"$DEPLOY_DIR/.venv/bin/pip" install --upgrade pip >/dev/null
"$DEPLOY_DIR/.venv/bin/pip" install -r "$DEPLOY_DIR/requirements.txt"

# --- Ownership ---
chown -R "$RUN_USER":"$RUN_USER" "$DEPLOY_DIR"

# --- Write the systemd service ---
echo "==> Writing systemd service: $SERVICE_FILE ..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Nucleus Server Info Web App
After=network.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${DEPLOY_DIR}
ExecStart=${DEPLOY_DIR}/.venv/bin/python ${DEPLOY_DIR}/app.py
Restart=on-failure
RestartSec=3
# Allow binding privileged port 80 without full root
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

# --- Enable + start ---
echo "==> Enabling and starting ${APP_NAME} ..."
systemctl daemon-reload
systemctl enable "${APP_NAME}.service"
systemctl restart "${APP_NAME}.service"

# --- Status ---
sleep 1
systemctl status "${APP_NAME}.service" --no-pager || true

echo ""
echo "============================================"
echo "  Web app installed."
echo "  Browse to:  http://10.30.1.1"
echo "  (Connect to WiFi SSID: 001-server-nucleus)"
echo "============================================"
