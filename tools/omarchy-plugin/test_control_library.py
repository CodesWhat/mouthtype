import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import time
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
        code, imported = self.main("spellings-import", str(csv), preview["digest"], preview["csv_digest"])
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


class DraftVerbTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.state = Path(self.directory.name)
        patch = mock.patch.dict("os.environ", {"XDG_STATE_HOME": str(self.state)})
        patch.start()
        self.addCleanup(patch.stop)
        for patch in (mock.patch.object(control, "_module_commands", None),
                      mock.patch.object(control, "PLUGIN_DIR", HERE),
                      mock.patch.object(control, "LOG", self.state / "control.log")):
            patch.start()
            self.addCleanup(patch.stop)
        control.module_commands()
        self.module = sys.modules["mouthtype_control_library"]
        self.drafts = self.state / "mouthtype" / "drafts"

    def call(self, verb, *args):
        return control.run_module_command(verb, list(args))

    def save(self, **fields):
        return self.call("draft-save", json.dumps({"kind": "spelling", **fields}))

    def test_verbs_are_registered(self):
        self.assertTrue({"draft-save", "draft-list", "draft-clear"} <= set(control.module_commands()))

    def test_save_list_clear_round_trip(self):
        self.assertEqual(self.call("draft-list"), {"drafts": []})
        saved = self.save(written="Sean", heardInput="shawn", heardForms=["shaun"])
        (draft,) = saved["drafts"]
        self.assertEqual((draft["kind"], draft["written"], draft["heardInput"], draft["heardForms"], draft["version"]),
                         ("spelling", "Sean", "shawn", ["shaun"], 1))
        self.assertEqual(self.call("draft-list")["drafts"][0]["id"], draft["id"])
        self.assertEqual(self.call("draft-clear", draft["id"]), {"drafts": []})
        self.assertEqual(list(self.drafts.iterdir()), [])

    def test_files_are_private_and_versioned(self):
        draft = self.call("draft-save", json.dumps({"kind": "phrase", "trigger": "sig", "expansion": "Thanks"}))["drafts"][0]
        path = self.drafts / (draft["id"] + ".json")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.drafts.stat().st_mode & 0o777, 0o700)
        self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["version"], 1)
        self.assertEqual(draft["trigger"], "sig")

    def test_two_saves_keep_both_oldest_first(self):
        with mock.patch.object(self.module.time, "time", return_value=1_700_000_000.0):
            self.save(written="One")
            self.save(written="Two")
        self.assertEqual([d["written"] for d in self.call("draft-list")["drafts"]], ["One", "Two"])

    def test_a_blank_draft_writes_nothing(self):
        self.assertEqual(self.save(written="", heardForms=[""]), {"drafts": []})
        self.assertFalse(self.drafts.exists() and any(self.drafts.iterdir()))

    def test_a_bad_payload_is_refused(self):
        with self.assertRaises(RuntimeError):
            self.call("draft-save", "not json")
        with self.assertRaises(RuntimeError):
            self.call("draft-save", json.dumps({"kind": "other", "written": "x"}))
        with self.assertRaises(RuntimeError):
            self.call("draft-clear", "../../etc/passwd")

    def test_drafts_older_than_a_week_are_pruned(self):
        self.save(written="Old")
        listed = self.save(written="Fresh")["drafts"]
        old, fresh = [next(d["id"] for d in listed if d["written"] == name) for name in ("Old", "Fresh")]
        eight_days = time.time() - 8 * 86400
        os.utime(self.drafts / (old + ".json"), (eight_days, eight_days))
        self.assertEqual([d["id"] for d in self.call("draft-list")["drafts"]], [fresh])
        self.assertFalse((self.drafts / (old + ".json")).exists())

    def test_malformed_and_newer_version_files_are_skipped_not_fatal(self):
        good = self.save(written="Good")["drafts"][0]["id"]
        (self.drafts / "spelling-1.json").write_text("{nope", encoding="utf-8")
        (self.drafts / "phrase-2.json").write_text(json.dumps({"kind": "bogus", "written": "x"}), encoding="utf-8")
        (self.drafts / "phrase-3.json").write_text(json.dumps({"version": 2, "kind": "phrase", "trigger": "x"}), encoding="utf-8")
        (self.drafts / "spelling-4.json").write_text(json.dumps([1, 2]), encoding="utf-8")
        (self.drafts / "notes.json").write_text(json.dumps({"kind": "phrase", "trigger": "x"}), encoding="utf-8")
        self.assertEqual([d["id"] for d in self.call("draft-list")["drafts"]], [good])
        self.assertTrue((self.drafts / "phrase-3.json").exists(), "a newer build's file is left alone")

    def test_a_file_without_a_version_still_reads(self):
        self.drafts.mkdir(parents=True)
        (self.drafts / "phrase-9.json").write_text(json.dumps({"kind": "phrase", "trigger": "sig"}), encoding="utf-8")
        (draft,) = self.call("draft-list")["drafts"]
        self.assertEqual((draft["trigger"], draft["expansion"], draft["version"]), ("sig", "", 1))

    def test_clear_without_an_id_removes_every_draft(self):
        self.save(written="A")
        self.save(written="B")
        self.assertEqual(self.call("draft-clear"), {"drafts": []})


if __name__ == "__main__":
    unittest.main()
