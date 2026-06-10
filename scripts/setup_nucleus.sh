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
#   4. MediaMTX       (RTSP/RTMP/HLS/WebRTC media server)
#   5. Mumble Server  (low-latency VOIP for ATAK)
#   6. Reticulum      (resilient mesh networking daemon)
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

# ============================================================================
# 1. Core Packages
# ============================================================================
echo "===> [1/6] Core packages (curl, pipx, avahi-daemon)"

apt update -y

for pkg in curl pipx; do
    if command -v "$pkg" &>/dev/null; then
        echo "  -> $pkg is already installed."
    else
        echo "  -> Installing $pkg ..."
        apt install -y "$pkg"
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
echo "===> [2/6] WiFi Access Point (hostapd + internet sharing)"
echo "  -> Delegating to setup_ap.sh ..."

bash "${SCRIPT_DIR}/setup_ap.sh"

echo "  -> WiFi AP setup complete."
echo ""

# ============================================================================
# 3. Tailscale
# ============================================================================
echo "===> [3/6] Tailscale (mesh VPN)"

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
# 4. MediaMTX
# ============================================================================
echo "===> [4/6] MediaMTX (media server)"

MEDIAMTX_VERSION="1.12.2"
MEDIAMTX_ARCH="linux_amd64"
MEDIAMTX_TARBALL="mediamtx_v${MEDIAMTX_VERSION}_${MEDIAMTX_ARCH}.tar.gz"
MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/${MEDIAMTX_TARBALL}"
MEDIAMTX_BIN="/usr/local/bin/mediamtx"
MEDIAMTX_CONF_DIR="/etc/mediamtx"
MEDIAMTX_CONF="${MEDIAMTX_CONF_DIR}/mediamtx.yml"
MEDIAMTX_SERVICE="/etc/systemd/system/mediamtx.service"

if [ -x "$MEDIAMTX_BIN" ]; then
    echo "  -> MediaMTX binary already exists at $MEDIAMTX_BIN."
else
    echo "  -> Downloading MediaMTX v${MEDIAMTX_VERSION} ..."
    TMPDIR=$(mktemp -d)
    curl -fsSL "$MEDIAMTX_URL" -o "${TMPDIR}/${MEDIAMTX_TARBALL}"
    echo "  -> Extracting ..."
    tar -xzf "${TMPDIR}/${MEDIAMTX_TARBALL}" -C "$TMPDIR"
    install -m 0755 "${TMPDIR}/mediamtx" "$MEDIAMTX_BIN"
    # Install default config if not already present
    mkdir -p "$MEDIAMTX_CONF_DIR"
    if [ ! -f "$MEDIAMTX_CONF" ]; then
        if [ -f "${TMPDIR}/mediamtx.yml" ]; then
            cp "${TMPDIR}/mediamtx.yml" "$MEDIAMTX_CONF"
        else
            # Minimal fallback config
            cat > "$MEDIAMTX_CONF" <<'YMEOF'
# MediaMTX configuration — see https://github.com/bluenviron/mediamtx
logLevel: info
api: yes
apiAddress: :9997
rtsp: yes
rtspAddress: :8554
rtmp: yes
rtmpAddress: :1935
hls: yes
hlsAddress: :8888
webrtc: yes
webrtcAddress: :8889
paths:
  all:
    source: publisher
YMEOF
        fi
        echo "  -> Default config written to $MEDIAMTX_CONF"
    fi
    rm -rf "$TMPDIR"
    echo "  -> MediaMTX installed to $MEDIAMTX_BIN"
fi

# Install systemd service (use repo copy if available, otherwise write inline)
if [ -f "${REPO_DIR}/system/mediamtx.service" ]; then
    cp "${REPO_DIR}/system/mediamtx.service" "$MEDIAMTX_SERVICE"
else
    cat > "$MEDIAMTX_SERVICE" <<'EOF'
[Unit]
Description=MediaMTX media server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable mediamtx
systemctl restart mediamtx
echo "  -> mediamtx is running."

# UFW rules for MediaMTX
if command -v ufw &>/dev/null; then
    echo "  -> Opening MediaMTX ports in UFW ..."
    ufw allow 8554/tcp comment "MediaMTX RTSP"
    ufw allow 8554/udp comment "MediaMTX RTSP UDP"
    ufw allow 1935/tcp comment "MediaMTX RTMP"
    ufw allow 8888/tcp comment "MediaMTX HLS"
    ufw allow 8889/tcp comment "MediaMTX WebRTC HTTP"
    ufw allow 8889/udp comment "MediaMTX WebRTC UDP"
    ufw allow 9997/tcp comment "MediaMTX API"
fi
echo ""

# ============================================================================
# 5. Mumble Server
# ============================================================================
echo "===> [5/6] Mumble Server (VOIP)"

MUMBLE_PORT=64738
MUMBLE_SUPERUSER_PW="52235223"

if dpkg -l mumble-server 2>/dev/null | grep -q '^ii'; then
    echo "  -> mumble-server is already installed."
else
    echo "  -> Installing mumble-server ..."
    apt install -y mumble-server
    echo "  -> mumble-server installed."
fi

systemctl enable mumble-server
systemctl restart mumble-server
echo "  -> mumble-server is running."

# Set the SuperUser (admin) password
echo "  -> Setting Mumble SuperUser password ..."
mumble-server -supw "$MUMBLE_SUPERUSER_PW" 2>/dev/null || true

# UFW rules for Mumble
if command -v ufw &>/dev/null; then
    echo "  -> Opening Mumble ports in UFW ..."
    ufw allow "${MUMBLE_PORT}/tcp" comment "Mumble control"
    ufw allow "${MUMBLE_PORT}/udp" comment "Mumble voice"
fi
echo ""

# ============================================================================
# 6. Reticulum (rns / rnsd)
# ============================================================================
echo "===> [6/6] Reticulum (mesh networking)"

# Install rns via pipx for the target user
if sudo -u "$TARGET_USER" bash -lc 'command -v rnsd' &>/dev/null; then
    echo "  -> Reticulum (rns) is already installed for $TARGET_USER."
else
    echo "  -> Installing Reticulum (rns) for $TARGET_USER ..."
    sudo -u "$TARGET_USER" bash -lc 'pipx install rns && pipx ensurepath'
    echo "  -> rns installed."
    echo "     NOTE: Open a new shell or 'source ~/.bashrc' for rnsd on PATH."
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
echo "  mediamtx       RTSP :8554 | RTMP :1935 | HLS :8888 | WebRTC :8889"
echo "  mumble-server  VOIP :${MUMBLE_PORT} (tcp+udp)"
echo "  rnsd           Reticulum mesh daemon"
echo ""
echo "  Next steps:"
echo "    sudo tailscale up          # authenticate Tailscale"
echo "    ssh ${TARGET_USER}@${HOSTNAME}.local"
echo "============================================"
