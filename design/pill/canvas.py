"""Tiny RGBA pixel canvas, stdlib only. Everything is drawn 1 art-pixel = 1 canvas pixel, scaled at the end."""
import struct
import zlib


def rgba(c):
    if c is None:
        return None
    if isinstance(c, tuple):
        return c if len(c) == 4 else c + (255,)
    c = c.lstrip("#")
    r, g, b = (int(c[i:i + 2], 16) for i in (0, 2, 4))
    a = int(c[6:8], 16) if len(c) == 8 else 255
    return (r, g, b, a)


def mix(a, b, t):
    a, b = rgba(a), rgba(b)
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(4))


class Canvas:
    def __init__(self, w, h, bg=None):
        self.w, self.h = w, h
        c = rgba(bg) or (0, 0, 0, 0)
        self.p = [[c] * w for _ in range(h)]

    # --- pixels
    def get(self, x, y):
        if 0 <= x < self.w and 0 <= y < self.h:
            return self.p[y][x]
        return (0, 0, 0, 0)

    def px(self, x, y, c):
        c = rgba(c)
        if c is None or not (0 <= x < self.w and 0 <= y < self.h):
            return
        if c[3] == 255:
            self.p[y][x] = c
            return
        if c[3] == 0:
            return
        d = self.p[y][x]
        a = c[3] / 255.0
        da = d[3] / 255.0
        oa = a + da * (1 - a)
        if oa == 0:
            return
        self.p[y][x] = tuple(int(round((c[i] * a + d[i] * da * (1 - a)) / oa)) for i in range(3)) + (int(round(oa * 255)),)

    def rect(self, x, y, w, h, c):
        for j in range(y, y + h):
            for i in range(x, x + w):
                self.px(i, j, c)

    def hline(self, x, y, w, c):
        self.rect(x, y, w, 1, c)

    def vline(self, x, y, h, c):
        self.rect(x, y, 1, h, c)

    def bevel(self, x, y, w, h, hi, lo, raised=True):
        """1px bevel drawn inside the rect: hi on top/left, lo on bottom/right (swapped when sunk)."""
        if not raised:
            hi, lo = lo, hi
        self.hline(x, y, w - 1, hi)
        self.vline(x, y, h - 1, hi)
        self.hline(x + 1, y + h - 1, w - 1, lo)
        self.vline(x + w - 1, y + 1, h - 1, lo)

    def crop(self, x, y, w, h):
        o = Canvas(w, h)
        for j in range(h):
            for i in range(w):
                o.p[j][i] = self.get(x + i, y + j)
        return o

    def text(self, x, y, s, font, c, gap=1):
        """Draw s in a bitmap font (dict char -> rows). Returns the width drawn."""
        cx = x
        for ch in s:
            g = font.get(ch) or font.get(ch.upper()) or font[" "]
            for j, row in enumerate(g):
                for i, b in enumerate(row):
                    if b == "#":
                        self.px(cx + i, y + j, c)
            cx += len(g[0]) + gap
        return cx - x - gap

    def png(self, path):
        raw = bytearray()
        for row in self.p:
            raw += b"\x00" + b"".join(bytes(px) for px in row)

        def chunk(tag, data):
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 6, 0, 0, 0))
        png += chunk(b"sRGB", b"\x00")  # tagged sRGB so the pixels match the layout's hex colours on screen
        png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
        open(path, "wb").write(png)


def inside_rr(x, y, w, h, r):
    """Pixel-art rounded rect membership."""
    if not (0 <= x < w and 0 <= y < h):
        return False
    cx = r if x < r else (w - r if x >= w - r else None)
    cy = r if y < r else (h - r if y >= h - r else None)
    if cx is None or cy is None:
        return True
    return (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2 <= r * r - 0.4


def shape(cv, ox, oy, w, h, inside, fill, edge):
    """Fill a mask with fill(x,y) (local coords) and trace a 1px edge colour around it."""
    for y in range(h):
        for x in range(w):
            if not inside(x, y):
                continue
            on_edge = not (inside(x - 1, y) and inside(x + 1, y) and inside(x, y - 1) and inside(x, y + 1))
            c = edge if (on_edge and edge) else fill(x, y)
            if c is not None:
                cv.px(ox + x, oy + y, c)


def disc(cv, cx, cy, r, c):
    for y in range(int(cy - r - 1), int(cy + r + 2)):
        for x in range(int(cx - r - 1), int(cx + r + 2)):
            if (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2 <= r * r:
                cv.px(x, y, c)


def ring(cv, cx, cy, r0, r1, c):
    for y in range(int(cy - r1 - 1), int(cy + r1 + 2)):
        for x in range(int(cx - r1 - 1), int(cx + r1 + 2)):
            d = (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2
            if r0 * r0 < d <= r1 * r1:
                cv.px(x, y, c)
