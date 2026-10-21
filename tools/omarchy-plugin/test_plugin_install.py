import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("omarchy_plugin_install", HERE / "install.py")
install = importlib.util.module_from_spec(spec)
spec.loader.exec_module(install)

LAYOUT = {"version": 1, "bar": {"layout": {"left": [], "center": [], "right": [{"id": "clock"}]}}}


class InstallFlowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        config = self.home / ".config/omarchy"
        config.mkdir(parents=True)
        self.shell = config / "shell.json"
        names = {
            "CONFIG_ROOT": config, "TARGET": config / "plugins/dstahl.mouthtype", "SHELL": self.shell,
            "UNIT": self.home / ".config/systemd/user/mouthtype-linux.service",
            "BINDINGS": self.home / ".config/hypr/bindings.lua",
            "PREFS": self.home / ".config/mouthtype/omarchy-plugin.json",
        }
        for name, value in names.items():
            patcher = mock.patch.object(install, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.target = names["TARGET"]
        self.names = names
        home = mock.patch.object(install.Path, "home", classmethod(lambda cls: self.home))
        home.start()
        self.addCleanup(home.stop)

    def run_main(self, *argv):
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err), \
                mock.patch.object(install.shutil, "which", lambda name: None), \
                mock.patch.object(install.subprocess, "run", return_value=mock.Mock(returncode=0, stdout="{}", stderr="")):
            install.main(list(argv))
        return err.getvalue()

    def test_missing_shell_config_names_the_file_and_what_it_means(self):
        with self.assertRaisesRegex(ValueError, "Omarchy shell configuration not found at .*shell.json"):
            install.load_shell()

    def test_invalid_shell_json_is_reported_not_traced(self):
        self.shell.write_text("{nope")
        with self.assertRaisesRegex(ValueError, "not valid JSON"):
            install.load_shell()

    def test_install_without_a_speech_setup_warns(self):
        self.shell.write_text(json.dumps(LAYOUT))
        warning = self.run_main("--no-autostart", "--no-restart-shell")
        self.assertIn("mouthtype-linux is not installed", warning)
        self.assertTrue((self.target / "control.py").is_file())

    def test_uninstall_removes_everything_the_install_added_and_keeps_user_data(self):
        self.shell.write_text(json.dumps(LAYOUT))
        self.run_main("--no-autostart", "--no-restart-shell")
        unit = self.names["UNIT"]
        unit.parent.mkdir(parents=True)
        unit.write_text("[Service]\n" + install.UNIT_MARKER + "\n")
        bindings = self.names["BINDINGS"]
        bindings.parent.mkdir(parents=True)
        bindings.write_text("hl.bind('a','b')\n\n" + install.BIND_BEGIN + "\nhl.bind('F10','x')\n" + install.BIND_END + "\n")
        prefs = self.names["PREFS"]
        prefs.parent.mkdir(parents=True)
        prefs.write_text("{}")
        data = self.home / ".local/share/mouthtype/speech-candidate"
        data.mkdir(parents=True)
        self.run_main("--uninstall")
        self.assertFalse(self.target.exists())
        self.assertFalse(unit.exists())
        self.assertFalse(prefs.exists())
        self.assertEqual(bindings.read_text(), "hl.bind('a','b')\n")
        self.assertEqual(json.loads(self.shell.read_text()), LAYOUT)
        self.assertTrue(data.is_dir(), "models and recordings are kept without --purge")

    def test_uninstall_leaves_an_unmanaged_unit_alone(self):
        unit = self.names["UNIT"]
        unit.parent.mkdir(parents=True)
        unit.write_text("[Service]\nExecStart=/bin/true\n")
        self.assertIn("Left", self.run_main("--uninstall"))
        self.assertTrue(unit.exists())

    def test_purge_deletes_user_data(self):
        data = self.home / ".local/share/mouthtype"
        data.mkdir(parents=True)
        (data / "model").write_text("x")
        self.run_main("--uninstall", "--purge")
        self.assertFalse(data.exists())


if __name__ == "__main__":
    unittest.main()
