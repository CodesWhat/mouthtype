"""Builds prototype.html from src/. Run from anywhere: python3 -I design/board/build.py

The three typefaces are read from the fonts the app bundles
(Sources/MouthtypeMac/Resources/Fonts) and embedded as base64 TTF, so the board rebuilds from this repo alone.
All three are SIL OFL 1.1, embedded unmodified; their licences sit beside the font files.
"""
import base64
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import font  # noqa: E402  the 5x7 and 3x5 bitmap faces

src = os.path.join(here, 'src')
FONT_DIR = os.path.join(here, '..', '..', 'Sources', 'MouthtypeMac', 'Resources', 'Fonts')
FONTS = [
    ('Instrument Serif', 'InstrumentSerif-Regular.ttf', '400'),
    ('Instrument Sans', 'InstrumentSans-Regular.ttf', '400'),
    ('Instrument Sans', 'InstrumentSans-Medium.ttf', '500'),
    ('Instrument Sans', 'InstrumentSans-SemiBold.ttf', '600'),
    # One static weight is bundled; the prototype asks for 500 only, so let it serve the whole range.
    ('JetBrains Mono', 'JetBrainsMono-Medium.ttf', '100 800'),
]


def fontface():
    out = []
    for family, name, weight in FONTS:
        with open(os.path.join(FONT_DIR, name), 'rb') as f:
            data = base64.b64encode(f.read()).decode()
        out.append("@font-face{font-family:'%s';font-style:normal;font-weight:%s;font-display:block;"
                   "src:url(data:font/ttf;base64,%s) format('truetype')}" % (family, weight, data))
    return '\n'.join(out)


def rd(name):
    with open(os.path.join(src, name)) as f:
        return f.read()


def spec(face):
    return {k: '/'.join(v) for k, v in face.items() if k != ' '}


fonts = 'const F5SPEC=%s;const F3SPEC=%s;' % (json.dumps(spec(font.F5)), json.dumps(spec(font.F3)))
head = rd('engine_head.js').replace('/*FONTS*/', fonts)
js = head + rd('engine_dirs.js') + rd('engine_text.js') + rd('engine_pill.js') + rd('util.js') + rd('card.js') + rd('page.js')
html = rd('template.html').replace('/*CSS*/', fontface() + rd('style.css')).replace('/*JS*/', js.replace('</script>', '<\\/script>'))
with open(os.path.join(here, 'prototype.html'), 'w') as f:
    f.write(html)
print('prototype.html', len(html), 'bytes')
