"""Menu bar glyphs, one per status state. 16 x 15, '#' is template ink and '.' is clear. The 2x file is the same
art doubled, which is exact for pixel art. A classic smiley: outlined when idle, solid while recording."""

IDLE = [
    ".....######.....",
    "...##......##...",
    "..#..........#..",
    ".#............#.",
    ".#...##..##...#.",
    "#....##..##....#",
    "#..............#",
    "#..............#",
    "#..#........#..#",
    "#..##......##..#",
    ".#..########..#.",
    ".#............#.",
    "..#..........#..",
    "...##......##...",
    ".....######.....",
]

# solid face with the eyes and smile knocked out: "on"
RECORDING = [
    ".....######.....",
    "...##########...",
    "..############..",
    ".##############.",
    ".####..##..####.",
    "#####..##..#####",
    "################",
    "################",
    "###.########.###",
    "###..######..###",
    ".###........###.",
    ".#####....#####.",
    "..############..",
    "...##########...",
    ".....######.....",
]

# the smile becomes three typing dots, 1 px so they don't read as a die face against the 2 x 2 eyes
PROCESSING = IDLE[:6] + [
    "#..............#",
    "#..............#",
    "#..............#",
    "#..............#",
    ".#..#..#..#...#.",
    ".#............#.",
] + IDLE[12:]


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


# a flat mouth, struck through
UNAVAILABLE = _slashed(IDLE[:8] + ["#..............#", "#..##########..#", ".#............#.", ".#............#."] + IDLE[12:])

GLYPHS = {"idle": IDLE, "recording": RECORDING, "processing": PROCESSING, "unavailable": UNAVAILABLE}
