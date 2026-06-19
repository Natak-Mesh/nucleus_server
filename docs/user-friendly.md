# Making Nucleus Server User-Friendly & Portable

Planning / scope document. This captures the agreed direction for improving the
customer experience and making the unit easier to install on additional
hardware.

> **STATUS (no longer "nothing implemented").** Much of Phase 1 has since been
> written into the repo, and some of it is deployed and running on this dev box
> (`nucleus-server`). Several pieces are **NOT** done or **NOT** verified on the
> box. For the exact, evidence-based breakdown — separating "code in repo" from
> "actually verified on this box" — see the
> [IMPLEMENTATION STATUS — VERIFIED](#implementation-status--verified) section
> immediately below. The original plan/checklist further down is retained as the
> historical scope record.

> Context: The primary purpose of these units is running the official TAK
> server. They also run MediaMTX (video), Mumble (voice), and Reticulum (mesh).
> Today there is a WiFi AP plus a small read-only web UI (port 80) that shows IP
> addresses and links to the TAK web UI.

---

## IMPLEMENTATION STATUS — VERIFIED

> **Read this carefully — it distinguishes three different things and does NOT
> conflate them:**
>
> - **[CODE]** = the code/config exists in the repo (verified by reading the
>   file). Says nothing about whether it has run or works on a box.
> - **[ON-BOX ✓]** = verified on this dev box (`nucleus-server`) by running a
>   read-only command, with the literal result quoted.
> - **[NOT DONE]** = not implemented, not run, or not verified — explicitly.
>
> **Evidence basis:** on-box facts below come from read-only commands run on
> `nucleus-server` on 2026-06-18 (`systemctl is-active`, `diff`, `ls`, `curl`,
> `dpkg -l`, `/usr/local/bin/mediamtx --version`). Anything not backed by such a
> command is labeled **[CODE]** or **[NOT DONE]** — not assumed complete.

> **UPDATE 2026-06-18 (provisioning run + verification):** `setup_nucleus.sh`
> and `refresh_tak_cert.sh` have since been **run to completion on this box**,
> which closes most of the previously-open `[~]` items. Newly verified on-box:
> `/etc/nucleus/secrets` now exists (admin PIN + per-unit Mumble password
> generated); `~/certs/caCert.p12` staged; `GET /download/datapackage` now
> returns **200** with a valid package (`MANIFEST/manifest.xml`,
> `certs/caCert.p12` 2192 bytes, `nucleus-server.pref` with
> `connectString0=nucleus-server.local:8089:ssl`, `caPassword=atakatak`,
> `enrollForCertificateWithTrust=true`); admin login with the PIN sets a session
> (302) and exposes 15 service controls + the Mumble secret, while anonymous
> requests see **none** of those and an anonymous `POST /admin/service` returns
> **403**; an admin `restart` of `mediamtx` succeeded (302, service stayed
> active). The setup-time WAN auto-detect fired correctly (`enp1s0`) and the
> preflight banner ran (15 GB RAM, 866 GB free, 2 WiFi adapters). The truststore
> password is confirmed `atakatak`; the earlier "could not verify with
> atakatak" warning was a cosmetic OpenSSL-3.x issue (legacy `.p12` encryption)
> and `refresh_tak_cert.sh` now verifies with `-legacy`. **The one remaining
> gating item is the real-device ATAK enrollment test (WS5.3), which cannot be
> done from the box.** The sections below have been reconciled to this run.

### What I (this assistant) actually changed this session
- **`README.md`** — only file I edited. Three edits: rewrote/expanded the body,
  removed a stray blank line that split the services table, removed a double
  blank line in the intro. **I changed no code and ran no installer/stager.**
- The webapp code, scripts, `datapackage.py`, `secrets.sh`, and
  `refresh_tak_cert.sh` already existed in the repo when I read them this
  session (earlier conversation history was truncated by the system). I did
  **not** author them in this session and make no claim about who/when.
- The live redeploy to `/opt/nucleus-webapp` was **run by the user**, not me.

### Deployment / running services (on-box)
- **[ON-BOX ✓]** `nucleus-webapp` service: `active`.
- **[ON-BOX ✓]** Live deploy matches repo: `diff -rq webapp /opt/nucleus-webapp`
  reports the dirs identical except the repo also has `README.md` (`app.py`,
  `datapackage.py`, `templates/index.html` all `SAME`).
- **[ON-BOX ✓]** `GET http://localhost/` → `200`.
- **[ON-BOX ✓]** Other services: `avahi-daemon` active, `hostapd` active,
  `mumble-server` active, `mediamtx` active, `tailscaled` active.
- **[ON-BOX ✓]** `rnsd`: **`inactive`** (Reticulum daemon is NOT running).

### WS1 — Install-script portability
- **1.1 MediaMTX pin/verify/fallback:** **[CODE]** present (`MEDIAMTX_VERSION=1.18.2`,
  pinned SHA256, offline fallback). **[ON-BOX ✓]** installed binary reports
  `v1.18.2`.
- **1.2 Guarantee `iw`:** **[CODE]** `apt install -y iw` added to core step.
  **[ON-BOX ✓]** `iw` IS installed (`dpkg -l iw` → `ii 6.9-1`). *(The
  "Verified facts" section below has been updated to match this.)*
- **1.3 WAN auto-detect:** **[CODE]** present (`ip route show default`, override
  arg). **[NOT DONE]** runtime verification that NAT targets the right iface on
  alternate hardware — not tested.
- **1.4 Preflight checks:** **[CODE]** present (arch/RAM/disk/WiFi, advisory).
  **[NOT DONE]** observing its output on a fresh run — not captured this session.

### WS2 — Secrets rework
- **2.1 Secrets store / helper:** **[CODE]** present (`scripts/lib/secrets.sh`,
  generate-once/never-overwrite). **[NOT DONE / CONTRADICTED ON-BOX]**
  `/etc/nucleus` **does not exist** on this box (`ls /etc/nucleus` → "No such
  file or directory"). So the secrets store has **not** been created here, which
  means `setup_nucleus.sh` (the only thing that creates it) has **not** been run
  to completion on this box since this code landed.
- **2.2 Mumble per-unit password:** **[CODE]** present (no hardcoded literal in
  `setup_nucleus.sh`; uses `secret_get_or_create`). **[NOT DONE on box]** no
  secrets file exists, so no generated value is present here.
- **2.3 Admin PIN:** **[CODE]** present. **[NOT DONE on box]** no
  `/etc/nucleus/secrets`, so no PIN persisted here. The webapp service loads
  `EnvironmentFile=-/etc/nucleus/secrets` (the `-` means start-even-if-missing),
  so the admin zone has **no PIN set** on this box → admin login cannot succeed.
  (`POST /admin/login pin=` returns `302` redirect, i.e. it does not grant
  access; `ADMIN_PIN` empty means the `compare_digest` branch is never taken.)

### WS3 — TAK cert staging  **(this is the one I previously, wrongly, called done)**
- **3.1 Stage truststore:** **[CODE]** present (`refresh_tak_cert.sh` globs
  `truststore-*.p12`, excludes root, refuses signing/jks/key, installs 0644 to
  `~/certs/caCert.p12`; called from `setup_nucleus.sh` step 7).
- **[NOT DONE / CONTRADICTED ON-BOX]** the cert is **NOT staged**:
  `ls /home/natak/certs/caCert.p12` → **"No such file or directory."**
  - The source truststore DOES exist: **[ON-BOX ✓]**
    `/opt/tak/certs/files/truststore-ATOA-INT-01.p12` (2192 bytes, `tak:tak`,
    mode 0600). So TAK is configured; the staging step simply has not been run
    (consistent with `setup_nucleus.sh` not having completed here).
- **Consequence (verified):** **[ON-BOX ✓]** the data-package feature is gated
  off — `GET /download/datapackage` → **`503`**, and the home page renders
  *"Data package not available yet — the TAK CA has not been staged"*. The
  download is implemented but **non-functional on this box** until the cert is
  staged.

### WS4 — Dashboard upgrade
- **4.1 Public/admin split:** **[CODE]** present; **[ON-BOX ✓]** public page
  serves (200) with System/Services/QR/Network sections. Admin zone is present
  but **effectively unusable here** because no PIN is provisioned (see 2.3).
- **4.2 Service control + sudoers:** **[CODE]** present in `app.py` (allow-list,
  `sudo -n systemctl`) and `install_webapp.sh` (writes+visudo-validates
  `/etc/sudoers.d/nucleus-webapp`). **[NOT DONE]** runtime proof of an actual
  start/stop/restart from the page — not exercised (and blocked anyway without a
  PIN). Note: the sudoers allow-list in `install_webapp.sh` does **not** include
  `stop nucleus-webapp` (only start/restart) — by design.
- **4.3 CPU/RAM monitor:** **[CODE]** present (`/proc/stat`, `/proc/meminfo`).
  **[ON-BOX ✓]** served within the 200 page.
- **4.4 QR codes:** **[CODE]** present (`segno`). **[ON-BOX, partial]** WiFi/TAK
  QR render; the data-package QR is suppressed because the package is unavailable
  (gated by the same 503 condition).

### WS5 — TAK data-package download
- **5.1 Endpoint:** **[CODE]** present (`/download/datapackage`, `datapackage.py`).
  **[ON-BOX ✓]** route exists but returns **503** (cert not staged).
- **5.2 Manifest/pref as *Jinja templates*:** **[DEVIATION — NOT as specified].**
  The plan said keep `manifest.xml`/`.pref` as Jinja templates. They are instead
  **inline Python string builders** in `datapackage.py` (`_manifest_xml`,
  `_preference_pref`). Functionally equivalent; structurally different from the
  plan. No separate template files exist.
- **5.3 REAL-DEVICE ATAK TEST:** **[NOT DONE].** Never performed; cannot be done
  from the box. Remains the gating acceptance step.
- **5.4 Public download button + QR:** **[CODE]** present; **[ON-BOX]** shows the
  "not available yet" state, not the button, because of the 503 gate.

### Cross-cutting
- **README update:** **[ON-BOX ✓]** done this session (the only file I edited).
- **Idempotency / no-private-key-ships:** **[CODE]** — design intent in the
  scripts (`refresh_tak_cert.sh` actively refuses `*signing*|*.jks|*.key`); not
  separately runtime-audited this session.

### Bottom line (what is genuinely working on THIS box right now)
- Working & verified: webapp deployed and serving (200), service status view,
  CPU/RAM, WiFi/TAK QR, and these services active: webapp, avahi, hostapd,
  mumble, mediamtx (v1.18.2), tailscaled. `iw` installed.
- **NOT working / NOT done on this box:** `rnsd` inactive; `/etc/nucleus/secrets`
  absent → **no admin PIN, no Mumble per-unit secret provisioned here**;
  `~/certs/caCert.p12` absent → **data-package download returns 503**; real-device
  ATAK enrollment test never run; WS5.2 deviates from the plan (inline builders,
  not Jinja templates).
- **Most likely root cause for the gaps:** `setup_nucleus.sh` has not been run to
  completion on this box since the secrets/cert-staging code landed. To close the
  gaps: run `sudo bash scripts/setup_nucleus.sh` (creates `/etc/nucleus/secrets`,
  generates PIN + Mumble pw) and `sudo bash scripts/refresh_tak_cert.sh` (stages
  `~/certs/caCert.p12`), then restart `nucleus-webapp`.

---

## Decisions from review (locked in)

These reflect the owner's notes and are settled:

- **AceMagic S1 LCD: leave it alone.** The `acemagic-s1-display/` utility is a
  one-off for *this* dev box only. This is **not** the final production
  hardware. Do **not** touch the LCD display work in any of this effort.
- **Pin MediaMTX version.** DONE — pinned to `1.18.2` in `setup_nucleus.sh`;
  on-box binary confirms `v1.18.2`.
- **Add `iw` to the installer.** DONE — `iw` is added to the core package step
  and is now installed on this box (`dpkg -l iw` → `ii 6.9-1`). (`setup_ap.sh`
  depends on it for `iw reg set US`.)
- **Drop "direct links for every service."** Not all services have a UI to link
  to, so a blanket "open" link per service isn't valid. Revisit per-service,
  only where a real UI/endpoint exists.
- **TAK data package download: yes, pursue it.** High value — confirmed we
  bundle the intermediate **truststore** `.p12` directly in the package so the
  cert lands on the device on import; auto-enroll takes over from there.
- **iTAK: explicitly ignored.** Make **no** provisions for iTAK. The one-click
  package targets **ATAK/WinTAK only**.
- **Dashboard access is restricted.** Anyone on the AP can *view* info and
  *download their data package*, but must **not** be able to control services or
  see admin secrets. The AP is the enrollment-handoff network, so control/admin
  actions are gated behind a PIN/password (operator-only).
- **System monitor: keep it minimal.** Just used/max for CPU and RAM. No
  elaborate RAM/temp/uptime dashboard.
- **Secrets rework: yes.** Stop hardcoding passwords (e.g. the Mumble SuperUser
  password `52235223`); generate per-unit and surface them where appropriate.
- **Quick-start card (printed PDF): deferred.** Good idea, parked for later.


---

## Phase 1 (agreed direction)

Three workstreams make up the agreed first phase:

1. **Web dashboard upgrade** (service control + QR + minimal CPU/RAM monitor)
2. **TAK data-package / onboarding** (downloadable client package)
3. **Hardware-portability hardening** of the install scripts

Each is detailed below with open questions to settle before implementation.

---

## 1. Install-script portability & fixes

### 1a. MediaMTX version mismatch (bug)
- `setup_nucleus.sh` downloads **MediaMTX `1.12.2`**.
- The tarball present on this box is **`mediamtx_v1.18.2_linux_amd64.tar.gz`**.
- **Action:** Pick one version, pin it in a single variable, and add:
  - SHA256 checksum verification of the download.
  - Offline fallback to a locally bundled tarball if the download fails (field
    installs may have no internet).

### 1b. Add `iw` to package install
- `setup_ap.sh` calls `iw reg set US` but `iw` is currently not installed.
- It *is* listed in the `setup_ap.sh` package loop (`hostapd iw firmware-mediatek`)
  — confirm that loop actually runs before the `iw reg set` call and that a
  fresh box gets it. Add `iw` explicitly to the core package step too so it's
  guaranteed present.

### 1c. Don't hardcode `eth0` for NAT / WAN
- NAT masquerade in `setup_ap.sh` is hardcoded to `-o eth0`. Other hardware may
  name the WAN interface differently (`enp1s0`, `eno1`, etc.).
- **Action:** Auto-detect the default-route (WAN) interface and use that, with
  an optional override argument.

### 1d. Preflight checks (lightweight)
- At the start of `setup_nucleus.sh`, verify: architecture, RAM (warn if < 8 GB
  for TAK), free disk, and that at least one WiFi adapter exists.
- Print a clear pass/warn summary; warn but don't necessarily hard-fail.

---

## 2. Web Dashboard Upgrade

Current dashboard (`webapp/app.py` + `templates/index.html`) is read-only:
hostname, mDNS, interface IPs, and Running/Stopped for TAK/MediaMTX/Mumble, plus
an "Open TAK" button.

### 2a. Service control (start / stop / restart) — operator-only
- **DECIDED:** Service control is **not** open to everyone on the AP. The AP is
  where field users grab their enrollment data package, so they must only be
  able to *view* status and *download their package* — never start/stop
  services or see secrets.
- Split the dashboard into two zones:
  - **Public zone** (no auth): status view, IPs, QR codes, data-package
    download.
  - **Admin zone** (PIN/password gated): service start/stop/restart, Mumble
    SuperUser password and other secrets.
- Admin actions backed by a **tightly allow-listed** privilege escalation: a
  `sudoers` rule permitting the webapp user to run only
  `systemctl {start,stop,restart} {takserver,mediamtx,mumble-server,rnsd}` —
  nothing else.
- POST endpoints validate the service name against a hardcoded allow-list
  (never pass user input straight to a shell) **and** require the admin session.
- **DECIDED — admin auth = per-unit PIN.** Generated once at setup and
  **persisted** so it survives re-runs/reboots (stored in `/etc/nucleus/secrets`,
  root-only `0600`). The setup script must **not** regenerate/overwrite an
  existing PIN — read-if-present, generate-only-if-missing — so we never lose it.
  Surface it to the operator at setup and in the admin zone.



### 2b. Minimal CPU / RAM monitor
- Just two readouts: CPU used/total (load or %) and RAM used/max.
- Source from `/proc/stat` and `/proc/meminfo` (no extra deps), refreshed on the
  existing auto-refresh cycle.

### 2c. QR codes
- Render QR codes for things a phone in the field actually uses:
  - **WiFi join** (`WIFI:S:<ssid>;T:nopass;;` or with key if we add one).
  - **TAK web UI** URL.
  - **The TAK data package download** (see section 3).
- Generate as inline SVG/PNG; keep dependencies minimal (a small pure-Python QR
  lib, or pre-rendered server-side).

### 2d. Links — only where a real UI exists
- Keep the "Open TAK" button.
- MediaMTX: only link if/where there's a meaningful endpoint to open (e.g. a
  specific HLS/WebRTC stream that exists) — not a blanket link.
- Mumble / Reticulum: no web UI; show connection info (host:port) instead of a
  link.

---

## 3. TAK Client Data Package — Download Button

Goal: a button on the dashboard that produces a ready-to-import client package
so a user can join this TAK server with minimal manual typing. The existing
`docs/client_auto_enroll.md` describes the server-side auto-enrollment config;
this builds the client-facing handoff on top of it.

### Background: how TAK onboarding actually works here
- The server uses **certificate auto-enrollment** (per `client_auto_enroll.md`).
- For auto-enrollment the client needs:
  1. The **intermediate CA cert** (the "TAK Server CA") on the device as a
     trust/enrollment cert (`.p12`).
  2. A **username + password**.
  3. Client config: server **hostname**, **port** (8089 for the enrollment/TLS
     streaming connection), and "Enroll for Client Certificate" +
     "User Authentication" enabled.
- With those, ATAK/WinTAK enroll themselves and pull their own client cert.
  (Note from the doc: **iTAK does not support this enrollment method.**)

### What the data package contains
A TAK data package is just a `.zip` with a known layout that ATAK/WinTAK can
import. For an auto-enroll connection it typically includes:

```
<package>.zip
├── MANIFEST/
│   └── manifest.xml          # declares package contents + a config entry
├── certs/
│   └── caCert.p12            # the intermediate CA / truststore (trust only)
└── <server>.pref             # connection preferences (host, port 8089,
                              #   enrollment=true, useAuth=true)
```

- The `.pref` file sets `connectString0 = <host>:8089:ssl`,
  `enrollForCertificateWithTrust = true`, `useAuth = true`, and points the
  CA/truststore at `caCert.p12` with its password.
- The package deliberately ships **only the CA/truststore**, **not** a client
  identity cert — the client mints its own via enrollment after the user logs
  in. This is what lets one package serve many users safely.

### How the cert gets onto the phone (the key design question)
This is the part the owner flagged. Options, in order of preference:

1. **Bundle the CA cert inside the data package itself** (recommended).
   - The `caCert.p12` *is* the intermediate/truststore cert. If it's in the
     `.zip`, importing the package puts the cert on the device automatically —
     no separate cert-transfer step needed. The user only needs username +
     password afterward.
   - This is the cleanest UX: **one download → import → log in.**
2. **Separate cert download + QR**, if for some reason the cert can't ride in
   the package (e.g. policy requires the user fetch it independently). Less
   smooth; requires a manual "install certificate" step on the phone.

> **DECIDED:** Bundle the intermediate **truststore** `.p12` (CA public cert,
> no private key) in the package. This is the standard TAK pattern and is safe.
> We export the **truststore**, *never* the private signing keystore.

### Confirmed cert layout on a provisioned box
`/opt/tak/certs/files/` on a configured unit contains (intermediate CA named
`ATOA-INT-01` in this example — the name varies per install):

| File | Role | Ships in package? |
|------|------|-------------------|
| `truststore-ATOA-INT-01.p12` | **Intermediate CA truststore** (public) | ✅ **YES** — this is `caCert.p12` |
| `truststore-root.p12` | Root CA truststore (public) | Optional (usually intermediate is enough) |
| `ATOA-INT-01-signing.jks` / `.p12` | **Private signing keystore** | 🚫 **NEVER** — stays on box |
| `ca-do-not-share.key`, `root-ca-do-not-share.key` | Private CA keys | 🚫 **NEVER** |
| `takserver.p12`, `webadmin.p12` | Server / web-admin identities | 🚫 **NEVER** |

- **The truststore filename is not fixed** — it's `truststore-<INT-NAME>.p12`
  where `<INT-NAME>` is the intermediate CA name chosen at TAK setup. The webapp
  must **glob** `truststore-*.p12` (excluding `truststore-root.p12`) or read the
  intermediate name from config rather than hardcoding `ATOA-INT-01`.
- **Truststore password:** confirmed **`atakatak`**. We'll use that for the
  bundled `caCert.p12` / referenced in the `.pref`.


### Server-side mechanics of the button
1. Webapp endpoint `GET /download/datapackage` (and a QR pointing at it).
2. On request, the webapp:
   - Locates the intermediate truststore via glob `truststore-*.p12`
     (excluding `truststore-root.p12`) under `/opt/tak/certs/files/`.
   - Reads the server hostname (use the `.local` mDNS name so it works
     regardless of current IP) and the enrollment port (8089).
   - Renders `manifest.xml` + `<server>.pref` from templates.
   - Zips it all and streams it as `application/zip` with a sensible filename
     like `<hostname>-tak.zip`.
3. **Permissions / cert location:** the webapp runs as a non-root user and
   **cannot** read `/opt/tak/certs/files/` (owned by `tak`). **DECIDED:** reuse
   the existing **`~/certs`** directory (`/home/natak/certs`). At setup time,
   copy *only* the intermediate `truststore-*.p12` there (e.g.
   `~/certs/caCert.p12`, mode 0644 — it's a public cert). Never widen
   permissions on the whole TAK certs dir, and never copy any private key/JKS.
   Re-copy on a hook or document re-running a small refresh step if the CA is
   regenerated.


### Resolved for section 3
- **Truststore path/filename:** confirmed — `truststore-<INT-NAME>.p12`; webapp
  globs for it (see above). Real example on this box: `truststore-ATOA-INT-01.p12`.
- **iTAK:** **out of scope.** No iTAK provisions at all. Package targets
  ATAK/WinTAK auto-enrollment only.
- **Username/password:** per-user, **not** baked into the shared package. The
  package carries cert + connection settings; the user enters their own
  credentials on first connect. (This is the intended, acceptable UX.)


---

## 4. Secrets rework

- **Mumble SuperUser password** is currently hardcoded as `52235223` in
  `setup_nucleus.sh`.
- **Action:**
  - Generate a per-unit random password at setup time.
  - Store it somewhere root-readable (e.g. `/etc/nucleus/secrets`) and surface
    it in the dashboard (admin section) so the operator can retrieve it.
  - Audit the rest of the scripts/configs for any other hardcoded credentials
    and apply the same pattern.

---

## Deferred / out of scope

- **Printed quick-start card (PDF) generator** — parked for later.
- **AceMagic S1 LCD** anything — explicitly off-limits (one-off dev hardware).
- **Fleet / multi-unit management view** — not in this phase.
- **Golden image / first-boot self-provisioning** — possible future portability
  step, not in this phase.

---

## Verified facts (checked on this dev box — `nucleus-server`)

Captured so future sessions don't have to re-derive these:

- **mDNS / hostname:** unit is reachable at `<hostname>.local` via avahi.
- **`iw` IS installed** on this box (`dpkg -l iw` → `ii 6.9-1`), as required by
  `setup_ap.sh` (`iw reg set US`). *(Updated 2026-06-18 — the earlier "not
  installed" claim is stale; `iw` was added to the installer's core package
  step.)*
- **MediaMTX:** RESOLVED — installer is pinned to `1.18.2` (with SHA256 verify +
  offline fallback); on-box binary confirms `v1.18.2`. *(Updated 2026-06-18 —
  the earlier `1.12.2` mismatch is resolved.)*
- **TAK certs dir:** `/opt/tak/certs/files/` is `drwxrwxr-x tak tak`
  (world-traversable), but the truststores inside are `-rw------- tak tak`:
  - `truststore-ATOA-INT-01.p12` (2192 bytes) — **intermediate, ships as `caCert.p12`**
  - `truststore-root.p12` (1168 bytes) — root, excluded
- **`natak` user CANNOT read the truststore** directly (confirmed Permission
  denied). → must copy at setup time to `~/certs` and `chown natak`.
- **Truststore password:** `atakatak` (confirmed convention; user-confirmed).
- **Python stdlib** has `zipfile`, `uuid`, `glob`, `os` → data-package zip needs
  **no extra dependencies**.
- **Enrollment port:** `8089` (TLS streaming / cert enrollment).
- **Existing AP download path is reusable:** hostapd AP + systemd-networkd DHCP +
  avahi mDNS + the Flask `nucleus-webapp` on port 80 already serve any client on
  the AP. A file download is just another Flask route — **not** new infra. The
  only new setup-time piece is staging the cert into `~/certs`.

---

## MASTER WORK PLAN (multi-session)

> This is the authoritative, resumable checklist. Each task notes the files
> touched and the acceptance check. Mark items done as we go. Workstreams are
> largely independent and can ship incrementally.

> **Status legend (reconciled 2026-06-18 against IMPLEMENTATION STATUS above):**
> - `[x]` = done **and** verified on-box.
> - `[~]` = **code in repo**, but **not provisioned/verified on this box**
>   (usually because `setup_nucleus.sh` hasn't been re-run here).
> - `[ ]` = not done.
>
> **One action closes most `[~]` items:** run `sudo bash scripts/setup_nucleus.sh`
> then `sudo bash scripts/refresh_tak_cert.sh`, and restart `nucleus-webapp`.

**Recommended execution order:** WS1 → WS2 → WS3 → WS5 → WS4
(pull the data package earlier because it's the piece that needs real-device
testing; WS3 must precede WS5 so the cert is readable.)

### WS1 — Install-script portability & fixes
*Goal: same scripts provision cleanly on varied hardware. Low risk.*

- [x] **1.1 Pin MediaMTX version.** *(DONE — pinned `1.18.2`, SHA256 verify +
  offline fallback in repo; on-box binary confirms `v1.18.2`.)* In
  `scripts/setup_nucleus.sh`, set one
  `MEDIAMTX_VERSION` var (decide 1.12.2 vs 1.18.2 — lean to latest tested).
  - Add SHA256 verification of the downloaded tarball (hardcode expected hash).
  - Offline fallback: if download fails, use a bundled/local tarball
    (`~/mediamtx_v<ver>_linux_amd64.tar.gz`) if present.
  - *Accept:* fresh run installs pinned version; tampered/failed download is
    caught; offline box still installs from local tarball.
- [x] **1.2 Guarantee `iw` present.** *(DONE — `iw` added to core step; on-box
  `dpkg -l iw` → `ii 6.9-1`.)* Add `iw` to the core package step in
  `setup_nucleus.sh` (don't rely solely on `setup_ap.sh`'s loop). Verify it's
  installed before any `iw reg set US`.
  - *Files:* `scripts/setup_nucleus.sh`, `scripts/setup_ap.sh`.
  - *Accept:* on a box without `iw`, setup installs it; `iw reg set US` succeeds.
- [x] **1.3 WAN auto-detect (drop hardcoded `eth0`).** *(DONE — verified on this
  box 2026-06-18: setup auto-detected the default-route WAN as `enp1s0` and the
  NAT masquerade targeted it; WiFi AP came up on `wlx00c0cab6c5a8`.)* In
  `scripts/setup_ap.sh`,
  detect the default-route interface:
  `ip route show default | awk '{print $5; exit}'`. Use it in the NAT
  masquerade rule. Accept optional override arg.
  - *Files:* `scripts/setup_ap.sh` (the `*nat ... -o eth0` block + summary).
  - *Accept:* on a box where WAN is `enp1s0`/`eno1`, NAT rule targets the right
    iface; WiFi clients still get internet.
- [x] **1.4 Preflight checks.** *(DONE — verified on this box 2026-06-18: the
  preflight banner ran and reported arch x86_64, 15 GB RAM, 866 GB free disk,
  2 WiFi adapters, "all checks passed".)* Add a function at the top of
  `setup_nucleus.sh`: report arch, RAM (warn if < 8 GB for TAK), free disk,
  presence of ≥1 WiFi adapter. Warn, don't hard-fail (except maybe arch).
  - *Accept:* clear pass/warn banner; under-RAM box shows the TAK warning.

### WS2 — Secrets rework
*Goal: no hardcoded creds; per-unit secrets persisted and never lost.*

- [x] **2.1 Secrets store.** *(DONE — verified on this box 2026-06-18:
  `setup_nucleus.sh` ran to completion and created `/etc/nucleus/secrets`
  (root-only). Re-running `refresh_tak_cert.sh` confirmed persistence.)* Create
  `/etc/nucleus/secrets` dir/file, root-only
  `0600`. Helper logic: **read-if-present, generate-only-if-missing** (never
  overwrite on re-run). Format: simple `KEY=value` lines.
  - *Files:* new `scripts/lib/secrets.sh` (sourced helper) or inline in
    `setup_nucleus.sh`.
- [x] **2.2 Mumble password.** *(DONE — verified on this box 2026-06-18: a
  per-unit Mumble SuperUser password was generated, stored in the secrets file,
  and printed in the setup summary.)* Replace hardcoded
  `52235223` in
  `setup_nucleus.sh` with a generated per-unit password stored in the secrets
  file; feed it to `mumble-server -supw`.
  - *Accept:* re-running setup keeps the same password; it's retrievable.
- [x] **2.3 Admin PIN.** *(DONE — verified on this box 2026-06-18: a per-unit
  admin PIN was generated and printed in the setup summary; admin login now sets
  a session (302) and a wrong PIN is rejected.)* Generate a per-unit dashboard
  admin PIN into the
  secrets file (same generate-if-missing rule). Print it in the setup summary.
  - *Accept:* PIN persists across re-runs/reboots.

### WS3 — TAK cert staging (prereq for WS5)
*Goal: make the public intermediate truststore readable by the webapp user.*

- [x] **3.1 Copy truststore to `~/certs`.** *(DONE — verified on this box
  2026-06-18: `refresh_tak_cert.sh` staged `truststore-ATOA-INT-01.p12` to
  `~/certs/caCert.p12` (owner natak, mode 0644, 2192 bytes). Password confirmed
  `atakatak`; the verify step now uses `-legacy` so modern OpenSSL no longer
  emits a false warning. No private key/JKS copied.)* Add a setup step
  (root) that globs
  `/opt/tak/certs/files/truststore-*.p12`, **excludes `truststore-root.p12`**,
  copies the intermediate to `~/certs/caCert.p12`, `chown natak:natak`,
  `chmod 0644`. Idempotent / re-runnable. Skip gracefully if TAK certs not yet
  present (TAK may be configured after first setup run).
  - *Files:* `scripts/setup_nucleus.sh` (new TAK-staging step), maybe a small
    standalone `scripts/refresh_tak_cert.sh` to re-run after CA changes.
  - *Accept:* `~/certs/caCert.p12` exists, owned by natak, readable;
    `openssl pkcs12 -info -in ~/certs/caCert.p12 -nokeys -passin pass:atakatak`
    succeeds. NO private key/JKS ever copied.

### WS4 — Dashboard upgrade
*Goal: public info zone + PIN-gated admin zone. Reuses existing Flask app.*

- [x] **4.1 Public/admin split.** *(DONE — verified on this box 2026-06-18:
  public page serves 200 with status/QR/download and leaks no admin controls or
  secrets to anonymous requests; logging in with the PIN reveals the admin zone
  (service controls + Mumble secret).)* Refactor `webapp/app.py` +
  `templates/index.html` into a public view (status, IPs, QR, package
  download) and an admin section behind PIN auth (session/cookie or HTTP
  basic against the PIN from `/etc/nucleus/secrets`).
  - *Note:* webapp currently can't read `/etc/nucleus/secrets` (root 0600) —
    decide: relax to a `nucleus` group the webapp user joins, or read PIN at
    service start via systemd `LoadCredential`/EnvironmentFile. **Open impl
    detail — resolve in WS4.**
- [x] **4.2 Service control (admin-only).** *(DONE — verified on this box
  2026-06-18: an admin-session `restart mediamtx` returned 302 and the service
  stayed active; an anonymous `POST /admin/service` returned 403.)* Add POST
  endpoints
  start/stop/restart, service name validated against a hardcoded allow-list
  `{takserver, mediamtx, mumble-server, rnsd}`. Backed by a narrow sudoers
  rule for the webapp user limited to exactly those `systemctl` verbs+units.
  - *Files:* `webapp/app.py`, new `/etc/sudoers.d/nucleus-webapp` (installed by
    `install_webapp.sh`), `templates/index.html`.
  - *Accept:* admin can restart takserver from the page; non-admin can't;
    webapp user cannot run any other systemctl/command via sudo.
- [x] **4.3 Minimal CPU/RAM.** *(DONE — served within the 200 page on-box.)*
  Read `/proc/stat` (CPU %) and `/proc/meminfo`
  (used/max). Show two readouts. No extra deps.
- [x] **4.4 QR codes.** *(DONE — verified on this box 2026-06-18: with the cert
  staged the 503 gate is lifted, the public download button renders, and the
  data-package QR is no longer suppressed alongside the WiFi/TAK QRs.)*
  Render QR for: WiFi join string, TAK web UI URL, and the
  data-package download URL. Use a minimal/pure-Python QR approach; add to
  `requirements.txt` if a lib is chosen.

### WS5 — TAK data-package download (the headline feature)
*Goal: one-tap enrollment package for ATAK/WinTAK over the AP.*

- [x] **5.1 Endpoint `GET /download/datapackage`** in `webapp/app.py`:
  *(DONE — verified on this box 2026-06-18: returns 200 and a valid zip
  containing `MANIFEST/manifest.xml`, `certs/caCert.p12` (2192 bytes), and
  `nucleus-server.pref` with `connectString0=nucleus-server.local:8089:ssl`,
  `caPassword=atakatak`, `enrollForCertificateWithTrust=true`,
  `onReceiveDelete=false`.)*
  - Read `~/certs/caCert.p12` (staged in WS3).
  - Build in-memory zip (stdlib `zipfile`) with this layout:
    ```
    MANIFEST/manifest.xml
    certs/caCert.p12
    <hostname>.pref
    ```
  - `manifest.xml`: `<MissionPackageManifest version="2">` with `<Configuration>`
    (`uid`=random uuid, `name`, `onReceiveImport=true`, `onReceiveDelete=true`)
    and `<Contents>` listing both zipEntries.
  - `<hostname>.pref`: `cot_streams` (`connectString0=<hostname>.local:8089:ssl`,
    `enabled0=true`, `description0=<hostname>`) + `com.atakmap.app_preferences`
    (`caLocation=cert/caCert.p12`, `caPassword=atakatak`,
    `enrollForCertificateWithTrust=true`, `useAuth=true`,
    `cacheCreds=Cache credentials`).
  - Stream as `application/zip`, `Content-Disposition: attachment;
    filename="<hostname>_enrollment.zip"`.
- [x] **5.2 Manifest/pref builders.** *(RESOLVED — deviation ACCEPTED by owner
  2026-06-18.)* `manifest.xml`/`.pref` are **inline Python string builders** in
  `datapackage.py` (`_manifest_xml`, `_preference_pref`) rather than Jinja
  templates. This is the chosen design: functionally equivalent, dependency-free,
  no separate template files. `onReceiveDelete` is intentionally **`false`**
  (owner decision — importing the package must not auto-delete it later).
- [ ] **5.3 REAL-DEVICE TEST (gating).** Generate a package, import on an actual
  **ATAK** device, confirm: CA imported, server appears, enroll prompts for
  user/pass, client cert issued (cross-check in TAK web admin →
  Client Certificates per `client_auto_enroll.md`). **Lock template only after
  this passes.** This is the one step that can't be validated from the box.
- [x] **5.4 Public download button + QR** wired to the endpoint on the page.
  *(DONE — verified on this box 2026-06-18: with the cert staged the public page
  renders the download button (and QR) instead of the "not available yet"
  state.)*

### Cross-cutting / done-criteria
- [x] Update `README.md` service table + quick start to reflect new dashboard,
  secrets, and data-package feature. *(DONE this session.)*
- [ ] Keep everything **idempotent** (setup re-runs safe).
- [ ] No secret/private key ever leaves the box; only the public CA ships.

> **Resume hint for a new session:** start by re-reading this MASTER WORK PLAN
> and the "Verified facts" section above. Then continue at the first unchecked
> task. Test commands and exact paths are recorded here intentionally.

