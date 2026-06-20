# Nucleus Server — Info Web App

A minimal, read-only web page that shows the server's network identity
(hostname + per-interface IP addresses), so you can find the box's IP without
running a network scan.

## What it is

- Flask app served by waitress on `0.0.0.0:80`.
- Runs as the `nucleus-webapp` systemd service (auto-starts on boot).
- Deployed to `/opt/nucleus-webapp` by `scripts/install_webapp.sh`.

## Install / update

```bash
sudo bash nucleus_server/scripts/install_webapp.sh
```

This deploys the source to `/opt/nucleus-webapp`, creates a venv, installs
dependencies (flask, waitress, segno — segno renders the QR codes), and
enables + starts the service.

Firewall: the app needs port 80 open in UFW (see build guide section 8.1).

## How to access

There are two ways to reach the page:

1. **By hostname (mDNS) — works over WiFi or Ethernet.**
   From any device on the same network (WiFi AP or wired LAN), browse to:

   ```
   http://<hostname>.local
   ```

   For example, `http://nucleus-server.local`. The `.local` name is always
   `<hostname>.local`. This uses mDNS (avahi-daemon, installed by
   `scripts/setup.sh`). Most clients (macOS, iOS, Linux, modern Windows and
   Android) resolve `.local` names natively. The WiFi SSID is the hostname, so
   the network you connect to tells you the name to use.

2. **Over WiFi, via the gateway address.**
   If a client can't resolve `.local` names, connect to the server's WiFi AP
   and browse to the **gateway / router address** assigned to your device by
   DHCP — the server is the gateway on its own `10.30.x.x` subnet. You can find
   this address in your device's WiFi connection details (listed as "Router" or
   "Gateway").

