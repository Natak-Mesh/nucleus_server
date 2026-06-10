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
| **hostapd** | WiFi access point (5GHz ch149) + internet sharing via eth0 (NAT) | — |
| **tailscaled** | Tailscale mesh VPN | — |
| **mediamtx** | RTSP / RTMP / HLS / WebRTC media server | 8554, 1935, 8888, 8889, 9997 |
| **mumble-server** | Low-latency VOIP (ATAK Mumble plugin) | 64738 tcp+udp |
| **rnsd** | Reticulum mesh networking daemon | — |

### WiFi AP & Internet Sharing

The WiFi AP is configured automatically per-device:

- **Interface**: Auto-detected (first wireless adapter found), or pass explicitly via argument
- **SSID**: Derived from the system hostname (each unit gets a unique SSID)
- **Config templates**: `system/hostapd.conf.template` and `system/10-ap.network.template` contain `__IFACE__` and `__SSID__` placeholders that are filled in at setup time

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

### `setup_ap.sh` Usage

```bash
# Interactive — lists all detected wireless interfaces and prompts for confirmation
sudo bash /home/natak/nucleus_server/scripts/setup_ap.sh

# Skip the prompt — specify the interface directly
sudo bash /home/natak/nucleus_server/scripts/setup_ap.sh wlx00c0cab6c5ba
```

When run without arguments, the script will:
1. Scan for all wireless interfaces and display them with driver and MAC info
2. Prompt you to confirm the default selection, pick a different one by number, or type an interface name
3. Proceed with the chosen interface

Example output:
```
Detected wireless interface(s):

  [1] wlx00c0cab6c5ba  (driver: mt7921u, mac: 00:c0:ca:b6:c5:ba)
  [2] wlan0             (driver: iwlwifi, mac: a4:c3:f0:12:34:56)

Enter number or interface name [default: wlx00c0cab6c5ba]:
```
