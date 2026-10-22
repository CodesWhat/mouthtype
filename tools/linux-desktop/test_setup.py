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
        detect = mock.patch.object(setup, 'detect_desktop', lambda: 'hyprland')
        detect.start()
        self.addCleanup(detect.stop)

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
            args = mock.Mock(cleanup=None, build_server=False)
            with mock.patch.object(setup.sys.stdin, 'isatty', return_value=False):
                setup.offer_cleanup(args, config, run=None, ask=lambda prompt: self.fail('prompted without a terminal'))
            prepared = []
            ran = []
            with mock.patch.object(setup.sys.stdin, 'isatty', return_value=True), \
                    mock.patch.object(setup.sys.stdout, 'isatty', return_value=True), \
                    mock.patch.object(setup, 'missing_packages', lambda table, which=None: self.fail('checked build tools without --build-server')), \
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
                setup.offer_cleanup(mock.Mock(cleanup='fast', build_server=True), config, run=None, cleanup=built)
            built.assert_not_called()
            self.assertIn('sudo pacman -S --needed cmake', shown.call_args[0][0])
            self.assertIn('--build-server', shown.call_args[0][0])


if __name__ == '__main__':
    unittest.main()


class PortalDesktopTests(unittest.TestCase):
    """GNOME and KDE: no Omarchy plugin, the service, the typing grant and the autostart entry instead."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        (self.root / 'speech').mkdir()
        (self.root / 'speech/linux.json').write_text('{}')
        self.commands = []
        self.record = mock.Mock()
        env = {'HOME': str(self.home), 'XDG_CONFIG_HOME': str(self.home / '.config'), 'XDG_SESSION_TYPE': 'wayland'}
        for patcher in (mock.patch.dict(setup.os.environ, env), mock.patch.object(setup, 'record_firstrun', self.record),
                        mock.patch.object(setup, 'find_launcher', lambda: '/usr/bin/mouthtype-linux'),
                        mock.patch.object(setup, 'missing_commands', lambda table, which=None: []),
                        mock.patch.object(setup.Path, 'home', classmethod(lambda cls: self.home)),
                        mock.patch.object(setup, 'VENDOR_UNIT', self.root / 'no-vendor.service'),
                        mock.patch.object(setup.sys, 'platform', 'linux'), mock.patch('sys.stdout')):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.host = self.root / 'mouthtype-desktop'
        self.host.write_text('#!/bin/sh\n')
        self.host.chmod(0o755)

    def runner(self, command, **kwargs):
        self.commands.append(command)
        return mock.Mock(returncode=0, stdout='ok')

    def main(self, *argv, grant=None):
        return setup.main(['--destination', str(self.root / 'speech'), '--cleanup', 'skip', '--host', str(self.host),
                           *argv], run=self.runner, speech=mock.Mock(return_value=0), grant=grant)

    def test_gnome_skips_the_plugin_and_never_needs_the_omarchy_shell(self):
        plugin = self.root / 'plugin'
        plugin.mkdir()
        (plugin / 'install.py').write_text('')
        self.assertEqual(self.main('--desktop', 'gnome', '--plugin-dir', str(plugin), grant=lambda: 'active'), 0)
        self.assertFalse([c for c in self.commands if c and str(plugin) in ' '.join(map(str, c))])
        self.record.assert_called_with('done')

    def test_service_is_enabled_and_a_managed_unit_is_written_without_a_packaged_one(self):
        self.assertEqual(self.main('--desktop', 'kde', '--skip-grant'), 0)
        unit = self.home / '.config/systemd/user/mouthtype-linux.service'
        text = unit.read_text()
        self.assertIn(setup.UNIT_MARKER, text)
        self.assertIn('ExecStart=/usr/bin/mouthtype-linux --config ' + str(self.root / 'speech/linux.json') + ' serve', text)
        self.assertIn(['systemctl', '--user', 'enable', '--now', 'mouthtype-linux.service'], self.commands)

    def test_packaged_unit_is_used_as_is(self):
        vendor = self.root / 'mouthtype-linux.service'
        vendor.write_text('')
        with mock.patch.object(setup, 'VENDOR_UNIT', vendor):
            self.assertEqual(self.main('--desktop', 'gnome', '--skip-grant'), 0)
        self.assertFalse((self.home / '.config/systemd/user/mouthtype-linux.service').exists())

    def test_autostart_entry_starts_the_host_in_the_background(self):
        self.main('--desktop', 'gnome', '--skip-grant')
        entry = (self.home / '.config/autostart/app.mouthtype.Mouthtype.desktop').read_text()
        self.assertIn('Exec=' + str(self.host) + ' --page home --background', entry)
        self.assertIn(setup.AUTOSTART_MARKER, entry)

    def test_no_autostart_flag_and_missing_host_add_no_entry(self):
        self.main('--desktop', 'gnome', '--skip-grant', '--no-autostart')
        self.assertFalse((self.home / '.config/autostart').exists())
        with mock.patch.object(setup, 'find_host', lambda explicit=None: None):
            self.main('--desktop', 'gnome', '--skip-grant')
        self.assertFalse((self.home / '.config/autostart').exists())

    def test_python_host_script_is_launched_through_the_interpreter(self):
        script = self.root / 'mouthtype_desktop.py'
        script.write_text('')
        self.assertIn('Exec=' + setup.sys.executable + ' ' + str(script), setup.autostart_entry(script))

    def test_foreign_autostart_file_is_left_alone(self):
        path = self.home / '.config/autostart/app.mouthtype.Mouthtype.desktop'
        path.parent.mkdir(parents=True)
        path.write_text('[Desktop Entry]\nExec=mine\n')
        self.main('--desktop', 'gnome', '--skip-grant')
        self.assertEqual(path.read_text(), '[Desktop Entry]\nExec=mine\n')

    def test_grant_runs_on_a_terminal_and_not_without_one(self):
        grant = mock.Mock(return_value='active')
        with mock.patch.object(setup.sys.stdin, 'isatty', lambda: False):
            self.main('--desktop', 'gnome', grant=grant)
        grant.assert_not_called()
        with mock.patch.object(setup.sys.stdin, 'isatty', lambda: True), mock.patch.object(setup.sys.stdout, 'isatty', lambda: True, create=True):
            self.main('--desktop', 'gnome', grant=grant)
        grant.assert_called_once()
        explicit = mock.Mock(return_value='active')
        with mock.patch.object(setup.sys.stdin, 'isatty', lambda: False):
            self.main('--desktop', 'gnome', '--grant', grant=explicit)
        explicit.assert_called_once()

    def test_a_refused_grant_does_not_fail_setup(self):
        self.assertEqual(self.main('--desktop', 'gnome', '--grant', grant=lambda: 'needs_grant'), 0)
        self.assertIn(['systemctl', '--user', 'enable', '--now', 'mouthtype-linux.service'], self.commands)

    def test_x11_session_is_refused_before_anything_is_changed(self):
        with mock.patch.dict(setup.os.environ, {'XDG_SESSION_TYPE': 'x11'}), mock.patch('sys.stderr'):
            self.assertEqual(self.main('--desktop', 'gnome', '--grant', grant=lambda: 'active'), 2)
        self.assertEqual(self.commands, [])

    def test_failed_doctor_stops_before_the_grant_and_service(self):
        grant = mock.Mock()
        self.runner = lambda command, **kwargs: (self.commands.append(command), mock.Mock(returncode=2, stdout='ERROR'))[1]
        with mock.patch('sys.stderr'):
            self.assertEqual(self.main('--desktop', 'kde', '--grant', grant=grant), 2)
        grant.assert_not_called()
        self.assertEqual(len(self.commands), 1)

    def test_missing_helpers_stop_before_any_download(self):
        speech = mock.Mock()
        with mock.patch.object(setup, 'missing_commands', lambda table, which=None: ['pw-record']), mock.patch('sys.stderr'):
            self.assertEqual(setup.main(['--destination', str(self.root / 'new'), '--desktop', 'gnome'], run=self.runner, speech=speech), 2)
        speech.assert_not_called()

    def test_uninstall_reverses_service_autostart_and_grant(self):
        self.main('--desktop', 'gnome', '--skip-grant')
        grant_file = self.home / '.local/state/mouthtype/portal.json'
        grant_file.parent.mkdir(parents=True)
        grant_file.write_text('{"remote_desktop_grant": "x"}')
        self.commands.clear()
        with mock.patch.dict(setup.os.environ, {'XDG_STATE_HOME': str(self.home / '.local/state')}):
            self.assertEqual(setup.main(['--desktop', 'gnome', '--uninstall', '--purge'], run=self.runner), 0)
        self.assertFalse((self.home / '.config/autostart/app.mouthtype.Mouthtype.desktop').exists())
        self.assertFalse((self.home / '.config/systemd/user/mouthtype-linux.service').exists())
        self.assertFalse(grant_file.exists())
        self.assertIn(['systemctl', '--user', 'disable', 'mouthtype-linux.service'], self.commands)
        self.assertIn(['systemctl', '--user', 'stop', 'mouthtype-linux.service'], self.commands)
        self.record.assert_called_with('uninstalled')

    def test_uninstall_without_purge_keeps_the_grant(self):
        grant_file = self.home / '.local/state/mouthtype/portal.json'
        grant_file.parent.mkdir(parents=True)
        grant_file.write_text('{}')
        with mock.patch.dict(setup.os.environ, {'XDG_STATE_HOME': str(self.home / '.local/state')}):
            setup.main(['--desktop', 'kde', '--uninstall'], run=self.runner)
        self.assertTrue(grant_file.exists())

    def test_grant_typing_stores_nothing_itself_and_closes_what_it_opened(self):
        portal = mock.Mock()
        portal.connect.return_value = portal
        session = mock.Mock()
        session.start.return_value = 'active'
        outcome = setup.grant_typing(portal_factory=lambda: portal, session_factory=lambda p, store: session, store_factory=mock.Mock)
        self.assertEqual(outcome, 'active')
        session.start.assert_called_once_with(interactive=True)
        portal.register.assert_called_once()
        session.close.assert_called_once()
        portal.close.assert_called_once()

    def test_grant_typing_reports_an_unreachable_portal_instead_of_raising(self):
        import portal as portal_module
        with mock.patch('sys.stderr'):
            outcome = setup.grant_typing(portal_factory=lambda: mock.Mock(connect=mock.Mock(side_effect=portal_module.PortalUnavailable('no bus'))),
                                         session_factory=mock.Mock(), store_factory=mock.Mock)
        self.assertEqual(outcome, 'unavailable')
