# Pill art

Source for the hi-fi dictation pill: a 146 x 32 pixel-art slab with a TALK button, REC lamp, amber VFD meter and
timer window, and cancel and stop caps. The art is original to this project.

`export.py` draws everything at 1x (one art pixel per point) and writes the shipped assets to
`Sources/MouthtypeMac/Resources/Pill/hifi/`: `chassis.png`, the state sprites, the two font atlases and
`layout.json` (positions, meter geometry, text slots, colours). The generated files are checked in, so the app
builds without Python.

Regenerate after changing the art (Python 3, standard library only; output is deterministic):

    python3 -I design/pill/export.py

`canvas.py` is the pixel canvas and PNG writer, `font.py` the 5x7 and 3x5 bitmap faces, `palette.py` the colours.
