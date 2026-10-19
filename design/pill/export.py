"""Draws the hi-fi pill and writes the shipped assets. Python 3 stdlib only; run as `python3 -I design/pill/export.py`.

Everything is drawn at 1x, one art pixel per point, and written to Sources/MouthtypeMac/Resources/Pill/hifi/:
the static chassis, the small state sprites, the two font atlases and layout.json (every position, rect and colour
the app needs). The delivery card's window sprites go to hifi/card/ with their own layout.json. Output is
deterministic, so a second run changes no bytes."""
import json
import math
import os
import random
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from canvas import Canvas, disc, inside_rr, mix, rgba, ring, shape
from font import ADVANCES, F3, F5
from palette import HIFI as P

W, H = 146, 32
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Sources", "MouthtypeMac", "Resources", "Pill", "hifi")

CARD_OUT = os.path.join(OUT, "card")

# geometry, in art pixels, origin top-left
TALK = (15, 14)                    # centre of the push button
LED = (34, 9)                      # centre of the REC lens
WIN = (42, 3, 68, 16)              # VFD window x, y, w, h
COLUMNS, SEGMENTS = 10, 5
SEG_W, SEG_H = 3, 2
CAPS = {"cancel": 117, "stop": 131}  # x of the 11 px square caps, y is 7

PADLOCK = ["..k..", ".k.k.", ".k.k.", "kkkkk", "kkkkk", "kkkkk"]


def segment_rect(col, seg):
    wx, wy, ww, wh = WIN
    return (wx + 3 + col * 4, wy + wh - 3 - seg * 3, SEG_W, SEG_H)


def glow(cv, cx, cy, r, c, a):
    r0, g0, b0, _ = rgba(c)
    for y in range(cy - r, cy + r + 1):
        for x in range(cx - r, cx + r + 1):
            d = math.hypot(x - cx, y - cy)
            if d <= r:
                cv.px(x, y, (r0, g0, b0, int(a * (1 - d / r) ** 1.5)))


def bbox(*canvases):
    xs, ys = [], []
    for cv in canvases:
        for y in range(cv.h):
            for x in range(cv.w):
                if cv.p[y][x][3]:
                    xs.append(x)
                    ys.append(y)
    return min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1


def chassis():
    cv = Canvas(W, H)
    rnd = random.Random(11)
    rows = [rnd.choice([P["metal_a"], P["metal_b"], P["metal"], P["metal"]]) for _ in range(H)]

    def fill(x, y):
        c = rows[y]
        if rnd.random() < 0.07:
            c = mix(c, P["metal_hi"], .25)
        return c
    shape(cv, 0, 0, W, H, lambda x, y: inside_rr(x, y, W, H, 5), fill, P["metal_edge"])
    cv.hline(5, 1, W - 10, P["metal_hi"])
    cv.hline(5, H - 2, W - 10, P["metal_lo"])
    cv.px(4, 2, P["metal_hi"])
    cv.px(W - 5, 2, mix(P["metal_hi"], P["metal"], .5))
    eng = P["engrave"]

    bx, by = TALK
    cv.text(bx - 7, 24, "TALK", F3, eng)

    lx, ly = LED
    disc(cv, lx, ly, 3.6, P["metal_lo"])
    ring(cv, lx, ly, 2.8, 3.6, P["silver_mid"])
    cv.px(lx - 2, ly - 3, P["silver_hi"])
    cv.text(lx - 5, 24, "REC", F3, eng)

    wx, wy, ww, wh = WIN
    cv.rect(wx - 2, wy - 2, ww + 4, wh + 4, P["metal_lo"])
    cv.hline(wx - 2, wy + wh + 1, ww + 4, P["metal_hi"])
    cv.vline(wx + ww + 1, wy - 1, wh + 3, P["metal_hi"])
    cv.rect(wx, wy, ww, wh, P["vfd_bg"])
    cv.rect(wx - 1, wy - 1, ww + 2, 1, P["vfd_edge"])
    cv.rect(wx - 1, wy - 1, 1, wh + 2, P["vfd_edge"])
    for col in range(COLUMNS):
        for seg in range(SEGMENTS):
            x, y, w, h = segment_rect(col, seg)
            cv.rect(x, y, w, h, P["seg_off"])
    for i in range(11):
        cv.px(wx + 2 + i * 4, wy + wh + 3, eng if i % 5 == 0 else P["engrave_dim"])
        if i % 5 == 0:
            cv.px(wx + 2 + i * 4, wy + wh + 4, eng)
    cv.text(wx + ww - 15, 24, "MT-1", F3, eng)

    for name, x0 in CAPS.items():
        cv.rect(x0 - 1, 6, 13, 13, P["metal_edge"])
        cv.text(x0 - 1, 22, "CAN" if name == "cancel" else "STP", F3, eng)
    return cv


