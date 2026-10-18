import importlib.util
import json
import re
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("omarchy_control", HERE / "control.py")
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)
ORIGINAL_EVENT_TIME = control.event_time


class AutostartTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.unit = self.root / "user" / "mouthtype-linux.service"
        self.calls = []
        patches = [
            mock.patch.object(control, "UNIT", self.unit),
            mock.patch.object(control, "LAUNCHER", self.root / "my bin" / "mouthtype-linux"),
            mock.patch.object(control, "CONFIG", self.root / "linux.json"),
            mock.patch.object(control, "state", lambda: {}),
            mock.patch.object(control.shutil, "which", lambda name: "/usr/bin/" + name),
            mock.patch.object(control.subprocess, "run", self.fake_run),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def fake_run(self, command, **kwargs):
        self.calls.append(command[2:])
        return mock.Mock(returncode=0)

    def test_unit_starts_with_the_graphical_session(self):
        control.set_autostart("on")
        text = self.unit.read_text(encoding="utf-8")
        self.assertIn("PartOf=graphical-session.target", text)
        self.assertIn("After=graphical-session.target pipewire.service", text)
        self.assertIn("WantedBy=graphical-session.target", text)
        self.assertNotIn("default.target", text)

    def test_exec_start_quotes_paths_with_spaces(self):
        control.set_autostart("on")
        line = next(l for l in self.unit.read_text(encoding="utf-8").splitlines() if l.startswith("ExecStart="))
        self.assertIn('"' + str(self.root / "my bin" / "mouthtype-linux") + '"', line)

    def test_enabled_check_reads_graphical_session_wants(self):
        wants = self.unit.parent / "graphical-session.target.wants"
        wants.mkdir(parents=True)
        self.assertFalse(control.unit_enabled())
        (wants / self.unit.name).symlink_to(self.unit)
        self.assertTrue(control.unit_enabled())

    def test_legacy_install_is_disabled_before_reenable(self):
        control.set_autostart("on")
        self.calls.clear()
        legacy = self.unit.parent / "default.target.wants"
        legacy.mkdir()
        (legacy / self.unit.name).symlink_to(self.unit)
        control.set_autostart("on")
        verbs = [call[0] for call in self.calls]
        self.assertEqual(verbs, ["disable", "daemon-reload", "enable"])

    def test_off_refuses_unmanaged_unit(self):
        self.unit.parent.mkdir(parents=True)
        self.unit.write_text("[Service]\nExecStart=/bin/true\n", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "was not changed"):
            control.set_autostart("off")
        self.assertEqual(self.calls, [])

    def test_off_disables_managed_unit(self):
        control.set_autostart("on")
        self.calls.clear()
        control.set_autostart("off")
        self.assertEqual([call[0] for call in self.calls], ["disable"])


class SettingsDuringImportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.config = root / "linux.json"
        self.config.write_text(json.dumps({"engine_config": "/x", "notifications": True}), encoding="utf-8")
        self.file_import = {"state": "transcribing"}
        self.shutdowns = []
        patches = [
            mock.patch.object(control, "CONFIG", self.config),
            mock.patch.object(control, "DESKTOP", HERE.parent / "linux-desktop"),
            mock.patch.object(control, "state", lambda: {"running": True, "state": "idle",
                                                         "file_import": self.file_import}),
            mock.patch.object(control, "act", lambda command: self.shutdowns.append(command)),
            mock.patch.object(control, "start_service", lambda: None),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_restarting_change_is_refused_while_a_file_import_runs(self):
        for state in ("preparing", "transcribing", "cancelling"):
            self.file_import["state"] = state
            with self.assertRaisesRegex(RuntimeError, "file transcription"):
                control.set_config("notifications", "off")
        self.assertEqual(self.shutdowns, [])
        self.assertTrue(json.loads(self.config.read_text(encoding="utf-8"))["notifications"])

    def test_change_applies_and_restarts_once_the_import_is_done(self):
        self.file_import["state"] = "finished"
        control.set_config("notifications", "off")
        self.assertEqual(self.shutdowns, ["shutdown"])
        self.assertFalse(json.loads(self.config.read_text(encoding="utf-8"))["notifications"])


class RetainedImportResultTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        (root / "launcher").write_text("", encoding="utf-8")
        (root / "linux.json").write_text("{}", encoding="utf-8")
        self.status = {}
        patches = [
            mock.patch.object(control, "LAUNCHER", root / "launcher"),
            mock.patch.object(control, "CONFIG", root / "linux.json"),
            mock.patch.object(control, "cli", lambda *a, **k: mock.Mock(returncode=0, stdout=json.dumps(self.status))),
            mock.patch.object(control, "recent_dictations", lambda limit=None: []),
            mock.patch.object(control, "words_today", lambda entries: 0),
            mock.patch.object(control, "capabilities", lambda: {}),
            mock.patch.object(control, "config_summary", lambda: {}),
            mock.patch.object(control, "preferences", lambda: {"sounds": True, "pill": {}, "font": {}}),
            mock.patch.object(control, "cleanup_models", lambda: {"models": {}}),
            mock.patch.object(control, "unit_enabled", lambda: False),
            mock.patch.object(control, "shortcut_mode", lambda: "off"),
            mock.patch.object(control, "shortcut_info", lambda: {"keys": ""}),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_failed_replacement_reports_the_retained_previous_result(self):
        self.status = {"state": "idle", "file_import": {"state": "failed", "error": "invalid_audio",
                                                        "id": "b" * 32, "retained_id": "a" * 32}}
        self.assertTrue(control.state()["file_import"]["retained"])

    def test_no_retained_result_when_the_service_reports_none(self):
        self.status = {"state": "idle", "file_import": {"state": "failed", "error": "invalid_audio",
                                                        "id": "b" * 32, "retained_id": None}}
        self.assertFalse(control.state()["file_import"]["retained"])
        self.status = {"state": "idle"}
        self.assertFalse(control.state()["file_import"]["retained"])

    def test_panel_offers_copy_and_save_for_a_retained_result(self):
        panel = (HERE / "Panel.qml").read_text(encoding="utf-8")
        self.assertIn("fileImport.retained", panel)
        for action in ("import-copy", "import-save"):
            row = next(line for line in panel.splitlines() if 'root.run(["%s"])' % action in line)
            self.assertIn("importRetained", row)


class HoldToTalkTests(unittest.TestCase):
    """Each event is a separate process in production: ordered by launch time, delivered in any order."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.recording = False
        self.calls = []
        self.start_gates = []
        self.lock = threading.Lock()
        self.local = threading.local()
        self.boot = "boot-a"
        patches = [
            mock.patch.object(control, "HOLD", self.root / "state" / "hold.json"),
            mock.patch.object(control, "cli", self.fake_cli),
            mock.patch.object(control, "cue", lambda name: self.calls.append("cue-" + name)),
            mock.patch.object(control, "state", lambda: {"running": True, "state": "idle"}),
            mock.patch.object(control, "event_time", lambda: self.local.t),
            mock.patch.object(control, "boot_id", lambda: self.boot),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def fake_cli(self, command, *args, timeout=35):
        gate = None
        with self.lock:
            self.calls.append(command)
            if command == "start":
                self.recording = True
                gate = self.start_gates.pop(0) if self.start_gates else None
            elif command == "stop":
                self.recording = False
            reply = mock.Mock(returncode=0, stdout=json.dumps({"state": "recording" if self.recording else "idle"}),
                              stderr="")
        if gate is not None:
            # The service already started; only this process's view of the response is late.
            gate.wait(5)
        return reply

    def event(self, command, t):
        self.local.t = t
        return control.act(command)

    def press(self, t):
        return self.event("start", t)

    def release(self, t):
        return self.event("stop", t)

    def threaded(self, command, t):
        thread = threading.Thread(target=self.event, args=(command, t))
        thread.start()
        self.addCleanup(thread.join, 5)
        return thread

    def service_calls(self):
        return [c for c in self.calls if not c.startswith("cue")]

    def wait_for(self, condition):
        deadline = time.monotonic() + 2
        while not condition():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.005)

    def test_lost_release_then_next_release_before_its_press_leaves_nothing_recording(self):
        self.press(10)
        self.assertTrue(self.recording)
        # Release 1 never arrives. Release 2 (launched after press 2) outruns press 2 to the lock.
        self.release(30)
        self.assertFalse(self.recording)
        self.press(20)
        self.assertFalse(self.recording)
        self.assertEqual(self.service_calls().count("start"), 1)

    def test_delayed_start_response_does_not_stop_a_newer_hold(self):
        gate = threading.Event()
        self.start_gates = [gate]
        first = self.threaded("start", 10)
        self.wait_for(lambda: "start" in self.calls)
        self.wait_for(lambda: json.loads(control.HOLD.read_text()).get("press"))
        self.release(20)
        self.press(30)
        self.assertTrue(self.recording)
        gate.set()
        first.join(5)
        self.assertFalse(first.is_alive())
        self.assertTrue(self.recording)
        self.assertEqual(self.service_calls(), ["start", "stop", "start"])
        self.release(40)
        self.assertFalse(self.recording)

    def test_release_during_a_slow_start_stops_the_recording_when_it_lands(self):
        gate = threading.Event()
        self.start_gates = [gate]
        first = self.threaded("start", 10)
        self.wait_for(lambda: "start" in self.calls)
        self.wait_for(lambda: json.loads(control.HOLD.read_text()).get("press"))
        self.release(20)
        gate.set()
        first.join(5)
        self.assertFalse(self.recording)

    def test_ordinary_hold_starts_once_and_stops_once(self):
        self.press(10)
        self.assertTrue(self.recording)
        self.release(500)
        self.assertFalse(self.recording)
        self.assertEqual(self.service_calls(), ["start", "stop"])

    def test_tap_whose_release_arrives_first_never_starts(self):
        self.release(11)
        self.press(10)
        self.assertNotIn("start", self.calls)
        self.assertFalse(self.recording)
        # The next ordinary press is not affected by the earlier tap.
        self.press(20)
        self.assertTrue(self.recording)
        self.release(25)
        self.assertFalse(self.recording)

    def test_rapid_taps_end_with_nothing_recording_in_every_arrival_order(self):
        import itertools
        taps = [(10, 11), (12, 13), (14, 15)]
        events = [(kind, t) for press, release in taps for kind, t in (("start", press), ("stop", release))]
        for order in itertools.permutations(events):
            with self.subTest(order=order):
                self.recording = False
                control.HOLD.unlink(missing_ok=True)
                for kind, t in order:
                    self.event(kind, t)
                self.assertFalse(self.recording)
                # And the following hold works.
                self.press(100)
                self.assertTrue(self.recording)
                self.release(101)
                self.assertFalse(self.recording)

    def test_equal_timestamps_count_as_release_after_press(self):
        self.press(10)
        self.release(10)
        self.assertFalse(self.recording)
        self.release(20)
        self.press(20)
        self.assertFalse(self.recording)
        self.assertEqual(self.service_calls().count("start"), 1)

    def test_late_release_for_an_older_press_does_not_stop_the_current_hold(self):
        self.press(10)
        self.press(30)
        self.release(20)
        self.assertTrue(self.recording)
        self.release(40)
        self.assertFalse(self.recording)

    def test_malformed_or_stale_hold_file_is_ignored(self):
        control.HOLD.parent.mkdir(parents=True)
        stale = {"boot": "boot-old", "seq": 9, "last_release_t": 10 ** 9,
                 "press": {"id": 9, "t": 10 ** 9, "started": True, "released": False}}
        garbage = ["not json", "[]", "null", "{}", json.dumps({"boot": "boot-a", "seq": "x"}),
                   json.dumps({"boot": "boot-a", "seq": 1, "press": {"id": "z"}, "last_release_t": "later"}),
                   json.dumps(stale)]
        for content in garbage:
            with self.subTest(content=content):
                self.recording = False
                control.HOLD.write_text(content, encoding="utf-8")
                self.press(10)
                self.assertTrue(self.recording)
                self.release(11)
                self.assertFalse(self.recording)

    def test_event_time_reads_process_start_after_the_last_parenthesis(self):
        fields = ["S"] + ["0"] * 18 + ["4242"] + ["0"] * 10
        line = "123 (odd ) name (x) " + " ".join(fields) + "\n"
        with mock.patch.object(control.Path, "read_text", lambda self, *a, **k: line):
            self.assertEqual(ORIGINAL_EVENT_TIME(), 4242)

    def test_event_time_falls_back_without_proc(self):
        with mock.patch.object(control.Path, "read_text", side_effect=FileNotFoundError):
            self.assertEqual(ORIGINAL_EVENT_TIME(), control.PROCESS_FALLBACK_TIME)


class PanelActionTests(unittest.TestCase):
    def test_every_action_the_panel_runs_is_accepted_by_the_dispatcher(self):
        panel = (HERE / "Panel.qml").read_text(encoding="utf-8")
        actions = set(re.findall(r'root\.run\(\["([^"]+)"', panel))
        self.assertIn("cleanup-setup", actions)
        self.assertEqual(sorted(actions - control.VALID_ACTIONS), [])
        self.assertNotIn("cleanup-cleanupPage", panel)
        self.assertNotIn("cleanup cleanupPage", panel)


if __name__ == "__main__":
    unittest.main()
