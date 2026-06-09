#!/usr/bin/env python3
"""
Nucleus Server - Info Web App

A minimal, read-only Flask page that shows the server's network identity
so you can find its IP without running a network scan.

Connect to the WiFi AP (SSID: 001-server-nucleus) and browse to
http://10.30.1.1 to view this page.

Served by waitress (production WSGI server) on 0.0.0.0:80.
"""

import json
import socket
import subprocess

from flask import Flask, render_template

app = Flask(__name__)

# Port to listen on. 80 = no port number needed in the URL.
LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 80


def get_interfaces():
    """
    Return a list of network interfaces with their IPv4 addresses.

    Uses `ip -j addr` (JSON output) so we don't need any extra Python deps.
    """
    interfaces = []
    try:
        out = subprocess.check_output(
            ["ip", "-j", "addr"], text=True, timeout=5
        )
        data = json.loads(out)
    except Exception as exc:  # noqa: BLE001 - show the error on the page
        return [{"name": "error", "addrs": [str(exc)], "state": "ERROR"}]

    for iface in data:
        name = iface.get("ifname", "?")
        # Skip loopback - not useful for finding the server.
        if name == "lo":
            continue
        state = iface.get("operstate", "UNKNOWN")
        addrs = [
            a.get("local")
            for a in iface.get("addr_info", [])
            if a.get("family") == "inet" and a.get("local")
        ]
        interfaces.append({"name": name, "addrs": addrs, "state": state})
    return interfaces


def get_hostname():
    return socket.gethostname()


def get_mdns_name():
    """
    Return the avahi-advertised mDNS name (e.g. "nucleus-server.local").

    avahi-daemon uses the system hostname by default, but this can be
    overridden with a `host-name=` entry in /etc/avahi/avahi-daemon.conf.
    We honour that override when present, otherwise fall back to the
    system hostname.
    """
    name = get_hostname()
    try:
        with open("/etc/avahi/avahi-daemon.conf", "r") as fh:
            for line in fh:
                stripped = line.strip()
                # Skip comments (lines starting with '#') and blanks.
                if not stripped or stripped.startswith("#"):
                    continue
                if stripped.startswith("host-name") and "=" in stripped:
                    value = stripped.split("=", 1)[1].strip()
                    if value:
                        name = value
                    break
    except OSError:
        # Config not present/readable - fall back to the system hostname.
        pass
    return f"{name}.local"


def get_service_status(name):
    """
    Return "Running" if the given systemd service is active, otherwise
    "Stopped".

    Uses `systemctl is-active <name>` (read-only, no root required).
    """
    try:
        out = subprocess.run(
            ["systemctl", "is-active", name],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return "Running" if out.stdout.strip() == "active" else "Stopped"
    except Exception:  # noqa: BLE001 - any failure means we can't confirm it's up
        return "Stopped"


@app.route("/")
def index():
    return render_template(
        "index.html",
        hostname=get_hostname(),
        mdns_name=get_mdns_name(),
        tak_status=get_service_status("takserver"),
        mediamtx_status=get_service_status("mediamtx"),
        mumble_status=get_service_status("mumble-server"),
        interfaces=get_interfaces(),
    )





if __name__ == "__main__":
    # Production WSGI server (waitress). Falls back to Flask dev server
    # only if waitress is somehow unavailable.
    try:
        from waitress import serve

        serve(app, host=LISTEN_HOST, port=LISTEN_PORT)
    except ImportError:
        app.run(host=LISTEN_HOST, port=LISTEN_PORT)
