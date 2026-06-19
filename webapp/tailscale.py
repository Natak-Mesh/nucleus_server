#!/usr/bin/env python3
"""
Nucleus Server - Tailscale control helpers.

A thin, defensive wrapper around the `tailscale` CLI used by the admin zone of
the web app to:

  * report connection status (BackendState, current tailnet, this node's IP),
  * start an interactive login (`tailscale login`), capturing the auth URL it
    prints so the operator can authenticate from a phone (link + QR), and
  * list and switch between logged-in profiles/tailnets.

This wrapper deliberately exposes only NON-destructive operations. There is no
`logout` here: logging out wipes the node's stored credentials and forces a
full browser re-auth, which is not something the UI should ever do by accident.

Privilege model: the web app runs unprivileged and calls tailscale via
`sudo -n` against a tightly-scoped sudoers rule (installed by
scripts/install_webapp.sh), mirroring the systemctl controls. This is used
instead of tailscale's `--operator` mode because operator access only works
once a profile exists -- a logged-out node could never bootstrap a login.

Everything degrades gracefully if the `tailscale` binary is absent.

"""

import json
import re
import shutil
import subprocess
import threading

# Cache of the most recent pending interactive-login auth URL (or None). Set by
# the background `tailscale up` thread, cleared once we observe a connected
# state. Guarded by _LOGIN_LOCK since it is touched from two threads.
_LOGIN_LOCK = threading.Lock()
_auth_url = None
_login_thread = None

# Matches the login URL tailscale prints during an interactive `up`.
_AUTH_URL_RE = re.compile(r"https://login\.tailscale\.com/\S+")


def _tailscale_bin():
    """Return the path to the tailscale binary, or None if not installed."""
    return shutil.which("tailscale")


def available():
    """True if the tailscale CLI is present on this system."""
    return _tailscale_bin() is not None


def _argv(args):
    """
    Build the argv for a tailscale command, invoked via `sudo -n`.

    The web app runs as an unprivileged user. Tailscale's `--operator` mode is
    not sufficient here: it only grants access once a profile exists, so a
    logged-out node can never bootstrap a login (the CLI returns "profiles
    access denied"). Instead we call tailscale through `sudo -n` against a
    tightly-scoped sudoers rule (see scripts/install_webapp.sh), mirroring how
    the systemctl controls are already scoped. `-n` => never prompt; if the
    rule is missing the call simply fails rather than hanging.
    """
    binary = _tailscale_bin()
    return ["sudo", "-n", binary, *args]


