# AceMagic S1 Front Display — Custom Logo

Small, self-contained utility for pushing a custom logo/image to the built-in
front LCD on an **AceMagic S1** mini PC.

Protocol verified by reading the community project
`tjaworski/AceMagic-S1-LED-TFT-Linux` (the `s1panel` component, GPL-3), cloned
into `vendor/` for reference.

## Hardware notes (this machine) — VERIFIED

- The front **LCD** is the **Holtek `04d9:fd01`** device, on **USB interface 01**
  (the repo's `config.json` uses `"device": "1-8:1.1"` = interface 01).
- On this machine interface 01 has **no kernel driver** and **no `/dev/hidraw`
  node**, so we drive it directly via **libusb** (pyusb), writing to the
  **interrupt OUT endpoint `0x02`**.
- Canvas is **320×170, RGB565** (big-endian 16-bit/pixel). A full redraw is sent
  as **27 chunks** with a `0x55 0xA3` header.
- IMPORTANT: the **CH340 at `/dev/ttyUSB0` is the RGB LED strip, NOT the screen.**
  (An early attempt sent image data there and nothing happened — wrong device.)

## Layout

```
acemagic-s1-display/
  README.md               <- this file
  send_logo.py            <- USB/libusb image sender (pyusb + Pillow)
  prepare_logos.py        <- resize/letterbox source logos to 320x170
  99-acemagic-s1-lcd.rules<- udev rule for non-root access (optional)
  .gitignore              <- ignores .venv/, prepared/, vendor/
  .venv/                  <- local Python virtualenv (git-ignored)
  prepared/               <- logos resized to 320x170 (git-ignored)
  vendor/                 <- cloned community repos for reference (git-ignored)
```

## Setup

```bash
cd nucleus_server/acemagic-s1-display
python3 -m venv .venv

.venv/bin/pip install --upgrade pip
.venv/bin/pip install pyusb Pillow
```

## Permissions

The LCD is a raw USB device, so by default only root can claim it. Either run
`send_logo.py` with `sudo`, or install the udev rule for passwordless access:

```bash
sudo cp 99-acemagic-s1-lcd.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
# unplug/replug not needed; the rule sets group=plugdev (you are in plugdev)
```

## Usage

`send_logo.py` takes any image, fits it to the panel (aspect-correct by
default), optionally rotates it, and streams it over USB. It can hold the
image with `--watch` (see "Why --watch" below).

```bash
# Send a logo, upright, on the portrait-mounted panel, and keep it shown:
sudo .venv/bin/python send_logo.py \
    /home/natak/Documents/images/NatakMeshvertical-overlay.png \
    --portrait --rotate 270 --watch
```

Flags:
- `--portrait` / `--landscape`  set panel orientation before drawing
- `--rotate {0,90,180,270}`     rotate image clockwise to match how the panel
                                is physically mounted (see note below)
- `--stretch`                   fill the panel (default preserves aspect ratio
                                with letterbox padding)
- `--watch`                     redraw in a loop so the firmware's stats screen
                                does not take back over (Ctrl-C to stop)
- `--interval SECONDS`          redraw period in `--watch` mode (default 1.0)

### Orientation / rotation note (this unit)

On THIS machine the panel is mounted such that, in `--portrait` mode, an
upright tall logo needs **`--rotate 270`**. Other S1 units may differ — if the
image is sideways try 90, and if it is upside-down try 180. `prepare_logos.py`
is optional; `send_logo.py` handles fitting/rotation directly from the source.

### Why --watch

The panel's firmware draws its own stats screen by default. A single image is
shown briefly and then the firmware takes back over. `--watch` keeps redrawing
(plus a heartbeat) so your image stays up. To make it permanent across reboots,
wrap it in a small systemd service that runs the `--watch` command.

## Sharing / other S1 owners

This directory is a self-contained git repo. The `.gitignore` excludes only the
local Python venv (`.venv/`), generated images (`prepared/`), and the cloned
reference repos (`vendor/`). Everything needed to reproduce is tracked:
`send_logo.py`, `prepare_logos.py`, the udev rule, and this README.

> Hardware this was verified on: **AceMagic S1** mini PC, Intel Alder Lake-N,
> front LCD = Holtek `04d9:fd01` interface 01, 320×170 RGB565. Protocol adapted
> from `tjaworski/AceMagic-S1-LED-TFT-Linux` (GPL-3).

