#!/usr/bin/env bash
# ============================================================================
# Nucleus Server - WiFi Access Point Setup Script
#
# Installs and configures hostapd to create a WiFi access point with
# internet sharing (NAT) from the WAN (default-route) interface to connected
# WiFi clients.
#
# Auto-detects the wireless interface (or accepts one as an argument).
# Auto-detects the WAN/uplink interface from the default route (or accepts one
# as a second argument). Generates hostapd.conf and systemd-networkd config
# from templates, sets the wireless regulatory domain, enables IP forwarding,
# configures NAT masquerade via UFW, and starts the AP.
#
# Usage (run as root):
#   sudo bash setup_ap.sh                         # auto-detect both interfaces
#   sudo bash setup_ap.sh wlx00c0ca...            # specify wireless iface
#   sudo bash setup_ap.sh wlx00c0ca... enp1s0     # specify wireless + WAN iface
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

# ---- Prompt for the AP subnet third octet (mandatory, no default) ----
# The AP address becomes 10.30.<octet>.1/24. There is intentionally no default:
# every unit must have an explicitly chosen subnet, so we loop until a valid
# octet (0-255) is entered.
AP_OCTET=""
while true; do
    echo -n "Enter AP subnet third octet (10.30.X.1): "
    read -r AP_OCTET
    if [[ "$AP_OCTET" =~ ^[0-9]+$ ]] && [ "$((10#$AP_OCTET))" -ge 0 ] && [ "$((10#$AP_OCTET))" -le 255 ]; then
        # Strip leading zeros. "03" must become "3": systemd-networkd rejects
        # Address=10.30.03.1/24 as an invalid argument, silently refuses to
        # assign any address, and then disables the DHCP server entirely --
        # clients associate to the SSID but never get an IP.
        AP_OCTET="$((10#$AP_OCTET))"
        break
    fi
    echo "  Invalid entry. Enter a number from 0 to 255."
done
echo "  -> AP subnet: 10.30.${AP_OCTET}.0/24 (server at 10.30.${AP_OCTET}.1)"

# ---- Derive SSID from hostname ----
AP_SSID="$(hostname)"

