"""Checks for the pill's delivery-card colours: contrast, the lime restraint rules, and the JS helpers. No Qt needed."""
import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEXT = (HERE / "CardPalette.js").read_text()
VAR_RE = r"var %s = \{(.*?)\n\}"
FIELD_RE = re.compile(r'(\w+):\s*("#[0-9A-Fa-f]{6}"|[0-9.]+|true|false|"\w*")')
VARS = {"classic": "CLASSIC", "minimal-dark": "MINIMAL_DARK", "minimal-light": "MINIMAL_LIGHT"}
# The Mac accent each palette would sit beside: lime is #A6CD52 on dark and #76A11A on light. Classic is dark.
ACCENT = {"classic": "#D3E58B", "minimal-dark": "#D3E58B", "minimal-light": "#D3E58B"}
LIME = {(0x76, 0xA1, 0x1A), (0xA6, 0xCD, 0x52), (0xD3, 0xE5, 0x8B)}


def load():
    out = {}
    for key, var in VARS.items():
        block = re.search(VAR_RE % var, TEXT, re.S).group(1)
        out[key] = {name: json.loads(raw) for name, raw in FIELD_RE.findall(block)}
    return out


def rgb(hexed):
    return tuple(int(hexed[i:i + 2], 16) for i in (1, 3, 5))


def over(fg, alpha, bg):
    return tuple(fg[i] * alpha + bg[i] * (1 - alpha) for i in range(3))


