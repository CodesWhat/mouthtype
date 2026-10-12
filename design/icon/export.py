"""Draws the app icon and the menu bar glyphs. Python 3 stdlib only; run as `python3 -I design/icon/export.py`.

The icon is drawn on a 64 unit grid and scaled 16x to the 1024 master (tile 52 units, 832 px, centred, with its
drop shadow inside the canvas). 512, 256, 128 and 64 px are box filtered from the master by an integer factor, so
every art pixel stays an even square. 32 and 16 px come from purpose-made small drawings. The iconset and
packaging/AppIcon.icns are written, and the glyph PNGs the status item loads. Output is deterministic."""
import os
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from canvas import Canvas, mix, rgba
from glyphs import GLYPHS
from sprites import LIPS16, LIPS32, LIPS64, PALETTE

ROOT = os.path.join(HERE, "..", "..")
ICONSET = os.path.join(HERE, "AppIcon.iconset")
ICNS = os.path.join(ROOT, "packaging", "AppIcon.icns")
GLYPH_DIR = os.path.join(ROOT, "Sources", "MouthtypeMac", "Resources", "MenuBar")

ORANGE, ORANGE_LIGHT = "#F08A3C", "#F59C54"
BAYER4 = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def squircle(n, half, dy=0.0, power=5.0):
    c = (n - 1) / 2.0
    return [[(abs(x - c) / half) ** power + (abs(y - dy - c) / half) ** power <= 1.0 for x in range(n)] for y in range(n)]


def tile(n, half, shadow_dy, dither, power=5.0):
    """The orange tile on an n x n grid: drop shadow, optional Bayer dither gradient, rim, top highlight."""
    cv = Canvas(n, n)
    mask, shadow = squircle(n, half, 0.0, power), squircle(n, half, shadow_dy, power)

    def inside(x, y):
        return 0 <= x < n and 0 <= y < n and mask[y][x]
    for y in range(n):
        for x in range(n):
            if shadow[y][x] and not mask[y][x]:
                cv.px(x, y, (0, 0, 0, 70))
    rim, hi = mix(ORANGE, "#000000", 0.28), mix(ORANGE, "#FFFFFF", 0.28)
    for y in range(n):
        for x in range(n):
            if not mask[y][x]:
                continue
            col = ORANGE
            if dither:
                t = max(0.0, min(1.0, ((x * 0.35 + y * 0.65) / n - 0.25) / 0.7))
                if t * 16 > BAYER4[y % 4][x % 4]:
                    col = ORANGE_LIGHT
            cv.px(x, y, col)
    for y in range(n):
        for x in range(n):
            if not mask[y][x]:
                continue
            if not (inside(x - 1, y) and inside(x + 1, y) and inside(x, y - 1) and inside(x, y + 1)):
                cv.px(x, y, rim)
            elif not inside(x, y - 2) and inside(x, y - 1) and cv.p[y][x][:3] == rgba(ORANGE)[:3]:
                cv.px(x, y, hi)
    return cv


def stamp(cv, rows, dx=0, dy=0):
    h, w = len(rows), len(rows[0])
    ox, oy = (cv.w - w) // 2 + dx, (cv.h - h) // 2 + dy
    for j, row in enumerate(rows):
        for i, ch in enumerate(row):
            if ch in PALETTE:
                cv.px(ox + i, oy + j, PALETTE[ch])


def art64():
    cv = tile(64, 26.0, 2.0, True)
    stamp(cv, LIPS64)
    return cv


def art32():
    cv = tile(32, 13.0, 1.0, False)
    stamp(cv, LIPS32)
    return cv


def art16():
    cv = tile(16, 6.6, 1.0, False, 7.0)
    stamp(cv, LIPS16)
    return cv


def glyph(rows, scale):
    cv = Canvas(len(rows[0]), len(rows))
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch == "#":
                cv.px(x, y, (0, 0, 0, 255))
    return cv.scaled(scale) if scale > 1 else cv


def main():
    master = art64().scaled(16)
    sizes = {1024: master, 512: master.boxed(2), 256: master.boxed(4), 128: master.boxed(8), 64: master.boxed(16)}
    small32, small16 = art32(), art16()
    sizes[32], sizes[16] = small32, small16

    shutil.rmtree(ICONSET, ignore_errors=True)
    os.makedirs(ICONSET)
    for base in (16, 32, 128, 256, 512):
        sizes[base].png(os.path.join(ICONSET, "icon_%dx%d.png" % (base, base)))
        # 16@2x is the 32 px drawing, 32@2x is the 64 unit art at 1x
        sizes[base * 2].png(os.path.join(ICONSET, "icon_%dx%d@2x.png" % (base, base)))
    master.png(os.path.join(HERE, "AppIcon-1024.png"))

    if sys.platform == "darwin":
        subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS], check=True)

    os.makedirs(GLYPH_DIR, exist_ok=True)
    for state, rows in GLYPHS.items():
        glyph(rows, 1).png(os.path.join(GLYPH_DIR, "glyph-%s.png" % state))
        glyph(rows, 2).png(os.path.join(GLYPH_DIR, "glyph-%s@2x.png" % state))


if __name__ == "__main__":
    main()
