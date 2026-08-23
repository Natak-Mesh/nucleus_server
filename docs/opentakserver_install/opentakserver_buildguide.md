# OpenTAKServer Build Guide — Debian Trixie

Installing OpenTAKServer (OTS) on a Nucleus unit that is already running the
standard service stack.

Verified on: Debian 13 (trixie), Python 3.13.5, OpenTAKServer 1.7.13, host `ion-04`.

`<ANGLE-BRACKETS>` = values you supply. Don't paste them blindly.

> **The vendor installer does not work unmodified on trixie.** It fails partway
> through and still prints a success message. Read section 2 before running it.

---

## 1. What the installer changes

Vendor installer: `https://i.opentakserver.io/ubuntu_installer`

Run it as the normal user (not root). It calls `sudo` itself.

### Packages added

```
curl python3 python3-pip python3-venv rabbitmq-server openssl nginx ffmpeg
libnginx-mod-stream python3-dev postgresql-postgis pgloader
```

Plus `apt upgrade -y` on every package already installed.

Optional prompts: ZeroTier (y/n), Mumble (y/n).

**Nothing is `apt remove`d.** The conflicts are config and unit-file overwrites,
not package replacement.

### What it overwrites

| Path | Effect |
|------|--------|
| `/etc/systemd/system/mediamtx.service` | Installed/replaced. Points at `~/ots/mediamtx/mediamtx` v1.13.0 |
| `/etc/nginx/sites-enabled/*` | **Deleted** (`rm -f`), then OTS vhosts symlinked in |
| `/etc/nginx/nginx.conf` | `stream { }` block appended |
| `/etc/rabbitmq/rabbitmq.conf` | Replaced wholesale |
| `/etc/rabbitmq/rabbitmq-env.conf` | `PLUGINS_DIR` appended |
| `/etc/mumble/mumble-server.ini` | Only if you answer Y — see below |

On a stock Nucleus unit `sites-enabled/` contains only Debian's `default`
symlink, so that deletion is harmless. Confirm before running if your unit
differs.

### Mumble (only if you answer Y)

- Uncomments `ice="tcp -h 127.0.0.1 -p 6502"` — Ice bound to localhost
- Comments out `icesecretwrite` — **no auth on Ice writes**
- Restarts `mumble-server`

Answer Y only if you want OTS to manage Mumble channels. Your existing
SuperUser password from the secrets store is *not* changed. The installer greps
`/var/log/syslog` to display a password; that file does not exist on trixie, so
it prints an empty value. Ignore it.

Anything that reaches `127.0.0.1:6502` gets full Mumble admin with no
credential. Local-only, but worth knowing.

### New systemd units

`opentakserver`, `cot_parser`, `eud_handler`, `eud_handler_ssl` — all run as the
invoking user, logging to `~/ots/logs/`. Plus `nginx`, `rabbitmq-server`,
`postgresql`.

---

## 2. Installer bugs

Encountered on trixie. Check each one.

### 2.1 Silent failure cascade — the installer deletes its own working directory

**Root cause, confirmed on ion-05 with a `set -x` trace.**

The installer `cd`s into a directory and then, on non-Ubuntu systems only,
deletes that directory while still sitting in it. Every subsequent command runs
with a working directory that no longer exists, and pip is the first casualty.

The relevant lines, verbatim:

```bash
INSTALLER_DIR=/tmp/ots_installer     # line 3
mkdir -p $INSTALLER_DIR              # line 4
cd $INSTALLER_DIR                    # line 5   <-- shell enters the directory

if [ "$NAME" != "Ubuntu" ]           # line 12
then
  read -p "...run anyway? [y/N]" confirm < /dev/tty && [[ ... ]] || exit 1
  rm -fr $INSTALLER_DIR              # line 17  <-- deletes the cwd out from under itself
fi
```

Answer `y` at that prompt and the shell's cwd becomes an unlinked inode. Bash
itself does not care. Python does — `pip` resolves `os.getcwd()` during startup:

```
+ line 39: python3 -m pip install --upgrade pip setuptools wheel
Traceback (most recent call last):
  File "/home/natak/.opentakserver_venv/lib/python3.13/site-packages/pip/__main__.py", line 8, in <module>
    if sys.path[0] in ("", os.getcwd()):
                           ~~~~~~~~~^^
FileNotFoundError: [Errno 2] No such file or directory
+ line 40: pip3 install opentakserver
ERROR: Could not install packages due to an OSError: [Errno 2] No such file or directory
```

