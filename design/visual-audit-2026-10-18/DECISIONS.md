# Mouthtype visual audit · locked decisions

Source: `visual-audit.dc.html` · repo main @ 8d70284 (v0.1.0-rc.1) · 18 Oct 2026

## Locked

### 1d · Menu bar glyph: caret-lips silhouette, opens with the voice
- 16×15 pt template image, 1× and 2× from the same art (same pipeline as `design/icon/glyphs.py` → `Resources/MenuBar/`).
- Idle: closed lips (the `B_CLOSED` bitmap in the audit, 1 px seam).
- Recording: mouth opens with the smoothed level the pill already computes; three frames `D_REC0 / D_REC1 / D_REC2`. Reduce Motion pins the middle frame.
- Processing: `D_REC1` with three 1 px dots on the centre row.
- Unavailable: closed lips, struck through with the existing `_slashed()` two-pixel bar.
- No caret inside the mouth. The I-beam stays on the app icon only.
- Replaces the smiley; the smiley is not kept as an option.

### 1j · Pill size: Automatic / Standard / Large, both skins
- New setting `pillSize` (Appearance): Automatic (default) · Standard · Large.
- Automatic resolves at show time from the screen PillPlacement already picks (the pointer's screen): Large when `visibleFrame.width >= 2000 pt`, otherwise Standard.
- Hi-Fi: integer art scale only (1× = 146×32 pt, 2× = 292×64 pt). Replaces `HiFiPillSize` / `hiFiPillSize`; migrate `large` → `pillSize = large`.
- Classic Large: 2× geometry — 56 pt height, 4.5 pt bar width, 8.5 pt pitch, 28.5 pt max bar, 36 pt controls, message face 28 / detail 22 pt, padding doubled. Bars stay snapped to even device pixels.
- Points, not pixels: nothing changes physical size per display density; Automatic only addresses proportion on large screens.

### 1e + 1f + 1g · Pill styles: all three ship, user picks
- `PillSkinKind` grows from `classic, hifi` to `classic, glass, matrix, minimal, hifi`. **Default stays Classic** (confirmed).
- Appearance → Pill style becomes a five-way picker (menu section `PillSkinMenuSection` follows).
- **Glass (1e):** Classic geometry and bars unchanged; body = NSGlassEffectView (clear over light content, smoked over dark), rim = specular edge; Stop control stays solid #FCFCFB; falls back to the solid Classic body when the system material is unavailable or the wallpaper fails a contrast check.
- **Matrix (1f):** spec.md "2 Floating Matrix": 30 pt squircle (superellipse n=4, corner 13.5 pt), body #252528→#19191B, 13×7 amber dot matrix (#FFB327, ghost α .11, glow #FF9A10), REC lamp #FF4A3C breathing 2 s, M:SS in JetBrains Mono only when locked, 20 pt squircle controls (cancel 10% fg, finish amber). Padlock → 9 px lips sprite. Light appearance = pager LCD window (#BFCAA6 face, #1D2815 ink).
- **Minimal (1g):** same silhouette, grid, controls and motion as Matrix; ten plain 2 pt bars at 4 pt pitch; system text (REC 9.5 pt 600, clock 12 pt 500, message 13 pt 600). Follows system appearance: light body #FBFBFC→#E6E6EA with 0.5 pt hairline rgba(0,0,0,.16), ink #1D1D1F, REC #E0281C; dark body as Matrix, ink #F4F3E8, REC #FF453A.
- All three honour 1j (Standard / Large) and the existing Reduce Motion paths.

### 1k + 1l + 1m · Delivery card follows the pill style
- The card is drawn by the active skin, not by one shared DeliveryCardView. CardLayout numbers (224 pt, 11/12/12 insets, 26 pt buttons, five-line transcript cap, 3 pt countdown bar) stay shared.
- **Classic:** today's card, with the two fixes from 1k: 24 pt dismiss; the pill under a card shows the detail line ("Your text is safe") instead of repeating the header.
- **Glass (1k):** same layout on the glass material; question cards use the amber accent (#FFB327) so the dot reads; secondary buttons are glass chips.
- **Matrix (1l):** one object. The pill grows upward into the card: one squircle (corner 16), one shadow, Matrix body gradient; readout row stays at the bottom and keeps saying the short thing (SAFE, Undo clock); primary button amber squircle. Dismiss shrinks it back to a pill. New panel-sizing path in PillController.
- **Minimal (1m):** 1l structure, Minimal body. Light appearance: #FBFBFC→#F0F0F3, 0.5 pt hairline, ink #1D1D1F, error #D70015, "good news" dot in #315B54. Dark: Minimal dark body, ink #F4F3E8.
- **Hi-Fi:** no card variant. Hi-Fi keeps today's dark Classic-coloured card (with the 24 pt dismiss and detail-line fixes).

### 1p · App icon: bigger lips, dither kept, Tahoe-safe tile
- Lips scaled from ~56% to 78% of the tile width (100 px of 128). New small sprites, same palette (k #1A1A1A · r #D8432C · p #F4846A · R #A02A1C · w #FFFFEB), drop-in for `LIPS32` / `LIPS16` in `design/icon/sprites.py`:

```python
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
```
- Tile #F19A4B full-bleed to the system squircle mask; baked pixel drop shadow and hand-drawn corners removed (the system supplies depth and the mask).
- Light dither kept as texture (never as shadow).
- Export as Icon Composer layers (tile, lips) so Dark / Clear / Tinted render; 1o's monochrome lips (cursor knocked out) are the Clear/Tinted glyph.

### 1q + 1s · Settings: Tahoe grouped forms, glass sidebar
- Window 900×620, min 860×600, no scroll on General.
- Sidebar 210 pt, Tahoe glass material, traffic lights inside it; mark 28 pt + wordmark Instrument Serif 24; pages General / Writing / Appearance / Diagnostics; "YOUR WORDS" group: Saved spellings, Phrases (replaces the two sidebar buttons); footer "ON YOUR MAC · <version>" in JetBrains Mono 10.
- Content: 22 pt serif title + 12.5 pt description in a 46 pt header bar; Form(.grouped) inset groups, 36–40 pt rows, inset hairlines; group eyebrows in JetBrains Mono 10 (never below 10 pt).
- General groups: INPUT (Microphone, Dictation shortcut, Recording behavior) · CLEANUP (level + model status + Download…) · WHILE RECORDING (Quiet other audio, Live words, Recording sounds) · MAC (Launch at login as a toggle, Updates). "Set Up Mouthtype…" moves to a sidebar entry.
- Accent: brand green #315B54 (light) / #4F8F82 controls, #8FC1B5 symbols (dark) instead of system blue.
- Appearance (1s): live PillSkinView preview over a wallpaper swatch (not a rendered PNG); Pill style five-way (Classic · Glass · Matrix · Minimal · Hi-Fi); Pill size (1j); Readout colour (Hi-Fi only, from 1i: Amber / Cool white / Red); Text font. Full Dark appearance parity.

### 1t · First-run setup: glass sheet with step dots
- Window sized to content (~560×440), glass material, traffic lights inside.
- Four step dots (active 18×5 pt pill, #315B54) replace "STEP n OF 4"; footer names all four steps in JetBrains Mono.
- Lips sprite (36×22 at 1.5×) replaces the SF symbol tile on every step.
- No Refresh status button: status polls while the window is key (windowDidBecomeKey already refreshes).
- Copy unchanged except the microphone step adds "Audio stays on this Mac."

## Open (not yet picked)
- 04 Hi-Fi: 1h glass shelf (declined for now) · 1i readout colour (adopted via 1s as a Hi-Fi-only setting)
- 09 Website hero: 1w desktop crop · 1x type-led · 1y dark editorial
