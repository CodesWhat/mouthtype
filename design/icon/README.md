# App icon and menu bar glyphs

The caret lips mark: red pixel-art lips, slightly parted, with a cream text cursor in the dark opening, on an orange
rounded-square tile with a fine dither texture. The art is original to this project.

The icon is drawn on a 64 unit grid and scaled 16x to a 1024 px master. The tile is 52 units (832 px), centred, with
its drop shadow inside the canvas. 512, 256, 128 and 64 px are box filtered from the master by an integer factor, so
every art pixel stays an even square. 32 and 16 px are separate small drawings, because the 64 unit art turns to mush
below 64 px.

`export.py` writes `AppIcon.iconset/` and `AppIcon-1024.png` here, builds `packaging/AppIcon.icns` with `iconutil` (macOS
only), and writes the menu bar glyphs to `Sources/MouthtypeMac/Resources/MenuBar/`: one template glyph per status
state (idle, recording, processing, unavailable) at 16 x 15 and 32 x 30: a classic smiley, outlined when idle, solid while
recording, with three dots for a mouth while processing and a struck-through flat face when unavailable. The generated files are checked in, so the app
builds without Python.

Regenerate after changing the art (Python 3, standard library only; output is deterministic):

    python3 -I design/icon/export.py

`sprites.py` holds the lips at the three tile sizes, `glyphs.py` the four glyphs, `canvas.py` the pixel canvas and PNG writer.
