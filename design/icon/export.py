"""Draws the app icon and the menu bar glyphs. Python 3 stdlib only; run as `python3 -I design/icon/export.py`.

The tile is full-bleed: a flat #F19A4B square with a light Bayer dither as texture, no baked shadow, no drawn
corners. macOS 26 applies its own squircle mask, depth and highlight. The lips are 78% of the tile width: the
36 unit sprite at 22x on the 1024 master (792 px). 512, 256 and 128 are box filtered from the master. 64 px is
the 25 px wide 32 sprite at 2x and 32 and 16 px are purpose-made small drawings, all on the pixel grid.

Written: the iconset and packaging/AppIcon.icns (the pre-Icon Composer fallback), the Icon Composer bundle
design/icon/AppIcon.icon (tile and lips layers with Dark and Clear/Tinted specialisations), and the glyph PNGs
the status item loads. Output is deterministic."""
import json
import os
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from canvas import Canvas, mix, rgba
from glyphs import GLYPHS
from sprites import LIPS16, LIPS32, LIPS64, PALETTE, mono

ROOT = os.path.join(HERE, "..", "..")
ICONSET = os.path.join(HERE, "AppIcon.iconset")
ICON_BUNDLE = os.path.join(HERE, "AppIcon.icon")
ICNS = os.path.join(ROOT, "packaging", "AppIcon.icns")
GLYPH_DIR = os.path.join(ROOT, "Sources", "MouthtypeMac", "Resources", "MenuBar")

TILE, TILE_DARK = "#F19A4B", "#2A2A2E"
DOT = (255, 255, 255, 36)  # the texture dots as white at 14%, the same lift as the flat tile's light dither
BAYER4 = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
MASTER, LIPS_SCALE = 1024, 22


def tile(n, cell, origin, base, dither):
    """A flat full-bleed n x n tile; with base None, only the dither dots on a transparent canvas (the texture
    layer of the Icon Composer bundle). With dither, a light Bayer pattern in cell x cell blocks fades in toward the
    bottom right; the block grid is anchored at origin so it lines up with the lips' pixels."""
    cv = Canvas(n, n)
    base_c = rgba(base) if base else (0, 0, 0, 0)
    light = mix(base, "#FFFFFF", 0.14) if base else DOT
    for y in range(n):
        cy = (y - origin) // cell
        for x in range(n):
            col = base_c
            if dither:
                cx = (x - origin) // cell
                t = max(0.0, min(1.0, (((cx + 0.5) * 0.35 + (cy + 0.5) * 0.65) * cell / n - 0.25) / 0.7))
                if t * 16 > BAYER4[cy % 4][cx % 4]:
                    col = light
            cv.p[y][x] = col
    return cv


def stamp(cv, rows, scale=1, colors=PALETTE):
    h, w = len(rows), len(rows[0])
    ox, oy = (cv.w - w * scale) // 2, (cv.h - h * scale) // 2
    for j, row in enumerate(rows):
        for i, ch in enumerate(row):
            if ch in colors:
                c = rgba(colors[ch])
                for dy in range(scale):
                    for dx in range(scale):
                        cv.px(ox + i * scale + dx, oy + j * scale + dy, c)


def lips_origin(n, rows, scale):
    return ((n - len(rows[0]) * scale) // 2) % scale


def layer(rows, scale, colors=PALETTE, n=MASTER):
    cv = Canvas(n, n)
    stamp(cv, rows, scale, colors)
    return cv


def art(n, rows, scale, cell, dither):
    cv = tile(n, cell, lips_origin(n, rows, scale), TILE, dither)
    stamp(cv, rows, scale)
    return cv


def srgb(c):
    r, g, b, _ = rgba(c)
    return "srgb:%.5f,%.5f,%.5f,1.00000" % (r / 255, g / 255, b / 255)


def write_icon_bundle():
    """Icon Composer bundle, 1024 px layers. The tile is the document fill (orange, charcoal in Dark) with the
    dither as a transparent texture layer named tile, under the lips. Clear and Tinted hide the coloured lips and
    show the one colour sprite (mouth and cursor knocked out). Compiled by `actool` in build-app.sh."""
    assets = os.path.join(ICON_BUNDLE, "Assets")
    shutil.rmtree(ICON_BUNDLE, ignore_errors=True)
    os.makedirs(assets)
    origin = lips_origin(MASTER, LIPS64, LIPS_SCALE)
    tile(MASTER, LIPS_SCALE // 2, origin, None, True).png(os.path.join(assets, "tile.png"))
    layer(LIPS64, LIPS_SCALE).png(os.path.join(assets, "lips.png"))
    layer(mono(LIPS64), LIPS_SCALE, {"W": "#FFFFFF"}).png(os.path.join(assets, "lips-mono.png"))
    spec = {
        "fill": {"solid": srgb(TILE)},
        "fill-specializations": [{"appearance": "dark", "value": {"solid": srgb(TILE_DARK)}}],
        "groups": [{
            "layers": [
                {
                    "name": "lips-mono",
                    "image-name": "lips-mono.png",
                    "hidden-specializations": [
                        {"value": True},
                        {"appearance": "tinted", "value": False},
                    ],
                },
                {
                    "name": "lips",
                    "image-name": "lips.png",
                    "hidden-specializations": [
                        {"value": False},
                        {"appearance": "tinted", "value": True},
                    ],
                },
                {"name": "tile", "image-name": "tile.png"},
            ],
        }],
        "supported-platforms": {"squares": ["macOS"]},
    }
    with open(os.path.join(ICON_BUNDLE, "icon.json"), "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


def glyph(rows, scale):
    cv = Canvas(len(rows[0]), len(rows))
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch == "#":
                cv.px(x, y, (0, 0, 0, 255))
    return cv.scaled(scale) if scale > 1 else cv


def main():
    master = art(MASTER, LIPS64, LIPS_SCALE, LIPS_SCALE // 2, True)
    sizes = {1024: master, 512: master.boxed(2), 256: master.boxed(4), 128: master.boxed(8)}
    sizes[64] = art(64, LIPS32, 2, 2, True)
    sizes[32] = art(32, LIPS32, 1, 1, False)
    sizes[16] = art(16, LIPS16, 1, 1, False)

    shutil.rmtree(ICONSET, ignore_errors=True)
    os.makedirs(ICONSET)
    for base in (16, 32, 128, 256, 512):
        sizes[base].png(os.path.join(ICONSET, "icon_%dx%d.png" % (base, base)))
        # 16@2x is the 32 px drawing, 32@2x the 64 px one
        sizes[base * 2].png(os.path.join(ICONSET, "icon_%dx%d@2x.png" % (base, base)))
    master.png(os.path.join(HERE, "AppIcon-1024.png"))
    write_icon_bundle()

    if sys.platform == "darwin":
        subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS], check=True)

    os.makedirs(GLYPH_DIR, exist_ok=True)
    for state, rows in GLYPHS.items():
        glyph(rows, 1).png(os.path.join(GLYPH_DIR, "glyph-%s.png" % state))
        glyph(rows, 2).png(os.path.join(GLYPH_DIR, "glyph-%s@2x.png" % state))


if __name__ == "__main__":
    main()
