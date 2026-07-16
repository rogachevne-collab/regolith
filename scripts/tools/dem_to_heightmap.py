#!/usr/bin/env python3
"""Convert a 16-bit LOLA DEM TIFF into a Godot-readable normalized heightmap.

Godot cannot load TIFF and its 16-bit PNG support is unreliable, so we encode a
normalized [0..1] height into two 8-bit channels (R=high byte, G=low byte) of a
plain RGB8 PNG. This is lossless through Godot's 8-bit PNG loader and gives full
16-bit precision back in-engine as h01 = (R * 256 + G) / 65535.

Source: NASA SVS ldem_4_uint.tif (equirectangular, 0deg-centered).
Encoding of source DN: elevation_m = (DN - 20000) * 0.5

Outputs (next to the source):
  resources/moon/lunar_dem_rg16.png   RGB8, R/G = 16-bit normalized height
  resources/moon/lunar_dem_meta.json  {min_m, max_m, width, height}
"""

import json
import os
import sys

from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "resources", "moon", "ldem_4_uint.tif")
OUT_PNG = os.path.join(REPO, "resources", "moon", "lunar_dem_rg16.png")
OUT_META = os.path.join(REPO, "resources", "moon", "lunar_dem_meta.json")

# LOLA uint encoding: elevation in meters above the 1737.4 km reference sphere.
DN_OFFSET = 20000.0
DN_SCALE_M = 0.5


def main() -> int:
    if not os.path.exists(SRC):
        print("ERROR: missing source DEM %s" % SRC, file=sys.stderr)
        return 1

    img = Image.open(SRC)
    # Force single-channel 32-bit int access ("I") so we keep the full DN range.
    img = img.convert("I")
    w, h = img.size
    print("DEM: %s %dx%d mode=%s" % (os.path.basename(SRC), w, h, img.mode))

    dn = list(img.getdata())
    dn_min = min(dn)
    dn_max = max(dn)
    span = float(dn_max - dn_min) if dn_max > dn_min else 1.0
    min_m = (dn_min - DN_OFFSET) * DN_SCALE_M
    max_m = (dn_max - DN_OFFSET) * DN_SCALE_M
    print("DEM DN range %d..%d -> meters %.1f..%.1f" % (dn_min, dn_max, min_m, max_m))

    buf = bytearray(w * h * 3)
    for i, v in enumerate(dn):
        n16 = int(round((v - dn_min) / span * 65535.0))
        if n16 < 0:
            n16 = 0
        elif n16 > 65535:
            n16 = 65535
        j = i * 3
        buf[j] = (n16 >> 8) & 0xFF
        buf[j + 1] = n16 & 0xFF
        buf[j + 2] = 0

    out = Image.frombytes("RGB", (w, h), bytes(buf))
    out.save(OUT_PNG)
    meta = {"min_m": min_m, "max_m": max_m, "width": w, "height": h}
    with open(OUT_META, "w") as f:
        json.dump(meta, f, indent=2)
    print("WROTE %s" % OUT_PNG)
    print("WROTE %s -> %s" % (OUT_META, json.dumps(meta)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