def talk_cap(pressed):
    cv = Canvas(W, H)
    bx, by = TALK
    disc(cv, bx, by, 9.2, P["metal_edge"])
    disc(cv, bx, by, 8.4, P["silver_lo"])
    ring(cv, bx, by, 7.2, 8.4, P["silver_mid"])
    if pressed:
        disc(cv, bx, by, 8.4, mix(P["metal_edge"], P["silver_lo"], .3))
        disc(cv, bx, by + 1, 6.6, P["silver_lo"])
        disc(cv, bx, by + 1, 5.8, mix(P["silver_mid"], P["silver_lo"], .5))
        glow(cv, bx, by + 1, 7, P["led_on"], 120)
        disc(cv, bx, by + 1, 2.8, P["led_on"])
        cv.px(bx - 1, by, P["led_hi"])
    else:
        disc(cv, bx, by, 7, P["silver_mid"])
        disc(cv, bx - .5, by - .5, 6, P["silver"])
        cv.hline(bx - 4, by - 5, 4, P["silver_hi"])
        cv.px(bx - 5, by - 4, P["silver_hi"])
        disc(cv, bx, by, 2.8, mix(P["led_on"], "#000000", .62))
    return cv


def led_lens(on):
    cv = Canvas(W, H)
    lx, ly = LED
    if on:
        disc(cv, lx, ly, 2.4, P["led_on"])
        cv.px(lx - 1, ly - 1, P["led_hi"])
    else:
        disc(cv, lx, ly, 2.4, P["led_off"])
    return cv


def led_glow():
    cv = Canvas(W, H)
    glow(cv, LED[0], LED[1], 8, P["led_on"], 90)
    return cv


def cap(x0, kind, lit):
    cv = Canvas(W, H)
    cv.rect(x0, 7, 11, 11, P["silver_lo"])
    cv.bevel(x0, 7, 11, 11, P["silver_hi"], P["metal_lo"])
    cv.rect(x0 + 1, 8, 9, 9, mix(P["silver_mid"], P["vfd"], .55) if lit else P["silver_mid"])
    cv.rect(x0 + 1, 8, 9, 1, P["silver"])
    cc = "#3a1a00" if lit else P["metal_edge"]
    if kind == "cancel":
        for k in range(5):
            cv.px(x0 + 3 + k, 10 + k, cc)
            cv.px(x0 + 7 - k, 10 + k, cc)
    else:
        cv.rect(x0 + 3, 10, 5, 5, cc)
    return cv


def padlock():
    wx, wy, _, _ = WIN
    cv = Canvas(W, H)
    x0 = wx + 3 + 40 + 3
    for r, row in enumerate(PADLOCK):
        for q, ch in enumerate(row):
            if ch == "k":
                cv.px(x0 + q, wy + 5 + r, P["seg_hot"])
    return cv


def atlas(font, chars):
    cw, ch = len(font[" "][0]), len(font[" "])
    cv = Canvas(cw * len(chars), ch)
    for i, c in enumerate(chars):
        for y, row in enumerate(font[c]):
            for x, b in enumerate(row):
                if b == "#":
                    cv.px(i * cw + x, y, (255, 255, 255, 255))
    return cv, cw, ch


def hexcolor(c):
    return "#%02x%02x%02x" % rgba(c)[:3]


# ---- delivery card window: 9-slice sprites, 1x. Slices are (left, top, right, bottom) and tile, never smooth-scale.
FRAME = (40, 40, (4, 13, 4, 4))     # brushed metal window with a title bar 13 px tall (grips, then a divider)
CLOSE = (9, 9)                     # title-bar close button
BUTTON = (12, 12, (3, 3, 3, 3))    # bevelled grey cap; the label is drawn live
VFD = (12, 12, (3, 3, 3, 3))       # sunk amber-display bezel; the glass is drawn live


