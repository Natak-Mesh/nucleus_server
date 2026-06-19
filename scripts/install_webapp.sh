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
cp -r "$SRC_DIR/app.py" "$SRC_DIR/datapackage.py" "$SRC_DIR/templates" \
      "$SRC_DIR/static" "$SRC_DIR/requirements.txt" "$DEPLOY_DIR/"



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

# --- Secrets file (created by setup_nucleus.sh; ensure it at least exists) ---
SECRETS_FILE="/etc/nucleus/secrets"
if [ ! -f "$SECRETS_FILE" ]; then
    echo "==> NOTE: $SECRETS_FILE not found yet."
    echo "    The admin PIN / Mumble password are provisioned by setup_nucleus.sh."
    echo "    The web app will start, but the admin zone stays locked until that"
    echo "    file exists with an ADMIN_PIN entry. Re-run this installer after"
    echo "    setup_nucleus.sh, or it will pick the file up on next boot."
fi

# --- Sudoers rule: allow the web app user to control ONLY these services ---
# Tightly scoped: exact systemctl verbs + exact unit names, nothing else.
SUDOERS_FILE="/etc/sudoers.d/nucleus-webapp"
echo "==> Installing sudoers rule: $SUDOERS_FILE ..."
cat > "$SUDOERS_FILE" <<EOF
# Allow the Nucleus web app to start/stop/restart ONLY the managed services.
${RUN_USER} ALL=(root) NOPASSWD: \\
    /usr/bin/systemctl start takserver, \\
    /usr/bin/systemctl stop takserver, \\
    /usr/bin/systemctl restart takserver, \\
    /usr/bin/systemctl start mediamtx, \\
    /usr/bin/systemctl stop mediamtx, \\
    /usr/bin/systemctl restart mediamtx, \\
    /usr/bin/systemctl start mumble-server, \\
    /usr/bin/systemctl stop mumble-server, \\
    /usr/bin/systemctl restart mumble-server, \\
    /usr/bin/systemctl start rnsd, \\
    /usr/bin/systemctl stop rnsd, \\
    /usr/bin/systemctl restart rnsd, \\
    /usr/bin/systemctl start nucleus-webapp, \\
    /usr/bin/systemctl restart nucleus-webapp
EOF
chmod 0440 "$SUDOERS_FILE"
# Validate before leaving it in place (a bad sudoers file can lock out sudo).
VISUDO_BIN="$(command -v visudo || echo /usr/sbin/visudo)"
if "$VISUDO_BIN" -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
    echo "==> sudoers rule validated."
else
    echo "ERROR: sudoers rule failed validation; removing it."
    rm -f "$SUDOERS_FILE"
    exit 1
fi

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
# Load the per-unit secrets (ADMIN_PIN, MUMBLE_SUPERUSER_PW) as environment
# variables. systemd reads this as root before dropping to ${RUN_USER}, so the
# web app gets the values without the file being world-readable. '-' => the
# service still starts if the file does not exist yet.
EnvironmentFile=-/etc/nucleus/secrets
# NOTE: NoNewPrivileges is intentionally NOT set — the admin zone uses a
# tightly-scoped 'sudo systemctl' (see /etc/sudoers.d/nucleus-webapp), which
# NoNewPrivileges would block.

[Install]
WantedBy=multi-user.target
EOF


# --- Open port 80 in UFW (info web app) ---
if command -v ufw &>/dev/null; then
    echo "==> Opening web app port in UFW (80/tcp)..."
    ufw allow 80/tcp
    echo "==> UFW rule added."
else
    echo "==> WARNING: ufw not found; skipping firewall rule."
    echo "    Manually open 80/tcp if a firewall is in use."
fi

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
echo "  Browse to (mDNS):  http://$(hostname).local"
echo ""
echo "  Or by IP:"
ip -o -4 addr show scope global 2>/dev/null \
    | awk '{ sub(/\/.*/, "", $4); print "    http://" $4 "  (" $2 ")" }'
echo "============================================"