Both pip invocations die. The venv is left containing only `pip`, so everything
downstream fails:

```
cd: ~/.opentakserver_venv/lib/python3.*/site-packages/opentakserver: No such file or directory
flask: command not found
```

No config, no CA, no database schema, no working install.

**Why only Debian.** Line 17 lives inside the `!= "Ubuntu"` branch. On Ubuntu it
never executes, the cwd stays valid, and the installer works. The bug is
unreachable on the only platform the vendor tests.

**Why it looks like a pip bug and isn't.** Re-running the same pip command by
hand (section 3.1) always succeeds, because your shell is in a directory that
exists. Nothing is wrong with pip, the venv, PEP 668, or
`--system-site-packages`. Two theories worth killing explicitly, both tested and
both wrong:

- *`curl | bash` stdin consumption.* Piping does let stdin-reading commands
  (like `apt`) swallow unexecuted script text. Real bash behaviour, but not what
  happens here — the `set -x` trace shows lines 39 and 40 **executing** and
  failing, not being skipped.
- *`apt upgrade` swapping the interpreter mid-run.* Unrelated. The trace shows
  apt completing normally long before the failure.

**Fix — one line.** Download the installer first:

```bash
curl -s -L https://i.opentakserver.io/ubuntu_installer -o /tmp/ots_installer.sh
```

Patch the non-Ubuntu branch so the shell leaves the doomed directory:

```bash
  rm -fr $INSTALLER_DIR
  cd /tmp          # <-- add this line
```

Run it as a file, never piped:

```bash
bash /tmp/ots_installer.sh
```

**Recommended: trace the run.** The failure mode is silent, so capture a
transcript with line numbers. This is what identified the bug:

```bash
sed -i '1a set -x' /tmp/ots_installer.sh
sed -i "2a PS4='+ line \${LINENO}: '" /tmp/ots_installer.sh
script -q -e -c "bash /tmp/ots_installer.sh" /tmp/ots_install.log
```

Every executed line appears in `/tmp/ots_install.log` prefixed with its number,
which distinguishes "ran and failed" from "never ran" — the exact ambiguity that
made this bug hard to find.

With the patch applied, 2.2, 2.3 and 2.5-reason-1 below do not occur. 2.4
(`lastversion`) is independent and still applies.

### 2.2 The success message is a lie

Line 328 is an unconditional `echo`. It prints:

```
Setup is complete and OpenTAKServer is running. You can access the Web UI at https://<all your IPs>
```

regardless of what failed. **Do not treat it as confirmation.** Verify with
section 4 instead.

### 2.3 Postgres password is lost

Lines 55–57 generate a random password, create the `ots` role with it, then
`sed` it into `~/ots/config.yml` — which does not exist yet, because
`generate-config` (line 42) failed. The role exists with a password nobody has.
Must be reset (section 3.3).

### 2.4 `lastversion` is never installed

Used at lines 159 and 227 to fetch mediamtx and the web UI. Not in the apt list.
Both downloads fail.

It *is* a dependency of the `opentakserver` package, so once section 3.2
succeeds it becomes available.

### 2.5 nginx fails to start

Two reasons, both at install time:

1. Its vhosts reference cert files that don't exist yet (CA creation failed)
2. `ots_http` binds `:80`, already held by `nucleus-webapp`

Reason 2 persists after recovery and is dealt with in section 5.

---

## 3. Recovery

Run after the vendor installer has failed. Picks up from a venv that exists but
is empty.

### 3.1 Fix pip

```bash
source ~/.opentakserver_venv/bin/activate
python3 -m pip install --upgrade pip setuptools wheel
```

Run on its own, in sequence, this succeeds. Not PEP 668 — the venv is fine.

### 3.2 Install OTS

```bash
pip3 install opentakserver
```

Pulls ~200 packages. Also installs `lastversion`, fixing 2.4.

### 3.3 Config and database

The site-packages path is version-specific. On Python 3.13:

```bash
export OTS_DIR=~/.opentakserver_venv/lib/python3.13/site-packages/opentakserver
cd "$OTS_DIR"
flask ots generate-config
```

Reset the lost postgres password and write it into the config:

```bash
NEWPW=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
sudo su postgres -c "psql -c \"ALTER ROLE ots WITH PASSWORD '${NEWPW}';\""
sed -i "s~postgresql+psycopg://ots:POSTGRESQL_PASSWORD@~postgresql+psycopg://ots:${NEWPW}@~" ~/ots/config.yml
echo "postgres password: ${NEWPW}"
```

