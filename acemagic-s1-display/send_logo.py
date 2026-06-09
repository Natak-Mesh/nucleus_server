#!/usr/bin/env python3
"""
send_logo.py — push an image to the AceMagic S1 front LCD.

VERIFIED hardware/protocol (read from tjaworski/AceMagic-S1-LED-TFT-Linux,
the s1panel component, GPL-3):
    - The LCD is the Holtek device 04d9:fd01, **USB interface 01**.
      (The repo's config.json uses device "1-8:1.1" = interface 01.)
      On this machine interface 01 has no kernel driver / no /dev/hidraw node,
      so we talk to it directly via libusb and write to interrupt OUT
      endpoint 0x02 (64-byte packets).
    - NOTE: the CH340 at /dev/ttyUSB0 is the *LED strip*, NOT the screen.
    - Canvas: 320x170, pixel format RGB16_565 (big-endian 16-bit per pixel).
    - A full-screen redraw is sent as CHUNK_COUNT=27 packets. Each packet is
      REPORT(1) + HEADER(8) + up to DATA(4096) bytes:
          byte0: report id (0x00)
          byte1: 0x55                (LCD_SIGNATURE)
          byte2: 0xA3                (LCD_REDRAW)
          byte3: redraw phase 0xF0 start / 0xF1 continue / 0xF2 end
          byte4: sequence (1..27)
          byte5: 0
          byte6..7: uint16 offset into image (bytes)   [big-endian]
          byte8..9: uint16 chunk length (bytes)         [big-endian]
          then pixel data (RGB565, big-endian per pixel)
      The final chunk (index 26) carries FINAL_CHUNK_SIZE=2304 bytes.
        26*4096 + 2304 = 108800 = 320*170*2  (matches exactly)

Usage:
    .venv/bin/python send_logo.py prepared/NatakMeshlogomark.png
    sudo .venv/bin/python send_logo.py prepared/x.png        # if not root via udev
    .venv/bin/python send_logo.py prepared/x.png --portrait
"""
import argparse
import sys
import time

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow not installed. Run: .venv/bin/pip install Pillow")

try:
    import usb.core
    import usb.util
except ImportError:
    sys.exit("pyusb not installed. Run: .venv/bin/pip install pyusb")

# --- constants mirrored from lcd_device.js -------------------------------
VENDOR_ID = 0x04D9
PRODUCT_ID = 0xFD01
INTERFACE = 1            # interface 01 = the LCD
EP_OUT = 0x02           # interrupt OUT endpoint

WIDTH = 320
HEIGHT = 170

HEADER_SIZE = 8
DATA_SIZE = 4096
CHUNK_COUNT = 27
FINAL_CHUNK_INDEX = CHUNK_COUNT - 1
FINAL_CHUNK_SIZE = 2304

LCD_SIGNATURE = 0x55
LCD_CONFIG = 0xA1
LCD_REDRAW = 0xA3
LCD_ORIENTATION = 0xF1
LCD_LANDSCAPE = 0x01
LCD_PORTRAIT = 0x02
LCD_REDRAW_START = 0xF0
LCD_REDRAW_CONTINUE = 0xF1
LCD_REDRAW_END = 0xF2


