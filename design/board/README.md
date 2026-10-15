# Pill board

The live prototype board for the dictation pill: looks, materials, shapes, delivery cards and text fonts, all drawn
by the same engine in one page. It's kept so future skins can be designed against it before any Swift is written.

Open `prototype.html` in a browser (no network, works from `file://`). `spec.md` is the written spec read off the same
code: sizes, radii, colours, timings, the card, the Text font roles. The app's Classic pill, message layout and
delivery card follow it; where the app differs on purpose, the commit that changed it says why.

## Rebuild

    python3 -I -B design/board/build.py

That reads `src/` and writes `prototype.html`. `font.py` is the 5x7 and 3x5 bitmap faces the LED looks use.

## Fonts

The page embeds three typefaces as base64 TTF, read at build time from `Sources/MouthtypeMac/Resources/Fonts/` (the
files the app bundles): Instrument Serif, Instrument Sans and JetBrains Mono. All three are SIL Open Font License 1.1,
embedded unmodified, and stay under the OFL. Their licence texts are beside the font files and listed in
`THIRD_PARTY_NOTICES.md`.

## Size

About 1 MB on disk, nearly all of it `prototype.html` (900 KB, of which about 800 KB is the embedded fonts). The generated
PNG sheets and per-state shots are not kept; open the page to see them live.
