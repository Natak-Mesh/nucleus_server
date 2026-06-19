#!/usr/bin/env python3
"""
Nucleus Server - Info & Control Web App

A small Flask app served on port 80 with two zones:

  * PUBLIC zone (no auth): network identity, live interface IPs, service
    up/down status, a minimal CPU/RAM readout, QR codes (WiFi join, TAK web
    UI, data-package download), and the one-tap TAK client data-package
    download.

  * ADMIN zone (PIN-gated): start/stop/restart of the core services and a
    view of the per-unit secrets (Mumble SuperUser password). The PIN is the
    per-unit ADMIN_PIN provisioned into /etc/nucleus/secrets and handed to
    this process by systemd via EnvironmentFile.

Connect to the WiFi AP (the SSID is the server's hostname) and browse to
http://<hostname>.local — or to the WiFi gateway address — to view this page.

Served by waitress (production WSGI server) on 0.0.0.0:80.
"""

import json
import os
import secrets as _secrets
import socket
import subprocess

from flask import (
    Flask,
    Response,
    abort,
    jsonify,
    redirect,
    render_template,
    request,
    session,
    url_for,
)

import datapackage
import tailscale


app = Flask(__name__)
# Ephemeral session key — fine for a single-process field appliance. Sessions
# only gate the admin zone; a restart simply re-prompts for the PIN.
app.secret_key = _secrets.token_hex(32)

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 80

# Services the admin zone is allowed to control. The service name is validated
# against this hardcoded allow-list before ever touching systemctl.
MANAGED_SERVICES = {
    "takserver": "TAK Server",
    "mediamtx": "MediaMTX",
    "mumble-server": "Mumble",
    "rnsd": "Reticulum",
    "meshchatx": "MeshChatX",
    "nucleus-webapp": "Web App",
}

# Port the MeshChatX headless web UI listens on (see install_meshchatx.sh).
MESHCHATX_PORT = 8000

# Admin PIN, supplied by systemd via EnvironmentFile=/etc/nucleus/secrets.
ADMIN_PIN = os.environ.get("ADMIN_PIN", "")
# Mumble password, same source (shown in the admin zone).
MUMBLE_PW = os.environ.get("MUMBLE_SUPERUSER_PW", "")

# WiFi AP passphrase for the join QR. Overridable via env; defaults to the
# value baked into the hostapd template.
WIFI_PSK = os.environ.get("WIFI_PSK", "52235223")


# --------------------------------------------------------------------------
# System info helpers
# --------------------------------------------------------------------------
def get_interfaces():
    """Return network interfaces with their IPv4 addresses via `ip -j addr`."""
    interfaces = []
    try:
        out = subprocess.check_output(["ip", "-j", "addr"], text=True, timeout=5)
        data = json.loads(out)
    except Exception as exc:  # noqa: BLE001 - show the error on the page
        return [{"name": "error", "addrs": [str(exc)], "state": "ERROR"}]

    for iface in data:
        name = iface.get("ifname", "?")
        if name == "lo":
            continue
        state = iface.get("operstate", "UNKNOWN")
        if state == "UNKNOWN" and "UP" in (iface.get("flags") or []):
            state = "UP"
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

    """Return the avahi-advertised mDNS name (e.g. "nucleus-server.local")."""
    name = get_hostname()
    try:
        with open("/etc/avahi/avahi-daemon.conf", "r") as fh:
            for line in fh:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                if stripped.startswith("host-name") and "=" in stripped:
                    value = stripped.split("=", 1)[1].strip()
                    if value:
                        name = value
                    break
    except OSError:
        pass
    return f"{name}.local"


