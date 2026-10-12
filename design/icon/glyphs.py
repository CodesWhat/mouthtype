"""Menu bar glyphs, one per status state. 16 x 16, '#' is template ink and '.' is clear. The 2x file is the same
art doubled, which is exact for pixel art."""

# the open lips with the cursor, from the first-round concept, used while recording
RECORDING = [
    "................",
    "...####..####...",
    "..############..",
    "################",
    "###..........###",
    "##....####....##",
    "#......##......#",
    "#......##......#",
    "#......##......#",
    "##....####....##",
    "###..........###",
    "################",
    ".##############.",
    "..############..",
    "...##########...",
    "................",
]

# parted a little: a flat slit with square ends, so it reads as a mouth and not an eye
IDLE = [
    "................",
    "................",
    "...####..####...",
    "..############..",
    "################",
    "#..............#",
    "#.....####.....#",
    "#......##......#",
    "#.....####.....#",
    "#..............#",
    "################",
    ".##############.",
    "..############..",
    "................",
    "................",
    "................",
]

# open, the cursor replaced by typing dots
PROCESSING = [
    "................",
    "...####..####...",
    "..############..",
    "################",
    "###..........###",
    "##............##",
    "#..##..##..##..#",
    "#..##..##..##..#",
    "#..............#",
    "##............##",
    "###..........###",
    "################",
    ".##############.",
    "..############..",
    "...##########...",
    "................",
]


def _slashed(rows):
    """The idle mouth with a diagonal bar across it and a one-pixel gap cut along both sides."""
    line = {(1 + i, 14 - i) for i in range(14)}
    g = [list(r) for r in rows]
    for x, y in line:
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            xx, yy = x + dx, y + dy
            if 0 <= xx < 16 and 0 <= yy < 16 and (xx, yy) not in line:
                g[yy][xx] = "."
    for x, y in line:
        g[y][x] = "#"
    return ["".join(r) for r in g]


# the cursor is dropped here so the bar crosses an empty slit
UNAVAILABLE = _slashed(IDLE[:6] + ["#..............#"] * 3 + IDLE[9:])

GLYPHS = {"idle": IDLE, "recording": RECORDING, "processing": PROCESSING, "unavailable": UNAVAILABLE}
