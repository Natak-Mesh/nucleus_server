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


@app.route("/")
def index():
    return render_template(
        "index.html",
        hostname=get_hostname(),
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
