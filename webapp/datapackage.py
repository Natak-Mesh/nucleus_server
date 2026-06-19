#!/usr/bin/env python3
"""
TAK client data-package builder.

Produces an ATAK/WinTAK "import" data package (.zip) that pre-configures a
connection to *this* TAK server and bundles the public intermediate CA
truststore so the client can auto-enroll.

The package contains ONLY the public CA truststore (caCert.p12) — never a
private key or the server's signing keystore. After import, the user supplies
their own username/password and ATAK/WinTAK mints its own client certificate
via certificate auto-enrollment.

Layout produced (relative to the zip root):

    MANIFEST/manifest.xml      - declares the package + its contents
    certs/caCert.p12           - public intermediate CA truststore
    <hostname>.pref            - connection preferences (host, 8089/ssl, enroll)

iTAK is intentionally NOT supported (it cannot auto-enroll this way).
"""

import io
import os
import uuid
import zipfile

# Default location the setup scripts stage the public truststore to.
DEFAULT_CA_PATH = os.path.expanduser("~/certs/caCert.p12")

# Standard TAK truststore password (confirmed for these units).
CA_PASSWORD = "atakatak"

# TAK certificate-enrollment / TLS streaming port.
ENROLL_PORT = 8089


def _manifest_xml(package_uid, package_name):
    """Render MANIFEST/manifest.xml for an onReceiveImport package."""
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<MissionPackageManifest version="2">\n'
        "  <Configuration>\n"
        f'    <Parameter name="uid" value="{package_uid}"/>\n'
        f'    <Parameter name="name" value="{package_name}"/>\n'
        '    <Parameter name="onReceiveImport" value="true"/>\n'
        '    <Parameter name="onReceiveDelete" value="false"/>\n'
        "  </Configuration>\n"
        "  <Contents>\n"
        '    <Content ignore="false" zipEntry="certs/caCert.p12"/>\n'
        f'    <Content ignore="false" zipEntry="{package_name}.pref"/>\n'
        "  </Contents>\n"
        "</MissionPackageManifest>\n"
    )


def _preference_pref(hostname, mdns_host):
    """
    Render the <hostname>.pref connection preferences.

    Uses the mDNS .local name for the connect string so it resolves regardless
    of the unit's current IP. Enables certificate auto-enrollment + user auth.
    """
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        "<preferences>\n"
        '  <preference version="1" name="cot_streams">\n'
        '    <entry key="count" class="class java.lang.Integer">1</entry>\n'
        f'    <entry key="description0" class="class java.lang.String">{hostname}</entry>\n'
        '    <entry key="enabled0" class="class java.lang.Boolean">true</entry>\n'
        f'    <entry key="connectString0" class="class java.lang.String">{mdns_host}:{ENROLL_PORT}:ssl</entry>\n'
        # Per-stream enrollment/auth keys (suffix 0). These MUST live inside
        # cot_streams and be bound to connectString0 — placing them globally in
        # app_preferences leaves them unbound and enrollment fails right after
        # the user enters credentials.
        '    <entry key="caLocation0" class="class java.lang.String">certs/caCert.p12</entry>\n'

        f'    <entry key="caPassword0" class="class java.lang.String">{CA_PASSWORD}</entry>\n'
        '    <entry key="enrollForCertificateWithTrust0" class="class java.lang.Boolean">true</entry>\n'
        '    <entry key="useAuth0" class="class java.lang.Boolean">true</entry>\n'
        '    <entry key="cacheCreds0" class="class java.lang.String">Cache credentials</entry>\n'
        "  </preference>\n"
        '  <preference version="1" name="com.atakmap.app_preferences">\n'
        '    <entry key="displayServerConnectionWidget" class="class java.lang.Boolean">true</entry>\n'
        "  </preference>\n"
        "</preferences>\n"
    )



def ca_available(ca_path=DEFAULT_CA_PATH):
    """True if the staged CA truststore exists and is readable."""
    return os.path.isfile(ca_path) and os.access(ca_path, os.R_OK)


def build_package(hostname, mdns_host, ca_path=DEFAULT_CA_PATH):
    """
    Build the data package in memory and return (filename, bytes).

    Raises FileNotFoundError if the staged CA truststore is missing.
    """
    if not ca_available(ca_path):
        raise FileNotFoundError(
            f"CA truststore not staged at {ca_path}. "
            "Run scripts/refresh_tak_cert.sh as root."
        )

    package_name = hostname  # e.g. "nucleus-server"
    package_uid = str(uuid.uuid4())

    with open(ca_path, "rb") as fh:
        ca_bytes = fh.read()

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("MANIFEST/manifest.xml", _manifest_xml(package_uid, package_name))
        zf.writestr("certs/caCert.p12", ca_bytes)
        zf.writestr(f"{package_name}.pref", _preference_pref(hostname, mdns_host))

    buf.seek(0)
    return (f"{package_name}_enrollment.zip", buf.read())
