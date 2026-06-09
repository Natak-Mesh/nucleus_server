#!/usr/bin/env bash
# ============================================================================
# Nucleus Server - Mumble (VOIP) Server Installer
#
# Installs the Mumble server (Debian package 'mumble-server', formerly Murmur),
# enables and starts it, and opens its ports in UFW so ATAK's Mumble voice
# plugin can connect.
#
# Mumble listens on its stock default port 64738:
#   - 64738/tcp  control channel
#   - 64738/udp  voice
#
# Run as root:
#   sudo bash /home/natak/nucleus_server/scripts/install_mumble.sh
# ============================================================================

set -euo pipefail

# --- Configuration ---
MUMBLE_PORT=64738

# Mumble SuperUser (admin) password.
# This is the password for the built-in "SuperUser" admin account, which you
# use to administer the server (create channels, ban users, grant admin to
# others) by logging in from a Mumble desktop client with username "SuperUser".
#
# Change it to whatever you want, then re-run this script -- OR change it later
# at any time without re-running the script:
#   sudo mumble-server -supw <new-password>
MUMBLE_SUPERUSER_PW="52235223"


# --- Must be root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    echo "Usage: sudo bash $0"
    exit 1
fi

# --- Install mumble-server ---
if dpkg -l mumble-server &>/dev/null 2>&1 && dpkg -l mumble-server | grep -q '^ii'; then
    echo "==> mumble-server is already installed."
else
    echo "==> Installing mumble-server..."
    apt update -y
    apt install -y mumble-server
    echo "==> mumble-server installed."
fi

# --- Enable and start mumble-server ---
echo "==> Enabling and starting mumble-server..."
systemctl enable mumble-server
systemctl restart mumble-server
echo "==> mumble-server is running."

# --- Set the SuperUser (admin) password ---
echo "==> Setting Mumble SuperUser password..."
mumble-server -supw "$MUMBLE_SUPERUSER_PW"
echo "==> SuperUser password set."

# --- Open ports in UFW ---

if command -v ufw &>/dev/null; then
    echo "==> Opening Mumble ports in UFW (${MUMBLE_PORT}/tcp, ${MUMBLE_PORT}/udp)..."
    ufw allow "${MUMBLE_PORT}/tcp"     # Mumble control channel
    ufw allow "${MUMBLE_PORT}/udp"     # Mumble voice
    echo "==> UFW rules added."
else
    echo "==> WARNING: ufw not found; skipping firewall rules."
    echo "    Manually open ${MUMBLE_PORT}/tcp and ${MUMBLE_PORT}/udp if a firewall is in use."
fi

# --- Status ---
sleep 1
systemctl status mumble-server --no-pager || true

# --- Summary ---
echo ""
echo "============================================"
echo "  Mumble server installed."
echo "  Port: ${MUMBLE_PORT} (tcp control + udp voice)"
echo ""
echo "  SuperUser (admin) password has been set."
echo "  Log in as user 'SuperUser' from a Mumble desktop client to administer."
echo ""
echo "  To change the password: edit MUMBLE_SUPERUSER_PW near the top of this"
echo "  script and re-run it, OR run directly (no re-run needed):"
echo "    sudo mumble-server -supw <new-password>"
echo ""
echo "  ATAK: connect via the Mumble plugin on port ${MUMBLE_PORT}."
echo "============================================"

