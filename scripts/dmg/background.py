#!/usr/bin/env python3
"""Draw the DMG window background: a quiet paper field with a pixel arrow.

Stdlib only and deterministic, in the same pixel idiom as design/icon. Writes
background.png (660x400), background@2x.png (1320x800, 144 dpi) and a combined
background.tiff via tiffutil so Finder picks the right one on Retina displays.

    python3 -I scripts/dmg/background.py OUTPUT_DIR
"""
import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
spec = importlib.util.spec_from_file_location('canvas', ROOT / 'design/icon/canvas.py')
canvas = importlib.util.module_from_spec(spec)
spec.loader.exec_module(canvas)

WIDTH, HEIGHT = 660, 400
UNIT = 6                      # one art pixel, in 1x points
PAPER, PANEL, ORANGE, LIME = '#ffffff', '#f1f3f6', '#ef8b43', '#d3e58b'
# Icon centres, shared with scripts/build-dmg.py. The arrow sits between them.
APP_X, APPS_X, ICON_Y = 170, 490, 190

BAYER = ((0, 8, 2, 10), (12, 4, 14, 6), (3, 11, 1, 9), (15, 7, 13, 5))


def arrow_cells():
    """Dashed shaft plus a stepped head, in art pixels relative to the arrow centre."""
    cells = set()
    for x in range(-9, 3):
        if (x + 9) % 3 != 2:
            cells.add((x, 0))
    for i in range(5):
        for dy in range(-(4 - i), 4 - i + 1):
            cells.add((3 + i, dy))
    return cells


def draw():
    cols, rows = WIDTH // UNIT + 1, HEIGHT // UNIT + 1
    art = canvas.Canvas(cols, rows)
    for y in range(rows):
        for x in range(cols):
            t = y / rows
            art.px(x, y, canvas.mix(PAPER, PANEL, t))
    # Light dither of lime in the lower-left corner and orange in the upper-right,
    # the same texture the app tile carries.
    for y in range(rows):
        for x in range(cols):
            for corner_x, corner_y, color in ((0, rows, LIME), (cols, 0, ORANGE)):
                d = ((x - corner_x) ** 2 + (y - corner_y) ** 2) ** 0.5 / 26
                if d < 1 and BAYER[y % 4][x % 4] / 16 < (1 - d) * 0.34:
                    art.px(x, y, canvas.mix(canvas.rgba(art.p[y][x]), color, 0.22))
    cx = (APP_X + APPS_X) // 2 // UNIT
    cy = ICON_Y // UNIT
    for dx, dy in arrow_cells():
        art.px(cx + dx, cy + dy, ORANGE)
    return art


def main():
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    art = draw()
    one, two = out / 'background.png', out / 'background@2x.png'
    # 1x and 2x both come from the same art grid, so they stay pixel aligned.
    crop = lambda c, w, h: _crop(c, w, h)
    crop(art.scaled(UNIT), WIDTH, HEIGHT).png(one)
    crop(art.scaled(UNIT * 2), WIDTH * 2, HEIGHT * 2).png(two)
    subprocess.run(['sips', '-s', 'dpiWidth', '72', '-s', 'dpiHeight', '72', str(one)],
                   check=True, capture_output=True)
    subprocess.run(['sips', '-s', 'dpiWidth', '144', '-s', 'dpiHeight', '144', str(two)],
                   check=True, capture_output=True)
    subprocess.run(['tiffutil', '-cathidpicheck', str(one), str(two), '-out', str(out / 'background.tiff')],
                   check=True, capture_output=True)
    print(out / 'background.tiff')


def _crop(c, w, h):
    o = canvas.Canvas(w, h)
    o.p = [row[:w] for row in c.p[:h]]
    return o


if __name__ == '__main__':
    main()
