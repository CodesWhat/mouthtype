"""Menu bar glyphs, one per status state. 16 x 15, '#' is template ink and '.' is clear. The 2x file is the same
art doubled, which is exact for pixel art. The lips from the app icon: closed when idle, open with the voice while
recording (three frames), the same mouth with dots while processing."""

# closed lips with a one pixel seam: "idle"
IDLE = [
    "................",
    "................",
    "....###..###....",
    "...##########...",
    "..############..",
    ".##############.",
    "################",
    "#..............#",
    "################",
    ".##############.",
    "..############..",
    "...##########...",
    ".....######.....",
    "................",
    "................",
]

# the mouth opens with the voice: three frames, and no caret inside
RECORDING_0 = IDLE[:6] + ["##............##"] * 3 + IDLE[9:]
RECORDING_1 = [
    "................",
    "....###..###....",
    "...##########...",
    "..############..",
    ".##############.",
    "##............##",
    "##............##",
    "##............##",
    "##............##",
    ".##..........##.",
    "..############..",
    "...##########...",
    ".....######.....",
    "................",
    "................",
]
RECORDING_2 = [
    "....###..###....",
    "...##########...",
    "..############..",
    ".##..........##.",
    "##............##",
    "##............##",
    "##............##",
    "##............##",
    "##............##",
    "##............##",
    ".##..........##.",
    "..############..",
    "...##########...",
    ".....######.....",
    "................",
]

# the middle frame with three 1 px dots on the centre row
PROCESSING = [("##...#..#..#..##" if i == 7 else r) for i, r in enumerate(RECORDING_1)]


def _slashed(rows):
    """The face with a two pixel diagonal bar from the bottom left to the top right and a one pixel gap on each side."""
    w, h = len(rows[0]), len(rows)
    line = {(w - 2 - i + dx, i) for i in range(-1, h + 1) for dx in (0, 1)}
    line = {(x, y) for x, y in line if 0 <= x < w and 0 <= y < h}
    g = [list(r) for r in rows]
    for x, y in line:
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            xx, yy = x + dx, y + dy
            if 0 <= xx < w and 0 <= yy < h and (xx, yy) not in line:
                g[yy][xx] = "."
    for x, y in line:
        g[y][x] = "#"
    return ["".join(r) for r in g]


# closed lips, struck through
UNAVAILABLE = _slashed(IDLE)

GLYPHS = {
    "idle": IDLE,
    "recording0": RECORDING_0,
    "recording1": RECORDING_1,
    "recording2": RECORDING_2,
    "processing": PROCESSING,
    "unavailable": UNAVAILABLE,
}
