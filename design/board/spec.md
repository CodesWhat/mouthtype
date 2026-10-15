# Pill marriage: spec

Open `prototype.html` to see all of this live. Everything below is read from the same code (`src/engine_*.js`); sizes are points (pt), 1 pt = 1 CSS px at 1x. Rebuild with `python3 -I build.py` (writes `prototype.html` and the dev-only `_sheets.html`).

## Recommendation

- **Default**: 2 Floating Matrix. Black capsule, round amber LED dots floating on the surface (no window), one red REC dot, M:SS clock only when locked.
- **Appearance**: follow the system. Dark = amber dots on the black body. Light = the same geometry on a light body with the readout set in an inset pager LCD window (green-grey face, dark ink, ghost dots). A floating amber readout cannot work on a light body, which is why light mode needs the window.
- **Work-machine option**: Minimal. Same silhouette, grid, controls, motion and clock rules, with the dots swapped for 10 plain rounded bars and system text.
- **Shape**: squircle for the LED default, and Minimal inherits it. Capsule is what every dictation pill already is; continuous corners with squircle controls make it read as a small device and are the one thing you can't mistake for the competitor.
- **Timer**: only when locked. Held shows `REC` (the clock would just add a second moving thing next to the meter).
- **Glass**: an LED readout survives on glass only as an opaque inset window, or on smoked glass. Dots floating on plain glass wash out over a light or busy background and fail at 1x.
- **Long messages**: LED pills scroll (marquee in a fixed-height readout). Minimal and the card grow taller.

Killed: 3 Two-Zone (the well and divider add parts without adding information), 5 Bargraph (reads level fine but loses the voice texture and is the least pager-like), 4 Full-Face LCD (looks like a calculator watch and loses the dark default). 1 Pager Window stays alive as the light-mode treatment.

## Silhouette

| Shape | Corner | Notes |
|---|---|---|
| capsule | radius H/2 = 15 pt | controls are 20 pt discs |
| in-between | radius 0.40 H = 12 pt | controls are rounded squares r = 8 |
| squircle | superellipse corner, exponent n = 4, extent 0.34 H x 1.32 = 13.5 pt | controls are squircles, 20 pt box |

The squircle is a real superellipse corner (|x|^n + |y|^n = 1, n = 4) joined to straight edges, 22 segments per corner; `shapePoly()` builds it once and it is used for the body, window, controls, glass clip and card. A taller pill (grow mode) keeps the corner of the 30 pt pill, so a capsule becomes a rounded rectangle and a squircle just gets taller.

## Sizes (pt)

| Pill | Height | Held | Locked | Message |
|---|---|---|---|---|
| Minimal | 30 | 108 | 155 | text width + 41, min 108 |
| 2 Floating Matrix | 30 | 108 | 155 | same |
| 1 Pager Window | 30 | 105 | 158 | same |
| 3 Two-Zone | 30 | 110 | 157 | same |
| 4 Full-Face LCD | 30 | 107 | 154 | same |
| 5 Bargraph | 28 | 115 | 163 | same |

Layout of the default, left to right: pad 12, indicator slot 10, gap 7, meter 38 (13 columns at 3 pt pitch, or 10 bars at 4 pt for Minimal), gap 7, label/clock slot 22 (REC) or 26 (0:00), then when locked 7, cancel 20, gap 3, finish 20, pad 5. Right pad held = 12.

## Chrome

- Dark body: gradient #252528 to #19191b; hairline 0.5 pt (min 1 device px) rgba(255,255,255,.15); inner top highlight rgba(255,255,255,.07); shadow y 4 pt blur 12 pt rgba(0,0,0,.5) plus contact shadow y .8 pt blur 2 pt rgba(0,0,0,.35).
- Light body: #fbfbfc to #e6e6ea; hairline rgba(0,0,0,.16); shadow rgba(0,0,0,.2).
- LCD window: inset 3 pt, face gradient #bfcaa6 to #aab691, inner shadow y 1.3 blur 3.2, top reflection rgba(255,255,255,.16) to 0 over the upper half. LED window face #0d0c0a.
- Glass (CSS approximation): a clip-path div behind the canvas with `backdrop-filter: blur(16px) saturate(1.9) brightness(1.05 light / 1.14 dark)`; tint white .46 to .26 over light content, rgba(34,34,40,.40) to rgba(12,12,16,.50) over dark or mid content; 0.8 pt specular rim, white .95 at top-left fading to .08 and back to .42 bottom-right; inner bottom shadow, lit inner top-left edge; ambient shadow only outside the body.
- Smoked glass: same, `blur(20px) saturate(1.5) brightness(.78)`, tint rgba(34,34,40,.56) to rgba(10,10,14,.66).
- This does not refract or lens the edge like real Liquid Glass. The app would use the system glass material (NSGlassEffectView) on macOS 26 and the solid body elsewhere; the readout window and controls sit on top of it unchanged.

