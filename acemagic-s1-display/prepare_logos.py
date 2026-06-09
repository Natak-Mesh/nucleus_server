#!/usr/bin/env python3
"""
prepare_logos.py — resize/letterbox source logos to the AceMagic S1 panel size.

Source images live in /home/natak/Documents/images. Each is scaled to fit
inside the panel resolution (preserving aspect ratio) and padded with a
background color so nothing is distorted. Results are written to ./prepared/.

Usage:
    .venv/bin/python prepare_logos.py
    .venv/bin/python prepare_logos.py --bg 0,0,0          # black padding
    .venv/bin/python prepare_logos.py --width 320 --height 170
"""
import argparse
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is not installed. Run: .venv/bin/pip install Pillow")

SRC_DIR = "/home/natak/Documents/images"
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prepared")
SOURCES = [
    "NatakMeshlogomark.png",
    "NatakMeshprimary-overlay.png",
    "NatakMeshvertical-overlay.png",
]


def parse_color(s):
    parts = [int(x) for x in s.split(",")]
    if len(parts) != 3:
        raise argparse.ArgumentTypeError("color must be R,G,B (e.g. 0,0,0)")
    return tuple(parts)


def letterbox(img, width, height, bg):
    """Fit img inside width x height preserving aspect ratio, pad with bg."""
    img = img.convert("RGBA")
    canvas = Image.new("RGB", (width, height), bg)

    src_w, src_h = img.size
    scale = min(width / src_w, height / src_h)
    new_w = max(1, int(round(src_w * scale)))
    new_h = max(1, int(round(src_h * scale)))
    resized = img.resize((new_w, new_h), Image.LANCZOS)

    # Composite onto a bg-colored tile so transparency flattens to bg.
    tile = Image.new("RGBA", (new_w, new_h), bg + (255,))
    tile.alpha_composite(resized)

    off_x = (width - new_w) // 2
    off_y = (height - new_h) // 2
    canvas.paste(tile.convert("RGB"), (off_x, off_y))
    return canvas


def main():
    ap = argparse.ArgumentParser(description="Prepare logos for the AceMagic S1 panel")
    ap.add_argument("--width", type=int, default=320)
    ap.add_argument("--height", type=int, default=170)
    ap.add_argument("--bg", type=parse_color, default=(0, 0, 0),
                    help="padding/background color as R,G,B (default 0,0,0)")
    args = ap.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)

    found = 0
    for name in SOURCES:
        src = os.path.join(SRC_DIR, name)
        if not os.path.isfile(src):
            print(f"  ! skip (not found): {src}")
            continue
        with Image.open(src) as img:
            out_img = letterbox(img, args.width, args.height, args.bg)
        out = os.path.join(OUT_DIR, name)
        out_img.save(out)
        found += 1
        print(f"  + {name}: -> {args.width}x{args.height}  ({out})")

    if found == 0:
        sys.exit(f"No source images found in {SRC_DIR}")
    print(f"\nDone. {found} image(s) written to {OUT_DIR}")


if __name__ == "__main__":
    main()
