"""Writes the freedesktop symbolic tray icons from the glyph grids in glyphs.py (no redrawn art).
    python3 design/icon/symbolic_svgs.py
Output is tools/linux-desktop/share/icons/hicolor/symbolic/apps/, one SVG per tray state. 16 x 16 viewBox, one
fill, no gradients, so GNOME's AppIndicator extension and KDE Plasma can recolour them to the panel."""
from pathlib import Path

from glyphs import GLYPHS

APP_ID = "app.mouthtype.Mouthtype"
OUT = Path(__file__).resolve().parent.parent.parent / "tools/linux-desktop/share/icons/hicolor/symbolic/apps"


def icon_name(glyph):
    return APP_ID + "-symbolic" if glyph == "idle" else "%s-%s-symbolic" % (APP_ID, glyph)


def path_data(rows):
    """Horizontal runs of ink as one rectangle each, in a 16 x 16 box."""
    parts = []
    for y, row in enumerate(rows):
        x = 0
        while x < len(row):
            if row[x] == "#":
                start = x
                while x < len(row) and row[x] == "#":
                    x += 1
                parts.append("M%d %dh%dv1h-%dz" % (start, y, x - start, x - start))
            else:
                x += 1
    return "".join(parts)


def svg(rows):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\n'
            '  <style id="current-color-scheme" type="text/css">.ColorScheme-Text{color:#bebebe}</style>\n'
            '  <path class="ColorScheme-Text" fill="currentColor" d="%s"/>\n'
            '</svg>\n' % path_data(rows))


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for glyph, rows in GLYPHS.items():
        (OUT / (icon_name(glyph) + ".svg")).write_text(svg(rows))
