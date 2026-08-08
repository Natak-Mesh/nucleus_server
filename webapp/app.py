#!/usr/bin/env python3
"""
Nucleus Server - Info & Control Web App

A small Flask app served on port 80 with two zones:

  * PUBLIC zone (no auth): network identity, live interface IPs, service
    up/down status, a minimal CPU/RAM readout, QR codes (WiFi join, share
    this page), and a one-tap download of the TAK CA certificate.

  * ADMIN zone (PIN-gated): start/stop/restart of the core services and a
    view of the per-unit secrets (Mumble SuperUser password). The PIN is the
    per-unit ADMIN_PIN provisioned into /etc/nucleus/secrets and handed to
    this process by systemd via EnvironmentFile.

This is the appliance's landing page, not a TAK admin console. TAK itself is
administered in OpenTAKServer's own web UI on port 8444; anything TAK-specific
beyond "is it up" and "how do I trust it" belongs there, not here.

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

import tailscale

# OpenTAKServer's public CA truststore. Clients install this to trust the
# server; it is a public trust anchor, not a credential, so it is served
# without auth (OTS's own /api/truststore endpoint does the same).
#
# No staging step is needed: this web app runs as the same user that owns
# ~/ots, so it can read the file directly. (Official TAK Server kept its
# certs under a separate `tak` user at mode 0600, which is why the old
# scripts/refresh_tak_cert.sh had to copy them out. That script is gone.)
OTS_CA_PATH = os.path.expanduser("~/ots/ca/truststore-root.p12")

# Port the OpenTAKServer web UI is reachable on. NOT 8443 — that vhost is the
# Marti API and sets `ssl_verify_client on`, so a browser without an enrolled
# client certificate is rejected. See docs/opentakserver_install/.
OTS_UI_PORT = 8444



app = Flask(__name__)
# Ephemeral session key — fine for a single-process field appliance. Sessions
# only gate the admin zone; a restart simply re-prompts for the PIN.
app.secret_key = _secrets.token_hex(32)

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 80

# OpenTAKServer is four cooperating units, not one. `opentakserver` is the
# parent: it declares Requires= on the other three, so starting/stopping it
# cascades. The page shows one rolled-up "TAK Server" state plus a per-unit
# breakdown, because a partial failure (typically cot_parser losing its
# RabbitMQ exchange race at boot) is otherwise invisible.
OTS_SERVICES = {
    "opentakserver": "Core",
    "cot_parser": "CoT parser",
    "eud_handler": "EUD (TCP)",
    "eud_handler_ssl": "EUD (SSL)",
}

# Services the admin zone is allowed to control. The service name is validated
# against this hardcoded allow-list before ever touching systemctl.
MANAGED_SERVICES = {
    "opentakserver": "TAK Server",
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
# Mumble SuperUser password, same source. setup_nucleus.sh no longer installs
# Mumble (the OpenTAKServer installer does), so this is normally unset and the
# admin zone hides the row. Kept so units provisioned before that change, which
# still have MUMBLE_SUPERUSER_PW in /etc/nucleus/secrets, keep displaying it.
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


def get_ots_status():
    """
    Roll the four OpenTAKServer units up into a single state plus detail.

    Returns {"status": "Running"|"Degraded"|"Stopped", "units": {...}}.

    "Degraded" is the case worth surfacing: the core is up and serving the web
    UI, but a helper died — e.g. cot_parser, which loses a startup race against
    RabbitMQ and then stays dead. A plain Running/Stopped flag reports that as
    healthy, which is how it goes unnoticed until CoT silently stops flowing.
    """
    units = {name: get_service_status(name) for name in OTS_SERVICES}
    running = sum(1 for s in units.values() if s == "Running")

    if running == len(units):
        status = "Running"
    elif running == 0:
        status = "Stopped"
    else:
        status = "Degraded"

    return {"status": status, "units": units}


# Previous /proc/stat snapshot, so CPU% is measured as the average over the

# real time between calls (i.e. between page loads / poll requests) instead of
# a short self-measuring sleep that spikes on the web app's own activity.
_cpu_prev = None


def get_cpu_percent():
    """
    CPU utilisation (%) as the average since the previous call, from /proc/stat.

    Returns an int 0-100, or None if unavailable (e.g. the very first call,
    which has no prior snapshot to diff against).
    """
    global _cpu_prev
    try:
        with open("/proc/stat", "r") as fh:
            parts = fh.readline().split()
        vals = [int(x) for x in parts[1:]]
        idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
        total = sum(vals)

        prev = _cpu_prev
        _cpu_prev = (idle, total)
        if prev is None:
            return None
        dt = total - prev[1]
        di = idle - prev[0]
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
    ots = get_ots_status()
    return render_template(
        "index.html",
        hostname=hostname,
        mdns_name=mdns,
        tak_status=ots["status"],
        tak_units=ots["units"],
        ots_service_labels=OTS_SERVICES,
        ots_ui_port=OTS_UI_PORT,
        mediamtx_status=get_service_status("mediamtx"),

        mumble_status=get_service_status("mumble-server"),
        rnsd_status=get_service_status("rnsd"),
        meshchatx_status=get_service_status("meshchatx"),
        meshchatx_port=MESHCHATX_PORT,
        interfaces=get_interfaces(),
        cpu_pct=get_cpu_percent(),
        mem_used=used_mb,
        mem_total=total_mb,
        cacert_ready=os.path.isfile(OTS_CA_PATH),
        qr_wifi=qr_svg(wifi_join_string(hostname)),

        qr_share=qr_svg(share_url),
        share_url=share_url,

        is_admin=is_admin(),
        managed_services=MANAGED_SERVICES,
        mumble_pw=MUMBLE_PW,
        ts_status=tailscale.status(),
        ts_profiles=tailscale.list_profiles() if is_admin() else [],
    )


@app.route("/stats")
def stats():
    """Live system stats as JSON for the page poller (CPU, RAM, services,
    interfaces). Mirrors the values rendered into the page at load time so the
    readouts can be refreshed in place without a full reload."""
    used_mb, total_mb = get_mem()
    ots = get_ots_status()
    return jsonify(
        {
            "cpu_pct": get_cpu_percent(),
            "mem_used": used_mb,
            "mem_total": total_mb,
            "services": {
                # Rolled-up TAK state; per-unit detail is under "tak_units".
                "opentakserver": ots["status"],
                "mediamtx": get_service_status("mediamtx"),
                "mumble-server": get_service_status("mumble-server"),
                "rnsd": get_service_status("rnsd"),
                "meshchatx": get_service_status("meshchatx"),
                "tailscale": "Running" if tailscale.status().get("logged_in") else "Stopped",
            },
            "tak_units": ots["units"],
            "interfaces": get_interfaces(),
        }
    )



@app.route("/download/cacert")
def download_cacert():
    """
    Stream OpenTAKServer's CA truststore so a client can trust this server.

    No auth, deliberately: this is a public trust anchor, not a credential. It
    lets a device verify the server's identity — it grants no access on its
    own, which still requires an OTS username and password. OTS serves the
    same file unauthenticated from its own /api/truststore.

    Note there is no webadmin.p12 equivalent here. Official TAK Server used a
    client certificate as the admin identity; OTS uses username/password, so
    there is no admin cert to hand out.
    """
    if not os.path.isfile(OTS_CA_PATH):
        abort(503, "OpenTAKServer CA not found. Has `flask ots create-ca` been run?")

    with open(OTS_CA_PATH, "rb") as fh:
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
