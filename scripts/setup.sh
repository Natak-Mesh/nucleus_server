#!/usr/bin/env bash
# ============================================================================
# Nucleus Server Initial Setup Script
# 
# Installs sudo, curl, pipx, adds the current user to the sudoers group,
# installs/starts avahi-daemon for .local hostname resolution,
# installs Tailscale for secure networking,
# and installs Reticulum (rns) for the target user.
#
# Run as root (required since sudo may not be installed yet):
#   su -c "bash /home/natak/nucleus_server/scripts/setup.sh"
# ============================================================================

set -euo pipefail

# Must be run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    echo "Usage: su -c \"bash $0\""
    exit 1
fi

# Determine the non-root user who invoked su
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    # If run via su -c, SUDO_USER won't be set. Try to find the login user.
    TARGET_USER=$(logname 2>/dev/null || echo "")
fi
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    # Fallback: get the first non-root user with UID >= 1000
    TARGET_USER=$(awk -F: '$3 >= 1000 && $1 != "nobody" { print $1; exit }' /etc/passwd)
fi
if [ -z "$TARGET_USER" ]; then
    echo "ERROR: Could not determine the target non-root user."
    echo "Please pass the username as an argument: su -c \"bash $0 username\""
    exit 1
fi

# Allow overriding via command-line argument
if [ $# -ge 1 ]; then
    TARGET_USER="$1"
fi

echo "==> Target user: $TARGET_USER"

# --- Install core packages (sudo, curl, pipx) ---
apt update -y
for pkg in sudo curl pipx; do
    if command -v "$pkg" &>/dev/null; then
        echo "==> $pkg is already installed."
    else
        echo "==> Installing $pkg..."
        apt install -y "$pkg"
        echo "==> $pkg installed."
    fi
done

# --- Add user to sudo group ---
if id -nG "$TARGET_USER" | grep -qw sudo; then
    echo "==> $TARGET_USER is already in the sudo group."
else
    echo "==> Adding $TARGET_USER to the sudo group..."
    /usr/sbin/usermod -aG sudo "$TARGET_USER"
    echo "==> $TARGET_USER added to sudo group."
    echo "    NOTE: Log out and back in for group changes to take effect."
fi

# --- Install avahi-daemon ---
if dpkg -l avahi-daemon &>/dev/null 2>&1 && dpkg -l avahi-daemon | grep -q '^ii'; then
    echo "==> avahi-daemon is already installed."
else
    echo "==> Installing avahi-daemon..."
    apt update -y
    apt install -y avahi-daemon
    echo "==> avahi-daemon installed."
fi

# --- Enable and start avahi-daemon ---
echo "==> Enabling and starting avahi-daemon..."
systemctl enable avahi-daemon
systemctl start avahi-daemon
echo "==> avahi-daemon is running."

# --- Install Tailscale ---
if command -v tailscale &>/dev/null; then
    echo "==> Tailscale is already installed."
else
    echo "==> Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "==> Tailscale installed."
fi

# --- Enable and start Tailscale ---
echo "==> Enabling and starting Tailscale..."
systemctl enable tailscaled
systemctl start tailscaled
echo "==> Tailscale is running."
echo "    NOTE: Run 'sudo tailscale up' to authenticate."

# --- Install Reticulum (rns) for the target user ---
if sudo -u "$TARGET_USER" bash -lc 'command -v rnsd' &>/dev/null; then
    echo "==> Reticulum (rns) is already installed for $TARGET_USER."
else
    echo "==> Installing Reticulum (rns) for $TARGET_USER..."
    sudo -u "$TARGET_USER" bash -lc 'pipx install rns && pipx ensurepath'
    echo "==> Reticulum (rns) installed."
    echo "    NOTE: $TARGET_USER must open a new shell (or 'source ~/.bashrc') for rnsd on PATH."
fi

# --- Summary ---
HOSTNAME=$(hostname)
echo ""
echo "============================================"
echo "  Setup complete!"
echo "  Hostname: $HOSTNAME"
echo "  mDNS:     $HOSTNAME.local"
echo "  SSH:      ssh $TARGET_USER@$HOSTNAME.local"
echo "============================================"
