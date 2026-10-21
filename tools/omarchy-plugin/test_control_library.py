import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("omarchy_control", HERE / "control.py")
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


class LibraryVerbTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config = self.root / "linux.json"
        self.config.write_text(json.dumps({"engine_config": "engines.json"}), encoding="utf-8")
        for patch in (mock.patch.object(control, "_module_commands", None),
                      mock.patch.object(control, "PLUGIN_DIR", HERE),
                      mock.patch.object(control, "LOG", self.root / "control.log")):
            patch.start()
            self.addCleanup(patch.stop)
        commands = control.module_commands()
        self.module = sys.modules["mouthtype_control_library"]
        for patch in (mock.patch.object(self.module, "CONFIG", self.config),
                      mock.patch.object(self.module, "DESKTOP_DIRS", (HERE.parent / "linux-desktop",))):
            patch.start()
            self.addCleanup(patch.stop)
        self.commands = commands

    def call(self, verb, *args):
        return control.run_module_command(verb, list(args))

    def main(self, *argv):
        out = io.StringIO()
        with mock.patch.object(sys, "argv", ["control.py", *argv]), contextlib.redirect_stdout(out):
            code = control.main()
        return code, json.loads(out.getvalue())

    def test_all_verbs_are_registered_and_none_shadow_built_ins(self):
        expected = {"spellings-list", "spellings-add", "spellings-edit", "spellings-remove", "spellings-import-preview",
                    "spellings-import", "phrases-list", "phrases-add", "phrases-edit", "phrases-remove"}
        self.assertTrue(expected <= set(self.commands))
        self.assertFalse(expected & control.VALID_ACTIONS)
        self.assertEqual(control.available_actions() & expected, expected)

    def test_spelling_round_trip_through_main(self):
        code, listed = self.main("spellings-list")
        self.assertEqual((code, listed["entries"], listed["configured"]), (0, [], False))
        code, added = self.main("spellings-add", "post hog", "PostHog")
        self.assertEqual((code, added["result"], added["configured"]), (0, "added", True))
        code, edited = self.main("spellings-edit", "post hog", "post hog", "Posthog", "PostHog")
        self.assertEqual((code, edited["entry"]["written"]), (0, "Posthog"))
        csv = self.root / "in.csv"
        csv.write_text("name\nSean\nPostHog\n", encoding="utf-8")
        code, preview = self.main("spellings-import-preview", str(csv))
        self.assertEqual((code, preview["can_import"], preview["counts"]["add"]), (0, True, 2))
        code, imported = self.main("spellings-import", str(csv), preview["digest"])
        self.assertEqual((code, imported["imported"], imported["count"]), (0, 2, 3))
        code, removed = self.main("spellings-remove", "sean", "")
        self.assertEqual((code, removed["count"]), (0, 2))

    def test_phrase_round_trip_through_main(self):
        self.assertEqual(self.main("phrases-add", "sig", "Thanks")[1]["result"], "added")
        code, edited = self.main("phrases-edit", "sig", "signoff", "Cheers", "Thanks")
        self.assertEqual((code, edited["entry"]), (0, {"trigger": "signoff", "expansion": "Cheers"}))
        code, removed = self.main("phrases-remove", "signoff")
        self.assertEqual((code, removed["entries"]), (0, []))

    def test_errors_are_json_with_exit_one(self):
        code, result = self.main("spellings-remove", "nobody")
        self.assertEqual(code, 1)
        self.assertIn("changed outside the editor", result["error"])
        code, result = self.main("spellings-add", "only-one-argument")
        self.assertEqual((code, result["error"]), (1, "Invalid control arguments"))

    def test_missing_service_files_are_a_readable_error(self):
        with mock.patch.object(self.module, "DESKTOP_DIRS", (self.root / "absent",)):
            code, result = self.main("phrases-list")
        self.assertEqual((code, result["error"]), (1, "The Mouthtype Linux service files are missing"))


if __name__ == "__main__":
    unittest.main()
