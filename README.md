# nucleus_server
Nucleus server base station
For Official TAK server requires 8GB ram

## Quick Start

Prerequisites: Debian-based system with `sudo` and `git` already installed.

```bash
# 1. Clone the repo (if not already present)
git clone <repo-url> /home/natak/nucleus_server

# 2. Run the full setup script (installs everything + enables auto-start)
sudo bash /home/natak/nucleus_server/scripts/setup_nucleus.sh
```

The setup script installs and auto-starts the following services:

| Service | Description | Ports |
|---------|-------------|-------|
| **avahi-daemon** | `.local` mDNS hostname resolution | 5353/udp |
| **hostapd** | WiFi access point (5GHz ch149, SSID: nucleus-server-02) + internet sharing via eth0 (NAT) | — |
| **tailscaled** | Tailscale mesh VPN | — |
| **mediamtx** | RTSP / RTMP / HLS / WebRTC media server | 8554, 1935, 8888, 8889, 9997 |
| **mumble-server** | Low-latency VOIP (ATAK Mumble plugin) | 64738 tcp+udp |
| **rnsd** | Reticulum mesh networking daemon | — |

> **UFW Note:** The setup scripts automatically add rules to `/etc/ufw/before.rules`:
> 1. **AP traffic** — allows all inbound traffic on the WiFi AP interface (required because UFW's default rules drop DHCP).
> 2. **NAT masquerade** — adds a `*nat` table that masquerades traffic from the AP subnet (`10.30.2.0/24`) out through `eth0`, giving WiFi clients internet access.
>
> IP forwarding is enabled via `/etc/sysctl.d/99-ip-forward.conf` and DNS servers (`1.1.1.1`, `8.8.8.8`) are provided to clients via DHCP.

After running the script, authenticate Tailscale:
```bash
sudo tailscale up
```

The script is idempotent — safe to re-run at any time.

## Individual Scripts

| Script | Purpose |
|--------|---------|
| `scripts/setup_nucleus.sh` | **Full setup** — installs all services in one shot |
| `scripts/setup.sh` | Base packages + Tailscale + Reticulum only |
| `scripts/install_mumble.sh` | Mumble server only |
| `scripts/install_webapp.sh` | Flask info web app |
| `scripts/setup_ap.sh` | WiFi access point (hostapd) + internet sharing (NAT via eth0) |
