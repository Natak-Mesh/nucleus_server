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
#   7. MeshChatX      (headless web UI for Reticulum)
#   8. Web App        (Nucleus info dashboard on port 80)
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
MUMBLE_SUPERUSER_PW="$(secret_get_or_create MUMBLE_SUPERUSER_PW gen_password 20)"
ADMIN_PIN="$(secret_get_or_create ADMIN_PIN gen_pin 6)"

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
echo "===> [1/8] Core packages (curl, pipx, iw, wifi firmware, avahi-daemon)"


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
echo "===> [2/8] WiFi Access Point (hostapd + internet sharing)"
echo "  -> Delegating to setup_ap.sh ..."

bash "${SCRIPT_DIR}/setup_ap.sh"

echo "  -> WiFi AP setup complete."
echo ""

# ============================================================================
# 3. Tailscale
# ============================================================================
echo "===> [3/8] Tailscale (mesh VPN)"

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
echo "===> [4/8] MediaMTX (media server)"

# Pinned MediaMTX version. The SHA256 is verified against every tarball
# (downloaded or local) before install. To bump the version, update both
# MEDIAMTX_VERSION and MEDIAMTX_SHA256 together.
MEDIAMTX_VERSION="1.18.2"
MEDIAMTX_ARCH="linux_amd64"
MEDIAMTX_SHA256="73ed27c292e05ceb4990dcb34531f01872dfff5374b7515c45a202e0abf47706"
MEDIAMTX_TARBALL="mediamtx_v${MEDIAMTX_VERSION}_${MEDIAMTX_ARCH}.tar.gz"
MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/${MEDIAMTX_TARBALL}"
MEDIAMTX_BIN="/usr/local/bin/mediamtx"
MEDIAMTX_CONF_DIR="/etc/mediamtx"
MEDIAMTX_CONF="${MEDIAMTX_CONF_DIR}/mediamtx.yml"
MEDIAMTX_SERVICE="/etc/systemd/system/mediamtx.service"
# Local fallback tarball locations (used if the download fails — e.g. offline
# field installs). Checked in order.
MEDIAMTX_LOCAL_CANDIDATES=(
    "${REPO_DIR}/vendor/${MEDIAMTX_TARBALL}"
    "${TARGET_HOME}/${MEDIAMTX_TARBALL}"
)

# Verify a tarball's SHA256 against the pinned value. Returns 0 on match.
verify_mediamtx_sha() {
    local file="$1"
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$actual" = "$MEDIAMTX_SHA256" ]; then
        return 0
    fi
    echo "     SHA256 mismatch for $file"
    echo "       expected: $MEDIAMTX_SHA256"
    echo "       actual  : $actual"
    return 1
}

if [ -x "$MEDIAMTX_BIN" ]; then
    echo "  -> MediaMTX binary already exists at $MEDIAMTX_BIN."
else
    TMPDIR=$(mktemp -d)
    TARBALL_PATH="${TMPDIR}/${MEDIAMTX_TARBALL}"
    GOT_TARBALL=0

    # 1. Try the pinned download.
    echo "  -> Downloading MediaMTX v${MEDIAMTX_VERSION} ..."
    if curl -fsSL "$MEDIAMTX_URL" -o "$TARBALL_PATH" && verify_mediamtx_sha "$TARBALL_PATH"; then
        echo "  -> Download verified (SHA256 OK)."
        GOT_TARBALL=1
    else
        echo "  -> Download failed or did not verify; trying local fallback ..."
    fi

    # 2. Offline fallback: use a local copy if present and verified.
    if [ "$GOT_TARBALL" -ne 1 ]; then
        for cand in "${MEDIAMTX_LOCAL_CANDIDATES[@]}"; do
            if [ -f "$cand" ]; then
                echo "  -> Found local tarball: $cand"
                if verify_mediamtx_sha "$cand"; then
                    cp "$cand" "$TARBALL_PATH"
                    echo "  -> Local tarball verified (SHA256 OK)."
                    GOT_TARBALL=1
                    break
                fi
            fi
        done
    fi

    if [ "$GOT_TARBALL" -ne 1 ]; then
        echo "ERROR: Could not obtain a verified MediaMTX v${MEDIAMTX_VERSION} tarball."
        echo "       Tried download and local fallbacks:"
        printf '         %s\n' "${MEDIAMTX_LOCAL_CANDIDATES[@]}"
        rm -rf "$TMPDIR"
        exit 1
    fi

    echo "  -> Extracting ..."
    tar -xzf "$TARBALL_PATH" -C "$TMPDIR"
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
echo "===> [5/8] Mumble Server (VOIP)"

MUMBLE_PORT=64738
# MUMBLE_SUPERUSER_PW is sourced from the per-unit secrets store near the top
# of this script (generate-once, persisted). No hardcoded password here.

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
echo "===> [6/8] Reticulum (mesh networking)"

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
# 7. MeshChatX (headless web UI for Reticulum)
# ============================================================================
echo "===> [7/8] MeshChatX (Reticulum web UI)"
echo "  -> Delegating to install_meshchatx.sh ..."

# Installs MeshChatX from its latest release wheel to /opt/meshchatx and runs
# it as a systemd service on :8000, attached to the shared rnsd instance.
# Non-fatal: a network/wheel failure must not abort the whole provisioning run.
bash "${SCRIPT_DIR}/install_meshchatx.sh" "$TARGET_USER" || \
    echo "  -> MeshChatX not installed (download may have failed). Re-run later: sudo bash ${SCRIPT_DIR}/install_meshchatx.sh"
echo ""

# ============================================================================
# 8. Nucleus info web app (port 80)
# ============================================================================
echo "===> [8/8] Nucleus info web app (dashboard on port 80)"
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
# 9. Stage TAK CA truststore for the web app (client data packages)
# ============================================================================
echo "===> [9] Staging TAK CA truststore for client data packages"
echo "  -> Delegating to refresh_tak_cert.sh ..."

# Non-fatal: TAK may not be configured yet on first run. The webapp simply
# won't offer the data-package download until this succeeds (re-run any time).
bash "${SCRIPT_DIR}/refresh_tak_cert.sh" "$TARGET_USER" || \
    echo "  -> TAK cert not staged yet (TAK may not be configured). Re-run later: sudo bash ${SCRIPT_DIR}/refresh_tak_cert.sh"
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
echo "  meshchatx      Reticulum web UI  http://${HOSTNAME}.local:8000"
echo "  nucleus-webapp Info dashboard    http://${HOSTNAME}.local"
echo ""
echo "  Per-unit secrets (stored in ${NUCLEUS_SECRETS_FILE}, root-only):"
echo "  ─────────────────────────────────────────"
echo "  Mumble SuperUser password : ${MUMBLE_SUPERUSER_PW}"
echo "  Dashboard admin PIN       : ${ADMIN_PIN}"
echo "  (Persisted — these stay the same across re-runs/reboots.)"
echo ""
echo "  Next steps:"
echo "    sudo tailscale up          # authenticate Tailscale"
echo "    ssh ${TARGET_USER}@${HOSTNAME}.local"
echo "============================================"