Verify line 242 of `~/ots/config.yml` no longer contains the literal
`POSTGRESQL_PASSWORD`, then migrate:

```bash
cd "$OTS_DIR"
flask db upgrade
```

Confirm — expect 37 tables:

```bash
sudo su postgres -c "psql -d ots -c '\dt'"
```

### 3.4 Certificate authority

```bash
mkdir -p ~/ots/ca ~/ots/logs
cd "$OTS_DIR"
flask ots create-ca
```

Produces `~/ots/ca/`:

```
ca.pem                                    CA cert (PEM)
ca-do-not-share.key                       CA private key
ca-trusted.pem
truststore-root.p12                       PKCS12 truststore
certs/opentakserver/opentakserver.pem     server cert
certs/opentakserver/opentakserver.nopass.key
certs/opentakserver/opentakserver.p12
```

Note both PEM and PKCS12 are produced. Official TAK stages `.p12` from
`/opt/tak/certs/files/`; OTS's equivalents live here.

### 3.5 Web UI

```bash
sudo mkdir -p /var/www/html/opentakserver
sudo chmod a+rw /var/www/html/opentakserver
cd /var/www/html/opentakserver
lastversion --assets extract brian7704/OpenTAKServer-UI
```

### 3.6 Ignorable noise

Every `flask` command emits these on Python 3.13. Harmless — they come from
gevent fork hooks during interpreter shutdown:

```
RuntimeError: greenlet is being finalized
AssertionError:   (from  assert sys.version_info[:2] < (3, 13) )
```

Commands complete successfully regardless. Verify by result (tables created,
certs on disk), not by absence of stderr.

---

## 4. MediaMTX — optionally run a newer binary

OTS owns MediaMTX. `setup_nucleus.sh` does not install it at all (it only opens
the firewall ports), so the installer's `mediamtx.service` pointing at its
bundled v1.13.0 in `~/ots/` is the expected end state. **If that is your setup,
skip this section.**

This section applies only to units that also have a newer MediaMTX at
`/usr/local/bin/mediamtx` — e.g. `ion-04`, which carries a SHA256-verified
v1.18.2 from an earlier build of the provisioning script. On those boxes the
installer's unit silently demotes you to v1.13.0.

The newer binary runs OTS's config fine — only deprecation warnings
(`protocols` → `rtspTransports`, etc.). So keep the binary, take the config:

```bash
sudo cp /etc/systemd/system/mediamtx.service /etc/systemd/system/mediamtx.service.ots-installer.bak

sudo tee /etc/systemd/system/mediamtx.service >/dev/null <<'EOF'
[Unit]
Description=MediaMTX media server
After=network.target
Wants=network.target

[Service]
Type=simple
User=<USER>
ExecStart=/usr/local/bin/mediamtx /home/<USER>/ots/mediamtx/mediamtx.yml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl restart mediamtx
```

This also restores `Description=`, `After=network.target` and `Restart=`, none of
which the installer's unit has.

---

## 5. Port conflicts and the 443 → 8444 swap

The main integration problem. OTS and the Nucleus dashboard both want the ports
a browser reaches by default.

### 5.1 Default OTS port map

| Port | Vhost / service | Purpose |
|------|-----------------|---------|
| 80, 8080 | `ots_http` | Web UI over plain HTTP, `8080 default_server` |
| 443 | `ots_https` (block 1) | Web UI over TLS |
| 8443 | `ots_https` (block 2) | Marti API — **requires client cert** |
| 8446 | `ots_certificate_enrollment` | Certificate enrollment |
| 8883 | stream | MQTT over TLS → rabbitmq 1883 |
| 8322 | stream | RTSP over TLS → mediamtx 8554 |
| 1936 | stream | RTMP over TLS → mediamtx 1935 |
| 8081 | opentakserver | App itself, localhost only. Everything proxies here |
| 8088 / 8089 | eud_handler | TCP / SSL CoT streaming |

Collides with Nucleus on `:80` (nucleus-webapp) and `:443`.

### 5.2 The requirement

Typing bare `<HOSTNAME>.local` must reach the Nucleus dashboard.

mDNS resolves name → IP and has no port component, so this is purely about
browser defaults — and there are **two**, not one:

