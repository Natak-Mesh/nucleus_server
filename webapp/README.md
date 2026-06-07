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
dependencies (flask, waitress), and enables + starts the service.

Firewall: the app needs port 80 open in UFW (see build guide section 8.1).

## How to access

There are two ways to reach the page:

1. **Over the WiFi access point (static IP).**
   Connect to the WiFi SSID `001-server-nucleus`, then browse to:

   ```
   http://10.30.1.1
   ```

   This address always works over WiFi regardless of the wired network.

2. **Over the wired LAN, by hostname (mDNS).**
   From any device on the same network the server's ethernet is plugged into,
   browse to:

   ```
   http://nucleus-server.local
   ```

   This uses mDNS (avahi-daemon, installed by `scripts/setup.sh`). Substitute
   your actual hostname if you changed it (the `.local` name is
   `<hostname>.local`). Most clients (macOS, iOS, Linux, modern Windows and
   Android) resolve `.local` names natively.