def luminance(c):
    def lin(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(v) for v in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def blend(a, b, fraction):
    return tuple(a[i] + (b[i] - a[i]) * fraction for i in range(3))


def primary_fill(p, hovered, pressed):
    base, white, black = rgb(p["primaryFill"]), (255, 255, 255), (0, 0, 0)
    if p["primaryLightens"]:
        return blend(base, white, 0.40 if pressed else 0.25 if hovered else 0)
    return blend(base, black, 0.18) if pressed else blend(base, white, 0.5) if hovered else base


def hue(c):
    r, g, b = (v / 255 for v in c)
    hi, lo = max(r, g, b), min(r, g, b)
    if hi == lo:
        return 0.0
    d = hi - lo
    h = ((g - b) / d) % 6 if hi == r else (b - r) / d + 2 if hi == g else (r - g) / d + 4
    return h * 60


def bodies(p):
    """The card body at its top and bottom, over both black and white: a translucent body shifts with what is behind it."""
    return [over(rgb(p[k]), p["bodyAlpha"], page) for k in ("bodyTop", "bodyBottom") for page in ((0, 0, 0), (255, 255, 255))]


STATES = ((False, False), (True, False), (False, True))


class CardContrast(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.palettes = load()

    def test_all_three_palettes_define_the_same_fields(self):
        keys = [set(p) for p in self.palettes.values()]
        self.assertEqual(keys[0], keys[1])
        self.assertEqual(keys[0], keys[2])

    def test_message_text_reaches_4_5(self):
        for name, p in self.palettes.items():
            for body in bodies(p):
                for field in ("text", "error", "quiet", "secondaryText"):
                    with self.subTest(palette=name, field=field):
                        self.assertGreaterEqual(ratio(rgb(p[field]), body), 4.5)

    def test_detail_line_reaches_4_5_at_its_alpha(self):
        for name, p in self.palettes.items():
            for body in bodies(p):
                with self.subTest(palette=name):
                    got = ratio(over(rgb(p["text"]), p["detailAlpha"], body), body)
                    self.assertGreaterEqual(got, 4.5, f"{name} detail is {got:.2f}:1")

    def test_status_dot_reaches_3(self):
        for name, p in self.palettes.items():
            for body in bodies(p):
                for field in ("warn", "quiet"):
                    with self.subTest(palette=name, field=field):
                        self.assertGreaterEqual(ratio(rgb(p[field]), body), 3.0)

    def test_primary_label_reaches_4_5_in_every_state(self):
        for name, p in self.palettes.items():
            for hovered, pressed in STATES:
                with self.subTest(palette=name, hovered=hovered, pressed=pressed):
                    got = ratio(rgb(p["primaryText"]), primary_fill(p, hovered, pressed))
                    self.assertGreaterEqual(got, 4.5, f"{name} primary hover={hovered} press={pressed} is {got:.2f}:1")

    def test_minimal_primary_gains_contrast_on_hover_and_press(self):
        for name in ("minimal-dark", "minimal-light"):
            p = self.palettes[name]
            label = rgb(p["primaryText"])
            rest, hover, press = (ratio(label, primary_fill(p, h, d)) for h, d in STATES)
            self.assertLess(rest, hover, name)
            self.assertLess(hover, press, name)

    def test_secondary_label_reaches_4_5_on_its_tint(self):
        for name, p in self.palettes.items():
            for body in bodies(p):
                for alpha in (p["tintRest"], p["tintHover"], p["tintPress"]):
                    with self.subTest(palette=name, alpha=alpha):
                        ground = over(rgb(p["tint"]), alpha, body)
                        self.assertGreaterEqual(ratio(rgb(p["secondaryText"]), ground), 4.5)


class LimeRestraint(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.palettes = load()

    def test_minimal_lime_is_the_mac_accent(self):
        self.assertEqual(rgb(self.palettes["minimal-light"]["primaryFill"]), (0xD3, 0xE5, 0x8B))
        self.assertEqual(rgb(self.palettes["minimal-dark"]["primaryFill"]), (0xD3, 0xE5, 0x8B))

    def test_only_minimal_light_wears_the_primary_edge(self):
        for name, p in self.palettes.items():
            self.assertEqual(p["primaryEdge"], "#4A6A12" if name == "minimal-light" else "", name)

    def test_lime_appears_only_as_the_primary_fill(self):
        for name, p in self.palettes.items():
            for field, value in p.items():
                if isinstance(value, str) and value.startswith("#") and field != "primaryFill":
                    self.assertNotIn(rgb(value), LIME, f"{name}.{field} wears lime")

    def test_classic_has_no_lime(self):
        self.assertNotIn(rgb(self.palettes["classic"]["primaryFill"]), LIME)

    def test_recording_red_is_distinct_from_the_accent(self):
        for name, p in self.palettes.items():
            gap = abs(hue(rgb(p["rec"])) - hue(rgb(ACCENT[name])))
            gap = min(gap, 360 - gap)
            self.assertGreater(gap, 60, f"{name}: rec and accent are {gap:.0f} degrees apart")

    def test_recording_red_reaches_3_on_the_body(self):
        for name, p in self.palettes.items():
            for body in bodies(p):
                self.assertGreaterEqual(ratio(rgb(p["rec"]), body), 3.0, name)


@unittest.skipUnless(shutil.which("node"), "node not installed")
class JsHelpers(unittest.TestCase):
    def run_js(self, file, expression):
        script = "const fs=require('fs');const src=fs.readFileSync(process.argv[1],'utf8').split('\\n').filter(l=>!l.startsWith('.pragma')).join('\\n');"
        script += "console.log(JSON.stringify(new Function(src+'\\nreturn ('+process.argv[2]+')')()))"
        result = subprocess.run(["node", "-e", script, str(HERE / file), expression], capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_primary_fill_matches_the_python_blend_in_every_state(self):
        palettes = load()
        for name, var in VARS.items():
            for hovered, pressed in STATES:
                got = self.run_js("CardPalette.js", "primaryFill(%s,%s,%s)" % (var, str(hovered).lower(), str(pressed).lower()))
                want = tuple(int(v + 0.5) for v in primary_fill(palettes[name], hovered, pressed))
                self.assertEqual(rgb(got), want, f"{name} hover={hovered} press={pressed}")

    def test_palette_picks_by_style_and_appearance(self):
        self.assertEqual(self.run_js("CardPalette.js", 'palette("minimal", true).style + palette("minimal", false).dark + palette("nonsense", false).style'),
                         "minimalfalseclassic")

    def test_with_alpha_is_argb(self):
        self.assertEqual(self.run_js("CardPalette.js", 'withAlpha("#102030", 1)'), "#FF102030")
        self.assertEqual(self.run_js("CardPalette.js", 'withAlpha("#102030", 0)'), "#00102030")

    def test_dot_and_headline_colours_follow_the_error_flag(self):
        self.assertEqual(self.run_js("CardPalette.js", "dotColor(CLASSIC, true)"), "#FF453A")
        self.assertEqual(self.run_js("CardPalette.js", "dotColor(CLASSIC, false)"), "#F4F3E8")
        self.assertEqual(self.run_js("CardPalette.js", "headlineColor(CLASSIC, true)"), "#FF6B5E")

    def test_pill_model_messages_are_unchanged(self):
        self.assertEqual(self.run_js("PillModel.js", 'message({error: "recording_limit"}, "paste")'),
                         {"headline": "Too long", "detail": "Saved to recovery", "isError": True})
        self.assertEqual(self.run_js("PillModel.js", 'message({delivery: "empty"}, "paste").headline'), "Nothing heard")
        self.assertEqual(self.run_js("PillModel.js", 'message({delivery: "unknown"}, "type").headline'), "Typed")

    def test_paste_failure_outcomes_have_honest_copy(self):
        self.assertEqual(self.run_js("PillModel.js", 'message({delivery: "clipboard_failed"}, "paste")'),
                         {"headline": "Couldn't paste", "detail": "Saved. Copy it from Home", "isError": False})
        self.assertEqual(self.run_js("PillModel.js", 'message({delivery: "clipboard_kept"}, "paste")'),
                         {"headline": "Saved", "detail": "Your clipboard held an image, so nothing was pasted",
                          "isError": False})

    def test_each_error_code_has_its_own_pill_copy(self):
        for code, headline in (("capture_unavailable", "No microphone"), ("capture_interrupted", "Microphone lost"),
                               ("transcription_failed", "Couldn't transcribe"), ("recovery_full", "Recovery is full"),
                               ("recording_limit", "Too long"), ("command_expired", "Timed out"),
                               ("dictionary_unavailable", "Dictionary unavailable"), ("phrases_unavailable", "Phrases unavailable"),
                               ("phrase_context_unavailable", "Phrase context unavailable"), ("cleanup_unavailable", "Cleanup unavailable")):
            result = self.run_js("PillModel.js", 'message({error: "%s"}, "paste")' % code)
            self.assertEqual(result["headline"], headline, code)
            self.assertTrue(result["isError"], code)

    def test_unknown_unavailable_codes_still_fall_to_the_generic_pill_copy(self):
        self.assertEqual(self.run_js("PillModel.js", 'message({error: "mic_unavailable"}, "paste")'),
                         {"headline": "Needs attention", "detail": "mic unavailable", "isError": True})

    def test_cleanup_note_details(self):
        cases = ((None, None), ({"outcome": "ok", "engine": "ready"}, None),
                 ({"outcome": "guard-rejected", "engine": "ready"}, None), ({"outcome": "skipped", "engine": "ready"}, None),
                 ({"outcome": "timeout", "engine": "ready"}, None), ({"outcome": "timeout", "engine": "absent"}, None),
                 ({"outcome": "timeout", "engine": "loading"}, "Basic cleanup \u00b7 model loading"),
                 ({"outcome": "timeout", "engine": "idle"}, "Basic cleanup \u00b7 model loading"),
                 ({"outcome": "timeout", "engine": "unloaded"}, "Basic cleanup \u00b7 model loading"),
                 ({"outcome": "failed", "engine": "failed"}, "Basic cleanup \u00b7 model restarting"),
                 ({"outcome": "timeout", "engine": "failed"}, "Basic cleanup \u00b7 model restarting"))
        for take, want in cases:
            got = self.run_js("PillModel.js", "(function(){var n=cleanupNote(%s);return n&&n.text})()" % json.dumps(take))
            self.assertEqual(got, want, take)

    def test_cleanup_note_shows_once_per_engine_state_change(self):
        loading = {"outcome": "timeout", "engine": "loading"}
        failed = {"outcome": "failed", "engine": "failed"}
        ok = {"outcome": "ok", "engine": "ready"}
        script = "(function(){var g=new CleanupNoteGate();return [%s].map(function(t){return g.next(t)})})()" % \
            ",".join(json.dumps(t) for t in (loading, loading, failed, failed, loading, ok, loading))
        loaded, restarting = "Basic cleanup \u00b7 model loading", "Basic cleanup \u00b7 model restarting"
        self.assertEqual(self.run_js("PillModel.js", script), [loaded, None, restarting, None, loaded, None, loaded])

    def test_cleanup_note_joins_the_settled_message(self):
        note = "Basic cleanup \u00b7 model loading"
        base = 'message({delivery: "unknown"}, "paste")'
        self.assertEqual(self.run_js("PillModel.js", 'withCleanupNote(%s, "%s")' % (base, note)),
                         {"headline": "Pasted", "detail": "Check the field \u00b7 " + note, "isError": False})
        self.assertEqual(self.run_js("PillModel.js", 'withCleanupNote(message({delivery: "empty"}, "paste"), "%s").detail' % note), note)
        self.assertEqual(self.run_js("PillModel.js", 'withCleanupNote(%s, null).detail' % base), "Check the field")
        self.assertIsNone(self.run_js("PillModel.js", 'withCleanupNote(null, "%s")' % note))
        self.assertEqual(self.run_js("PillModel.js", 'withCleanupNote(message({error: "recording_limit"}, "paste"), "%s").detail' % note),
                         "Saved to recovery")

    def test_lips_frame_follows_the_mac_thresholds(self):
        cases = {"0": 0, "0.2499": 0, "0.25": 1, "0.5999": 1, "0.6": 2, "1": 2, "NaN": 0}
        for level, frame in cases.items():
            self.assertEqual(self.run_js("PillModel.js", "lipsFrame(%s, false)" % level), frame, level)

    def test_reduce_motion_pins_the_middle_lips_frame(self):
        for level in ("0", "0.4", "0.9"):
            self.assertEqual(self.run_js("PillModel.js", "lipsFrame(%s, true)" % level), 1)

    def test_lips_level_is_the_tallest_bar(self):
        self.assertEqual(self.run_js("PillModel.js", "lipsLevel([0.1, 0.7, 0.3])"), 0.7)
        self.assertEqual(self.run_js("PillModel.js", "lipsLevel([])"), 0)

    def test_lips_gate_caps_swaps_at_15_fps(self):
        script = "(function() { var g = new LipsGate(); g.reset(0, 10); return [g.next(0.9, false, 10.01), g.next(0.9, false, 10.07), g.next(0.9, false, 10.2), g.next(0.1, false, 10.3)] })()"
        self.assertEqual(self.run_js("PillModel.js", script), [None, 2, None, 0])


if __name__ == "__main__":
    unittest.main()
