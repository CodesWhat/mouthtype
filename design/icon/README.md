# App icon and menu bar glyphs

The caret lips mark: red pixel-art lips, slightly parted, with a cream text cursor in the dark opening, on an orange
rounded-square tile with a fine dither texture. The art is original to this project.

The tile is full-bleed: a flat #F19A4B square with a light Bayer dither as texture, no baked shadow and no drawn
corners. macOS 26 supplies the squircle mask, depth and highlight. The lips are 78% of the tile width: the 36 unit
sprite at 22x on the 1024 px master (792 px). 512, 256 and 128 px are box filtered from the master. 64 px is the 25 px
wide 32 sprite at 2x, and 32 and 16 px are separate small drawings (`LIPS32`, `LIPS16`), all on the pixel grid.

`AppIcon.icon` is the Icon Composer bundle for macOS 26: a document fill (orange, charcoal in Dark), a transparent
dither layer named `tile`, and the `lips` layer. Clear and Tinted hide `lips` and show `lips-mono`, the one colour lips
with the mouth and cursor knocked out. `scripts/build-app.sh` compiles it with `xcrun actool` into `Assets.car`
(`CFBundleIconName`); the `.icns` stays as the fallback (`CFBundleIconFile`). Preview any appearance with Icon Composer's
`ictool AppIcon.icon --export-image --platform macOS --rendition Dark|Default|TintedLight|ClearDark ...`.

`export.py` writes `AppIcon.iconset/`, `AppIcon-1024.png` and `AppIcon.icon/` here, builds `packaging/AppIcon.icns` with `iconutil` (macOS
only), and writes the menu bar glyphs to `Sources/MouthtypeMac/Resources/MenuBar/`: one template glyph per status
state (idle, three recording frames, processing, unavailable) at 16 x 15 and 32 x 30: the caret-free lips, closed when idle, open with the voice while
recording, the middle frame with three dots while processing and closed lips struck through when unavailable. The generated files are checked in, so the app
builds without Python.

Regenerate after changing the art (Python 3, standard library only; output is deterministic):

    python3 -I design/icon/export.py

`sprites.py` holds the lips at the three tile sizes and the mono variant, `glyphs.py` the menu bar glyphs, `canvas.py` the pixel canvas and PNG writer.