def card_frame():
    w, h, _ = FRAME
    cv = Canvas(w, h)
    rnd = random.Random(23)
    tones = [P["metal"], P["metal_a"], P["metal_b"], P["metal_a"]]
    grid = []
    for y in range(h):
        row, x = [], 0
        while x < w:
            run, c = rnd.randint(6, 24), rnd.choice(tones)
            row += [c] * run
            x += run
        grid.append(row[:w])
    shape(cv, 0, 0, w, h, lambda x, y: inside_rr(x, y, w, h, 3), lambda x, y: grid[y][x], P["metal_edge"])
    cv.hline(3, 1, w - 6, P["metal_hi"])
    cv.vline(1, 3, h - 6, mix(P["metal_hi"], P["metal"], .5))
    cv.hline(3, h - 2, w - 6, P["metal_lo"])
    cv.vline(w - 2, 3, h - 6, P["metal_lo"])
    for yy in (3, 5, 7):
        cv.hline(4, yy, w - 8, mix(P["metal"], P["metal_lo"], .7))
        cv.hline(4, yy + 1, w - 8, mix(P["metal"], P["metal_hi"], .5))
    cv.hline(2, 11, w - 4, P["metal_lo"])
    cv.hline(2, 12, w - 4, mix(P["metal"], P["metal_hi"], .35))
    return cv


CLOSE_X = ["#.#", ".#.", "#.#"]


def card_close(pressed):
    w, h = CLOSE
    cv = Canvas(w, h)
    cv.rect(0, 0, w, h, P["metal_lo"])
    if pressed:
        cv.rect(1, 1, w - 2, h - 2, mix(P["cap"], P["metal_lo"], .35))
        cv.bevel(1, 1, w - 2, h - 2, mix(P["cap"], P["cap_hi"], .4), P["cap_lo"], raised=False)
    else:
        cv.rect(1, 1, w - 2, h - 2, P["cap"])
        cv.bevel(1, 1, w - 2, h - 2, P["cap_hi"], P["cap_lo"])
    ox = 4 if pressed else 3
    for j, row in enumerate(CLOSE_X):
        for i, ch in enumerate(row):
            if ch == "#":
                cv.px(ox + i, ox + j, P["ink"])
    return cv


def card_button(pressed):
    w, h, _ = BUTTON
    cv = Canvas(w, h)
    for y in range(h):
        for x in range(w):
            on_ring = x in (0, w - 1) or y in (0, h - 1)
            corner = x in (0, w - 1) and y in (0, h - 1)
            if on_ring and not corner:
                cv.px(x, y, P["metal_lo"])
    cv.rect(1, 1, w - 2, h - 2, mix(P["cap"], P["metal_lo"], .35) if pressed else P["cap"])
    if pressed:
        cv.bevel(1, 1, w - 2, h - 2, mix(P["cap"], P["cap_hi"], .4), P["cap_lo"], raised=False)
    else:
        cv.bevel(1, 1, w - 2, h - 2, P["cap_hi"], P["cap_lo"])
        cv.hline(2, 2, w - 4, mix(P["cap"], P["cap_hi"], .35))
    return cv


def card_vfd():
    w, h, _ = VFD
    cv = Canvas(w, h)
    for y in range(h):
        for x in range(w):
            ring = min(x, y, w - 1 - x, h - 1 - y)
            if ring == 0:
                c = mix(P["metal_hi"], P["metal"], .4) if (y == h - 1 or x == w - 1) else P["metal_lo"]
            elif ring == 1:
                c = P["metal_lo"]
            elif ring == 2:
                c = P["vfd_edge"]
            else:
                c = P["vfd_bg"]
            cv.px(x, y, c)
    return cv