def _letterbox(img, w, h, bg):
    """Fit img inside w x h preserving aspect ratio, padding with bg (RGB)."""
    img = img.convert("RGBA")
    sw, sh = img.size
    scale = min(w / sw, h / sh)
    nw, nh = max(1, round(sw * scale)), max(1, round(sh * scale))
    resized = img.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGB", (w, h), bg)
    tile = Image.new("RGBA", (nw, nh), bg + (255,))
    tile.alpha_composite(resized)
    canvas.paste(tile.convert("RGB"), ((w - nw) // 2, (h - nh) // 2))
    return canvas


def to_rgb565_be(img, rotate=0, stretch=False, bg=(0, 0, 0)):
    """Return a flat list of 16-bit RGB565 values for the 320x170 framebuffer.

    The framebuffer is 320x170 (landscape). When the panel is mounted portrait
    the firmware rotates it, so to show an upright portrait image we first
    compose into the UPRIGHT canvas (170x320 for rotate 90/270, else 320x170),
    preserving aspect ratio (letterbox) unless --stretch is given, then rotate
    that composition clockwise by `rotate` to land in the 320x170 framebuffer.
    """
    rgb = img.convert("RGB")

    # upright composition canvas depends on rotation
    if rotate in (90, 270):
        cw, ch = HEIGHT, WIDTH        # 170 x 320 (portrait)
    else:
        cw, ch = WIDTH, HEIGHT        # 320 x 170 (landscape)

    if stretch:
        composed = rgb.resize((cw, ch), Image.LANCZOS)
    else:
        composed = _letterbox(rgb, cw, ch, bg)

    if rotate:
        # PIL rotate() is counter-clockwise; negate for clockwise.
        composed = composed.rotate(-rotate, expand=True)

    if composed.size != (WIDTH, HEIGHT):
        composed = composed.resize((WIDTH, HEIGHT), Image.LANCZOS)

    px = composed.load()
    out = []
    for y in range(HEIGHT):
        for x in range(WIDTH):
            r, g, b = px[x, y]
            out.append(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3))
    return out  # len == 320*170 == 54400 pixels



def claim(dev):
    """Detach kernel driver if present and claim interface 01."""
    try:
        if dev.is_kernel_driver_active(INTERFACE):
            dev.detach_kernel_driver(INTERFACE)
    except (NotImplementedError, usb.core.USBError):
        pass
    usb.util.claim_interface(dev, INTERFACE)


def write_packet(dev, data):
    dev.write(EP_OUT, data, timeout=2000)


def set_orientation(dev, portrait):
    buf = bytearray(HEADER_SIZE)
    buf[0] = LCD_SIGNATURE
    buf[1] = LCD_CONFIG
    buf[2] = LCD_ORIENTATION
    buf[3] = LCD_PORTRAIT if portrait else LCD_LANDSCAPE
    write_packet(dev, bytes(buf))


LCD_SET_TIME = 0xF2


def heartbeat(dev):
    """Mirror lcd_device.js heartbeat (keeps the firmware from reverting)."""
    t = time.localtime()
    buf = bytearray(HEADER_SIZE)
    buf[0] = LCD_SIGNATURE
    buf[1] = LCD_CONFIG
    buf[2] = LCD_SET_TIME
    buf[3] = t.tm_hour
    buf[4] = t.tm_min
    buf[5] = t.tm_sec
    write_packet(dev, bytes(buf))



def redraw(dev, pixels):
    """Send a full-screen image. pixels = list of RGB565 ints (len 54400).

    IMPORTANT: lcd_device.js always transmits the full fixed-size buffer
    (BUFFER_SIZE == HEADER_SIZE + DATA_SIZE == 4104 bytes) for EVERY chunk,
    including the final one (it just sets a shorter logical length and leaves
    the rest of the buffer as-is). We replicate that exactly: every USB write
    is BUFFER_SIZE bytes, with the tail zero-padded on the final chunk.
    """
    for index in range(CHUNK_COUNT):
        if index == 0:
            phase = LCD_REDRAW_START
        elif index == FINAL_CHUNK_INDEX:
            phase = LCD_REDRAW_END
        else:
            phase = LCD_REDRAW_CONTINUE

        length = DATA_SIZE if index < FINAL_CHUNK_INDEX else FINAL_CHUNK_SIZE
        offset = index * DATA_SIZE

        # full fixed-size buffer, zero-padded
        buf = bytearray(HEADER_SIZE + DATA_SIZE)   # 4104 bytes, always
        buf[0] = LCD_SIGNATURE
        buf[1] = LCD_REDRAW
        buf[2] = phase
        buf[3] = 1 + index                          # sequence
        # buf[4] unused (0)
        buf[5] = (offset >> 8) & 0xFF               # uint16 offset, big-endian
        buf[6] = offset & 0xFF
        buf[7] = (length >> 8) & 0xFF               # uint16 length high byte
        # (low byte of length lives at buf[8], which is also the first pixel
        #  byte in the JS layout; for length 4096 -> 0x1000 low byte 0x00,
        #  for final 2304 -> 0x0900 low byte 0x00, so it is benignly 0 here)

        # pixel payload for this chunk (RGB565 big-endian) starting at byte 8
        pix_start = offset // 2
        pix_len = length // 2
        o = HEADER_SIZE
        for i in range(pix_len):
            v = pixels[pix_start + i]
            buf[o] = (v >> 8) & 0xFF
            buf[o + 1] = v & 0xFF
            o += 2

        write_packet(dev, bytes(buf))



def main():
    ap = argparse.ArgumentParser(description="Send an image to the AceMagic S1 LCD")
    ap.add_argument("image")
    ap.add_argument("--portrait", action="store_true",
                    help="set portrait orientation before drawing")
    ap.add_argument("--landscape", action="store_true",
                    help="set landscape orientation before drawing")
    ap.add_argument("--watch", action="store_true",
                    help="keep redrawing in a loop so the firmware's stats "
                         "screen does not take back over (Ctrl-C to stop)")
    ap.add_argument("--interval", type=float, default=1.0,
                    help="seconds between redraws in --watch mode (default 1.0)")
    ap.add_argument("--rotate", type=int, default=0, choices=[0, 90, 180, 270],
                    help="rotate image clockwise before sending. In portrait "
                         "mode the panel renders 90 CCW, so use --rotate 90.")
    ap.add_argument("--stretch", action="store_true",
                    help="stretch to fill (default keeps aspect ratio with "
                         "letterbox padding)")
    args = ap.parse_args()




    try:
        img = Image.open(args.image)
    except FileNotFoundError:
        sys.exit(f"Image not found: {args.image}")

    dev = usb.core.find(idVendor=VENDOR_ID, idProduct=PRODUCT_ID)
    if dev is None:
        sys.exit(f"LCD not found ({VENDOR_ID:#06x}:{PRODUCT_ID:#06x}). Is it plugged in?")

    try:
        claim(dev)
    except usb.core.USBError as e:
        sys.exit(f"Could not claim interface {INTERFACE}: {e}\n"
                 f"Try running with sudo, or install the udev rule.")

    try:
        if args.portrait or args.landscape:
            set_orientation(dev, portrait=args.portrait)
            time.sleep(0.1)

        pixels = to_rgb565_be(img, rotate=args.rotate, stretch=args.stretch)
        print(f"Image  : {args.image}  (rotate={args.rotate} stretch={args.stretch})")


        print(f"Canvas : {WIDTH}x{HEIGHT} RGB565  ({len(pixels)} px)")
        print(f"Sending {CHUNK_COUNT} chunks to USB {VENDOR_ID:#06x}:{PRODUCT_ID:#06x} iface {INTERFACE} ep {EP_OUT:#04x} ...")
        redraw(dev, pixels)
        print("Done. Check the panel.")

        if args.watch:
            print(f"--watch: redrawing every {args.interval}s to hold the image. "
                  f"Press Ctrl-C to stop.")
            try:
                while True:
                    time.sleep(args.interval)
                    redraw(dev, pixels)
                    heartbeat(dev)
            except KeyboardInterrupt:
                print("\nStopped watching.")

    finally:
        usb.util.release_interface(dev, INTERFACE)
        try:
            dev.attach_kernel_driver(INTERFACE)
        except (NotImplementedError, usb.core.USBError):
            pass


if __name__ == "__main__":
    main()
