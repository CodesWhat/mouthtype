"""Static checks for the Stats page (slice V4): its files follow the page contract, the fixtures match what stats.py prints,
the page asks for the verb the plugin serves, and the repo's text rules hold for the new files. Plain stdlib, no Qt needed.
The drawing is checked by shell-render/tst_stats.qml on the NAS testbed."""
import importlib.util
import json
import re
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAGE = HERE / "pages" / "StatsPage.qml"
PARTS = sorted((HERE / "pages" / "stats").glob("*.qml"))
FIXTURES = HERE / "shell-render" / "StatsFixtures.js"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StatsPageTests(unittest.TestCase):
    def test_follows_the_page_contract(self):
        text = PAGE.read_text()
        self.assertRegex(text, r"property var backend\b")
        self.assertRegex(text, r"property bool active\b")
        self.assertRegex(text, r"signal request\(string command, var args\)")
        self.assertIn("implicitHeight", text)

    def test_requests_the_stats_verb_the_plugin_serves(self):
        self.assertIn('request("stats", [])', PAGE.read_text())
        served = load("omarchy_control_stats", HERE / "control_stats.py")
        self.assertIn("stats", served.COMMANDS)

    def test_every_part_exists(self):
        names = {path.name for path in PARTS}
        for name in ("Counter.qml", "Tape.qml", "SpeedMeter.qml", "StreakDots.qml", "HourChart.qml", "HighScores.qml",
                     "StatsCard.qml", "AxisLabel.qml", "HoverTip.qml", "MonoLine.qml"):
            self.assertIn(name, names)
        self.assertTrue((HERE / "pages" / "stats" / "StatsFormat.js").is_file())

    def test_uses_the_design_system_and_no_hard_coded_colours(self):
        for path in [PAGE] + PARTS:
            text = path.read_text()
            self.assertIn('import "../design"' if path == PAGE else 'import "../../design"', text, path.name)
            for colour in re.findall(r'"(#[0-9A-Fa-f]{3,8})"', text):
                self.fail("%s hard-codes %s" % (path.name, colour))

    def test_text_rules(self):
        for path in [PAGE] + PARTS:
            text = path.read_text()
            self.assertNotRegex(text, r"elide:\s*Text\.Elide(?!None)", path.name)
            self.assertNotIn("—", text, path.name)
            for size in re.findall(r"pixelSize:\s*(\d+(?:\.\d+)?)\s*$", text, re.M):
                self.assertGreaterEqual(float(size), 9, path.name)
            if path.name != "AxisLabel.qml":
                self.assertNotRegex(text, r"pixelSize:\s*9\b", path.name)

    def test_nine_pixel_text_only_in_the_tagged_axis_label(self):
        axis = (HERE / "pages" / "stats" / "AxisLabel.qml").read_text()
        self.assertIn("property bool axisLabel: true", axis)
        self.assertIn("Type.axisSize", axis)

    def test_no_restricted_word_in_new_names(self):
        for path in [PAGE, FIXTURES, HERE / "shell-render" / "gen_stats_fixtures.py"] + PARTS:
            self.assertNotIn("token", path.name.lower(), str(path))

    def test_lime_is_never_a_text_colour(self):
        for path in [PAGE] + PARTS:
            for line in path.read_text().splitlines():
                if re.search(r"\bcolor:\s*Theme\.accent\b", line) and "Text" in line:
                    self.fail("%s sets lime text: %s" % (path.name, line))


class FixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.generator = load("gen_stats_fixtures", HERE / "shell-render" / "gen_stats_fixtures.py")
        cls.scenes = json.loads(FIXTURES.read_text().split("var scenes = ", 1)[1])

    def test_fixtures_are_current(self):
        self.assertEqual(self.generator.render(), FIXTURES.read_text(), "run shell-render/gen_stats_fixtures.py")

    def test_fixtures_have_the_real_shape(self):
        engine = self.generator.load()
        real = engine.build([], now=self.generator.NOW.timestamp(), tz=self.generator.timezone.utc)
        for name, scene in self.scenes.items():
            self.assertEqual(set(scene), set(real), name)
            self.assertTrue(scene["history_limited"], name)

    def test_scenes_cover_the_cases(self):
        self.assertEqual(set(self.scenes), {"empty", "one_take", "sparse", "dense", "audio_only"})
        self.assertFalse(self.scenes["empty"]["has_history"])
        self.assertEqual(self.scenes["empty"]["tape"], [])
        self.assertEqual(len(self.scenes["one_take"]["tape"]), 1)
        self.assertFalse(self.scenes["audio_only"]["has_history"])
        self.assertTrue(all(take["audio_only"] for take in self.scenes["audio_only"]["tape"]))
        self.assertGreaterEqual(len(self.scenes["dense"]["tape"]), 30)
        self.assertEqual(len(self.scenes["dense"]["daily"]), 30)
        self.assertTrue(any(take["audio_only"] for take in self.scenes["sparse"]["tape"]))
        self.assertLess(sum(1 for day in self.scenes["sparse"]["daily"] if day["words"]), 10)


if __name__ == "__main__":
    unittest.main()