def export_card():
    os.makedirs(CARD_OUT, exist_ok=True)
    sprites = {}

    def emit(name, cv, slices=None):
        cv.png(os.path.join(CARD_OUT, name + ".png"))
        sprites[name] = {"file": name + ".png", "w": cv.w, "h": cv.h}
        if slices:
            sprites[name]["slices"] = dict(zip(("left", "top", "right", "bottom"), slices))

    emit("frame", card_frame(), FRAME[2])
    emit("close_up", card_close(False))
    emit("close_down", card_close(True))
    emit("button_up", card_button(False), BUTTON[2])
    emit("button_down", card_button(True), BUTTON[2])
    emit("vfd", card_vfd(), VFD[2])
    layout = {
        "version": 1,
        "sprites": sprites,
        # every length is in art pixels at 1x. The card is as wide as CardLayout.width, which is 224.
        "metrics": {
            "titleBar": 13, "margin": 6,
            "plate": {"x": 6, "y": 2, "h": 9, "padX": 4, "ledGap": 3},
            "close": {"right": 6, "y": 2, "hitW": 24, "hitH": 24},
            "vfd": {"gapTop": 3, "ring": 3, "padX": 3, "padY": 3, "lineGap": 2,
                    "barGap": 3, "barH": 2, "barSegW": 3, "barSegGap": 1},
            "button": {"h": 17, "minW": 36, "padX": 8, "gap": 4, "gapTop": 5, "labelPressedDy": 1},
            "bottomPad": 3,
            "maxLines": 5,
        },
        "colors": {k: hexcolor(P[k]) for k in (
            "metal", "metal_hi", "metal_lo", "metal_edge", "engrave", "engrave_dim", "engrave_hi",
            "cap", "cap_hi", "cap_lo", "ink", "vfd_bg", "vfd", "led_on", "led_hi", "seg_off")},
    }
    with open(os.path.join(CARD_OUT, "layout.json"), "w", encoding="utf-8") as f:
        json.dump(layout, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print("wrote", os.path.normpath(CARD_OUT))


def main():
    os.makedirs(OUT, exist_ok=True)
    layout = {"version": 1, "size": {"w": W, "h": H}}
    layout["chassis"] = "chassis.png"
    chassis().png(os.path.join(OUT, "chassis.png"))

    sprites = {}

    def emit(name, cv, box):
        x, y, w, h = box
        cv.crop(x, y, w, h).png(os.path.join(OUT, name + ".png"))
        sprites[name] = {"file": name + ".png", "x": x, "y": y, "w": w, "h": h}

    # a state pair shares one rect so swapping the image never moves the sprite
    pairs = [
        (("talk_up", talk_cap(False)), ("talk_down", talk_cap(True))),
        (("led_off", led_lens(False)), ("led_on", led_lens(True))),
        (("cancel", cap(CAPS["cancel"], "cancel", False)), ("cancel_lit", cap(CAPS["cancel"], "cancel", True))),
        (("stop", cap(CAPS["stop"], "stop", False)), ("stop_lit", cap(CAPS["stop"], "stop", True))),
    ]
    for (na, a), (nb, b) in pairs:
        box = bbox(a, b)
        emit(na, a, box)
        emit(nb, b, box)
    g = led_glow()
    emit("led_glow", g, bbox(g))
    p = padlock()
    emit("padlock", p, bbox(p))
    layout["sprites"] = sprites

    wx, wy, ww, wh = WIN
    layout["window"] = {"x": wx, "y": wy, "w": ww, "h": wh}
    layout["meter"] = {
        "columns": COLUMNS,
        "segmentsPerColumn": SEGMENTS,
        # segments[column][row], row 0 is the baseline segment
        "segments": [[dict(zip("xywh", segment_rect(c, s))) for s in range(SEGMENTS)] for c in range(COLUMNS)],
        "rowTiers": ["normal", "normal", "normal", "hot", "peak"],
    }
    tx = wx + 3 + 40 + 3
    layout["text"] = {
        "timer": {"x": tx, "y": wy + 5, "maxWidth": wx + ww - tx - 1, "font": "f3"},
        "timerLocked": {"x": tx + 7, "y": wy + 5, "maxWidth": wx + ww - tx - 8, "font": "f3"},
        "message": {"x": wx + 2, "y": wy + 4, "maxWidth": ww - 4, "font": "f5"},
    }
    layout["colors"] = {
        "segmentNormal": hexcolor(P["seg_on"]),
        "segmentHot": hexcolor(P["seg_hot"]),
        "segmentPeak": hexcolor(P["seg_peak"]),
        "segmentDim": hexcolor(P["seg_off"]),
        "windowBackground": hexcolor(P["vfd_bg"]),
        "text": hexcolor(P["vfd"]),
        "error": hexcolor(P["seg_peak"]),
    }

    fonts = {}
    for key, font in (("f5", F5), ("f3", F3)):
        chars = " " + "".join(c for c in font if c != " ")
        cv, cw, ch = atlas(font, chars)
        cv.png(os.path.join(OUT, "font-%s.png" % key[1]))
        fonts[key] = {"file": "font-%s.png" % key[1], "cellWidth": cw, "cellHeight": ch, "gap": 1,
                      "chars": chars, "advances": ADVANCES[key]}
    layout["fonts"] = fonts

    with open(os.path.join(OUT, "layout.json"), "w", encoding="utf-8") as f:
        json.dump(layout, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print("wrote", os.path.normpath(OUT))
    export_card()


if __name__ == "__main__":
    main()
