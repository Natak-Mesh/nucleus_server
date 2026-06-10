#!/usr/bin/env bash
# ============================================================================
# Nucleus Server - WiFi Access Point Setup Script
#
# Installs and configures hostapd to create a WiFi access point with
# internet sharing (NAT) from eth0 to connected WiFi clients.
#
# Auto-detects the wireless interface (or accepts one as an argument).
# Generates hostapd.conf and systemd-networkd config from templates,
# sets the wireless regulatory domain, enables IP forwarding,
# configures NAT masquerade via UFW, and starts the AP.
#
# Usage (run as root):
#   sudo bash setup_ap.sh              # auto-detect wireless interface
#   sudo bash setup_ap.sh wlx00c0ca... # specify interface explicitly
# ============================================================================

set -euo pipefail

# ---- Must be root ----
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    echo "Usage: sudo bash $0 [interface]"
    exit 1
fi

# ---- Resolve the repo root ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ---- Discover all wireless interfaces ----
WIFI_IFACES=()
for iface_path in /sys/class/net/*/wireless; do
    if [ -d "$iface_path" ]; then
        WIFI_IFACES+=( "$(basename "$(dirname "$iface_path")")" )
    fi
done

# ---- Determine the wireless interface ----
if [ $# -ge 1 ]; then
    AP_IFACE="$1"
    echo "Using specified wireless interface: $AP_IFACE"
else
    if [ ${#WIFI_IFACES[@]} -eq 0 ]; then
        echo "ERROR: No wireless interfaces detected."
        echo "Make sure a WiFi adapter is plugged in, or specify one manually:"
        echo "  sudo bash $0 <interface-name>"
        exit 1
    fi

    # List all detected wireless interfaces with driver info
    echo "Detected wireless interface(s):"
    echo ""
    for i in "${!WIFI_IFACES[@]}"; do
        DRIVER=$(readlink -f "/sys/class/net/${WIFI_IFACES[$i]}/device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
        MAC=$(cat "/sys/class/net/${WIFI_IFACES[$i]}/address" 2>/dev/null || echo "unknown")
        echo "  [$((i+1))] ${WIFI_IFACES[$i]}  (driver: $DRIVER, mac: $MAC)"
    done
    echo ""

    # Default to the first one
    AP_IFACE="${WIFI_IFACES[0]}"

    if [ ${#WIFI_IFACES[@]} -eq 1 ]; then
        echo -n "Use $AP_IFACE? [Y/n] or type a different interface name: "
    else
        echo -n "Enter number or interface name [default: $AP_IFACE]: "
    fi

    read -r USER_CHOICE
    if [ -n "$USER_CHOICE" ]; then
        case "$USER_CHOICE" in
            [Nn]|[Nn][Oo])
                echo "Aborted. Re-run with the desired interface:"
                echo "  sudo bash $0 <interface-name>"
                exit 0
                ;;
            [Yy]|[Yy][Ee][Ss]|"")
                ;; # keep default
            *)
                # Check if user entered a number
                if [[ "$USER_CHOICE" =~ ^[0-9]+$ ]] && [ "$USER_CHOICE" -ge 1 ] && [ "$USER_CHOICE" -le ${#WIFI_IFACES[@]} ]; then
                    AP_IFACE="${WIFI_IFACES[$((USER_CHOICE-1))]}"
                else
                    AP_IFACE="$USER_CHOICE"
                fi
                ;;
        esac
    fi

    echo "  -> Selected: $AP_IFACE"
fi

# Verify the interface exists
if [ ! -d "/sys/class/net/${AP_IFACE}" ]; then
    echo "ERROR: Interface '$AP_IFACE' does not exist."
    echo ""
    if [ ${#WIFI_IFACES[@]} -gt 0 ]; then
        echo "Available wireless interfaces:"
        printf '  %s\n' "${WIFI_IFACES[@]}"
    fi
    exit 1
fi

# ---- Derive SSID from hostname ----
AP_SSID="$(hostname)"

echo ""
echo "============================================"
echo "  WiFi Access Point Setup"
echo "  Interface : $AP_IFACE"
echo "  SSID      : $AP_SSID"
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
# 2. Generate and deploy configuration files
# ============================================================================
echo "===> [2/8] Generating configuration files for $AP_IFACE"

# hostapd.conf — generate from template
HOSTAPD_TEMPLATE="${REPO_DIR}/system/hostapd.conf.template"
if [ ! -f "$HOSTAPD_TEMPLATE" ]; then
    echo "ERROR: Template not found: $HOSTAPD_TEMPLATE"
    exit 1
fi
sed -e "s/__IFACE__/${AP_IFACE}/g" \
    -e "s/__SSID__/${AP_SSID}/g" \
    "$HOSTAPD_TEMPLATE" > /etc/hostapd/hostapd.conf
echo "  -> Generated /etc/hostapd/hostapd.conf (interface=$AP_IFACE, ssid=$AP_SSID)"

# Set DAEMON_CONF in /etc/default/hostapd
sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd 2>/dev/null || \
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd
echo "  -> Set DAEMON_CONF in /etc/default/hostapd"

# systemd-networkd config — generate from template
NETWORK_TEMPLATE="${REPO_DIR}/system/10-ap.network.template"
if [ ! -f "$NETWORK_TEMPLATE" ]; then
    echo "ERROR: Template not found: $NETWORK_TEMPLATE"
    exit 1
fi
sed "s/__IFACE__/${AP_IFACE}/g" "$NETWORK_TEMPLATE" > /etc/systemd/network/10-ap.network
echo "  -> Generated /etc/systemd/network/10-ap.network (Name=$AP_IFACE)"

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

UFW_BEFORE="/etc/ufw/before.rules"

if [ -f "$UFW_BEFORE" ]; then
    if grep -q "Allow all traffic on WiFi AP interface" "$UFW_BEFORE"; then
        echo "  -> UFW AP rule already present."
    else
        # Insert the rule before the final COMMIT in the filter table
        sed -i "/^COMMIT/i # Allow all traffic on WiFi AP interface\\n-A ufw-before-input -i ${AP_IFACE} -j ACCEPT" "$UFW_BEFORE"
        echo "  -> Added UFW rule to allow traffic on $AP_IFACE"
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
AP_IP=$(grep '^Address=' /etc/systemd/network/10-ap.network | cut -d= -f2)
AP_CHANNEL=$(grep '^channel=' /etc/hostapd/hostapd.conf | cut -d= -f2)

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
