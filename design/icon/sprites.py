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

# 25 x 19, for the 32 pixel tile, a one pixel stem cursor with 3 px serifs
LIPS32 = symc([
    ".....kkkk....",
    "...kkrrrrkkk.",
    "..krrrrpprrrr",
    ".krrrrrrrrrrr",
    "krrrrrrrrrrrr",
    "krrrrrkkkkkkk",
    "krrrkkkkkkkww",
    "krrkkkkkkkkkw",
    "krkkkkkkkkkkw",
    "kkkkkkkkkkkkw",
    "krkkkkkkkkkkw",
    "krrkkkkkkkkkw",
    "krrrkkkkkkkww",
    "krrrrrkkkkkkk",
    "krrrrrrrrrrrr",
    ".krrrrrrrpprr",
    "..kkrrrrrrRRR",
    "....kkrrRRRRR",
    "......kkkkkkk",
])

# 12 x 11, for the 16 pixel tile: two pixel stem, cupid's bow kept
LIPS16 = sym([
    "..kkk.",
    ".krrrk",
    "krrrrr",
    "krrkkk",
    "kkkkww",
    "kkkkkw",
    "kkkkww",
    "krrkkk",
    "krrrrr",
    ".krrrR",
    "..kkkk",
])


def mono(rows):
    """The one colour lips for the Clear and Tinted appearances: the red body only, so the mouth opening and
    the cursor are knocked out (transparent) and the system supplies the colour."""
    return ["".join("W" if ch in "rpR" else "." for ch in row) for row in rows]
