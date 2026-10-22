import importlib.util
import json
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
DESKTOP = HERE.parent / "linux-desktop"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


control = load("omarchy_control_for_stats", HERE / "control.py")
control_stats = load("omarchy_control_stats", HERE / "control_stats.py")


class ControlStatsTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.recovery = self.root / "recovery"
        take = self.recovery / ("a" * 32)
        take.mkdir(parents=True)
        (take / "take.json").write_text(json.dumps({"created": time.time()}))
        (take / "transcript.txt").write_text("one two three four")
        patches = [mock.patch.object(control_stats, "RECOVERY", self.recovery),
                   mock.patch.object(control_stats, "STATS_SOURCES", (self.root / "absent.py", DESKTOP / "stats.py"))]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_stats_verb_returns_the_page_json(self):
        result = control_stats.COMMANDS["stats"]()
        self.assertEqual(result["words"]["all_time"], 4)
        self.assertEqual(result["takes"], 1)
        self.assertIn("high_scores", result)
        json.dumps(result)

    def test_missing_stats_module_is_a_panel_readable_error(self):
        with mock.patch.object(control_stats, "STATS_SOURCES", (self.root / "absent.py",)):
            with self.assertRaisesRegex(RuntimeError, "unavailable"):
                control_stats.COMMANDS["stats"]()

    def test_control_dispatches_the_verb(self):
        plugin = self.root / "plugin"
        plugin.mkdir()
        shutil.copy(HERE / "control_stats.py", plugin / "control_stats.py")
        with mock.patch.object(control, "PLUGIN_DIR", plugin), mock.patch.object(control, "_module_commands", None):
            commands = control.module_commands()
            self.assertIn("stats", commands)
            # The copy has no stats.py beside it, so point it at the source checkout and the temp recovery.
            module = sys.modules["mouthtype_control_stats"]
            module.RECOVERY = self.recovery
            module.STATS_SOURCES = (DESKTOP / "stats.py",)
            result = control.run_module_command("stats", [])
            with self.assertRaises(RuntimeError):
                control.run_module_command("stats", ["extra"])
        self.assertEqual(result["words"]["all_time"], 4)


if __name__ == "__main__":
    unittest.main()
