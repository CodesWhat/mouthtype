"""Menu bar glyphs, one per status state. 22 x 18, '#' is template ink and '.' is clear. The 2x file is the same
art doubled, which is exact for pixel art. Open-sides lips: two lip strokes with a serifed I-beam between them."""

# the lips with the cursor standing between them
IDLE = [
    "....#####....#####....",
    "..########..########..",
    ".####################.",
    "######################",
    "##..................##",
    "........######........",
    "..........##..........",
    "..........##..........",
    "..........##..........",
    "..........##..........",
    "..........##..........",
    "........######........",
    "##..................##",
    "######################",
    ".####################.",
    "..##################..",
    "....##############....",
    "......................",
]

# filled between the lips, the cursor knocked out: "on"
RECORDING = [
    "....#####....#####....",
    "..########..########..",
    ".####################.",
    "######################",
    "######################",
    "########......########",
    "##########..##########",
    "##########..##########",
    "##########..##########",
    "##########..##########",
    "##########..##########",
    "########......########",
    "######################",
    "######################",
    ".####################.",
    "..##################..",
    "....##############....",
    "......................",
]

# the cursor replaced by three typing dots
PROCESSING = IDLE[:5] + [
    "......................",
    "......................",
    "....###...###...###...",
    "....###...###...###...",
    "....###...###...###...",
    "......................",
    "......................",
] + IDLE[12:]


def _slashed(rows):
    """The mouth with a two pixel bar (a 2 x 2 brush stepped along the diagonal) from the bottom left corner to the top right and a one pixel gap on each side."""
    w, h = len(rows[0]), len(rows)
    line = {(w - 3 - i + dx, i + dy) for i in range(h - 1) for dx in (0, 1) for dy in (0, 1)}
    g = [list(r) for r in rows]
    for x, y in line:
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            xx, yy = x + dx, y + dy
            if 0 <= xx < w and 0 <= yy < h and (xx, yy) not in line:
                g[yy][xx] = "."
    for x, y in line:
        g[y][x] = "#"
    return ["".join(r) for r in g]


# no cursor, so the bar crosses an empty mouth
UNAVAILABLE = _slashed(IDLE[:5] + ["......................"] * 7 + IDLE[12:])

GLYPHS = {"idle": IDLE, "recording": RECORDING, "processing": PROCESSING, "unavailable": UNAVAILABLE}
