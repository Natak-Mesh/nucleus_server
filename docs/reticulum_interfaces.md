# Reticulum Interfaces — Manual Additions

These are interface definitions to add **by hand** to the Reticulum config at:

```
~/.reticulum/config        (on this appliance: /home/natak/.reticulum/config)
```

Add them under the existing `[interfaces]` section, then restart the daemon:

```
sudo systemctl restart rnsd
```

> Note: indentation matters in Reticulum's config (it uses configobj). Each
> nested level is indented further, exactly as shown below.

---

## Natak Public (TCP client)

Outbound TCP connection to the Natak public transport node.

- Type: `TCPClientInterface`
- Target host: `173.230.150.24`
- Target port: `4243`

Paste this block inside `[interfaces]`:

```ini
  [[Natak Public]]
    type = TCPClientInterface
    enabled = Yes
    target_host = 173.230.150.24
    target_port = 4243
```

After adding, restart and confirm it comes up:

```
sudo systemctl restart rnsd
rnstatus
```