- Bare hostname → port 80
- Modern browsers try **HTTPS first** → port 443

Freeing only :80 is not enough. A browser typing `ion-04.local` will try
`https://ion-04.local` and land on OTS. Both ports must be clear.

### 5.3 Free port 80

`ots_http` is the only vhost on :80. The installer enables all three via a glob
(`ln -s /etc/nginx/sites-available/ots_* ...`), so drop the one symlink:

```bash
sudo rm /etc/nginx/sites-enabled/ots_http
```

Costs the plain-HTTP UI and `8080 default_server`. Nothing else uses 8080.

### 5.4 Free port 443 — move, don't merge

`ots_https` contains two `server` blocks, and they are **not** interchangeable:

| | 443 block | 8443 block |
|---|---|---|
| `/` UI | yes | yes |
| `/socket.io` | **yes** | no |
| `/hls` → mediamtx 8888 | **yes** | no |
| `/webrtc` → mediamtx 8889 | **yes** | no |
| `/Marti` | returns 404 | **yes** |
| `/files` (CloudTak) | no | **yes** |
| `ssl_verify_client` | off | **on** |

Folding 443's contents into 8443 breaks the browser UI twice over: `ssl_verify_client on`
rejects any browser without an enrolled client certificate, and the live-update
and video routes don't exist there.

So move the 443 block intact to **8444**, preserving all its locations:

```bash
sudo cp /etc/nginx/sites-available/ots_https /etc/nginx/sites-available/ots_https.bak-443

sudo sed -i 's/^    listen 443 ssl;/    listen 8444 ssl;/; s/proxy_set_header Host \$host:443;/proxy_set_header Host $host:8444;/g' \
    /etc/nginx/sites-available/ots_https

sudo nginx -t && sudo systemctl reload nginx
```

Exactly three lines change: the `listen` directive, and two `proxy_set_header
Host $host:443` headers (in the 443 block's `/api`, and the 8443 block's
`/files` — the latter is hardcoded to 443 in the vendor config even though it
sits in the 8443 block).

Safe to move because the OTS UI builds its URLs from `location.origin` /
`.hostname` / `.protocol` — no hardcoded `:443` anywhere in its JS — and
`config.yml` has no 443 setting. `OTS_MARTI_HTTPS_PORT: 8443` is unrelated.

`nginx -t` also warns about `proxy_headers_hash_bucket_size`. Pre-existing, from
the vendor config, unrelated to this change.

### 5.5 Result

| Port | Serves |
|------|--------|
| 80 | Nucleus dashboard |
| 443 | *(closed — connection refused)* |
| 8444 | OTS web UI |
| 8443 | OTS Marti API (client cert required) |
| 8446 | OTS certificate enrollment |

With 443 closed, a browser given a bare hostname tries HTTPS, gets refused, and
falls back to HTTP on :80 → the dashboard.

> Chrome and Safari perform this fallback. **Firefox with HTTPS-Only Mode
> enabled shows an interstitial instead of falling back.** If that matters for
> your users, the dashboard needs to serve TLS on 443 itself, which is a larger
> change.

---

## 6. cot_parser boot race

`cot_parser` exits immediately with:

```
cot_parser error: (404, "NOT_FOUND - no exchange 'cot_parser' in vhost '/'")
```

The exchange is declared by `opentakserver` at startup. The installer's
`cot_parser.service` sets `PartOf=opentakserver.service` but **no `After=`**, so
systemd is free to start it first — it finds no exchange and gives up. There's
no `Restart=`, so it stays dead. Recurs on every boot.

Fix with a drop-in:

```bash
sudo mkdir -p /etc/systemd/system/cot_parser.service.d
sudo tee /etc/systemd/system/cot_parser.service.d/ordering.conf >/dev/null <<'EOF'
[Unit]
After=opentakserver.service rabbitmq-server.service
Requires=rabbitmq-server.service

[Service]
Restart=on-failure
RestartSec=10
EOF

sudo systemctl daemon-reload
sudo systemctl restart cot_parser
```

`opentakserver.service` also declares `Requires=eud_handler eud_handler_ssl cot_parser`
without `.service` suffixes and without matching `After=`. Left alone so far —
noted in case ordering problems appear elsewhere.

---

## 7. Verification

```bash
for s in nginx opentakserver cot_parser eud_handler eud_handler_ssl \
         mediamtx nucleus-webapp mumble-server rabbitmq-server; do
    printf "%-20s %s\n" "$s" "$(systemctl is-active $s)"
done
```

