# Nucleus Server

Nucleus is a self-contained field base station. A single box provides a WiFi
access point with shared internet, a web UI for finding the server, plus media
streaming, voice, mesh VPN, and mesh-radio services for TAK.

> Each unit gets a unique hostname/SSID, and the WiFi AP runs on its own
> `10.30.x.x` subnet — so this guide refers to the server by its **`.local`
> hostname** rather than any fixed IP address.

For the official TAK server, the box requires 8 GB RAM.

## Accessing the Web UI

The web UI (`nucleus-webapp`, served on port 80) has two zones:

- **Public zone** (no login): the server's hostname/mDNS name, live interface
  IPs, a minimal CPU/RAM readout, running/stopped status of the key services
  (TAK is rolled up from its four units, with a per-unit breakdown), QR codes
  (WiFi join, share this page), and a one-tap **TAK CA certificate download**
  so clients can trust the server.
- **Admin zone** (PIN): start/stop/restart the core services and manage
  Tailscale (connect/disconnect, log into or switch between tailnets). The PIN
  is set at setup time and shown in the setup summary (stored in
  `/etc/nucleus/secrets`).


It's the easiest way to find the box's current addresses without a network scan.

There are two ways to reach it:

### 1. By hostname (mDNS) — works over WiFi *or* Ethernet

From any device on the same network (whether you joined the WiFi AP or the box
is plugged into the wired LAN), browse to:

```
http://<hostname>.local
```

For example, `http://nucleus-server.local`. The `.local` name is always
`<hostname>.local`. This is resolved via mDNS (avahi-daemon) and works natively
on macOS, iOS, Linux, Android, and modern Windows.

> **Tip:** The WiFi SSID *is* the hostname, so the network name you connect to
> tells you the `<hostname>` to use in the URL above.

### 2. Over WiFi, via the gateway address

If a client can't resolve `.local` names, connect to the server's WiFi AP and
browse to the **gateway / router address** your device was assigned by DHCP —
the Nucleus server is the gateway on its own subnet. You can find this address
in your device's WiFi connection details (listed as "Router" or "Gateway").

Once you're on the web UI, it lists every interface IP, so you can use those
directly for the other services below.

## Onboard Services

All services are enabled to auto-start on boot.

| Service | Purpose | Port(s) | How to access |
|---------|---------|---------|---------------|
| **nucleus-webapp** | Server info web page | 80/tcp | `http://<hostname>.local` (or the WiFi gateway address) |
| **avahi-daemon** | `.local` mDNS hostname resolution | 5353/udp | Enables `<hostname>.local` for every service |
| **hostapd** | WiFi access point (5 GHz, channel 149) + internet sharing via the auto-detected WAN interface (NAT) | — | Connect to the WiFi network named after the hostname |
| **tailscaled** | Tailscale mesh VPN | — | Run `sudo tailscale up` once to authenticate |
| **rnsd** | Reticulum mesh networking daemon | — | Runs as a background daemon |
| **meshchatx** | Reticulum MeshChatX — headless web UI (LXMF messaging, network map, page browsing) for the mesh | 8000/tcp | `http://<hostname>.local:8000` (or the WiFi gateway address). Also linked from the web UI's Services list |

### Installed by the OpenTAKServer installer

`setup_nucleus.sh` does **not** install these — the OpenTAKServer installer
does (see `docs/opentakserver_install/`). Their firewall ports are opened by
`setup_nucleus.sh` anyway, so they work the moment OTS puts them on the box,
and the web UI shows their status either way.

| Service | Purpose | Port(s) | How to access |
|---------|---------|---------|---------------|
| **opentakserver** | TAK server (four units: core, CoT parser, EUD TCP, EUD SSL) | 8444 (web UI), 8089 (SSL EUD) | Web UI `https://<hostname>.local:8444`. Not 8443 — that vhost is the Marti API and requires a client cert |
| **mediamtx** | RTSP / RTMP / HLS / WebRTC media server | 8554, 1935, 8888, 8889, 9997 | RTSP `rtsp://<hostname>.local:8554/<path>`, RTMP `rtmp://<hostname>.local:1935/<path>`, HLS `http://<hostname>.local:8888`, WebRTC `http://<hostname>.local:8889`, API `:9997` |
| **mumble-server** | Low-latency VOIP (ATAK Mumble plugin) | 64738 tcp+udp | Connect a Mumble client / the ATAK Mumble plugin to `<hostname>.local:64738`. Admin via the `SuperUser` account |