# ---- Determine the WAN / uplink interface (for NAT internet sharing) ----
# Priority: explicit 2nd arg > default-route interface > legacy eth0.
if [ $# -ge 2 ]; then
    WAN_IFACE="$2"
    echo "Using specified WAN interface: $WAN_IFACE"
else
    WAN_IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
    if [ -z "$WAN_IFACE" ]; then
        WAN_IFACE="eth0"
        echo "WARNING: No default route found; falling back to WAN interface 'eth0'."
    else
        echo "Auto-detected WAN interface (default route): $WAN_IFACE"
    fi
fi

# Don't let the WAN accidentally be the AP interface.
if [ "$WAN_IFACE" = "$AP_IFACE" ]; then
    echo "WARNING: Detected WAN interface ($WAN_IFACE) is the same as the AP"
    echo "         interface. NAT internet sharing will not work until a"
    echo "         separate uplink is connected. Pass the WAN iface explicitly:"
    echo "           sudo bash $0 $AP_IFACE <wan-iface>"
fi

echo ""
echo "============================================"
echo "  WiFi Access Point Setup"
echo "  AP Interface  : $AP_IFACE"
echo "  WAN Interface : $WAN_IFACE"
echo "  SSID          : $AP_SSID"
echo "============================================"
echo ""


# ============================================================================
# 1. Install packages
# ============================================================================
echo "===> [1/9] Installing packages (hostapd, iw, firmware-mediatek)"

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
echo "===> [2/9] Generating configuration files for $AP_IFACE"

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
sed -e "s/__IFACE__/${AP_IFACE}/g" \
    -e "s/__OCTET__/${AP_OCTET}/g" \
    "$NETWORK_TEMPLATE" > /etc/systemd/network/10-ap.network
echo "  -> Generated /etc/systemd/network/10-ap.network (Name=$AP_IFACE, Address=10.30.${AP_OCTET}.1/24)"

echo ""

# ============================================================================
# 3. Set wireless regulatory domain
# ============================================================================
echo "===> [3/9] Setting wireless regulatory domain to US"

iw reg set US
echo "  -> Regulatory domain set to US"

echo ""

# ============================================================================
# 4. Enable IP forwarding
# ============================================================================
echo "===> [4/9] Enabling IP forwarding"

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
echo "===> [5/9] Enabling systemd-networkd"

systemctl enable systemd-networkd
systemctl restart systemd-networkd
echo "  -> systemd-networkd is running"

echo ""

# ============================================================================
# 6. Unmask, enable, and start hostapd
# ============================================================================
echo "===> [6/9] Starting hostapd"

systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd
systemctl restart hostapd
echo "  -> hostapd is running"

echo ""

# ============================================================================
# 7. UFW — allow all traffic on the AP interface
# ============================================================================
echo "===> [7/9] Configuring UFW for AP interface"

UFW_BEFORE="/etc/ufw/before.rules"

# Purge stale user rules left behind by a previous WiFi dongle. When the adapter
# is swapped the interface name changes (it is derived from the MAC), so old
# "allow 67/udp on wlxOLD" and "route allow ... on wlanN" rules linger while the
# new interface has no rule at all. With ufw's default deny-incoming policy the
# DHCP requests are then dropped and clients get no IP -- the AP looks alive but
# hands out nothing. Delete anything bound to a wireless iface that is not the
# one we are configuring now.
if command -v ufw >/dev/null 2>&1; then
    while read -r STALE_IFACE; do
        [ -z "$STALE_IFACE" ] && continue
        [ "$STALE_IFACE" = "$AP_IFACE" ] && continue
        echo "  -> Removing stale UFW rules for old interface: $STALE_IFACE"
        ufw --force delete allow in on "$STALE_IFACE" to any port 67 proto udp 2>/dev/null || true
        ufw --force delete allow in on "$STALE_IFACE" 2>/dev/null || true
        ufw --force delete route allow in on "$STALE_IFACE" out on "$WAN_IFACE" 2>/dev/null || true
        ufw --force delete allow in on "$STALE_IFACE" to any port 67 proto udp 2>/dev/null || true
    done < <(ufw status 2>/dev/null \
             | grep -oE 'on (wlx[0-9a-f]+|wlan[0-9]+|wl[a-z0-9]+)' \
             | awk '{print $2}' | sort -u)
fi

if [ -f "$UFW_BEFORE" ]; then
    if grep -q "Allow all traffic on WiFi AP interface" "$UFW_BEFORE"; then
        # Rule block exists — make sure it points at the current AP interface.
        CURRENT_AP_RULE=$(grep -A1 "Allow all traffic on WiFi AP interface" "$UFW_BEFORE" | grep -- '-A ufw-before-input' | head -1)
        if echo "$CURRENT_AP_RULE" | grep -q -- "-i ${AP_IFACE} "; then
            echo "  -> UFW AP rule already present (interface=$AP_IFACE)."
        else
            sed -i "/Allow all traffic on WiFi AP interface/{n;s/-A ufw-before-input -i [^ ]* -j ACCEPT/-A ufw-before-input -i ${AP_IFACE} -j ACCEPT/;}" "$UFW_BEFORE"
            echo "  -> Updated UFW AP rule to use interface $AP_IFACE"
        fi
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

# Belt-and-braces: also add an explicit user rule permitting DHCP on the AP
# interface. before.rules covers this, but the explicit rule makes the intent
# visible in "ufw status" and survives a before.rules reset.
if command -v ufw >/dev/null 2>&1; then
    ufw allow in on "$AP_IFACE" to any port 67 proto udp >/dev/null 2>&1 || true
    echo "  -> Allowed DHCP (67/udp) in on $AP_IFACE"
fi

echo ""

# ============================================================================
# 8. UFW — NAT masquerade (internet sharing via the WAN interface)
# ============================================================================
echo "===> [8/9] Configuring NAT masquerade for internet sharing (-> $WAN_IFACE)"

# Use the network address (e.g. 10.30.X.0/24), not the host address on the
# Address= line (10.30.X.1/24), so the masquerade rule matches the whole subnet.
AP_SUBNET="10.30.${AP_OCTET}.0/24"

if [ -f "$UFW_BEFORE" ]; then
    if grep -q "NAT masquerade for WiFi AP internet sharing" "$UFW_BEFORE"; then
        # Rule block exists — make sure it points at the current WAN interface.
        CURRENT_NAT=$(grep -E '^-A POSTROUTING -s .* -o .* -j MASQUERADE' "$UFW_BEFORE" | head -1)
        if echo "$CURRENT_NAT" | grep -q -- "-o ${WAN_IFACE} "; then
            echo "  -> NAT masquerade rule already present (-> $WAN_IFACE)."
        else
            # Update the existing masquerade line to the detected WAN iface + subnet.
            sed -i -E "s|^-A POSTROUTING -s .* -o .* -j MASQUERADE|-A POSTROUTING -s ${AP_SUBNET} -o ${WAN_IFACE} -j MASQUERADE|" "$UFW_BEFORE"
            echo "  -> Updated NAT masquerade rule (${AP_SUBNET} -> ${WAN_IFACE})"
        fi
    else
        # Prepend the *nat table block before the *filter table
        sed -i "1a\\
# NAT masquerade for WiFi AP internet sharing\\
*nat\\
:POSTROUTING ACCEPT [0:0]\\
-A POSTROUTING -s ${AP_SUBNET} -o ${WAN_IFACE} -j MASQUERADE\\
COMMIT\\
" "$UFW_BEFORE"
        echo "  -> Added NAT masquerade rule (${AP_SUBNET} -> ${WAN_IFACE})"
    fi
    ufw reload
    echo "  -> UFW reloaded."
else
    echo "  -> UFW not found, skipping NAT setup."
    echo "     You may need to manually configure iptables NAT."
fi


echo ""

# ============================================================================
# 9. Verify the AP actually came up
# ============================================================================
# Previously this script printed "Setup Complete!" unconditionally, even when
# systemd-networkd had rejected the config and silently disabled the DHCP
# server. The AP then broadcast its SSID and accepted associations while never
# handing out an address, which is very hard to diagnose after the fact.
# Fail loudly here instead.
echo "===> [9/9] Verifying AP configuration"

VERIFY_FAILED=0

# Give networkd a moment to finish configuring the link.
for _ in $(seq 1 10); do
    if networkctl status "$AP_IFACE" 2>/dev/null | grep -q 'State: routable (configured)'; then
        break
    fi
    sleep 1
done

# 1. The static address must actually be applied to the interface.
EXPECTED_IP="10.30.${AP_OCTET}.1"
if ip -4 addr show "$AP_IFACE" 2>/dev/null | grep -q "inet ${EXPECTED_IP}/24"; then
    echo "  -> OK: $AP_IFACE has address ${EXPECTED_IP}/24"
else
    echo "  -> FAIL: $AP_IFACE does not have ${EXPECTED_IP}/24 assigned."
    VERIFY_FAILED=1
fi

# 2. networkd must consider the link fully configured, not stuck "configuring".
LINK_STATE=$(networkctl status "$AP_IFACE" 2>/dev/null | grep -E '^\s*State:' | head -1 | sed 's/.*State: //')
if echo "$LINK_STATE" | grep -q 'routable (configured)'; then
    echo "  -> OK: link state is routable (configured)"
else
    echo "  -> FAIL: link state is '${LINK_STATE:-unknown}' (expected 'routable (configured)')"
    VERIFY_FAILED=1
fi

# 3. networkd must not have rejected anything in our config file.
if journalctl -u systemd-networkd --since "5 minutes ago" --no-pager 2>/dev/null \
   | grep -qE 'Failed to parse|no suitable static address|Disabling DHCP server'; then
    echo "  -> FAIL: systemd-networkd reported config errors:"
    journalctl -u systemd-networkd --since "5 minutes ago" --no-pager 2>/dev/null \
        | grep -E 'Failed to parse|no suitable static address|Disabling DHCP server' \
        | sed 's/^/       /'
    VERIFY_FAILED=1
fi

# 4. hostapd must be running.
if systemctl is-active --quiet hostapd; then
    echo "  -> OK: hostapd is active"
else
    echo "  -> FAIL: hostapd is not active"
    VERIFY_FAILED=1
fi

if [ "$VERIFY_FAILED" -ne 0 ]; then
    echo ""
    echo "============================================"
    echo "  AP SETUP FAILED VERIFICATION"
    echo "============================================"
    echo ""
    echo "The access point will NOT hand out IP addresses in this state."
    echo "Inspect the config and logs:"
    echo "  cat /etc/systemd/network/10-ap.network"
    echo "  sudo journalctl -u systemd-networkd -n 50 --no-pager"
    echo "  sudo networkctl status $AP_IFACE"
    exit 1
fi

echo "  -> All checks passed."

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
echo "  SSID       : $AP_SSID"
echo "  AP Iface   : $AP_IFACE"
echo "  WAN Iface  : $WAN_IFACE"
echo "  Channel    : $AP_CHANNEL"
echo "  IP/Subnet  : $AP_IP"
echo "  Internet   : NAT via $WAN_IFACE"
echo ""
echo "  Services:"
echo "  ─────────────────────────────────────────"
echo "  hostapd          WiFi AP"
echo "  systemd-networkd Static IP + DHCP server"
echo "  IP forwarding    Enabled (sysctl)"
echo "  NAT masquerade   $WAN_IFACE (UFW before.rules)"
echo "============================================"

