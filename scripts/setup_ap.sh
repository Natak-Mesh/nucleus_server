#!/usr/bin/env bash
# ============================================================================
# Nucleus Server - WiFi Access Point Setup Script
#
# Installs and configures hostapd to create a WiFi access point with
# internet sharing (NAT) from eth0 to connected WiFi clients.
#
# Deploys hostapd.conf and systemd-networkd config from the repo,
# sets the wireless regulatory domain, enables IP forwarding,
# configures NAT masquerade via UFW, and starts the AP.
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
echo "===> [1/8] Installing packages (hostapd, iw, firmware-mediatek)"

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
echo "===> [2/8] Deploying configuration files"

# hostapd.conf
cp "${REPO_DIR}/system/hostapd.conf" /etc/hostapd/hostapd.conf
echo "  -> Copied hostapd.conf to /etc/hostapd/hostapd.conf"

# Set DAEMON_CONF in /etc/default/hostapd
sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd 2>/dev/null || \
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd
echo "  -> Set DAEMON_CONF in /etc/default/hostapd"

# systemd-networkd config for the AP interface (static IP + DHCP server + IP forwarding)
cp "${REPO_DIR}/system/10-ap.network" /etc/systemd/network/10-ap.network
echo "  -> Copied 10-ap.network to /etc/systemd/network/"

echo ""

# ============================================================================
# 3. Set wireless regulatory domain
# ============================================================================
echo "===> [3/8] Setting wireless regulatory domain to US"

iw reg set US
echo "  -> Regulatory domain set to US"

echo ""

# ============================================================================
# 4. Enable IP forwarding
# ============================================================================
echo "===> [4/8] Enabling IP forwarding"

SYSCTL_CONF="/etc/sysctl.d/99-ip-forward.conf"
if [ -f "$SYSCTL_CONF" ] && grep -q 'net.ipv4.ip_forward=1' "$SYSCTL_CONF"; then
    echo "  -> IP forwarding sysctl already configured."
else
    echo 'net.ipv4.ip_forward=1' > "$SYSCTL_CONF"
    echo "  -> Created $SYSCTL_CONF"
fi

# Apply immediately
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "  -> IP forwarding is enabled."

echo ""

# ============================================================================
# 5. Enable and start systemd-networkd
# ============================================================================
echo "===> [5/8] Enabling systemd-networkd"

systemctl enable systemd-networkd
systemctl restart systemd-networkd
echo "  -> systemd-networkd is running"

echo ""

# ============================================================================
# 6. Unmask, enable, and start hostapd
# ============================================================================
echo "===> [6/8] Starting hostapd"

systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd
systemctl restart hostapd
echo "  -> hostapd is running"

echo ""

# ============================================================================
# 7. UFW — allow all traffic on the AP interface
# ============================================================================
echo "===> [7/8] Configuring UFW for AP interface"

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
# 8. UFW — NAT masquerade (internet sharing via eth0)
# ============================================================================
echo "===> [8/8] Configuring NAT masquerade for internet sharing"

AP_SUBNET=$(grep '^Address=' /etc/systemd/network/10-ap.network | cut -d= -f2 | xargs)

if [ -f "$UFW_BEFORE" ]; then
    if grep -q "NAT masquerade for WiFi AP internet sharing" "$UFW_BEFORE"; then
        echo "  -> NAT masquerade rule already present."
    else
        # Prepend the *nat table block before the *filter table
        sed -i "1a\\
# NAT masquerade for WiFi AP internet sharing\\
*nat\\
:POSTROUTING ACCEPT [0:0]\\
-A POSTROUTING -s ${AP_SUBNET} -o eth0 -j MASQUERADE\\
COMMIT\\
" "$UFW_BEFORE"
        echo "  -> Added NAT masquerade rule (${AP_SUBNET} -> eth0)"
    fi
    ufw reload
    echo "  -> UFW reloaded."
else
    echo "  -> UFW not found, skipping NAT setup."
    echo "     You may need to manually configure iptables NAT."
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
echo "  Internet   : NAT via eth0"
echo ""
echo "  Services:"
echo "  ─────────────────────────────────────────"
echo "  hostapd          WiFi AP"
echo "  systemd-networkd Static IP + DHCP server"
echo "  IP forwarding    Enabled (sysctl)"
echo "  NAT masquerade   eth0 (UFW before.rules)"
echo "============================================"
