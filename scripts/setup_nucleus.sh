#!/usr/bin/env bash
# ============================================================================
# Nucleus Server - Full Setup Script
#
# One-shot provisioning script that installs and configures all Nucleus
# server services on a fresh Debian system:
#
#   1. Core packages  (curl, pipx, avahi-daemon)
#   2. WiFi AP        (hostapd access point)
#   3. Tailscale      (secure mesh VPN)
#   4. Reticulum      (resilient mesh networking daemon)
#   5. MeshChatX      (headless web UI for Reticulum)
#   6. Web App        (Nucleus info dashboard on port 80)
#   7. Firewall       (UFW rules for MediaMTX + Mumble)
#
# MediaMTX and Mumble are deliberately NOT installed here. The OpenTAKServer
# installer ships its own pinned MediaMTX (overwriting mediamtx.service) and
# installs mumble-server when you answer Y at its prompt. Installing them
# ahead of time only created unit/config overwrites to reconcile afterwards.
# Their UFW ports are still opened here (step 7) so both work as soon as the
# OTS installer puts them on the box.
#
# All services are enabled to auto-start on boot.
# The script is idempotent — safe to re-run.
#
# Prerequisites: sudo and git must already be installed.
#
# Run as root:
#   sudo bash /home/natak/nucleus_server/scripts/setup_nucleus.sh
# ============================================================================

set -euo pipefail

# ---- Must be root ----
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    echo "Usage: sudo bash $0"
    exit 1
fi

# ---- Determine the non-root target user ----
TARGET_USER="${SUDO_USER:-}"
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
# Allow overriding via command-line argument
if [ $# -ge 1 ]; then
    TARGET_USER="$1"
fi

TARGET_HOME=$(eval echo "~${TARGET_USER}")

echo ""
echo "============================================"
echo "  Nucleus Server Setup"
echo "  Target user: $TARGET_USER"
echo "============================================"
echo ""

# ---- Resolve the repo root (where this script lives) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ---- Per-unit secrets (generate-once, persisted, never overwritten) ----
# shellcheck source=lib/secrets.sh
source "${SCRIPT_DIR}/lib/secrets.sh"
# Fixed appliance-wide dashboard admin PIN. Note: this is the same value as the
# default WIFI_PSK, so anyone who can join the AP can also unlock the admin
# zone (which can start/stop TAK, Mumble, MediaMTX and Reticulum once the
# OpenTAKServer install has put those services on the box). Replace this
# with 'gen_pin 6' to go back to a random per-unit PIN.
ADMIN_PIN="$(secret_get_or_create ADMIN_PIN echo 52235223)"


# ============================================================================
# 0. Preflight checks (advisory — warns, does not hard-fail)
# ============================================================================

echo "===> [0] Preflight checks"

PREFLIGHT_WARN=0

# Architecture
ARCH="$(uname -m)"
echo "  -> Architecture : $ARCH"
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ]; then
    echo "     WARNING: untested architecture '$ARCH' (expected x86_64 or aarch64)."
    PREFLIGHT_WARN=1
fi

# RAM (TAK server needs 8 GB)
MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_GB=$(( MEM_KB / 1024 / 1024 ))
echo "  -> RAM          : ${MEM_GB} GB"
if [ "$MEM_GB" -lt 8 ]; then
    echo "     WARNING: < 8 GB RAM. The official TAK server requires 8 GB."
    PREFLIGHT_WARN=1
fi

# Free disk on / (root)
DISK_AVAIL=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
echo "  -> Free disk (/): ${DISK_AVAIL} GB"
if [ -n "$DISK_AVAIL" ] && [ "$DISK_AVAIL" -lt 10 ]; then
    echo "     WARNING: < 10 GB free on /."
    PREFLIGHT_WARN=1
fi