## Colour

| Readout | Ink | REC dot | Error | Ghost alpha | Glow |
|---|---|---|---|---|---|
| Amber (default, dark) | #ffb327 | #ff4a3c | #ff4a3c | .11 | #ff9a10, 2.4 pt blur + 1.1 pt core |
| Red | #ff3d32 | #ff3d32 | #ff7a6e | .12 | #ff2a20 |
| Cool white | #e8f1ff | #ff4a40 | #ff5a4e | .10 | #78aefc |
| Pager LCD (light) | #1d2815 on #bfcaa6 | #1d2815 | #6e2312 | .09 | none |
| Minimal dark / light | #f4f3e8 / #1d1d1f | #ff453a / #e0281c | #ff6b5e / #d70015 | .45 on the idle dot | none |

## Readout geometry

- Default dot grid: 13 columns x 7 rows, dot 2 pt round, pitch 3 pt, centre-mirrored (a column lights an odd number of rows around the middle). Ghost dots always drawn at the ghost alpha; an idle column keeps its centre dot at 45%.
- Pager Window: 10 x 6 segments, 3 x 2 pt, pitch 4 x 3, bottom-up, 7-segment clock 6 x 11 pt (stroke 1.5 pt, ghost 8s).
- Minimal: 10 bars, 2 pt wide, 4 pt pitch, rounded caps, height = (2n - 1) x 3 - 1 pt, same n as the LED grid so the motion is identical.
- Text faces: 5x7 bitmap at 2 pt pitch (14 pt caps) for messages up to 156 pt; 3x5 at 2 pt pitch (10 pt caps) for REC, the dot clock and wrapped text. Dot gap is 0.5 pt at 2x and above, none at 1x (text turns into crisp 2 px pixels at 1x). Padlock 5x7 and X 5x5 are the same bitmaps; the check is 7x5.
- System text (Minimal, and the Sans/Rounded label options): REC 9.5 px 600 with 0.9 px tracking, clock 12 px 500 with fixed digit advance 7, message 13 px 600.

## Meter feed

One loudness 0..1 per frame. Column target = level x profile x offset where profile = 0.62 + 0.38 sin(pi (i + .5)/N) and offset is a per-column random 0.72..1.16 refreshed every 85 ms. Attack time constant 28 ms, release 140 ms (`1 - exp(-dt/tau)` per frame). Bargraph also keeps a peak hold (380 ms hold, then falls in 900 ms).

## Controls

20 x 20 pt hit area each (>= the 20 pt minimum), 3 pt apart. Cancel: 10% foreground disc/squircle with an X; hover 17%, pressed 26% and scale .93. Finish: filled with the readout ink (Minimal: off-white on dark, near-black on light) with a dark glyph; hover +20% white, pressed -22%. Finish glyph is a stop square (8 x 8 pt, r 1.2) or a check mark (7x5 dots / 1.9 pt stroke), selectable; my pick is the stop square while recording continues indefinitely and a check once the button means "accept". Cancel and finish both become 5 pt from the right edge.

## Timings (ms)

| Transition | Timing |
|---|---|
| Appear | 260 ms ease-out cubic: opacity 0 to 1, scale .90 to 1, rises 5 pt. Readout "segment test" (all dots lit) 110 to 200 ms |
| Hide | 160 ms ease-in: fade, scale to .90, drop 5 pt |
| Width and height change | critically damped, tau 55 ms (95% at about 165 ms) |
| Element fade in / out | 120 ms in, after a 70 ms delay (so the pill has grown first); 50 ms out |
| Hold to locked | width tween about 165 ms; padlock replaces dot, clock replaces REC, controls scale .85 to 1 and fade in |
| REC dot | breathes between 78% and 100% on a 2000 ms sine |
| Processing | scanner column with a 3-column falloff bounces over 900 ms; the dot pulses at about 1.6 Hz; three dots step every 220 ms in the label slot |
| Message | content swaps in 120 ms (after the 70 ms delay); no auto-hide in the demo unless ticked, 1400 ms + 800 ms when ticked |
| Error | dot flashes at 180 ms steps for about 1.1 s, then holds |
| New record | 0 to 320 ms the meter fills left to right (wave) with width tween, 320 to 720 ms "NEW BEST" blinks twice (100 ms steps), glow x1.9 decaying over 260 ms, star and plus sparkle alternate every 180 ms, a diagonal highlight sweeps once 260 to 900 ms; total about 1000 ms |
| Marquee (scroll) | pause 700 ms, scroll at 36 pt/s, pause 900 ms, jump back, repeat; viewport 140 pt (LED, 5x7 face) or 150 pt (plain) |
| Grow | wrapped to 148 pt (LED 3x5 face) or 150 pt (plain), H = 16 + 10 n + 4 (n - 1) for LED, 14 + 16 n plain, animated with the width tau |