## Quick Start

Prerequisites: Debian-based system with `sudo` and `git` already installed.

```bash
# 1. Clone the repo (if not already present)
git clone <repo-url> /home/natak/nucleus_server

# 2. Run the full setup script (installs everything + enables auto-start)
sudo bash /home/natak/nucleus_server/scripts/setup_nucleus.sh
```

After running the script, authenticate Tailscale:

```bash
sudo tailscale up
```

The setup script is idempotent — safe to re-run at any time.

### WiFi AP & Internet Sharing

The WiFi AP is configured automatically per-device:

- **Interface**: Auto-detected (first wireless adapter found), or pass explicitly via argument
- **SSID**: Derived from the system hostname (each unit gets a unique SSID)
- **Subnet**: Each unit runs its own `10.30.x.x` subnet; the server is the gateway and DHCP server for its WiFi clients
- **Config templates**: `system/hostapd.conf.template` and `system/10-ap.network.template` contain `__IFACE__`, `__SSID__`, and `__OCTET__` (subnet) placeholders that are filled in at setup time

> **UFW Note:** The setup scripts automatically add rules to `/etc/ufw/before.rules`:
> 1. **AP traffic** — allows all inbound traffic on the WiFi AP interface (required because UFW's default rules drop DHCP).
> 2. **NAT masquerade** — adds a `*nat` table that masquerades traffic from the AP subnet out through the auto-detected WAN interface (taken from the default route, or passed explicitly), giving WiFi clients internet access.
>
> IP forwarding is enabled via `/etc/sysctl.d/99-ip-forward.conf` and DNS servers (`1.1.1.1`, `8.8.8.8`) are provided to clients via DHCP.

## Individual Scripts

| Script | Purpose |
|--------|---------|
| `scripts/setup_nucleus.sh` | **Full setup** — installs all services (including the web app) in one shot |
| `scripts/setup.sh` | Base packages + Tailscale + Reticulum only |
| `scripts/install_webapp.sh` | Flask info web app (also disables apache2, which otherwise squats on port 80) |
| `scripts/install_meshchatx.sh` | Reticulum MeshChatX headless web UI (port 8000) |
| `scripts/setup_ap.sh` | WiFi access point (hostapd) + wireless firmware (Realtek/MediaTek/etc.) + internet sharing (NAT via the auto-detected WAN interface) |
| `scripts/lib/secrets.sh` | Sourced helper — creates/reads the per-unit secrets in `/etc/nucleus/secrets` |

> There is no Mumble or MediaMTX installer, and no TAK cert-staging script.
> Mumble and MediaMTX come from the OpenTAKServer installer, and the web app
> reads the OTS CA directly out of `~/ots/ca/`, so nothing needs to be copied.


### `setup_ap.sh` Usage

```bash
# Interactive — lists all detected wireless interfaces and prompts for confirmation
sudo bash /home/natak/nucleus_server/scripts/setup_ap.sh

# Skip the interface prompt — specify the wireless interface directly
sudo bash /home/natak/nucleus_server/scripts/setup_ap.sh wlx00c0cab6c5ba

# Also specify the WAN/uplink interface for NAT (otherwise auto-detected from the default route)
sudo bash /home/natak/nucleus_server/scripts/setup_ap.sh wlx00c0cab6c5ba enp1s0
```

When run without arguments, the script will:
1. Scan for all wireless interfaces and display them with driver and MAC info
2. Prompt you to confirm the default selection, pick a different one by number, or type an interface name
3. Prompt for the AP subnet's third octet (`10.30.X.1`) — this is always asked, even when the interface is passed as an argument, so each unit gets its own subnet
4. Auto-detect the WAN/uplink interface from the default route (or use the one you passed) for NAT internet sharing
5. Proceed with the chosen interfaces

Example output:
```
Detected wireless interface(s):

  [1] wlx00c0cab6c5ba  (driver: mt7921u, mac: 00:c0:ca:b6:c5:ba)
  [2] wlan0             (driver: iwlwifi, mac: a4:c3:f0:12:34:56)

Enter number or interface name [default: wlx00c0cab6c5ba]:
```
