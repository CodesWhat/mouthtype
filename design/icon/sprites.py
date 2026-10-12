"""The caret lips sprites. Rows of palette letters, '.' is empty, one letter is one square pixel."""


def sym(half):
    """Mirror an even-width design: each row is its left half."""
    return [r + r[::-1] for r in half]


def symc(half):
    """Mirror an odd-width design: the last column of each row is the centre."""
    return [r + r[-2::-1] for r in half]


PALETTE = dict(k="#1A1A1A", r="#D8432C", p="#F4846A", R="#A02A1C", w="#FFFFEB")

# 36 x 22, for the 64 unit tile
LIPS64 = sym([
    "..................",
    "..........kkkk....",
    "........kkrrrrkk..",
    "......kkrrpprrrrkk",
    "....kkrrrpprrrrrrk",
    "..kkrrrrrrrrrrrrrr",
    ".krrrrrrrrrrrrrrrr",
    "krrrrrrrrrrrrrrrrr",
    "krrrrrrrrkkkkkkkkk",
    "krrrrkkkkkkkkkwwww",
    "krrkkkkkkkkkkkkkkw",
    "kkkkkkkkkkkkkkkkkw",
    "krrkkkkkkkkkkkkkkw",
    "krrrrkkkkkkkkkwwww",
    "krrrrrrrrkkkkkkkkk",
    "krrrrrrrrrrrrrrrrr",
    "krrrrrrrrrppppprrr",
    ".krrrrrrrrrrrrrrrr",
    "..kkrrrrrrrrrrrrrr",
    "....kkrrrrrrrrRRRR",
    "......kkrrRRRRRRRR",
    "........kkkkkkkkkk",
])[1:]  # the first row is blank padding

# 21 x 17, hand-drawn for the 32 pixel tile, a one pixel stem cursor
LIPS32 = symc([
    "....kkkk...",
    "..kkrrrkkk.",
    ".krrrrrrrrr",
    "krrrrrrrrrr",
    "krrrrkkkkkk",
    "krrkkkkkwww",
    "krkkkkkkkkw",
    "kkkkkkkkkkw",
    "krkkkkkkkkw",
    "krrkkkkkwww",
    "krrrrkkkkkk",
    "krrrrrrrrrr",
    "krrrrrrpprr",
    ".krrrrrrrrr",
    "..kkrrrrrRR",
    "....kkRRRRR",
    "......kkkkk",
])

# 9 x 9, for the 16 pixel tile: the cursor keeps its serifs, the rest is the bare minimum of lips
LIPS16 = symc([
    "..kk.",
    ".krrr",
    "krrrr",
    "kkkww",
    "kkkkw",
    "kkkww",
    "krrrr",
    ".krrr",
    "..kkk",
])
