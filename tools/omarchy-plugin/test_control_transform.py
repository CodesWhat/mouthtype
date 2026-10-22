import importlib.util
import json
import os
import stat
import sys
import signal
import subprocess
import tempfile
import textwrap
import threading
import time
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
if mode == "cancellable":
    import signal
    signal.signal(signal.SIGTERM, lambda *_: (sys.stdout.write('{"state": "cancelled"}'), sys.stdout.flush(), sys.exit(0)))
    open(os.environ["FAKE_LOG"] + ".ready", "w").write("ready")
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
            mock.patch.object(control_transform, "RUNTIME", self.root / "runtime"),
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
            "transform-open", "transform-focus", "transform-status", "transform-capture", "transform-run", "transform-accept", "transform-copy",
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

    def test_open_captures_and_writes_the_panel_request(self):
        self.answer({"state": "captured", "id": IDENTITY, "text": "héllo", "app": {"name": "Slack", "address": "0xab"}})
        before = time.time()
        self.assertEqual(control_transform.transform_open(), {"state": "captured", "id": IDENTITY})
        self.assertEqual(self.recorded()["argv"][-1], "capture")
        path = self.root / "runtime" / control_transform.PANEL_REQUEST
        request = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual((request["id"], request["text"], request["app"]["name"]), (IDENTITY, "héllo", "Slack"))
        self.assertGreaterEqual(request["opened_at"], before)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        self.assertEqual([item.name for item in path.parent.iterdir()], [control_transform.PANEL_REQUEST])

    def test_open_writes_a_failed_capture_too(self):
        self.answer({"state": "error", "error": "nothing_selected", "message": "Select some text."})
        self.assertEqual(control_transform.transform_open()["state"], "error")
        request = json.loads((self.root / "runtime" / control_transform.PANEL_REQUEST).read_text())
        self.assertEqual((request["state"], request["error"]), ("error", "nothing_selected"))

    def test_focus_dispatches_to_the_captured_window(self):
        done = subprocess.CompletedProcess([], 0, stdout="ok\n", stderr="")
        with mock.patch.object(control_transform.subprocess, "run", return_value=done) as run:
            self.assertEqual(control_transform.transform_focus("0x55d1c0a3b2f0"), {"state": "focused"})
        self.assertEqual(run.call_args.args[0], ["hyprctl", "dispatch", "focuswindow", "address:0x55d1c0a3b2f0"])

    def test_focus_reports_a_refusal_and_validates_the_address(self):
        done = subprocess.CompletedProcess([], 0, stdout="Window not found", stderr="")
        with mock.patch.object(control_transform.subprocess, "run", return_value=done):
            result = control_transform.transform_focus("0xabc")
        self.assertEqual((result["state"], result["message"]), ("focus_failed", "Window not found"))
        with mock.patch.object(control_transform.subprocess, "run") as run:
            for bad in ("class:Slack", "0xZZ", "", None, "0xabc ; exec x"):
                with self.assertRaises(ValueError):
                    control_transform.transform_focus(bad)
            run.assert_not_called()

    def test_focus_without_hyprctl_is_a_runtime_error(self):
        with mock.patch.object(control_transform.subprocess, "run", side_effect=FileNotFoundError):
            with self.assertRaisesRegex(RuntimeError, "hyprctl"):
                control_transform.transform_focus("0xabc")

    def test_sigterm_reaches_the_cli_and_its_answer_comes_back(self):
        self.answer("cancellable")
        ready = Path(str(self.log) + ".ready")

        def interrupt():
            for _ in range(200):
                if ready.exists():
                    break
                time.sleep(.05)
            os.kill(os.getpid(), signal.SIGTERM)

        before = signal.getsignal(signal.SIGTERM)
        threading.Thread(target=interrupt, daemon=True).start()
        self.assertEqual(control_transform.transform_run(IDENTITY, "fix-grammar"), {"state": "cancelled"})
        self.assertIs(signal.getsignal(signal.SIGTERM), before)

    def test_missing_launcher_is_an_oserror(self):
        with mock.patch.object(control_transform, "LAUNCHER", self.root / "missing"):
            with self.assertRaises(OSError):
                control_transform.transform_status()


if __name__ == "__main__":
    unittest.main()
