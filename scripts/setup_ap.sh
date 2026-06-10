#!/usr/bin/env bash
# ============================================================================
# Nucleus Server - WiFi Access Point Setup Script
#
# Installs and configures hostapd to create a WiFi access point.
# Deploys hostapd.conf and systemd-networkd config from the repo,
# sets the wireless regulatory domain, and starts the AP.
#
# Run as root:
#   sudo bash /home/natak/nucleus_server/scripts/setup_ap.sh
# ============================================================================

set -euo pipefail

# ---- Must be root ----
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    echo "Usage: sudo bash $0"
    exit 1
fi

# ---- Resolve the repo root ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo ""
echo "============================================"
echo "  WiFi Access Point Setup"
echo "============================================"
echo ""

# ============================================================================
# 1. Install packages
# ============================================================================
echo "===> [1/6] Installing packages (hostapd, iw, firmware-mediatek)"

apt update -y

for pkg in hostapd iw firmware-mediatek; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        echo "  -> $pkg is already installed."
    else
        echo "  -> Installing $pkg ..."
        apt install -y "$pkg"
    fi
done

echo ""

# ============================================================================
# 2. Deploy configuration files
# ============================================================================
echo "===> [2/6] Deploying configuration files"

# hostapd.conf
cp "${REPO_DIR}/system/hostapd.conf" /etc/hostapd/hostapd.conf
echo "  -> Copied hostapd.conf to /etc/hostapd/hostapd.conf"

# Set DAEMON_CONF in /etc/default/hostapd
sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd 2>/dev/null || \
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd
echo "  -> Set DAEMON_CONF in /etc/default/hostapd"

# systemd-networkd config for the AP interface (static IP + DHCP server)
cp "${REPO_DIR}/system/10-ap.network" /etc/systemd/network/10-ap.network
echo "  -> Copied 10-ap.network to /etc/systemd/network/"

echo ""

# ============================================================================
# 3. Set wireless regulatory domain
# ============================================================================
echo "===> [3/6] Setting wireless regulatory domain to US"

iw reg set US
echo "  -> Regulatory domain set to US"

echo ""

# ============================================================================
# 4. Enable and start systemd-networkd
# ============================================================================
echo "===> [4/6] Enabling systemd-networkd"

systemctl enable systemd-networkd
systemctl restart systemd-networkd
echo "  -> systemd-networkd is running"

echo ""

# ============================================================================
# 5. Unmask, enable, and start hostapd
# ============================================================================
echo "===> [5/6] Starting hostapd"

systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd
systemctl restart hostapd
echo "  -> hostapd is running"

echo ""

# ============================================================================
# 6. UFW — allow all traffic on the AP interface
# ============================================================================
echo "===> [6/6] Configuring UFW for AP interface"

AP_IFACE_UFW=$(grep '^interface=' /etc/hostapd/hostapd.conf | cut -d= -f2)
UFW_BEFORE="/etc/ufw/before.rules"

if [ -f "$UFW_BEFORE" ]; then
    if grep -q "Allow all traffic on WiFi AP interface" "$UFW_BEFORE"; then
        echo "  -> UFW AP rule already present."
    else
        # Insert the rule before the final COMMIT in the filter table
        sed -i "/^COMMIT/i # Allow all traffic on WiFi AP interface\\n-A ufw-before-input -i ${AP_IFACE_UFW} -j ACCEPT" "$UFW_BEFORE"
        echo "  -> Added UFW rule to allow traffic on $AP_IFACE_UFW"
    fi
    ufw reload
    echo "  -> UFW reloaded."
else
    echo "  -> UFW not found, skipping."
fi

echo ""

# ============================================================================
# Summary
# ============================================================================
# Read SSID and interface from the deployed config
AP_SSID=$(grep '^ssid=' /etc/hostapd/hostapd.conf | cut -d= -f2)
AP_IFACE=$(grep '^interface=' /etc/hostapd/hostapd.conf | cut -d= -f2)
AP_CHANNEL=$(grep '^channel=' /etc/hostapd/hostapd.conf | cut -d= -f2)
AP_IP=$(grep '^Address=' /etc/systemd/network/10-ap.network | cut -d= -f2)

echo "============================================"
echo "  WiFi Access Point Setup Complete!"
echo "============================================"
echo ""
echo "  SSID      : $AP_SSID"
echo "  Interface  : $AP_IFACE"
echo "  Channel    : $AP_CHANNEL"
echo "  IP/Subnet  : $AP_IP"
echo ""
echo "  Services:"
echo "  ─────────────────────────────────────────"
echo "  hostapd          WiFi AP"
echo "  systemd-networkd Static IP + DHCP server"
echo "============================================"