# At least one wireless interface (needed for the AP)
WIFI_COUNT=0
for w in /sys/class/net/*/wireless; do
    [ -d "$w" ] && WIFI_COUNT=$((WIFI_COUNT + 1))
done
echo "  -> WiFi adapters: $WIFI_COUNT"
if [ "$WIFI_COUNT" -eq 0 ]; then
    echo "     WARNING: no wireless interface detected — the WiFi AP step will fail."
    PREFLIGHT_WARN=1
fi

if [ "$PREFLIGHT_WARN" -eq 0 ]; then
    echo "  -> Preflight: all checks passed."
else
    echo "  -> Preflight: completed with warnings (continuing in 3s) ..."
    sleep 3
fi
echo ""

# ============================================================================
# 1. Core Packages
# ============================================================================
echo "===> [1/7] Core packages (curl, pipx, iw, ufw, wifi firmware, avahi-daemon)"


apt update -y

for pkg in curl pipx; do
    if command -v "$pkg" &>/dev/null; then
        echo "  -> $pkg is already installed."
    else
        echo "  -> Installing $pkg ..."
        apt install -y "$pkg"
    fi
done

# iw — required by setup_ap.sh (iw reg set US). Install here so it is
# guaranteed present before the AP step runs, regardless of setup_ap.sh.
if command -v iw &>/dev/null; then
    echo "  -> iw is already installed."
else
    echo "  -> Installing iw ..."
    apt install -y iw
fi

# ufw — required by setup_ap.sh, which configures the AP firewall rules and the
# NAT masquerade for internet sharing. Install here for the same reason as iw:
# guarantee it is present before the AP step runs. When it was missing,
# setup_ap.sh silently skipped both firewall steps and clients ended up with a
# working AP, a DHCP lease, and no route to the internet.
if command -v ufw &>/dev/null; then
    echo "  -> ufw is already installed."
else
    echo "  -> Installing ufw ..."
    apt install -y ufw
fi

# Wireless firmware blobs. USB WiFi dongles get swapped often, and without the
# matching firmware the kernel driver binds to the device but the probe fails,
# so no wireless interface is ever created and the AP step has nothing to
# configure. Install broadly up front (Realtek rtw88, MediaTek mt76, etc.).
for fw in firmware-realtek firmware-mediatek firmware-misc-nonfree firmware-atheros; do
    if dpkg -l "$fw" 2>/dev/null | grep -q '^ii'; then
        echo "  -> $fw is already installed."
    else
        echo "  -> Installing $fw ..."
        apt install -y "$fw" || echo "     WARNING: failed to install $fw (continuing)."
    fi
done



# avahi-daemon for .local mDNS
if dpkg -l avahi-daemon 2>/dev/null | grep -q '^ii'; then
    echo "  -> avahi-daemon is already installed."
else
    echo "  -> Installing avahi-daemon ..."
    apt install -y avahi-daemon
fi
systemctl enable avahi-daemon
systemctl start avahi-daemon
echo "  -> avahi-daemon is running."

# Add user to sudo group if not already
if id -nG "$TARGET_USER" | grep -qw sudo; then
    echo "  -> $TARGET_USER is already in the sudo group."
else
    echo "  -> Adding $TARGET_USER to the sudo group ..."
    /usr/sbin/usermod -aG sudo "$TARGET_USER"
    echo "     NOTE: Log out and back in for group changes to take effect."
fi

echo ""

# ============================================================================
# 2. WiFi Access Point (hostapd + internet sharing)
# ============================================================================
echo "===> [2/7] WiFi Access Point (hostapd + internet sharing)"
echo "  -> Delegating to setup_ap.sh ..."

bash "${SCRIPT_DIR}/setup_ap.sh"

echo "  -> WiFi AP setup complete."
echo ""

# ============================================================================
# 3. Tailscale
# ============================================================================
echo "===> [3/7] Tailscale (mesh VPN)"

if command -v tailscale &>/dev/null; then
    echo "  -> Tailscale is already installed."
else
    echo "  -> Installing Tailscale ..."
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "  -> Tailscale installed."
fi

systemctl enable tailscaled
systemctl start tailscaled
echo "  -> tailscaled is running."
echo "     NOTE: Run 'sudo tailscale up' to authenticate if not already connected."
echo ""

# ============================================================================
# 4. Reticulum (rns / rnsd)
# ============================================================================
echo "===> [4/7] Reticulum (mesh networking)"

# Install rns via pipx for the target user
if sudo -u "$TARGET_USER" bash -lc 'command -v rnsd' &>/dev/null; then
    echo "  -> Reticulum (rns) is already installed for $TARGET_USER."
else
    echo "  -> Installing Reticulum (rns) for $TARGET_USER ..."
    sudo -u "$TARGET_USER" bash -lc 'pipx install rns && pipx ensurepath'
    echo "  -> rns installed."
    echo "     NOTE: Open a new shell or 'source ~/.bashrc' for rnsd on PATH."
fi

# Reticulum's on-network interface discovery (any interface with
# discoverable = yes) requires the LXMF module. Without it rnsd logs a Critical
# error and exits 255 at startup, then trips StartLimitBurst and parks in
# "failed". Run unconditionally so pre-existing rns installs get fixed too.
if sudo -u "$TARGET_USER" bash -lc 'pipx runpip rns show lxmf' &>/dev/null; then
    echo "  -> lxmf already present in the rns venv."
else
    echo "  -> Injecting lxmf into the rns venv (needed for interface discovery) ..."
    sudo -u "$TARGET_USER" bash -lc 'pipx inject rns lxmf'
fi

# Determine rnsd binary path (pipx installs to ~/.local/bin)
RNSD_BIN="${TARGET_HOME}/.local/bin/rnsd"

# Create systemd service for rnsd
RNSD_SERVICE="/etc/systemd/system/rnsd.service"
echo "  -> Installing systemd service for rnsd ..."
cat > "$RNSD_SERVICE" <<EOF
[Unit]
Description=Reticulum Network Stack Daemon
After=network.target
# Stop retrying after 5 failed starts within 60s; otherwise a fatal config
# error (e.g. a bad interface) would crash-loop forever. After the limit the
# unit parks in "failed" state, which the web UI reports correctly.
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${TARGET_USER}
ExecStart=${RNSD_BIN}
Restart=on-failure
RestartSec=5


[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rnsd
systemctl restart rnsd
echo "  -> rnsd is running."
echo ""

# ============================================================================
# 5. MeshChatX (headless web UI for Reticulum)
# ============================================================================
echo "===> [5/7] MeshChatX (Reticulum web UI)"
echo "  -> Delegating to install_meshchatx.sh ..."

# Installs MeshChatX from its latest release wheel to /opt/meshchatx and runs
# it as a systemd service on :8000, attached to the shared rnsd instance.
# Non-fatal: a network/wheel failure must not abort the whole provisioning run.
bash "${SCRIPT_DIR}/install_meshchatx.sh" "$TARGET_USER" || \
    echo "  -> MeshChatX not installed (download may have failed). Re-run later: sudo bash ${SCRIPT_DIR}/install_meshchatx.sh"
echo ""

# ============================================================================
# 6. Nucleus info web app (port 80)
# ============================================================================
echo "===> [6/7] Nucleus info web app (dashboard on port 80)"
echo "  -> Delegating to install_webapp.sh ..."

# This is the primary way to find the box in the field (http://<hostname>.local),
# so it must be part of the one-shot provisioning run. install_webapp.sh also
# disables apache2 when present: Debian's "web server" tasksel option installs
# it, and it squats on *:80 serving its own default page, which would otherwise
# leave the dashboard unreachable.
# Fatal on failure — without the dashboard the unit is effectively unfindable.
bash "${SCRIPT_DIR}/install_webapp.sh"

echo "  -> Web app setup complete."
echo ""

# ============================================================================
# 7. Firewall rules for MediaMTX and Mumble
# ============================================================================
echo "===> [7/7] Firewall rules (MediaMTX + Mumble)"

# Neither service is installed by this script — the OpenTAKServer installer
# provides both. The ports are opened here anyway so the services are
# reachable the moment OTS brings them up, without needing a second pass over
# the firewall. 'ufw allow' is idempotent, so re-runs are harmless.
MUMBLE_PORT=64738

if command -v ufw &>/dev/null; then
    echo "  -> Opening MediaMTX ports ..."
    ufw allow 8554/tcp comment "MediaMTX RTSP"
    ufw allow 8554/udp comment "MediaMTX RTSP UDP"
    ufw allow 1935/tcp comment "MediaMTX RTMP"
    ufw allow 8888/tcp comment "MediaMTX HLS"
    ufw allow 8889/tcp comment "MediaMTX WebRTC HTTP"
    ufw allow 8889/udp comment "MediaMTX WebRTC UDP"
    ufw allow 9997/tcp comment "MediaMTX API"

    echo "  -> Opening Mumble ports ..."
    ufw allow "${MUMBLE_PORT}/tcp" comment "Mumble control"
    ufw allow "${MUMBLE_PORT}/udp" comment "Mumble voice"
else
    echo "  -> WARNING: ufw not found; skipping firewall rules."
fi
echo ""

# NOTE: There is no longer a step to stage the TAK CA truststore. OpenTAKServer
# keeps its CA in ~/ots/ca/ owned by the same user the web app runs as, so the
# app reads truststore-root.p12 directly and refresh_tak_cert.sh was deleted.
# (That script existed only because official TAK Server kept its certs under a
# separate `tak` user at mode 0600, out of the web app's reach.)


# ============================================================================
# Summary
# ============================================================================
HOSTNAME=$(hostname)

echo ""
echo "============================================"
echo "  Nucleus Server Setup Complete!"
echo "============================================"
echo ""
echo "  Hostname : $HOSTNAME"
echo "  mDNS     : ${HOSTNAME}.local"
echo "  User     : $TARGET_USER"
echo ""
echo "  Services (all enabled for auto-start):"
echo "  ─────────────────────────────────────────"
echo "  avahi-daemon   .local hostname resolution"
echo "  hostapd        WiFi AP (5GHz channel 149)"
echo "  tailscaled     Tailscale mesh VPN"
echo "  rnsd           Reticulum mesh daemon"
echo "  meshchatx      Reticulum web UI  http://${HOSTNAME}.local:8000"
echo "  nucleus-webapp Info dashboard    http://${HOSTNAME}.local"
echo ""
echo "  MediaMTX and Mumble are not installed by this script — the"
echo "  OpenTAKServer installer provides both. Their firewall ports"
echo "  (8554, 1935, 8888, 8889, 9997, ${MUMBLE_PORT}) are already open."
echo ""
echo "  Per-unit secrets (stored in ${NUCLEUS_SECRETS_FILE}, root-only):"
echo "  ─────────────────────────────────────────"
echo "  Dashboard admin PIN       : ${ADMIN_PIN}"
echo "  (Persisted — this stays the same across re-runs/reboots.)"
echo ""
echo "  Next steps:"
echo "    sudo tailscale up          # authenticate Tailscale"
echo "    ssh ${TARGET_USER}@${HOSTNAME}.local"
echo "============================================"

