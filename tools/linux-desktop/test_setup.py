import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('linux_setup', Path(__file__).with_name('setup.py'))
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class SetupTests(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
