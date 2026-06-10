# TAK Server 5.7 Build Guide — Debian Trixie

Derived from [MyTecknet](https://mytecknet.com/lets-build-a-tak-server/).
`<ANGLE-BRACKETS>` = values you supply. Don't paste them blindly.

---

## 1. Prerequisites

```bash
echo -e "Package: *\nPin: release n=bookworm\nPin-Priority: 100" | sudo tee /etc/apt/preferences.d/bookworm
echo "deb http://deb.debian.org/debian bookworm main" | sudo tee /etc/apt/sources.list.d/bookworm.list
sudo apt update
sudo apt install -y postgresql-15 postgresql-client-15 postgresql-15-postgis-3
sudo apt install -y openjdk-17-jdk openjdk-17-jre
echo -e "*      soft      nofile      32768\n*      hard      nofile      32768\n" | sudo tee --append /etc/security/limits.conf
```

```bash
java -version          # openjdk 17.x
pg_lsclusters          # 15 main cluster, online
```

Install TAK Server:

```bash
sudo apt install ./takserver_5.7-RELEASE32_all.deb   # use your actual filename
```

---

## 2. Certificate metadata

```bash
sudo su tak
cd /opt/tak/certs
nano cert-metadata.sh
```

Edit: `COUNTRY`, `STATE`, `CITY`, `ORGANIZATION`, `ORGANIZATIONAL_UNIT`.
Quote values with spaces (e.g. `CITY="New York City"`).

---

## 3. Build the PKI

CA common names cannot contain spaces.

```bash
./makeRootCa.sh --ca-name <ROOT-CA-NAME>
./makeCert.sh ca <INTERMEDIATE-CA-NAME>        # answer Y to move files
./makeCert.sh server takserver
```

---

## 4. CoreConfig — point truststore at your intermediate CA

```bash
sed -i 's/truststore-root/truststore-<INTERMEDIATE-CA-NAME>/g' /opt/tak/CoreConfig.example.xml
grep truststore- /opt/tak/CoreConfig.example.xml
```

---

## 5. Start the server

```bash
exit                                      # leave tak user
sudo systemctl enable takserver.service
sudo systemctl start takserver.service
tail -f /opt/tak/logs/takserver-messaging.log
```

Look for: `Started Netty Server ... on Port 8089`, `Server started`, `TAK Server version`.

---

## 6. Admin certificate

```bash
sudo su tak
cd /opt/tak/certs
./makeCert.sh client webadmin
java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/webadmin.pem
java -jar /opt/tak/utils/UserManager.jar certmod -g <GROUP> /opt/tak/certs/files/webadmin.pem
exit
```

---

## 7. Export admin cert

```bash
sudo cp -v /opt/tak/certs/files/webadmin.p12 ~/
sudo chown <USER>:<USER> ~/webadmin.p12
```

---

## 8. Create client certificates

Repeat for each client:

```bash
sudo su tak
cd /opt/tak/certs
./makeCert.sh client <CLIENT-NAME>
java -jar /opt/tak/utils/UserManager.jar certmod -g <GROUP> /opt/tak/certs/files/<CLIENT-NAME>.pem
exit
```

Export the client `.p12` and the truststore:

```bash
sudo cp -v /opt/tak/certs/files/<CLIENT-NAME>.p12 ~/
sudo cp -v /opt/tak/certs/files/truststore-<INTERMEDIATE-CA-NAME>.p12 ~/
sudo chown <USER>:<USER> ~/<CLIENT-NAME>.p12 ~/truststore-<INTERMEDIATE-CA-NAME>.p12
```

Client needs both files: truststore (Install Certificate Authority) + client `.p12` (Install Client Certificate). Connect on port 8089.

---

## 9. Firewall (UFW)

### TAK Server

| Port | Service |
|------|---------|
| 8089/tcp | Client connect (TLS) |
| 8090/udp | QUIC |
| 8443/tcp | Web UI / WebTAK / API |
| 8446/tcp | Cert enrollment / WebTAK login |
| 8444/tcp | Federation (legacy) |
| 9000/tcp | Federation v1 |
| 9001/tcp | Federation v2 |

### MediaMTX

| Port | Service |
|------|---------|
| 8554/tcp | RTSP |
| 8000/udp | RTP |
| 8001/udp | RTCP |
| 1935/tcp | RTMP |
| 8888/tcp | HLS |
| 8889/tcp | WebRTC |
| 8189/udp | WebRTC ICE |
| 8890/udp | SRT |

### Mumble

| Port | Service |
|------|---------|
| 64738/tcp | Control |
| 64738/udp | Voice |

### Other

| Port | Service |
|------|---------|
| 22/tcp | SSH |
| 80/tcp | Info web app |
| 67/udp | DHCP (AP interface only) |

### Commands

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH
sudo ufw allow ssh

# TAK Server
sudo ufw allow 8089/tcp
sudo ufw allow 8090/udp
sudo ufw allow 8443/tcp
sudo ufw allow 8446/tcp
sudo ufw allow 8444/tcp
sudo ufw allow 9000/tcp
sudo ufw allow 9001/tcp

# MediaMTX
sudo ufw allow 8554/tcp
sudo ufw allow 8000/udp
sudo ufw allow 8001/udp
sudo ufw allow 1935/tcp
sudo ufw allow 8888/tcp
sudo ufw allow 8889/tcp
sudo ufw allow 8189/udp
sudo ufw allow 8890/udp

# Mumble
sudo ufw allow 64738/tcp
sudo ufw allow 64738/udp

# Info web app
sudo ufw allow 80/tcp

# WiFi AP DHCP (scope to AP interface only)
sudo ufw allow in on wlx00c0cab6c5a8 to any port 67 proto udp

# Allow forwarded packets from WiFi AP clients
sudo ufw route allow in on wlan0

# Tailscale (if used)
sudo ufw allow in on tailscale0

sudo ufw enable
```

### Mumble SuperUser password

Default: `52235223`. Change with:

```bash
sudo mumble-server -supw <NEW-PASSWORD>
```

---

## Client connection

Connect ATAK/WinTAK on **port 8089** (SSL). Use the server's ethernet IP, AP IP (`10.30.1.1`), or Tailscale IP depending on how the client reaches the server. Do **not** use port 8446.
