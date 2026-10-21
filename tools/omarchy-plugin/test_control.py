import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
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
install_spec = importlib.util.spec_from_file_location("omarchy_install", HERE / "install.py")
install = importlib.util.module_from_spec(install_spec)
install_spec.loader.exec_module(install)


class AutostartTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.unit = self.root / "user" / "mouthtype-linux.service"
        self.calls = []
        patches = [
            mock.patch.object(control, "UNIT", self.unit),
            mock.patch.object(control, "VENDOR_UNIT", self.root / "vendor" / "mouthtype-linux.service"),
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

    def test_packaged_unit_is_enabled_without_writing_a_user_copy(self):
        vendor = self.root / "vendor" / "mouthtype-linux.service"
        vendor.parent.mkdir()
        vendor.write_text("[Service]\n")
        control.set_autostart("on")
        self.assertFalse(self.unit.exists())
        self.assertEqual([call[0] for call in self.calls], ["enable"])
        wants = self.unit.parent / "graphical-session.target.wants"
        wants.mkdir(parents=True)
        (wants / self.unit.name).symlink_to(vendor)
        self.calls.clear()
        control.set_autostart("off")
        self.assertEqual([call[0] for call in self.calls], ["disable"])

    def test_failed_enable_explains_why_and_leaves_no_unit_behind(self):
        def failing(command, **kwargs):
            return mock.Mock(returncode=1, stdout="", stderr="Failed to connect to bus: No medium found\n")
        with mock.patch.object(control.subprocess, "run", failing):
            with self.assertRaisesRegex(RuntimeError, "daemon-reload failed: Failed to connect to bus.*systemd user session"):
                control.set_autostart("on")
        self.assertFalse(self.unit.exists())

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
            mock.patch.object(control, "recent_dictations", lambda limit=None, previews=True: []),
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
        page = (HERE / "pages" / "TranscribeFilePage.qml").read_text(encoding="utf-8")
        self.assertIn("fileImport.retained", panel)
        self.assertIn("root.host.importRetained", page)
        for action in ("import-copy", "import-save"):
            row = next(line for line in page.splitlines() if 'root.host.run(["%s"])' % action in line)
            self.assertIn("importCanExport", row)


class HoldToTalkTests(unittest.TestCase):
    """Each event is a separate process in production: ordered by launch time, delivered in any order."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.recording = False
        self.calls = []
        self.start_gates = []
        self.stop_gates = []
        self.stop_errors = []
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
                gate = self.stop_gates.pop(0) if self.stop_gates else None
                error = self.stop_errors.pop(0) if self.stop_errors else None
                if error is not None:
                    raise error
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

    def test_stop_for_a_released_hold_finishes_before_a_new_press_can_start(self):
        gate = threading.Event()
        self.press(10)
        self.stop_gates = [gate]
        stopper = self.threaded("stop", 20)
        self.wait_for(lambda: self.calls.count("stop") == 1)
        # The next press is launched after the release but reaches the lock while the stop is still in flight.
        starter = self.threaded("start", 30)
        time.sleep(.2)
        self.assertEqual(self.service_calls(), ["start", "stop"])
        gate.set()
        stopper.join(5)
        starter.join(5)
        self.assertEqual(self.service_calls(), ["start", "stop", "start"])
        self.assertTrue(self.recording)
        self.release(40)
        self.assertFalse(self.recording)

    def test_failed_stop_is_reported_and_leaves_the_lock_and_state_usable(self):
        self.press(10)
        self.stop_errors = [subprocess.TimeoutExpired(["mouthtype-linux", "stop"], 35)]
        with self.assertRaises(RuntimeError):
            self.release(20)
        saved = json.loads(control.HOLD.read_text())
        self.assertTrue(saved["press"]["released"])
        self.press(30)
        self.assertTrue(self.recording)
        self.release(40)
        self.assertFalse(self.recording)

    def test_hung_daemon_during_cleanup_stop_clears_skipped_and_frees_the_lock(self):
        gate = threading.Event()
        self.start_gates = [gate]
        errors = []

        def first():
            try:
                self.event("start", 10)
            except Exception as error:
                errors.append(error)
        thread = threading.Thread(target=first)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.wait_for(lambda: "start" in self.calls)
        self.wait_for(lambda: json.loads(control.HOLD.read_text()).get("press"))
        # Its stop (30) runs normally, then the tap (20) arrives late and is marked skipped.
        self.stop_errors = [None, subprocess.TimeoutExpired(["mouthtype-linux", "stop"], 35)]
        self.release(30)
        self.press(20)
        self.assertTrue(json.loads(control.HOLD.read_text())["press"].get("skipped"))
        gate.set()
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertFalse(json.loads(control.HOLD.read_text())["press"].get("skipped"))
        self.press(50)
        self.assertTrue(self.recording)

    def test_oserror_from_the_cleanup_stop_is_also_contained(self):
        gate = threading.Event()
        self.start_gates = [gate]
        thread = self.threaded("start", 10)
        self.wait_for(lambda: "start" in self.calls)
        self.wait_for(lambda: json.loads(control.HOLD.read_text()).get("press"))
        self.stop_errors = [None, OSError("launcher vanished")]
        self.release(30)
        self.press(20)
        gate.set()
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertFalse(json.loads(control.HOLD.read_text())["press"].get("skipped"))

    def test_event_time_reads_process_start_after_the_last_parenthesis(self):
        fields = ["S"] + ["0"] * 18 + ["4242"] + ["0"] * 10
        line = "123 (odd ) name (x) " + " ".join(fields) + "\n"
        with mock.patch.object(control.Path, "read_text", lambda self, *a, **k: line):
            self.assertEqual(ORIGINAL_EVENT_TIME(), 4242)

    def test_event_time_falls_back_without_proc(self):
        with mock.patch.object(control.Path, "read_text", side_effect=FileNotFoundError):
            self.assertEqual(ORIGINAL_EVENT_TIME(), control.PROCESS_FALLBACK_TIME)


class SetupRunningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.pidfile = Path(self.directory.name) / "cleanup-setup.pid"
        self.alive = {4242: (777, "/usr/bin/python3 /x/setup_cleanup.py --destination /y --level fast")}
        patches = [
            mock.patch.object(control, "SETUP_PID", self.pidfile),
            mock.patch.object(control, "process_start", lambda pid: self.alive.get(pid, (None, ""))[0]),
            mock.patch.object(control, "process_command", lambda pid: self.alive.get(pid, (None, ""))[1]),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def write(self, value):
        self.pidfile.write_text(value if isinstance(value, str) else json.dumps(value), encoding="utf-8")

    def test_no_pidfile_means_not_running(self):
        self.assertFalse(control.setup_running())

    def test_matching_pid_start_time_and_command_is_running(self):
        self.write({"pid": 4242, "start": 777})
        self.assertTrue(control.setup_running())

    def test_reused_pid_with_a_different_start_time_is_not_running(self):
        self.write({"pid": 4242, "start": 700})
        self.assertFalse(control.setup_running())

    def test_unrelated_process_on_the_pid_is_not_running(self):
        self.alive[4242] = (777, "/usr/bin/vim notes.txt")
        self.write({"pid": 4242, "start": 777})
        self.assertFalse(control.setup_running())

    def test_exited_process_is_not_running(self):
        self.write({"pid": 999, "start": 777})
        self.assertFalse(control.setup_running())

    def test_malformed_pidfile_is_not_running(self):
        for content in ["", "nope", "[]", "{}", {"pid": "4242", "start": 777}, {"pid": True, "start": 777},
                        {"pid": 4242}]:
            with self.subTest(content=content):
                self.write(content)
                self.assertFalse(control.setup_running())


class ShortcutBlockTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.bindings = Path(self.directory.name) / "bindings.lua"
        self.bindings.write_text('local o = require("omarchy")\n', encoding="utf-8")
        patches = [
            mock.patch.object(control, "BINDINGS", self.bindings),
            mock.patch.object(control, "state", lambda: {}),
            mock.patch.object(control.subprocess, "run", self.fake_run),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def fake_run(self, command, **kwargs):
        return mock.Mock(returncode=0, stdout="[]" if "binds" in command else "", stderr="")

    def test_toggle_uses_the_omarchy_helper_only_when_it_exists(self):
        control.set_shortcut("toggle", "super+alt+m")
        text = self.bindings.read_text(encoding="utf-8")
        self.assertIn('if type(o) == "table" and type(o.bind) == "function" then', text)
        self.assertIn('o.bind("SUPER + ALT + M", "Toggle Mouthtype dictation"', text)
        self.assertRegex(text, r'else\n  hl\.bind\("SUPER \+ ALT \+ M", hl\.dsp\.exec_cmd\(".* toggle"\)\)\nend')
        info = control.shortcut_info()
        self.assertEqual(info, {"mode": "toggle", "keys": "SUPER + ALT + M"})

    def test_hold_block_is_still_recognised_as_hold(self):
        control.set_shortcut("hold", "F9")
        self.assertEqual(control.shortcut_info(), {"mode": "hold", "keys": "F9"})
        self.assertIn("release = true", self.bindings.read_text(encoding="utf-8"))

    def test_switching_back_to_off_removes_the_block(self):
        control.set_shortcut("toggle", "F10")
        control.set_shortcut("off")
        self.assertEqual(control.shortcut_info()["mode"], "off")
        self.assertNotIn("Mouthtype", self.bindings.read_text(encoding="utf-8"))


class TransformShortcutTests(ShortcutBlockTests):
    def test_on_writes_its_own_block_and_leaves_the_dictation_block_alone(self):
        control.set_shortcut("toggle", "super+alt+m")
        control.set_transform_shortcut("on")
        text = self.bindings.read_text(encoding="utf-8")
        self.assertIn(control.TRANSFORM_BEGIN, text)
        self.assertRegex(text, r'o\.bind\("SUPER \+ SHIFT \+ T", "Mouthtype transform selection", ".*control\.py transform-open"\)')
        self.assertEqual(control.shortcut_info(), {"mode": "toggle", "keys": "SUPER + ALT + M"})
        self.assertEqual(control.transform_shortcut_keys(), "SUPER + SHIFT + T")

    def test_on_twice_is_idempotent_and_off_removes_only_the_transform_block(self):
        control.set_shortcut("toggle", "F10")
        control.set_transform_shortcut("on")
        once = self.bindings.read_text(encoding="utf-8")
        control.set_transform_shortcut("on")
        self.assertEqual(self.bindings.read_text(encoding="utf-8"), once)
        control.set_transform_shortcut("off")
        text = self.bindings.read_text(encoding="utf-8")
        self.assertNotIn("transform", text)
        self.assertEqual(control.shortcut_info()["keys"], "F10")

    def test_a_key_hyprland_already_uses_is_refused_and_the_file_is_unchanged(self):
        before = self.bindings.read_text(encoding="utf-8")
        taken = '[{"key": "T", "modmask": %d}]' % (control.MODIFIER_MASKS["SUPER"] + control.MODIFIER_MASKS["SHIFT"])
        with mock.patch.object(control.subprocess, "run", lambda c, **k: mock.Mock(returncode=0, stdout=taken if "binds" in c else "", stderr="")):
            with self.assertRaisesRegex(RuntimeError, "already bound"):
                control.set_transform_shortcut("on")
        self.assertEqual(self.bindings.read_text(encoding="utf-8"), before)

    def test_the_dictation_key_is_refused_for_transform(self):
        control.set_shortcut("toggle", "super+shift+t")
        with self.assertRaisesRegex(RuntimeError, "dictation shortcut"):
            control.set_transform_shortcut("on")


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def test_install_reads_plugin_and_app_versions_from_a_checkout(self):
        source = self.root / "tools/omarchy-plugin"
        (self.root / "packaging").mkdir()
        source.mkdir(parents=True)
        (source / "manifest.json").write_text('{"version": "1.3.0"}', encoding="utf-8")
        (self.root / "packaging/Version.plist").write_bytes(
            b'<?xml version="1.0"?><plist version="1.0"><dict><key>MouthtypeDisplayVersion</key>'
            b'<string>0.3.0</string></dict></plist>')
        self.assertEqual(install.read_versions(source), {"plugin": "1.3.0", "app": "0.3.0"})

    def test_install_leaves_app_version_empty_without_the_repository(self):
        source = self.root / "tools/omarchy-plugin"
        source.mkdir(parents=True)
        (source / "manifest.json").write_text('{"version": "1.3.0"}', encoding="utf-8")
        self.assertEqual(install.read_versions(source), {"plugin": "1.3.0", "app": None})

    def test_install_survives_unreadable_inputs(self):
        source = self.root / "tools/omarchy-plugin"
        (self.root / "packaging").mkdir()
        source.mkdir(parents=True)
        (source / "manifest.json").write_text("[", encoding="utf-8")
        (self.root / "packaging/Version.plist").write_text("not a plist", encoding="utf-8")
        self.assertEqual(install.read_versions(source), {"plugin": None, "app": None})

    def test_written_version_file_is_what_the_plugin_reports(self):
        installed = self.root / "installed"
        installed.mkdir()
        install.write_versions(installed, {"plugin": "1.3.0", "app": "0.3.0"})
        (installed / "manifest.json").write_text('{"version": "9.9.9"}', encoding="utf-8")
        with mock.patch.object(control, "PLUGIN_DIR", installed):
            self.assertEqual(control.versions(), {"plugin": "1.3.0", "app": "0.3.0"})

    def test_a_source_checkout_falls_back_to_the_manifest(self):
        (self.root / "manifest.json").write_text('{"version": "1.3.0"}', encoding="utf-8")
        with mock.patch.object(control, "PLUGIN_DIR", self.root):
            self.assertEqual(control.versions(), {"plugin": "1.3.0", "app": None})

    def test_missing_files_give_empty_versions(self):
        with mock.patch.object(control, "PLUGIN_DIR", self.root):
            self.assertEqual(control.versions(), {"plugin": None, "app": None})


class ControlModuleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "control_example.py").write_text(
            "def echo(*words):\n    return {'words': list(words)}\n"
            "def boom():\n    raise RuntimeError('no thanks')\n"
            "def state():\n    return {'hijacked': True}\n"
            "COMMANDS = {'echo': echo, 'boom': boom, 'state': state, 'Bad Name': echo}\n", encoding="utf-8")
        (self.root / "control_broken.py").write_text("COMMANDS = {\n", encoding="utf-8")
        (self.root / "control_nocommands.py").write_text("X = 1\n", encoding="utf-8")
        (self.root / "control_Upper.py").write_text("COMMANDS = {'upper': lambda: {}}\n", encoding="utf-8")
        (self.root / "control_later.py").write_text("COMMANDS = {'echo': lambda: {'later': True}, 'late-only': lambda: {'ok': 1}}\n",
                                                    encoding="utf-8")
        (self.root / "control_data.py").write_text(
            "from __future__ import annotations\nfrom dataclasses import dataclass\n@dataclass\nclass R:\n    m: str\n"
            "def data():\n    return {'m': R('ok').m}\nCOMMANDS = {'data': data}\n", encoding="utf-8")
        (self.root / "notcontrol.py").write_text("COMMANDS = {'sneaky': lambda: {}}\n", encoding="utf-8")
        patches = [
            mock.patch.object(control, "PLUGIN_DIR", self.root),
            mock.patch.object(control, "LOG", self.root / "state" / "control.log"),
            mock.patch.object(control, "_module_commands", None),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def run_main(self, *argv):
        out = io.StringIO()
        with mock.patch.object(sys, "argv", ["control.py", *argv]), contextlib.redirect_stdout(out):
            code = control.main()
        return code, json.loads(out.getvalue())

    def test_modules_are_loaded_by_name_and_bad_ones_are_skipped(self):
        commands = control.module_commands()
        self.assertEqual(sorted(commands), ["boom", "data", "echo", "late-only"])
        log = control.LOG.read_text(encoding="utf-8")
        self.assertIn("control_broken.py was not loaded", log)
        self.assertIn("control_nocommands.py was not loaded", log)
        self.assertIn("ignored command 'state'", log)
        self.assertIn("ignored invalid command 'Bad Name'", log)
        self.assertIn("ignored command 'echo'", log)

    def test_module_using_dataclasses_with_postponed_annotations_loads(self):
        self.assertEqual(control.module_commands()["data"](), {"m": "ok"})
        self.assertNotIn("mouthtype_control_broken", sys.modules)

    def test_first_module_alphabetically_owns_a_clashing_verb(self):
        self.assertEqual(control.module_commands()["echo"]("x"), {"words": ["x"]})

    def test_available_actions_include_module_verbs_and_the_built_ins(self):
        actions = control.available_actions()
        self.assertTrue({"echo", "late-only", "toggle", "state"} <= actions)
        self.assertNotIn("sneaky", actions)
        self.assertNotIn("upper", actions)

    def test_main_runs_a_module_verb_with_its_arguments(self):
        self.assertEqual(self.run_main("echo", "a", "b"), (0, {"words": ["a", "b"]}))

    def test_module_error_is_reported_as_json(self):
        self.assertEqual(self.run_main("boom"), (1, {"error": "no thanks"}))

    def test_wrong_argument_count_is_refused_without_calling_the_verb(self):
        self.assertEqual(self.run_main("boom", "extra"), (1, {"error": "Invalid control arguments"}))

    def test_built_in_actions_are_not_shadowed(self):
        with mock.patch.object(control, "state", lambda: {"built_in": True}):
            self.assertEqual(self.run_main("state"), (0, {"built_in": True}))

    def test_unknown_verb_is_still_rejected(self):
        self.assertEqual(self.run_main("nothing"), (2, {"error": "Unknown control action"}))

    def test_missing_plugin_directory_loads_nothing(self):
        with mock.patch.object(control, "PLUGIN_DIR", self.root / "absent"), mock.patch.object(control, "_module_commands", None):
            self.assertEqual(control.module_commands(), {})


class PanelActionTests(unittest.TestCase):
    def test_every_action_the_panel_runs_is_accepted_by_the_dispatcher(self):
        sources = [HERE / "Panel.qml", *sorted(HERE.glob("Mouthtype*.qml")), *sorted((HERE / "pages").glob("*.qml"))]
        panel = "\n".join(path.read_text(encoding="utf-8") for path in sources)
        actions = set(re.findall(r'(?:root|host)\.run\(\["([^"]+)"', panel))
        self.assertIn("cleanup-setup", actions)
        self.assertEqual(sorted(actions - control.available_actions()), [])
        self.assertNotIn("cleanup-cleanupPage", panel)
        self.assertNotIn("cleanup cleanupPage", panel)


class CapabilitiesCacheTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.launcher = Path(self.directory.name) / "launcher"
        self.launcher.write_text("", encoding="utf-8")
        self.calls = []
        self.output = json.dumps({"interface": "x", "features": {"a": True}})
        self.returncode = 0
        self.runtime = Path(self.directory.name) / "runtime"
        env = mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": str(self.runtime)})
        env.start()
        self.addCleanup(env.stop)

        def fake_cli(*args, **kwargs):
            self.calls.append(args)
            return mock.Mock(returncode=self.returncode, stdout=self.output)
        for patch in (mock.patch.object(control, "LAUNCHER", self.launcher),
                      mock.patch.object(control, "cli", fake_cli)):
            patch.start()
            self.addCleanup(patch.stop)

    def test_repeated_polls_spawn_the_launcher_once(self):
        first = control.capabilities()
        self.assertEqual(control.capabilities(), first)
        self.assertEqual(first["features"], {"a": True})
        self.assertEqual(len(self.calls), 1)

    def test_replaced_launcher_is_asked_again(self):
        control.capabilities()
        stat = self.launcher.stat()
        os.utime(self.launcher, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000_000))
        control.capabilities()
        self.assertEqual(len(self.calls), 2)

    def test_failed_answer_is_not_cached(self):
        self.returncode = 1
        self.assertEqual(control.capabilities(), {})
        self.assertEqual(control.capabilities(), {})
        self.assertEqual(len(self.calls), 2)
        self.returncode = 0
        self.assertTrue(control.capabilities())
        control.capabilities()
        self.assertEqual(len(self.calls), 3)

    def test_cache_expires_after_the_ttl(self):
        control.capabilities()
        later = time.time() + control.CAPABILITIES_TTL + 1
        with mock.patch.object(control.time, "time", lambda: later):
            control.capabilities()
        self.assertEqual(len(self.calls), 2)

    def test_cache_file_is_private_and_unreadable_cache_falls_back(self):
        control.capabilities()
        path = control.capabilities_cache_path()
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        path.write_text("not json", encoding="utf-8")
        self.assertEqual(control.capabilities()["features"], {"a": True})
        self.assertEqual(len(self.calls), 2)

    def test_cache_falls_back_to_the_user_cache_dir_without_a_runtime_dir(self):
        with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(self.runtime / "c")}):
            os.environ.pop("XDG_RUNTIME_DIR")
            self.assertEqual(control.capabilities_cache_path(), self.runtime / "c/mouthtype/capabilities.json")

    def test_separate_processes_share_the_cache(self):
        marker = Path(self.directory.name) / "spawns"
        launcher = Path(self.directory.name) / "fake-launcher"
        launcher.write_text("#!/bin/sh\necho x >> '%s'\necho '{\"features\": {\"a\": true}}'\n" % marker, encoding="utf-8")
        launcher.chmod(0o755)
        script = ("import importlib.util,sys\n"
                  "from pathlib import Path\n"
                  "s=importlib.util.spec_from_file_location('c', sys.argv[1]);c=importlib.util.module_from_spec(s);s.loader.exec_module(c)\n"
                  "c.LAUNCHER=Path(sys.argv[2]);c.CONFIG=Path(sys.argv[3])\n"
                  "if len(sys.argv)>4: c.time.time=lambda v=float(sys.argv[4]): v\n"
                  "print(c.capabilities()['features']['a'])\n")
        env = {**os.environ, "XDG_RUNTIME_DIR": str(self.runtime)}

        def run(*extra):
            out = subprocess.run([sys.executable, "-I", "-c", script, str(HERE / "control.py"), str(launcher),
                                  str(launcher), *extra], capture_output=True, text=True, env=env, check=True)
            self.assertEqual(out.stdout.strip(), "True")
            return len(marker.read_text().split())
        self.assertEqual(run(), 1)
        self.assertEqual(run(), 1)
        stat = launcher.stat()
        os.utime(launcher, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000_000))
        self.assertEqual(run(), 2)
        self.assertEqual(run(str(time.time() + control.CAPABILITIES_TTL + 5)), 3)

    def test_missing_launcher_returns_empty_without_spawning(self):
        self.launcher.unlink()
        self.assertEqual(control.capabilities(), {})
        self.assertEqual(self.calls, [])


class SessionSocketTests(unittest.TestCase):
    """Hotkey verbs talk to the service socket directly and fall back to the CLI only when it is missing."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.runtime = Path(self.directory.name)
        patcher = mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": str(self.runtime)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.cli_calls = []
        patcher = mock.patch.object(control, "cli", self.fake_cli)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.requests = []
        self.server = None

    def fake_cli(self, *args, timeout=35):
        self.cli_calls.append(args)
        return subprocess.CompletedProcess(args, 0, json.dumps({"state": "idle", "via": "cli"}), "")

    def serve(self, reply):
        import socket as socket_module
        path = self.runtime / "mouthtype" / "session.sock"
        path.parent.mkdir()
        server = socket_module.socket(socket_module.AF_UNIX)
        server.bind(str(path))
        server.listen(4)
        server.settimeout(5)
        self.addCleanup(server.close)

        def loop():
            while True:
                try:
                    connection, _ = server.accept()
                except OSError:
                    return
                with connection:
                    raw = b""
                    while not raw.endswith(b"\n"):
                        raw += connection.recv(1024)
                    self.requests.append(json.loads(raw))
                    connection.sendall(json.dumps(reply).encode() + b"\n")
        thread = threading.Thread(target=loop, daemon=True)
        thread.start()
        return path

    def test_start_stop_toggle_cancel_status_use_the_socket_and_never_spawn_the_cli(self):
        self.serve({"state": "recording"})
        for verb in ("start", "stop", "toggle", "cancel", "status"):
            self.assertEqual(control.deliver(verb)["state"], "recording")
        self.assertEqual([r["action"] for r in self.requests], ["start", "stop", "toggle", "cancel", "status"])
        self.assertEqual(self.cli_calls, [])
        # Same line the CLI sends: a start carries the admission deadline.
        self.assertIsInstance(self.requests[0]["admit_before"], float)

    def test_missing_socket_falls_back_to_the_cli(self):
        self.assertEqual(control.deliver("start")["via"], "cli")
        self.assertEqual(self.cli_calls, [("start",)])

    def test_verbs_that_need_the_cli_still_use_it(self):
        self.serve({"state": "idle"})
        control.deliver("transcribe", "a" * 32)
        control.deliver("shutdown")
        self.assertEqual(self.requests, [])
        self.assertEqual(len(self.cli_calls), 2)

    def test_stale_socket_fails_like_the_cli_without_a_second_interpreter(self):
        import socket as socket_module
        path = self.runtime / "mouthtype" / "session.sock"
        path.parent.mkdir()
        stale = socket_module.socket(socket_module.AF_UNIX)
        stale.bind(str(path))
        stale.close()
        with self.assertRaises(RuntimeError):
            control.deliver("start")
        self.assertEqual(self.cli_calls, [])

    def test_state_reads_status_from_the_socket(self):
        self.serve({"state": "idle", "maximum_takes": 7, "file_import": None})
        root = self.runtime / "files"
        root.mkdir()
        launcher, config = root / "launcher", root / "linux.json"
        launcher.write_text("")
        config.write_text("{}")
        with mock.patch.object(control, "LAUNCHER", launcher), mock.patch.object(control, "CONFIG", config), \
                mock.patch.object(control, "RECOVERY", root / "recovery"), \
                mock.patch.object(control, "capabilities", lambda: {}):
            report = control.state()
        self.assertTrue(report["running"])
        self.assertEqual(report["state"], "idle")
        self.assertEqual(report["history"]["maximum"], 7)
        self.assertEqual(self.cli_calls, [])

    def test_loading_control_does_not_import_inspect(self):
        script = "import sys, runpy; runpy.run_path(%r, run_name='control_probe'); print('inspect' in sys.modules)" \
                 % str(HERE / "control.py")
        out = subprocess.run([sys.executable, "-I", "-c", script], capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout.strip(), "False")


def reference_recent_dictations(root, limit=5):
    """The pre-scandir implementation, kept as the oracle the new scan must match."""
    if not root.is_dir():
        return []
    takes = [p for p in root.iterdir()
             if p.is_dir() and not p.is_symlink() and len(p.name) == 32
             and all(c in "0123456789abcdef" for c in p.name)]
    recent = []
    for path in sorted(takes, key=lambda p: p.stat().st_mtime, reverse=True)[:limit]:
        transcript = path / "transcript.txt"
        preview = ""
        if transcript.is_file():
            preview = " ".join(transcript.read_text(encoding="utf-8").split())[:36]
        recent.append({"id": path.name, "transcript": transcript.is_file(),
                       "audio": (path / "recording.wav").is_file(),
                       "preview": preview, "mtime": path.stat().st_mtime})
    return recent


class TakeScanTests(unittest.TestCase):
    COUNT = 2000

    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.root = Path(cls.directory.name)
        cls.build(cls.root, cls.COUNT)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def setUp(self):
        cache = tempfile.TemporaryDirectory()
        self.addCleanup(cache.cleanup)
        for patcher in (mock.patch.object(control, "RECOVERY", self.root),
                        mock.patch.object(control, "created_cache_path", lambda: Path(cache.name) / "take-created.json")):
            patcher.start()
            self.addCleanup(patcher.stop)

    @staticmethod
    def build(root, count):
        now = time.time()
        for index in range(count):
            path = root / ("%032x" % index)
            path.mkdir()
            kind = index % 3
            if kind != 2:
                (path / "transcript.txt").write_text("word " * (index % 7 + 1) + "\n tail", encoding="utf-8")
            if kind != 0:
                (path / "recording.wav").write_bytes(b"\0" * 44)
            stamp = now - (count - index) * 700
            (path / "take.json").write_text(json.dumps({"created": stamp}))
            os.utime(path, (stamp, stamp))
        (root / "not-a-take").mkdir()
        (root / ("f" * 32)).write_text("a file named like a take")
        (root / ("e" * 32)).symlink_to(root / ("%032x" % 0), target_is_directory=True)

    def test_matches_the_old_implementation_on_two_thousand_takes(self):
        self.assertEqual(control.recent_dictations(limit=None), reference_recent_dictations(self.root, None))
        self.assertEqual(control.recent_dictations(), reference_recent_dictations(self.root, 5))
        self.assertEqual(control.recent_dictations(limit=3), reference_recent_dictations(self.root, 3))
        old = reference_recent_dictations(self.root, None)
        light = control.recent_dictations(limit=None, previews=False)
        self.assertEqual([{**entry, "preview": ""} for entry in old if True][0]["id"], light[0]["id"])
        self.assertEqual([(e["id"], e["transcript"], e["audio"], e["mtime"]) for e in light],
                         [(e["id"], e["transcript"], e["audio"], e["mtime"]) for e in old])

    def test_words_today_matches_the_old_count(self):
        old = reference_recent_dictations(self.root, None)
        self.assertEqual(control.words_today(), control.words_today(old))
        self.assertGreater(control.words_today(), 0)

    def test_only_the_rows_shown_have_their_transcript_read(self):
        reads = []
        real = Path.read_text
        control.take_rows()  # the first poll fills the creation-time cache
        with mock.patch.object(Path, "read_text", lambda path, *a, **k: reads.append(path) or real(path, *a, **k)):
            control.recent_dictations(limit=5)
            self.assertLessEqual(len([p for p in reads if p.name == "transcript.txt"]), 5)
            self.assertFalse([path for path in reads if path.name == "take.json"], "a warm poll must not read take.json")
            reads.clear()
            control.recent_dictations(limit=None, previews=False)
            self.assertEqual([p.name for p in reads], ["take-created.json"])

    def test_state_reads_five_previews_not_the_whole_history(self):
        reads = []
        real = Path.read_text
        files = self.root / "files"
        files.mkdir()
        (files / "l").write_text("")
        (files / "c").write_text("{}")
        with mock.patch.object(control, "LAUNCHER", files / "l"), mock.patch.object(control, "CONFIG", files / "c"), \
                mock.patch.object(control, "session_call", lambda *a, **k: subprocess.CompletedProcess(a, 2, "", "")), \
                mock.patch.object(control, "capabilities", lambda: {}), \
                mock.patch.object(control, "config_summary", lambda: {}), \
                mock.patch.object(control, "preferences", lambda: {"sounds": False, "pill": {}, "font": {}}), \
                mock.patch.object(control, "cleanup_models", lambda: {}), \
                mock.patch.object(control, "unit_enabled", lambda: False), \
                mock.patch.object(control, "shortcut_mode", lambda: "off"), \
                mock.patch.object(control, "shortcut_info", lambda: {"keys": ""}), \
                mock.patch.object(control, "versions", lambda: {}), \
                mock.patch.object(Path, "read_text", lambda path, *a, **k: reads.append(path) or real(path, *a, **k)):
            report = control.state()
        old = reference_recent_dictations(self.root, None)
        self.assertEqual(report["history"]["takes"], len(old))
        self.assertEqual(report["recent"], [e for e in old if e["transcript"]][:5])
        self.assertEqual(report["saved"], [{**e, "preview": ""} for e in old if e["audio"] and not e["transcript"]])
        self.assertEqual(report["words_today"], control.words_today(old))
        previews = [p for p in reads if p.parent.parent == self.root and p.name == "transcript.txt"]
        # Five previews, plus the transcripts of takes made today for the word count.
        self.assertLessEqual(len(previews), 5 + sum(1 for e in old if e["transcript"] and time.localtime(e["mtime"]).tm_yday == time.localtime().tm_yday))

    def test_latest_transcript_stops_at_the_newest_take_with_text(self):
        newest = next(e for e in reference_recent_dictations(self.root, None) if e["transcript"])
        checked = []
        real = Path.is_file
        with mock.patch.object(Path, "is_file", lambda path: checked.append(path) or real(path)), \
                mock.patch.object(control, "recover", lambda identity: {"text": identity}):
            self.assertEqual(control.latest_transcript(), newest["id"])
        self.assertLessEqual(len(checked), 3)

    def test_recent_dictations_order_by_creation_time_after_a_wav_is_retired(self):
        small = Path(tempfile.mkdtemp(dir=self.root.parent))
        self.addCleanup(shutil.rmtree, small)
        now = time.time()
        for name, created in (("a" * 32, now - 100 * 86400), ("b" * 32, now - 60), ("c" * 32, now - 120)):
            (small / name).mkdir()
            (small / name / "take.json").write_text(json.dumps({"created": created}))
            (small / name / "transcript.txt").write_text(name[0] + " words")
        (small / ("d" * 32)).mkdir()  # no take.json: falls back to its directory mtime
        (small / ("d" * 32) / "transcript.txt").write_text("d words")
        os.utime(small / ("d" * 32), (now - 600, now - 600))
        # Retiring the old take's expired WAV rewrites its directory, so its mtime is the newest.
        os.utime(small / ("a" * 32), (now + 5, now + 5))
        with mock.patch.object(control, "RECOVERY", small):
            order = [entry["id"][0] for entry in control.recent_dictations(limit=None)]
            self.assertEqual(order, ["b", "c", "d", "a"])
            self.assertEqual([e["id"][0] for e in control.recent_dictations(limit=2)], ["b", "c"])
            # A deleted take leaves the cache; a repeat poll gives the same answer from the cache.
            shutil.rmtree(small / ("c" * 32))
            self.assertEqual([e["id"][0] for e in control.recent_dictations(limit=None)], ["b", "d", "a"])
            cached = json.loads(control.created_cache_path().read_text())
            self.assertEqual(sorted(name[0] for name in cached), ["a", "b"])

    def test_a_reused_take_name_does_not_keep_the_old_creation_time(self):
        small = Path(tempfile.mkdtemp(dir=self.root.parent))
        self.addCleanup(shutil.rmtree, small)
        now = time.time()
        def make(name, created):
            (small / name).mkdir()
            (small / name / "take.json").write_text(json.dumps({"created": created}))
            (small / name / "transcript.txt").write_text(name[0] + " words")
        make("a" * 32, now - 1000)
        make("b" * 32, now - 500)
        with mock.patch.object(control, "RECOVERY", small):
            self.assertEqual([n[0] for n, _ in control.take_rows()], ["b", "a"])
            # The name "a" is reused by a newer take (forgotten, then a new take drew the same name).
            shutil.rmtree(small / ("a" * 32))
            make("a" * 32, now - 10)
            self.assertEqual([n[0] for n, _ in control.take_rows()], ["a", "b"])
            # Same size, same second: only the inode or mtime can tell them apart; a rewrite in place is caught too.
            (small / ("b" * 32) / "take.json").write_text(json.dumps({"created": now + 50}))
            self.assertEqual([n[0] for n, _ in control.take_rows()], ["b", "a"])

    def test_latest_transcript_uses_creation_time_not_directory_mtime(self):
        small = Path(tempfile.mkdtemp(dir=self.root.parent))
        self.addCleanup(shutil.rmtree, small)
        now = time.time()
        for name, created, text in (("a" * 32, now - 100 * 86400, "old words"), ("b" * 32, now - 60, "new words")):
            (small / name).mkdir()
            (small / name / "take.json").write_text(json.dumps({"created": created}))
            (small / name / "transcript.txt").write_text(text)
        # Retiring the old take's expired WAV rewrites its directory, so its mtime is the newest.
        os.utime(small / ("a" * 32), (now + 5, now + 5))
        with mock.patch.object(control, "RECOVERY", small), \
                mock.patch.object(control, "recover", lambda identity: {"text": identity}):
            self.assertEqual(control.latest_transcript(), "b" * 32)

    def test_prune_selects_targets_from_the_scan(self):
        small = Path(tempfile.mkdtemp(dir=self.root.parent))
        self.addCleanup(shutil.rmtree, small)
        self.build(small, 10)
        forgotten = []
        with mock.patch.object(control, "RECOVERY", small), mock.patch.object(control, "cli", lambda *a, **k: forgotten.append(a[1]) or subprocess.CompletedProcess(a, 0, "", "")), \
                mock.patch.object(control, "state", lambda: {}):
            control.prune("keep", "4")
        oldest = [e["id"] for e in reversed(reference_recent_dictations(small, None))][:6]
        self.assertEqual(forgotten, oldest)


if __name__ == "__main__":
    unittest.main()