## Vector, bitmap, animated

| Element | Kind | Animates |
|---|---|---|
| Body, stroke, shadow, window, controls, glass | vector (CAShapeLayer / system material) | width, height, alpha, scale |
| Meter dots / bars | LED: rounded-rect or circle layers on a fixed grid; Minimal: vector bars | per-column height every frame |
| REC, messages, clock (dot face) | bitmap 5x7 and 3x5, scaled nearest-neighbour | alpha, scroll offset |
| Padlock, X, check, star | bitmap | alpha, twinkle |
| 7-segment clock (LCD) | vector polygons | digit change |
| Glow | blurred duplicate of the lit layer (or shadow on the lit layer) | strength on new record |
| Indicator dot | vector circle plus glow | breathing, error flash |

## Delivery card (paste failed and friends)

Sits 8 pt above the pill, same corner family and material, no tail. Face 224 pt wide (pill centred under it); padding 11 / 12 / 12 pt; shape hr = 30 so corners match the pill. Content: header row (accent dot 6 pt, reason, 20 pt dismiss), transcript 13/18 px system face (never the display face), up to 5 lines (90 pt) then it scrolls inside, buttons right-aligned, 26 pt high, min 64 pt wide, radius 13 / 10 / 8 by shape. One card at a time, driven by the same pill (it shows the matching short message).

| Case | Reason | Actions |
|---|---|---|
| Paste failed | Couldn't paste. Your text is safe. | Copy |
| No field focused | No text field was focused. | Copy |
| Secure field | Secure field, so nothing was pasted. | Copy |
| Cancelled | Dictation cancelled. | Undo (5 s countdown in the label and a 2 pt bar) |
| Crash recovery | Recovered a dictation. | Insert, Copy |

Timings: card in 200 ms (opacity .18 s, rises 10 pt, slight overshoot); Copy changes the label in place to "Copied" with a check, the pill says Copied, the card leaves after 900 ms. Undo auto-dismisses at 5000 ms. Failures stay until dismissed or acted on. Copy writes with `navigator.clipboard` and falls back silently to `execCommand`.