def get_service_status(name):
    """Return "Running" if the systemd service is active, else "Stopped"."""
    try:
        out = subprocess.run(
            ["systemctl", "is-active", name],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return "Running" if out.stdout.strip() == "active" else "Stopped"
    except Exception:  # noqa: BLE001
        return "Stopped"


def get_cpu_percent():
    """
    Rough CPU utilisation (%) over a short sample, from /proc/stat.

    Returns an int 0-100, or None if unavailable.
    """
    try:
        def _read():
            with open("/proc/stat", "r") as fh:
                parts = fh.readline().split()
            vals = [int(x) for x in parts[1:]]
            idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
            total = sum(vals)
            return idle, total

        import time

        idle1, total1 = _read()
        time.sleep(0.1)
        idle2, total2 = _read()
        dt = total2 - total1
        di = idle2 - idle1
        if dt <= 0:
            return None
        return max(0, min(100, round((1 - di / dt) * 100)))
    except Exception:  # noqa: BLE001
        return None


def get_mem():
    """Return (used_mb, total_mb) from /proc/meminfo, or (None, None)."""
    try:
        info = {}
        with open("/proc/meminfo", "r") as fh:
            for line in fh:
                key, _, rest = line.partition(":")
                info[key.strip()] = int(rest.strip().split()[0])  # kB
        total = info.get("MemTotal", 0)
        avail = info.get("MemAvailable", info.get("MemFree", 0))
        used = total - avail
        return round(used / 1024), round(total / 1024)
    except Exception:  # noqa: BLE001
        return None, None


# --------------------------------------------------------------------------
# QR codes (pure-python via segno; degrade gracefully if missing)
# --------------------------------------------------------------------------
def qr_svg(data, scale=4):
    """Return an inline SVG string for `data`, or None if segno is missing.

    Note: segno's SVG writer emits *bytes*, so we serialize into a BytesIO and
    decode to str. (Using StringIO raises "string argument expected, got
    'bytes'" on segno >= 1.6, which silently produced no QR codes.)
    """
    if not data:
        return None
    try:
        import segno
        import io

        buf = io.BytesIO()
        segno.make(data, error="m").save(buf, kind="svg", scale=scale, border=2)
        return buf.getvalue().decode("utf-8")
    except Exception:  # noqa: BLE001
        return None



def wifi_join_string(ssid):
    """WPA WiFi join payload for a QR code."""
    return f"WIFI:S:{ssid};T:WPA;P:{WIFI_PSK};;"


# --------------------------------------------------------------------------
# Auth helpers
# --------------------------------------------------------------------------
def is_admin():
    return bool(session.get("admin"))


# --------------------------------------------------------------------------
# Routes — public
# --------------------------------------------------------------------------
@app.route("/")
def index():
    hostname = get_hostname()
    mdns = get_mdns_name()
    used_mb, total_mb = get_mem()
    # "Share this page" QR: encode the exact address THIS viewer used to reach
    # the page (request.host includes host:port). Works whether they arrived
    # via the AP gateway IP or a dynamic LAN DHCP address, so a colleague on the
    # same network can scan and land on the same dashboard — no guessing.
    share_url = f"http://{request.host}/"
    return render_template(
        "index.html",
        hostname=hostname,
        mdns_name=mdns,
        tak_status=get_service_status("takserver"),
        mediamtx_status=get_service_status("mediamtx"),
        mumble_status=get_service_status("mumble-server"),
        rnsd_status=get_service_status("rnsd"),
        meshchatx_status=get_service_status("meshchatx"),
        meshchatx_port=MESHCHATX_PORT,
        interfaces=get_interfaces(),
        cpu_pct=get_cpu_percent(),
        mem_used=used_mb,
        mem_total=total_mb,
        datapackage_ready=datapackage.ca_available(),
        qr_wifi=qr_svg(wifi_join_string(hostname)),
        qr_share=qr_svg(share_url),
        share_url=share_url,

        is_admin=is_admin(),
        managed_services=MANAGED_SERVICES,
        mumble_pw=MUMBLE_PW,
        ts_status=tailscale.status(),
        ts_profiles=tailscale.list_profiles() if is_admin() else [],
    )


@app.route("/download/datapackage")

def download_datapackage():
    """Stream the staged intermediate CA truststore (caCert.p12) directly."""
    if not datapackage.ca_available():
        abort(503, "TAK CA not staged yet. Run scripts/refresh_tak_cert.sh.")

    with open(datapackage.DEFAULT_CA_PATH, "rb") as fh:
        blob = fh.read()

    return Response(
        blob,
        mimetype="application/x-pkcs12",
        headers={"Content-Disposition": 'attachment; filename="caCert.p12"'},
    )



# --------------------------------------------------------------------------
# Routes — admin
# --------------------------------------------------------------------------
@app.route("/admin/login", methods=["POST"])
def admin_login():
    pin = request.form.get("pin", "")
    if ADMIN_PIN and _secrets.compare_digest(pin, ADMIN_PIN):
        session["admin"] = True
    return redirect(url_for("index"))


@app.route("/admin/logout", methods=["POST"])
def admin_logout():
    session.pop("admin", None)
    return redirect(url_for("index"))


@app.route("/admin/service", methods=["POST"])
def admin_service():
    if not is_admin():
        abort(403)
    service = request.form.get("service", "")
    action = request.form.get("action", "")
    if service not in MANAGED_SERVICES or action not in {"start", "stop", "restart"}:
        abort(400, "Invalid service or action.")
    # service/action are both validated against fixed allow-lists above, so
    # this is never attacker-controlled free text.
    try:
        subprocess.run(
            ["sudo", "-n", "systemctl", action, service],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception:  # noqa: BLE001
        pass
    return redirect(url_for("index"))


# --------------------------------------------------------------------------
# Routes — admin / Tailscale
# --------------------------------------------------------------------------
@app.route("/admin/tailscale/login", methods=["POST"])
def admin_tailscale_login():
    """Kick off an interactive `tailscale up` in the background."""
    if not is_admin():
        abort(403)
    tailscale.start_login()
    return redirect(url_for("index"))


@app.route("/admin/tailscale/status")
def admin_tailscale_status():
    """JSON status for the page poller (state, auth URL, profiles)."""
    if not is_admin():
        abort(403)
    info = tailscale.status()
    auth_url = tailscale.get_auth_url()
    return jsonify(
        {
            **info,
            "auth_url": auth_url,
            "auth_url_qr": qr_svg(auth_url) if auth_url else None,
            "login_in_progress": tailscale.login_in_progress(),
            "profiles": tailscale.list_profiles(),
        }
    )


@app.route("/admin/tailscale/switch", methods=["POST"])
def admin_tailscale_switch():
    """Switch to an already-logged-in profile/tailnet by id."""
    if not is_admin():
        abort(403)
    profile_id = request.form.get("profile_id", "")
    # Validate against the live list so this is never arbitrary input.
    valid_ids = {p["id"] for p in tailscale.list_profiles()}
    if profile_id not in valid_ids:
        abort(400, "Unknown Tailscale profile.")
    tailscale.switch_profile(profile_id)
    return redirect(url_for("index"))


@app.route("/admin/tailscale/action", methods=["POST"])
def admin_tailscale_action():
    """
    Connection control: up (reconnect) or down (disconnect).

    Note: there is NO logout action. Logging out wipes the node's stored
    credentials and forces a full browser re-auth, so it is intentionally not
    exposed in the web UI.
    """
    if not is_admin():
        abort(403)
    action = request.form.get("action", "")
    if action == "up":
        tailscale.up()
    elif action == "down":
        tailscale.down()
    else:
        abort(400, "Invalid action.")
    return redirect(url_for("index"))



if __name__ == "__main__":

    try:
        from waitress import serve

        serve(app, host=LISTEN_HOST, port=LISTEN_PORT)
    except ImportError:
        app.run(host=LISTEN_HOST, port=LISTEN_PORT)
