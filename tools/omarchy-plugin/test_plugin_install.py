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

    def test_install_binds_transform_by_default_and_opt_out_skips_it(self):
        self.shell.write_text(json.dumps(LAYOUT))
        commands = []

        def run(command, **kwargs):
            commands.append(command)
            return mock.Mock(returncode=0, stdout="{}", stderr="")
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(install.shutil, "which", lambda name: None), \
                mock.patch.object(install.subprocess, "run", run):
            install.main(["--no-autostart", "--no-restart-shell"])
        self.assertTrue(any(c[-2:] == ["set-transform-shortcut", "on"] for c in commands))
        shutil_target = self.target
        install.shutil.rmtree(shutil_target)
        self.shell.write_text(json.dumps(LAYOUT))
        commands.clear()
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(install.shutil, "which", lambda name: None), \
                mock.patch.object(install.subprocess, "run", run):
            install.main(["--no-autostart", "--no-restart-shell", "--no-transform-shortcut"])
        self.assertFalse(any("set-transform-shortcut" in c for c in commands))

    def linux_json(self, value):
        path = self.home / ".local/share/mouthtype/speech-candidate/linux.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"engine_config": "/x", **value}))
        return path

    def test_install_moves_default_notifications_to_errors_only(self):
        self.shell.write_text(json.dumps(LAYOUT))
        path = self.linux_json({"notifications": True})
        self.run_main("--no-autostart", "--no-restart-shell")
        self.assertEqual(json.loads(path.read_text())["notifications"], "errors")
        self.assertEqual(json.loads(path.read_text())["engine_config"], "/x")

    def test_install_leaves_an_explicit_notifications_choice_alone(self):
        for value in (False, "errors"):
            with self.subTest(value=value):
                if self.target.exists():
                    install.shutil.rmtree(self.target)
                self.shell.write_text(json.dumps(LAYOUT))
                path = self.linux_json({"notifications": value})
                self.run_main("--no-autostart", "--no-restart-shell")
                self.assertEqual(json.loads(path.read_text())["notifications"], value)

    def test_install_without_a_notifications_key_or_config_changes_nothing(self):
        self.shell.write_text(json.dumps(LAYOUT))
        path = self.linux_json({})
        self.run_main("--no-autostart", "--no-restart-shell")
        self.assertNotIn("notifications", json.loads(path.read_text()))
        install.shutil.rmtree(self.target)
        path.unlink()
        self.shell.write_text(json.dumps(LAYOUT))
        self.run_main("--no-autostart", "--no-restart-shell")
        self.assertFalse(path.exists())

    def test_uninstall_removes_the_transform_block_too(self):
        self.shell.write_text(json.dumps(LAYOUT))
        bindings = self.names["BINDINGS"]
        bindings.parent.mkdir(parents=True)
        bindings.write_text("keep()\n\n" + install.BIND_BEGIN + "\na()\n" + install.BIND_END + "\n\n" +
                            install.TRANSFORM_BEGIN + "\nb()\n" + install.TRANSFORM_END + "\n")
        self.run_main("--uninstall")
        self.assertEqual(bindings.read_text(), "keep()\n")

    def test_omarchy_plugin_add_is_used_when_available_and_the_copy_is_the_fallback(self):
        self.shell.write_text(json.dumps(LAYOUT))
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            if command[0] == "/bin/omarchy-plugin-add":
                self.target.mkdir(parents=True)
                (self.target / "manifest.json").write_text("{}")
                (self.target / "control.py").write_text("from omarchy")
                (self.target / "save_dialog.py").write_text("")
                return mock.Mock(returncode=0, stdout="", stderr="")
            if command[0] == "/bin/git" and "commit" in command:
                self.assertTrue((Path(command[2]) / "manifest.json").is_file())
            return mock.Mock(returncode=0, stdout="{}", stderr="")
        found = {"omarchy-plugin-add": "/bin/omarchy-plugin-add", "git": "/bin/git"}
        out = io.StringIO()
        with contextlib.redirect_stdout(out), mock.patch.object(install.shutil, "which", found.get), \
                mock.patch.object(install.subprocess, "run", run):
            install.main(["--no-autostart", "--no-restart-shell", "--no-transform-shortcut"])
        add = next(c for c in calls if c[0] == "/bin/omarchy-plugin-add")
        self.assertEqual(add[2:], ["--yes", "--enable"])
        self.assertIn("omarchy plugin add", out.getvalue())
        self.assertEqual((self.target / "control.py").read_text(), "from omarchy", "the copy is skipped when Omarchy installed it")
        self.assertIn({"id": "dstahl.mouthtype"}, json.loads(self.shell.read_text())["bar"]["layout"]["right"])

        install.shutil.rmtree(self.target)
        self.shell.write_text(json.dumps(LAYOUT))

        def failing(command, **kwargs):
            return mock.Mock(returncode=1 if command[0] == "/bin/omarchy-plugin-add" else 0, stdout="{}", stderr="shell not running")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), \
                mock.patch.object(install.shutil, "which", found.get), mock.patch.object(install.subprocess, "run", failing):
            install.main(["--no-autostart", "--no-restart-shell", "--no-transform-shortcut"])
        self.assertTrue((self.target / "control.py").is_file(), "falls back to copying the files")

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
