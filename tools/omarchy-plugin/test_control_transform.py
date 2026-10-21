import importlib.util
import json
import os
import stat
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("omarchy_control", HERE / "control.py")
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)
module_spec = importlib.util.spec_from_file_location("omarchy_control_transform", HERE / "control_transform.py")
control_transform = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(control_transform)

IDENTITY = "a" * 32

# Records its arguments and standard input, then answers with the JSON named by the first line of FAKE_REPLY.
LAUNCHER = """#!/usr/bin/env python3
import json, os, sys, time
record = {"argv": sys.argv[1:], "stdin": None if sys.stdin.isatty() else sys.stdin.read()}
open(os.environ["FAKE_LOG"], "w").write(json.dumps(record))
mode = open(os.environ["FAKE_REPLY"]).read()
if mode == "hang":
    import signal
    signal.signal(signal.SIGTERM, lambda *_: (open(os.environ["FAKE_LOG"] + ".term", "w").write("term"), sys.exit(0)))
    time.sleep(60)
sys.stdout.write(mode)
"""


class ControlTransformTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        launcher = self.root / "mouthtype-linux"
        launcher.write_text(LAUNCHER)
        launcher.chmod(stat.S_IRWXU)
        self.log, self.reply = self.root / "log.json", self.root / "reply"
        patches = [
            mock.patch.object(control_transform, "LAUNCHER", launcher),
            mock.patch.object(control_transform, "CONFIG", self.root / "linux.json"),
            mock.patch.dict(os.environ, {"FAKE_LOG": str(self.log), "FAKE_REPLY": str(self.reply)}),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.answer({"state": "ok"})

    def answer(self, value):
        self.reply.write_text(value if isinstance(value, str) else json.dumps(value))

    def recorded(self):
        return json.loads(self.log.read_text())

    def test_commands_are_valid_control_verbs(self):
        self.assertEqual(set(control_transform.COMMANDS), {
            "transform-status", "transform-capture", "transform-run", "transform-accept", "transform-copy",
            "transform-cancel"})
        for verb in control_transform.COMMANDS:
            self.assertRegex(verb, r"[a-z][a-z0-9-]*")
            self.assertNotIn(verb, control.VALID_ACTIONS)

    def test_control_loads_the_module(self):
        with tempfile.TemporaryDirectory() as plugin:
            (Path(plugin) / "control_transform.py").write_text((HERE / "control_transform.py").read_text())
            with mock.patch.object(control, "PLUGIN_DIR", Path(plugin)), mock.patch.object(control, "_module_commands", None):
                self.assertIn("transform-capture", control.module_commands())

    def test_status_and_capture_pass_the_cli_json_through(self):
        self.answer({"state": "captured", "id": IDENTITY, "text": "héllo"})
        self.assertEqual(control_transform.transform_capture(), {"state": "captured", "id": IDENTITY, "text": "héllo"})
        self.assertEqual(self.recorded()["argv"], ["--config", str(self.root / "linux.json"), "transform", "capture"])
        control_transform.transform_status()
        self.assertEqual(self.recorded()["argv"][-1], "status")

    def test_run_validates_before_calling(self):
        control_transform.transform_run(IDENTITY, "fix-grammar")
        self.assertEqual(self.recorded()["argv"][-3:], ["run", IDENTITY, "fix-grammar"])
        for call in (lambda: control_transform.transform_run("../x", "clean-up"),
                     lambda: control_transform.transform_run(IDENTITY, "translate")):
            with self.assertRaises(ValueError):
                call()

    def test_accept_sends_edited_text_on_stdin_not_argv(self):
        control_transform.transform_accept(IDENTITY, "My edit\nwith lines é")
        record = self.recorded()
        self.assertEqual(record["argv"][-3:], ["accept", IDENTITY, "--stdin"])
        self.assertEqual(record["stdin"], "My edit\nwith lines é")
        self.assertNotIn("My edit", " ".join(record["argv"]))
        control_transform.transform_accept(IDENTITY)
        self.assertEqual(self.recorded()["argv"][-2:], ["accept", IDENTITY])

    def test_copy_variants(self):
        control_transform.transform_copy(IDENTITY)
        self.assertEqual(self.recorded()["argv"][-2:], ["copy", IDENTITY])
        control_transform.transform_copy(IDENTITY, "original", "ignored edit")
        record = self.recorded()
        self.assertEqual(record["argv"][-3:], ["copy", IDENTITY, "--original"])
        self.assertEqual(record["stdin"], "")
        control_transform.transform_copy(IDENTITY, "result", "edit")
        self.assertEqual(self.recorded()["stdin"], "edit")
        with self.assertRaises(ValueError):
            control_transform.transform_copy(IDENTITY, "both")

    def test_cancel_with_and_without_an_id(self):
        control_transform.transform_cancel()
        self.assertEqual(self.recorded()["argv"][-1], "cancel")
        control_transform.transform_cancel(IDENTITY)
        self.assertEqual(self.recorded()["argv"][-2:], ["cancel", IDENTITY])

    def test_error_state_is_returned_for_the_panel_to_render(self):
        self.answer({"state": "error", "error": "nothing_selected", "message": "Select some text."})
        self.assertEqual(control_transform.transform_capture()["error"], "nothing_selected")

    def test_unusable_cli_output_raises(self):
        self.answer("not json")
        with self.assertRaises(RuntimeError):
            control_transform.transform_status()

    def test_overlong_call_is_terminated_and_reported(self):
        self.answer("hang")
        with mock.patch.dict(control_transform.LIMITS, {"status": 1}), mock.patch.object(control_transform, "GRACE", 2):
            with self.assertRaisesRegex(RuntimeError, "took too long"):
                control_transform.transform_status()
        self.assertTrue(Path(str(self.log) + ".term").exists())

    def test_missing_launcher_is_an_oserror(self):
        with mock.patch.object(control_transform, "LAUNCHER", self.root / "missing"):
            with self.assertRaises(OSError):
                control_transform.transform_status()


if __name__ == "__main__":
    unittest.main()
