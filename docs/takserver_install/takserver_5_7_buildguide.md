# TAK Server Build Guide (stripped-down, 5.7 on Debian Trixie)

A condensed, command-focused build derived from the MyTecknet guide
(<https://mytecknet.com/lets-build-a-tak-server/>), corrected for **TAK Server
5.7 on Debian Trixie**.

> **Environment:** Debian 13 (Trixie), headless — no desktop environment
> (CLI / SSH only).


> ## ⚠️ Read first — differences from the MyTecknet page
> 1. **Skip the page's package steps.** Its EPEL / PostgreSQL / PostGIS / Java
>    and Rocky/RHEL/SELinux sections do not apply. We install PostgreSQL 15 +
>    Java 17 from Bookworm via APT pinning (Section 1).
> 2. **Truststore placeholder changed.** The page's
>    `sed 's/truststore-root/.../'` is **obsolete**. 5.7 ships
>    `truststore-<CACommonName>` by default — see Section 4.
> 3. **We use `nano`**, not `vi`.
>
> **About placeholders:** anything in `<ANGLE-BRACKETS>` is a value YOU supply
> (CA names, username, group, etc.). Lines containing them are **not** safe to
> copy-paste blindly — edit them first. Plain code blocks with no brackets are
> safe to paste as-is.

---

## 1. Prerequisites — packages & APT pinning

Trixie ships PostgreSQL 18 and no OpenJDK 17, but TAK Server needs PostgreSQL 15
and OpenJDK 17. Pull those two from Bookworm via pinning (rest of system stays
on Trixie).

```bash
echo -e "Package: *\nPin: release n=bookworm\nPin-Priority: 100" | sudo tee /etc/apt/preferences.d/bookworm
echo "deb http://deb.debian.org/debian bookworm main" | sudo tee /etc/apt/sources.list.d/bookworm.list
sudo apt update
sudo apt install -y postgresql-15 postgresql-client-15 postgresql-15-postgis-3
sudo apt install -y openjdk-17-jdk openjdk-17-jre
```

Verify:

```bash
java -version          # openjdk 17.x
pg_lsclusters          # a 15 main cluster, online
```

**Increase open-file limit for JVM threads** (default step, required on any
install path). TAK Server's JVM needs a higher per-user open-file limit:

```bash
echo -e "*      soft      nofile      32768\n*      hard      nofile      32768\n" | sudo tee --append /etc/security/limits.conf
```

Check the two `nofile` lines were added:

```bash
sudo tail -n 15 /etc/security/limits.conf
```

**Install TAK Server:** from the directory holding your `.deb`, e.g.:

```bash
sudo apt install ./takserver_5.7-RELEASE43_all.deb   # use your actual filename
```

Confirm `/opt/tak/` exists.



---

## 2. Certificate metadata

All work under `/opt/tak` is done as the `tak` user.

```bash
sudo su tak
cd /opt/tak/certs
nano cert-metadata.sh
```

Edit these to match your organization (quote any value containing spaces, e.g.
`CITY="New York City"`):

- `COUNTRY`, `STATE`, `CITY`, `ORGANIZATION`, `ORGANIZATIONAL_UNIT`
- optional: `CAPASS` (CA password), `PASS` (other certs; defaults to `CAPASS`)

Save and exit.

---

## 3. Build the PKI (root CA → intermediate CA → server cert)

Order matters — it builds the chain of trust. CA common names **cannot contain
spaces** (use `-` or `_`).

```bash
# Root CA  — supply your own root CA name
./makeRootCa.sh --ca-name <ROOT-CA-NAME>

# Intermediate (signing/issuing) CA — supply your own name.
# Answer Y to "move the files around so future certs are signed by this CA?"
./makeCert.sh ca <INTERMEDIATE-CA-NAME>

# Server certificate — keep the common name 'takserver'
# (this is the default filename referenced in CoreConfig)
./makeCert.sh server takserver
```

> Keep `takserver` as the server common name unless you have a reason to change
> it. If you change it, you must also update every `takserver` reference in
> `CoreConfig.example.xml`.

---

## 4. CoreConfig — point truststore at your intermediate CA  ⚠️ 5.7 change

The MyTecknet page says to run
`sed 's/truststore-root/truststore-<CA>/'`. **Do not** — on 5.7 there is no
`truststore-root`; the file already ships `truststore-<CACommonName>`.

Substitute your intermediate CA name into the existing placeholder:

```bash
# Replace <INTERMEDIATE-CA-NAME> with the name you used in Section 3
sed -i 's/truststore-<CACommonName>/truststore-<INTERMEDIATE-CA-NAME>/g' /opt/tak/CoreConfig.example.xml
```

Verify (no `<CACommonName>` should remain):

```bash
grep truststore- /opt/tak/CoreConfig.example.xml
```

---

## 5. Start the server

```bash
exit                                      # leave the tak user
sudo systemctl enable takserver.service
sudo systemctl start takserver.service
tail -f /opt/tak/logs/takserver-messaging.log
```

Watch for, at minimum:
- `Successfully Started Netty Server for TlsServerInitializer on Port 8089`
- `Server started`
- `TAK Server version ...`

(Ctrl-C to stop tailing.)

---

## 6. Admin (webadmin) certificate

Create the admin client cert, elevate it to admin, and optionally assign a group.

```bash
sudo su tak
cd /opt/tak/certs

# Create the webadmin client certificate
./makeCert.sh client webadmin

# Elevate it to administrator (-A)
java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/webadmin.pem
```

**Optional — assign the cert to a group** (`-g`). Groups are named with leading
and trailing double underscores; `__ANON__` is the default group clients land in
if you skip this:

```bash
# Replace <GROUP> (e.g. __ANON__)
java -jar /opt/tak/utils/UserManager.jar certmod -g <GROUP> /opt/tak/certs/files/webadmin.pem
```

```bash
exit
```

---

## 7. Export the admin cert to your user

Copy `webadmin.p12` out of `/opt/tak` so you can SCP it to your admin
workstation, and fix ownership.

```bash
cd ~
sudo cp -v /opt/tak/certs/files/webadmin.p12 ~/
# Replace <USER> and <GROUP> with your Linux user/group
sudo chown <USER>:<GROUP> ~/webadmin.p12
```

> Note: TAK `.p12` files use a legacy algorithm (RC2-40-CBC). To inspect with
> modern OpenSSL add `-legacy`. ATAK/WinTAK import them fine.

---

## 8. Firewall (UFW)

Allow the client-facing ports. Minimum secure ports:

| Service | Port |
|---------|------|
| TAK signaling (client connect) | 8089/tcp |
| Web UI / WebTAK / API | 8443/tcp |

```bash
sudo ufw allow ssh
sudo ufw allow 8089/tcp
sudo ufw allow 8443/tcp
sudo ufw enable
```

> If you set `sudo ufw default deny incoming` (as TAK's docs do), you must also
> explicitly allow your local bridge/mesh interfaces, or local services break.
> See `ufw_mesh_firewall_rules.md` for the interface-specific rules
> (`ufw allow in on <iface>`).

### 8.1 WiFi access point & info web app

The server runs a WiFi access point (SSID `001-server-nucleus`, static IP
`10.30.1.1`) so you can always reach the box from a known address regardless of
what the ethernet side is assigned. With `ufw default deny incoming`, two extra
allows are required or the AP appears broken (clients never get an IP, and the
info page is unreachable):

```bash
# DHCP server for the WiFi AP — scope to the AP interface ONLY.
# Never allow DHCP on ethernet: the box would act as a rogue DHCP server
# on whatever LAN it is plugged into and could break that network.
sudo ufw allow in on wlx00c0cab6c5a8 to any port 67 proto udp

# Info web app (port 80) on all interfaces, so it is reachable both over
# the WiFi AP (http://10.30.1.1) and over ethernet (at the server's
# ethernet IP). The page is read-only.
sudo ufw allow 80/tcp
```

> Replace `wlx00c0cab6c5a8` with your Alfa AP interface name if different
> (`ip link` to find it). The DHCP rule is interface-scoped on purpose; the
> web rule is intentionally global.

### 8.2 MediaMTX streaming server

MediaMTX (installed to `/usr/local/bin/mediamtx`, config at
`/etc/mediamtx/mediamtx.yml`, running as the `mediamtx` systemd service) listens
on the following default ports. Open all of them to expose every protocol, or
trim the list to only the protocols you actually use:

| Service | Port | Notes |
|---------|------|-------|
| RTSP | 8554/tcp | RTSP streaming |
| RTP (RTSP) | 8000/udp | UDP media for RTSP |
| RTCP (RTSP) | 8001/udp | UDP media for RTSP |
| RTMP | 1935/tcp | RTMP ingest/playback |
| HLS | 8888/tcp | HLS over HTTP |
| WebRTC | 8889/tcp | WebRTC signaling/HTTP |
| WebRTC ICE | 8189/udp | WebRTC UDP media |
| SRT | 8890/udp | SRT |

```bash
sudo ufw allow 8554/tcp     # RTSP
sudo ufw allow 8000/udp     # RTP (RTSP media)
sudo ufw allow 8001/udp     # RTCP (RTSP media)
sudo ufw allow 1935/tcp     # RTMP
sudo ufw allow 8888/tcp     # HLS
sudo ufw allow 8889/tcp     # WebRTC
sudo ufw allow 8189/udp     # WebRTC ICE
sudo ufw allow 8890/udp     # SRT
```

> These are MediaMTX's out-of-the-box defaults. If you change any `*Address`
> setting in `/etc/mediamtx/mediamtx.yml`, update the firewall rules to match.

---

## Quick reference — client connection

When adding the server in ATAK/WinTAK, the connection uses **port 8089**. There
is one port field; enrollment and the live data feed both use 8089. Do **not**
point the client at 8446 (that is the internal cert-config web connector) — doing
so makes enrollment "succeed" then immediately drop with
`I/O error, reconnecting`.

**Which host/IP to enter** depends on how the client reaches the server (port is
always 8089):

- **Client on the same wired LAN as the server:** use the server's **ethernet
  IP** (look it up on the info web page, or `ip -4 addr`).
- **Client connected over the server's WiFi access point:** use the **AP's
  static IP**.


---

## Info web page — finding the server

The server hosts a small read-only info page (hostname + interface IPs) so you
can find its address without a network scan. Two ways to reach it:

- **WiFi AP (static IP):** connect to SSID `001-server-nucleus` →
  `http://10.30.1.1`
- **Wired LAN (mDNS hostname):** from any device on the same network →
  `http://nucleus-server.local` (use `<hostname>.local` if renamed)

See `webapp/README.md` for details and install steps.
