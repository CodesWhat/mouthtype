"""Checks for the shared design foundations: palette contrast, icon and font manifests. Plain stdlib, no Qt needed."""
import re
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENTRY_RE = re.compile(r'^\s*(\w+):\s*"(#[0-9A-Fa-f]{6})(?:/([0-9.]+))?"', re.M)


def load_palette():
    text = (HERE / "Palette.js").read_text()
    sets = {}
    for name in ("light", "dark"):
        block = re.search(r"var %s = \{(.*?)\n\}" % name, text, re.S).group(1)
        sets[name] = {
            key: (tuple(int(hexed[i:i + 2], 16) for i in (1, 3, 5)), float(alpha) if alpha else 1.0)
            for key, hexed, alpha in ENTRY_RE.findall(block)
        }
    return sets


def over(top, bottom):
    """Composite a possibly translucent colour over an opaque RGB."""
    (rgb, alpha) = top
    return tuple(rgb[i] * alpha + bottom[i] * (1 - alpha) for i in range(3))


def luminance(rgb):
    def lin(v):
        v = v / 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(v) for v in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# (foreground, background) pairs where text is drawn. Translucent backgrounds are composited over the page they sit on.
TEXT_PAIRS = [
    ("ink", "bg"), ("ink", "surface"), ("ink", "key"),
    ("ink2", "bg"), ("ink2", "surface"),
    ("ink3", "bg"), ("ink3", "surface"),
    ("onAccent", "accent"),
    ("accentText", "bg"), ("accentText", "surface"),
    ("danger", "surface"),
    ("personalBestInk", "personalBest"),
    ("sideInk", "sideBase"),
]
# Text on a translucent fill: (foreground, fill, page the fill sits on).
TEXT_ON_FILL = [
    ("ink", "sel", "surface"), ("ink", "sel", "bg"), ("ink2", "sel", "surface"),
]
# UI fills and rings that need 3:1 against what they sit on. The accent is only claimed against surface (cards, where
# switches and primary buttons sit); light accent on the page ground is 2.75:1, same as the Mac palette.
UI_PAIRS = [
    ("accent", "surface"),
    ("focus", "surface"), ("focus", "bg"),
]


def gallery_names(text):
    block = re.search(r'model: \[((?:"[\w-]+",? ?)+)\]\s*delegate: Icon', text)
    return re.findall(r'"([\w-]+)"', block.group(1)) if block else []


class PaletteContrast(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.palette = load_palette()

    def solid(self, mode, name):
        value = self.palette[mode][name]
        self.assertEqual(value[1], 1.0, f"{mode}.{name} must be opaque to use as a background")
        return value[0]

    def test_both_sets_define_the_same_names(self):
        self.assertEqual(set(self.palette["light"]), set(self.palette["dark"]))

    def test_text_pairs_reach_4_5(self):
        for mode in ("light", "dark"):
            for fg, bg in TEXT_PAIRS:
                with self.subTest(mode=mode, fg=fg, bg=bg):
                    got = ratio(self.solid(mode, fg), self.solid(mode, bg))
                    self.assertGreaterEqual(got, 4.5, f"{mode} {fg} on {bg} is {got:.2f}:1")

    def test_text_on_translucent_fills_reaches_4_5(self):
        for mode in ("light", "dark"):
            for fg, fill, page in TEXT_ON_FILL:
                with self.subTest(mode=mode, fg=fg, fill=fill, page=page):
                    ground = over(self.palette[mode][fill], self.solid(mode, page))
                    got = ratio(self.solid(mode, fg), ground)
                    self.assertGreaterEqual(got, 4.5, f"{mode} {fg} on {fill} over {page} is {got:.2f}:1")

    def test_ui_fills_reach_3(self):
        for mode in ("light", "dark"):
            for fill, ground in UI_PAIRS:
                with self.subTest(mode=mode, fill=fill, ground=ground):
                    got = ratio(self.solid(mode, fill), self.solid(mode, ground))
                    self.assertGreaterEqual(got, 3.0, f"{mode} {fill} against {ground} is {got:.2f}:1")

    def test_accent_matches_the_mac_lime_pass(self):
        self.assertEqual(self.palette["light"]["accent"][0], (0x76, 0xA1, 0x1A))
        self.assertEqual(self.palette["dark"]["accent"][0], (0xA6, 0xCD, 0x52))


class Manifests(unittest.TestCase):
    def test_icon_data_is_current(self):
        result = subprocess.run([sys.executable, str(HERE / "gen_icons.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_required_icons_exist(self):
        required = ["house", "chart-bar", "book", "magic-wand", "text-aa", "pill", "gear", "heartbeat", "sliders-horizontal", "linux-logo",
                    "x", "plus", "caret-left", "caret-right", "caret-up", "caret-down", "magnifying-glass", "copy", "fire"]
        for name in required:
            self.assertTrue((HERE / "icons" / f"{name}.svg").is_file(), name)

    def test_every_icon_name_used_in_qml_resolves(self):
        data = (HERE / "IconData.js").read_text()
        known = set(re.findall(r'^  "([\w-]+)":', data, re.M))
        aliases = {"flame": "fire", "warning": "warning-diamond", "close": "x", "search": "magnifying-glass",
                   "chevron-left": "caret-left", "chevron-right": "caret-right", "chevron-up": "caret-up", "chevron-down": "caret-down"}
        for path in HERE.glob("**/*.qml"):
            text = path.read_text()
            for name in re.findall(r'iconName:\s*"([\w-]+)"', text) + re.findall(r'Icon \{[^}]*name:\s*"([\w-]+)"', text) + gallery_names(text):
                self.assertTrue(name in known or aliases.get(name) in known, f"{path.name}: unknown icon {name}")

    def test_licences_ship_next_to_the_assets(self):
        for name in ("OFL-InstrumentSans.txt", "OFL-InstrumentSerif.txt", "OFL-JetBrainsMono.txt"):
            self.assertTrue((HERE / "fonts" / name).is_file(), name)
        self.assertTrue((HERE / "icons" / "MIT-Phosphor.txt").is_file())

    def test_bundled_fonts_match_the_mac_copies(self):
        mac = HERE.parents[2] / "Sources" / "MouthtypeMac" / "Resources" / "Fonts"
        if not mac.is_dir():
            self.skipTest("Mac font directory not present")
        for ttf in (HERE / "fonts").glob("*.ttf"):
            self.assertEqual(ttf.read_bytes(), (mac / ttf.name).read_bytes(), ttf.name)

    def test_type_loads_the_files_that_exist(self):
        text = (HERE / "Type.qml").read_text()
        for name in re.findall(r'resolvedUrl\("fonts/([^"]+)"\)', text):
            self.assertTrue((HERE / "fonts" / name).is_file(), name)

    def test_qmldir_lists_every_component_file(self):
        listed = set(re.findall(r"^(?:singleton )?\w+ [\d.]+ (\S+\.qml)$", (HERE / "qmldir").read_text(), re.M))
        for path in HERE.glob("*.qml"):
            self.assertIn(path.name, listed)

    def test_no_restricted_word_in_new_names(self):
        for path in HERE.rglob("*"):
            self.assertNotIn("token", path.name.lower())


if __name__ == "__main__":
    unittest.main()
