import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("omarchy_control", HERE / "control.py")
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


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