Label face on the LED card (control in the prototype): status strip in a small dark display chip set in the chosen face (dot matrix with ghost dots, solid pixel, 14-segment) over a one-line system sentence; or Rounded or Sans sentence case with only the accent dot in amber. Buttons are calm by default (off-white primary, grey secondary, system face); amber primary is a toggle. My pick: dot matrix strip (the pill's own face, so the card header reads as a second small display) with calm buttons. Hi-fi skin: the card would become a dark plate with the same bevelled edge and a VFD strip for the header, buttons as the silver square keys.

Faces to bundle: dot matrix (5x7, 3x5) and the check/padlock glyphs are ours and already exist as bitmaps; the 14-segment face is stroke maps in code (about 40 lines). If we want a real typeface instead, candidates (SIL OFL, from memory and unverified, nothing downloaded here): Departure Mono, Doto (a dot-matrix variable font), Silkscreen. Confirm licence and glyph coverage before adopting.

## Prototype notes

- `prototype.html` is one file with no network access, and opens from `file://`. The microphone button uses `getUserMedia` and falls back to the simulation silently if blocked.
- Reference pills (Classic, Hi-Fi) are approximations drawn from the screenshots.
- Sheets and state PNGs are rendered from the same engine in a headless browser, not from the Python renderer originally suggested, so what you see in the PNGs is exactly what the prototype draws.

## Text font (ordinary text only)

The Text font control sets the face for everything that is not an LED display: Classic's messages, Minimal's messages, `REC` and clock, and all text in the delivery cards (reason, transcript, button labels). The LED dot-matrix readouts, and the status strip on the LED card, keep the separate Label font control.

- Options: System (SF Pro), System Rounded, System Serif (New York), System Mono, then Avenir Next, Helvetica Neue, Futura, Gill Sans, Optima, Charter, Georgia, Palatino, American Typewriter, Courier New, Menlo, Monaco, each listed in its own face with fallbacks. "Any installed font" takes a family name and applies live; if it isn't installed it falls back to System with a small note. Detection compares canvas text widths against the generic families because `document.fonts.check()` answers true for unknown families.
- Weight Regular 400, Medium 500, Semibold 600 (default 600) applies to messages, `REC`, headers and buttons; the clock uses min(weight, 500); the transcript stays 400. Size nudge -1, 0, +1 pt applies to every role (message 13, REC 9.5, clock 12, Classic 12, card body 13, header 12, buttons 12, sub-line 11.5).
- Layout: pills measure with the chosen face and size (`measure()` against the real font string), so message width, wrapped line count, line height (max(16, 1.25 x size)), the `REC` slot and the clock slot all follow it; cards use DOM layout, so they wrap and grow with any face. Glyphs are centred on cap height (`fillTextC`), not the em box, so serif, rounded and mono faces all sit optically centred in the pill. Fonts are re-measured on `document.fonts.ready` and on every change. Choices persist in `localStorage` key `pm.textfont`.
- In the app: a "Text font" setting choosing among the system designs through `NSFont.systemFont(ofSize:weight:)` with a font design (default, rounded, serif, monospaced via `NSFontDescriptor.withDesign`), plus any installed family through the standard font picker (`NSFontPanel`) or `NSFont(name:size:)`. Default stays System. Measure with the resolved `NSFont` and re-lay-out when it changes.

## Systema set and fonts to bundle

The Text font list leads with three embedded faces from the sibling SystemaMachinae project (base64 `@font-face`, latin subsets only, read from its `node_modules`, nothing downloaded): Instrument Serif 400 (21 KB), Instrument Sans variable `wght` (30 KB), JetBrains Mono variable `wght` (40 KB). They add about 127 KB to `prototype.html`, which is now about 223 KB in total. Two installed families appear as "installed on this Mac" entries and are dimmed if missing: JetBrainsMono Nerd Font and Geist Mono. Embedded faces are loaded with `document.fonts.load()` before pills are measured, and pills and cards are re-measured when loading completes.

**Systema set** (one click): pill messages and Classic messages and card headers in Instrument Serif at 15 pt (pills) / 14 pt (Classic) / 15 px (card header), a couple of points above the 13 / 12 / 12 sans equivalents because it runs small and light, always at weight 400 (it has one weight, so bold is never requested or synthesised); card body, transcript, sub-line and buttons in Instrument Sans (weight and nudge controls still apply); `REC` (9 pt), clocks (11 pt) and the Undo countdown in JetBrains Mono 500, whose figures are tabular, with the clock and `REC` slots widened to the measured width. The LED card's Label font gained a JetBrains Mono option (sentence case, 500, neutral colour with the amber accent dot) as a cleaner alternative to the generic monospace.

Fonts to bundle in the app (licence statements to verify before bundling):
- Instrument Serif, Instrument Sans and JetBrains Mono are SIL Open Font License 1.1, as shipped by `@fontsource`. To verify: the OFL text and each copyright line ship alongside the fonts (for example in an acknowledgements file and the bundle), the reserved font names are respected (do not rename or sell the fonts on their own, no subsetting that keeps the name unless the licence allows it), and bundling them in a GPL-3.0 app is fine because the OFL permits embedding in software under another licence.
- App size: three latin woff2 files are about 91 KB; macOS needs them as TTF/OTF registered through `ATSApplicationFontsPath` or `CTFontManagerRegisterFontsForURL`, so budget more than the woff2 size.
- A Nerd-patched build is only worth it for its icon glyphs, which the app doesn't need (it has its own pixel pictograms). It is several times larger, and its icon sets carry mixed licences that would have to be checked first. The plain JetBrains Mono above covers the letterforms. The Nerd Font and Geist Mono entries in the prototype exist so the look can be judged on this Mac only; they are not embedded.

## Open questions

1. Squircle versus capsule is a taste call; the prototype can't settle it for you, the Shape control can.
2. Should Minimal be a user preference (Settings) or a managed-device default?
3. Hi-Fi remains as a skin? The delivery card and glass have no hi-fi version beyond the sentence above.
4. Does the clock need to appear on the held pill for very long dictations (past about a minute)?
5. Error colour on the LCD face: red-brown ink is legible but weak; a blinking full-face invert might be clearer.
