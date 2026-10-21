import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('linux_setup', Path(__file__).with_name('setup.py'))
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class SetupTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(setup, 'record_firstrun', mock.Mock())
        self.record = patcher.start()
        self.addCleanup(patcher.stop)

    def test_missing_packages_maps_commands_to_arch_packages(self):
        have = {'curl'}
        found = setup.missing_packages(setup.REQUIRED, lambda name: name if name in have else None)
        self.assertEqual(found, ['pipewire-audio'])

    def test_missing_launcher_stops_with_the_install_command(self):
        with mock.patch.object(setup, 'find_launcher', lambda: None), mock.patch.object(setup.sys, 'platform', 'linux'), \
            mock.patch('sys.stderr') as err:
            self.assertEqual(setup.main(['--skip-plugin']), 2)
        self.assertIn('install.py', ''.join(call.args[0] for call in err.write.call_args_list))

    def test_prepared_speech_is_not_downloaded_again_and_plugin_runs_with_update(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'speech').mkdir()
            (root / 'speech/linux.json').write_text('{}')
            plugin = root / 'plugin'
            plugin.mkdir()
            (plugin / 'install.py').write_text('')
            home = root / 'home'
            (home / '.config/omarchy/plugins/dstahl.mouthtype').mkdir(parents=True)
            (home / '.config/omarchy/shell.json').write_text('{}')
            commands = []

            def run(command, **kwargs):
                commands.append(command)
                return mock.Mock(returncode=0, stdout='ok')
            speech = mock.Mock(return_value=0)
            with mock.patch.object(setup, 'find_launcher', lambda: '/usr/bin/mouthtype-linux'), \
                    mock.patch.object(setup, 'missing_packages', lambda table, which=None: []), \
                    mock.patch.object(setup.Path, 'home', classmethod(lambda cls: home)), \
                    mock.patch.object(setup.sys, 'platform', 'linux'):
                status = setup.main(['--destination', str(root / 'speech'), '--plugin-dir', str(plugin),
                                     '--no-restart-shell'], run=run, speech=speech)
            self.assertEqual(status, 0)
            speech.assert_not_called()
            self.assertIn('--update', commands[-1])
            self.assertIn('--no-restart-shell', commands[-1])

    def test_missing_omarchy_shell_stops_before_any_download(self):
        with tempfile.TemporaryDirectory() as temp:
            plugin = Path(temp) / 'plugin'
            plugin.mkdir()
            (plugin / 'install.py').write_text('')
            speech = mock.Mock(return_value=0)
            with mock.patch.object(setup, 'find_launcher', lambda: '/x/mouthtype-linux'), \
                    mock.patch.object(setup, 'missing_packages', lambda table, which=None: []), \
                    mock.patch.object(setup.Path, 'home', classmethod(lambda cls: Path(temp))), \
                    mock.patch.object(setup.sys, 'platform', 'linux'), mock.patch('sys.stderr'):
                self.assertEqual(setup.main(['--destination', temp + '/s', '--plugin-dir', str(plugin)], speech=speech), 2)
            speech.assert_not_called()

    def test_uninstall_runs_the_plugin_uninstaller_with_purge(self):
        with tempfile.TemporaryDirectory() as temp:
            plugin = Path(temp)
            (plugin / 'install.py').write_text('')
            commands = []

            def run(command, **kwargs):
                commands.append(command)
                return mock.Mock(returncode=0)
            with mock.patch.object(setup.sys, 'platform', 'linux'):
                self.assertEqual(setup.main(['--uninstall', '--purge', '--plugin-dir', temp], run=run), 0)
            self.assertEqual(commands[0][-2:], ['--uninstall', '--purge'])

    def test_failed_doctor_stops_before_the_plugin(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'linux.json').write_text('{}')
            commands = []

            def run(command, **kwargs):
                commands.append(command)
                return mock.Mock(returncode=2, stdout='ERROR models')
            with mock.patch.object(setup, 'find_launcher', lambda: '/x/mouthtype-linux'), \
                    mock.patch.object(setup, 'missing_packages', lambda table, which=None: []), \
                    mock.patch.object(setup.sys, 'platform', 'linux'):
                self.assertEqual(setup.main(['--destination', temp, '--skip-plugin'], run=run), 2)
            self.assertEqual(len(commands), 1)

    def test_uninstall_and_a_finished_setup_leave_markers_for_the_login_unit(self):
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / 'install.py').write_text('')
            with mock.patch.object(setup.sys, 'platform', 'linux'):
                setup.main(['--uninstall', '--plugin-dir', temp], run=lambda c, **k: mock.Mock(returncode=0))
            self.record.assert_called_with('uninstalled')

    def test_transform_opt_out_reaches_the_plugin_installer(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'speech').mkdir()
            (root / 'speech/linux.json').write_text('{}')
            plugin = root / 'plugin'
            plugin.mkdir()
            (plugin / 'install.py').write_text('')
            home = root / 'home'
            (home / '.config/omarchy').mkdir(parents=True)
            (home / '.config/omarchy/shell.json').write_text('{}')
            commands = []

            def run(command, **kwargs):
                commands.append(command)
                return mock.Mock(returncode=0, stdout='ok')
            with mock.patch.object(setup, 'find_launcher', lambda: '/x/l'), \
                    mock.patch.object(setup, 'missing_packages', lambda table, which=None: []), \
                    mock.patch.object(setup.Path, 'home', classmethod(lambda cls: home)), \
                    mock.patch.object(setup.sys, 'platform', 'linux'):
                setup.main(['--destination', str(root / 'speech'), '--plugin-dir', str(plugin), '--no-transform-shortcut',
                            '--cleanup', 'skip'], run=run)
            self.assertIn('--no-transform-shortcut', commands[-1])
            self.record.assert_called_with('done')

    def test_an_incomplete_speech_directory_is_moved_aside_so_a_retry_can_run(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'speech-candidate'
            target.mkdir()
            (target / 'partial.tar.bz2').write_text('x')
            (Path(temp) / 'speech-candidate.incomplete').mkdir()
            setup.set_aside_incomplete(target)
            self.assertFalse(target.exists())
            self.assertTrue((Path(temp) / 'speech-candidate.incomplete/partial.tar.bz2').is_file())
            complete = Path(temp) / 'other'
            complete.mkdir()
            setup.set_aside_incomplete(complete)
            self.assertTrue(complete.is_dir(), 'only the default setup directory is ever moved')

    def test_cleanup_offer_asks_only_on_a_terminal_and_wires_linux_json(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / 'linux.json'
            config.write_text('{"cleanup": "basic"}')
            args = mock.Mock(cleanup=None)
            with mock.patch.object(setup.sys.stdin, 'isatty', return_value=False):
                setup.offer_cleanup(args, config, run=None, ask=lambda prompt: self.fail('prompted without a terminal'))
            prepared = []
            ran = []
            with mock.patch.object(setup.sys.stdin, 'isatty', return_value=True), \
                    mock.patch.object(setup.sys.stdout, 'isatty', return_value=True), \
                    mock.patch.object(setup, 'missing_packages', lambda table, which=None: []), \
                    mock.patch.object(setup, 'CLEANUP_DESTINATION', Path(temp) / 'cleanup'):
                setup.offer_cleanup(args, config, run=lambda c, **k: ran.append(c), ask=lambda prompt: 'f',
                                    cleanup=lambda argv: prepared.append(argv) or 0)
            self.assertEqual(prepared[0][-2:], ['--level', 'fast'])
            data = json.loads(config.read_text())
            self.assertEqual((data['cleanup'], data['cleanup_engine']), ('fast', str(Path(temp) / 'cleanup/cleanup.json')))
            self.assertEqual(ran[0][:3], ['systemctl', '--user', 'try-restart'])

    def test_cleanup_offer_names_missing_build_tools_instead_of_building(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / 'linux.json'
            config.write_text('{}')
            built = mock.Mock(return_value=0)
            with mock.patch.object(setup, 'missing_packages', lambda table, which=None: ['cmake']), \
                    mock.patch('builtins.print') as shown:
                setup.offer_cleanup(mock.Mock(cleanup='fast'), config, run=None, cleanup=built)
            built.assert_not_called()
            self.assertIn('sudo pacman -S --needed cmake', shown.call_args[0][0])


if __name__ == '__main__':
    unittest.main()