All nine should be `active`.

```bash
curl -s     -o /dev/null -w "80   → %{http_code}\n" http://localhost/
curl -sk    -o /dev/null -w "8444 → %{http_code}\n" https://localhost:8444/
curl -sk --max-time 3 -o /dev/null -w "443  → %{http_code}\n" https://localhost:443/
```

Expect `200`, `200`, and `000` (refused) respectively.

Confirm the right app answers each port:

```bash
curl -s  http://localhost/        | grep -oiE "<title>[^<]*</title>"   # Nucleus Server
curl -sk https://localhost:8444/  | grep -oiE "<title>[^<]*</title>"   # OpenTAKServer
```

**Finish in a real browser.** `curl` forces the protocol and cannot exercise
HTTPS-first fallback — the exact behaviour section 5.2 hinges on. Type the bare
hostname with no scheme and no port, and confirm you land on the dashboard.

Service logs, if something is wrong:

```
~/ots/logs/opentakserver.log
~/ots/logs/cot_parser.log
~/ots/logs/eud_handler_tcp.log
~/ots/logs/eud_handler_ssl.log
```

Per-service logs are more useful than `journalctl` here — the units redirect
stdout/stderr to files.

---

## 8. Post-install

### Default credentials

OTS creates `administrator` / `password` on first run. **Change it.**

### Mumble authentication

Off by default even with the Ice setup done. In `~/ots/config.yml`:

```yaml
OTS_ENABLE_MUMBLE_AUTHENTICATION: false
```

Set `true` and restart `opentakserver` for OTS to manage Mumble users.

### Firewall

The Nucleus install opens direct mediamtx ports. OTS instead fronts them with
TLS on 8322/1936, and adds its own:

```bash
sudo ufw allow 8444/tcp comment "OTS Web UI"
sudo ufw allow 8443/tcp comment "OTS Marti API"
sudo ufw allow 8446/tcp comment "OTS cert enrollment"
sudo ufw allow 8089/tcp comment "OTS CoT streaming (SSL)"
sudo ufw allow 8088/tcp comment "OTS CoT streaming (TCP)"
sudo ufw allow 8883/tcp comment "OTS MQTT over TLS"
sudo ufw allow 8322/tcp comment "OTS RTSP over TLS"
sudo ufw allow 1936/tcp comment "OTS RTMP over TLS"
```

Do **not** open 8081 — the app binds `127.0.0.1` and must stay behind nginx.

### Files changed

| Path | Note |
|------|------|
| `/etc/nginx/sites-available/ots_https` | 443 → 8444 |
| `/etc/nginx/sites-available/ots_https.bak-443` | backup, pre-change |
| `/etc/nginx/sites-enabled/ots_http` | removed |
| `/etc/systemd/system/mediamtx.service` | only if you did section 4 — repointed at `/usr/local/bin/mediamtx` |
| `/etc/systemd/system/mediamtx.service.ots-installer.bak` | only if you did section 4 — backup, installer's version |
| `/etc/systemd/system/cot_parser.service.d/ordering.conf` | boot-race drop-in |
| `~/ots/config.yml` | postgres password reset |

---

## 9. Differences from official TAK Server

For anyone adapting Nucleus tooling across both.

| | Official TAK | OpenTAKServer |
|---|---|---|
| Service(s) | `takserver` | `opentakserver`, `cot_parser`, `eud_handler`, `eud_handler_ssl` |
| Install root | `/opt/tak` | `~/ots` + `~/.opentakserver_venv` |
| Certs | `/opt/tak/certs/files/*.p12` | `~/ots/ca/` (PEM + `truststore-root.p12`) |
| CA password | `atakatak` | none — PEM files |
| Web UI | `:8443`, mutual TLS | `:8444` after the swap, nginx-fronted |
| Cert enrollment | `:8446` | `:8446` |
| CoT streaming | `:8089` (SSL) | `:8089` (SSL), `:8088` (TCP) |
| Client connect string | `<host>:8089:ssl` | `<host>:8089:ssl` |
| Admin identity | `webadmin.p12` client cert | username / password |
| Runtime | Java | Python + RabbitMQ + PostgreSQL |
| Owns mediamtx | no | yes |
| Owns mumble | no | optionally, via Ice |

The `webadmin.p12` download and the `.p12`-based data-package builder have no
direct OTS equivalent — OTS uses password auth and PEM certs.