def _run(args, timeout=15):
    """
    Run `tailscale <args>` (via sudo -n) and return a CompletedProcess, or None
    if the binary is missing or the call blows up. Never raises.
    """
    if not available():
        return None
    try:
        return subprocess.run(
            _argv(args),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except Exception:  # noqa: BLE001 - callers handle None
        return None



# --------------------------------------------------------------------------
# Status
# --------------------------------------------------------------------------
def status():
    """
    Return a dict describing the current Tailscale state:

        {
            "available":  bool,   # binary present
            "state":      str,    # BackendState: Running/NeedsLogin/Stopped/...
            "tailnet":    str,    # current tailnet (MagicDNS suffix) or ""
            "ip":         str,    # this node's first Tailscale IP or ""
            "dns_name":   str,    # this node's MagicDNS name or ""
            "logged_in":  bool,   # True when BackendState == "Running"
        }
    """
    info = {
        "available": available(),
        "state": "Unknown",
        "tailnet": "",
        "ip": "",
        "dns_name": "",
        "logged_in": False,
    }
    if not info["available"]:
        info["state"] = "NotInstalled"
        return info

    proc = _run(["status", "--json"])
    if proc is None or proc.returncode != 0 or not proc.stdout.strip():
        # `tailscale status` exits non-zero when stopped/logged out; still try
        # to parse stdout (it may contain a useful BackendState).
        if proc is None or not proc.stdout.strip():
            info["state"] = "Stopped"
            return info

    try:
        data = json.loads(proc.stdout)
    except (ValueError, TypeError):
        info["state"] = "Stopped"
        return info

    info["state"] = data.get("BackendState", "Unknown")
    info["logged_in"] = info["state"] == "Running"

    self_node = data.get("Self") or {}
    ips = self_node.get("TailscaleIPs") or []
    if ips:
        info["ip"] = ips[0]
    dns_name = (self_node.get("DNSName") or "").rstrip(".")
    info["dns_name"] = dns_name

    # The current tailnet is exposed under CurrentTailnet.Name on recent
    # versions; fall back to deriving it from the MagicDNS suffix.
    current_tailnet = data.get("CurrentTailnet") or {}
    info["tailnet"] = current_tailnet.get("Name", "")
    if not info["tailnet"] and dns_name and "." in dns_name:
        # DNSName looks like "host.tailnet-name.ts.net."
        info["tailnet"] = dns_name.split(".", 1)[1]

    # If we are connected, clear any stale pending auth URL.
    if info["logged_in"]:
        with _LOGIN_LOCK:
            global _auth_url
            _auth_url = None

    return info


# --------------------------------------------------------------------------
# Interactive login
# --------------------------------------------------------------------------
def _login_worker():
    """
    Background worker: run `tailscale login` and scrape the auth URL it prints.

    We deliberately use `tailscale login` (NOT `up`): login generates a fresh
    auth URL on demand and adds/authenticates a profile WITHOUT disconnecting
    or clearing any existing session. It works whether the node is currently
    connected or logged out, so "add / log into a tailnet" is always safe and
    never destructive.

    The command blocks until the operator authenticates in a browser, so it
    must run off the request thread. We read its output line-by-line, stash the
    first login URL we see, and let the process run to completion.
    """
    global _auth_url, _login_thread
    if not available():
        with _LOGIN_LOCK:
            _login_thread = None
        return

    try:
        # Via sudo -n (scoped sudoers rule); see _argv() for why.
        proc = subprocess.Popen(
            _argv(["login"]),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )


        for line in proc.stdout:
            match = _AUTH_URL_RE.search(line)
            if match:
                with _LOGIN_LOCK:
                    _auth_url = match.group(0)
        proc.wait(timeout=300)
    except Exception:  # noqa: BLE001 - best effort background task
        pass
    finally:
        with _LOGIN_LOCK:
            _login_thread = None


def start_login():
    """
    Kick off an interactive `tailscale up` in the background (idempotent).

    Returns True if a login is now in progress (or was already running), False
    if Tailscale is not installed.
    """
    global _login_thread, _auth_url
    if not available():
        return False
    with _LOGIN_LOCK:
        if _login_thread is not None and _login_thread.is_alive():
            return True
        _auth_url = None
        _login_thread = threading.Thread(target=_login_worker, daemon=True)
        _login_thread.start()
    return True


def get_auth_url():
    """Return the pending interactive-login auth URL, or None."""
    with _LOGIN_LOCK:
        return _auth_url


def login_in_progress():
    """True if a background `tailscale up` is currently running."""
    with _LOGIN_LOCK:
        return _login_thread is not None and _login_thread.is_alive()


# --------------------------------------------------------------------------
# Profiles / tailnets
# --------------------------------------------------------------------------
def list_profiles():
    """
    Return the list of logged-in profiles (accounts/tailnets) as dicts:

        [{"id": str, "account": str, "tailnet": str, "current": bool}, ...]

    Parsed from `tailscale switch --list`. Returns [] on any failure.
    """
    proc = _run(["switch", "--list"])
    if proc is None or proc.returncode != 0 or not proc.stdout.strip():
        return []

    profiles = []
    for raw in proc.stdout.splitlines():
        line = raw.rstrip()
        if not line:
            continue
        # Skip a header row if present (older/newer formats vary).
        if line.lower().startswith(("id ", "id\t")):
            continue
        current = line.endswith("*")
        cleaned = line.rstrip("*").strip()
        cols = cleaned.split()
        if not cols:
            continue
        profile_id = cols[0]
        account = cols[1] if len(cols) > 1 else profile_id
        tailnet = cols[2] if len(cols) > 2 else ""
        profiles.append(
            {
                "id": profile_id,
                "account": account,
                "tailnet": tailnet,
                "current": current,
            }
        )
    return profiles


def switch_profile(profile_id):
    """
    Switch to an already-logged-in profile by id. The caller is responsible for
    validating `profile_id` against list_profiles() before calling this.

    Returns True on success.
    """
    if not available() or not profile_id:
        return False
    proc = _run(["switch", profile_id], timeout=30)
    return proc is not None and proc.returncode == 0


def up():
    """Bring the connection up (re-connect without re-authenticating)."""
    proc = _run(["up"], timeout=30)
    return proc is not None and proc.returncode == 0


def down():
    """Disconnect from the tailnet (stays logged in, credentials preserved)."""
    proc = _run(["down"], timeout=30)
    return proc is not None and proc.returncode == 0


# NOTE: There is intentionally NO logout() helper here. `tailscale logout`
# erases this node's stored credentials and cannot be undone from the UI (it
# forces a full re-authentication in a browser). Switching tailnets does NOT
# require logging out -- use start_login() to add a profile and switch_profile()
# to move between them. Keeping logout out of the web app prevents an
# accidental, destructive credential wipe.

