import math
from pathlib import Path
import struct
import tempfile
import unittest
import wave

import types

import consent_atspi
from acceptance import consent_dialog, tone_metrics


class ToneTests(unittest.TestCase):
    def test_real_capture_comparison_requires_signal_not_just_a_wav_header(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'tone.wav'
            frames = [round(math.sin(2 * math.pi * 440 * n / 16000) * 3276) for n in range(8000)]
            with wave.open(str(path), 'wb') as output:
                output.setparams((1, 2, 16000, 0, 'NONE', ''))
                output.writeframes(struct.pack('<' + 'h' * len(frames), *frames))
            self.assertEqual(tone_metrics(path).get('frames'), 8000)
            self.assertAlmostEqual(tone_metrics(path)['frequency_hz'], 440, delta=3)
            self.assertGreater(tone_metrics(path)['rms'], .05)
            with wave.open(str(path), 'wb') as output:
                output.setparams((1, 2, 16000, 0, 'NONE', ''))
                output.writeframes(b'\0\0' * 8000)
            with self.assertRaises(ValueError):
                tone_metrics(path)

class DiagnosticTests(unittest.TestCase):
    def test_synthetic_failed_command_keeps_bounded_stderr_for_investigation(self):
        import contextlib
        import io
        import os
        import subprocess
        import sys
        from acceptance import run
        output = io.StringIO()
        with contextlib.redirect_stderr(output), self.assertRaises(subprocess.CalledProcessError):
            run([sys.executable, '-c', 'import sys;sys.stderr.write("synthetic helper failure");sys.exit(3)'], dict(os.environ))
        self.assertIn('synthetic helper failure', output.getvalue())

class MappingTests(unittest.TestCase):
    def test_target_file_readiness_does_not_substitute_for_a_mapped_native_node(self):
        from acceptance import mapped_target
        self.assertIsNone(mapped_target({'nodes': []}, 'app.mouthtype.Acceptance'))
        tree = {'nodes': [{'nodes': [{'id': 17, 'app_id': 'app.mouthtype.Acceptance'}]}]}
        self.assertEqual(mapped_target(tree, 'app.mouthtype.Acceptance'),
                         {'id': 17, 'app_id': 'app.mouthtype.Acceptance'})

class ClipboardTests(unittest.TestCase):
    def test_empty_selection_is_pending_without_relaxing_exact_clipboard_check(self):
        import subprocess
        from unittest.mock import patch
        from acceptance import clipboard_ready
        empty = subprocess.CalledProcessError(1, ['wl-paste'], stderr=b'Nothing is copied')
        with patch('acceptance.run', side_effect=empty):
            self.assertFalse(clipboard_ready({}, b'original'))
        with patch('acceptance.run', return_value=subprocess.CompletedProcess([], 0, stdout=b'original')):
            self.assertTrue(clipboard_ready({}, b'original'))
        with patch('acceptance.run', return_value=subprocess.CompletedProcess([], 0, stdout=b'changed')):
            self.assertFalse(clipboard_ready({}, b'original'))
        with patch('acceptance.run', side_effect=subprocess.CalledProcessError(2, ['wl-paste'])):
            with self.assertRaises(subprocess.CalledProcessError):
                clipboard_ready({}, b'original')

class NativeTargetTests(unittest.TestCase):
    def test_existing_gtk_program_name_is_replaced_before_creating_surface(self):
        import runpy
        import sys
        import types
        from unittest.mock import patch
        name = ['wayland_target.py']
        observed = []
        class SurfaceCreated(Exception):
            pass
        class Application:
            def __init__(self, **kwargs):
                pass
            def connect(self, event, callback):
                self.activate = callback
            def run(self, args):
                self.activate(self)
        def window(**kwargs):
            observed.append(name[0])
            raise SurfaceCreated()
        gi = types.ModuleType('gi')
        gi.require_version = lambda *args: None
        repository = types.ModuleType('gi.repository')
        repository.Gdk = types.SimpleNamespace(KEY_Shift_L=0xffe1, SELECTION_CLIPBOARD=None)
        repository.Gtk = types.SimpleNamespace(Application=Application, ApplicationWindow=window)
        repository.GLib = types.SimpleNamespace(set_prgname=lambda value: name.__setitem__(0, value))
        with patch.dict(sys.modules, {'gi': gi, 'gi.repository': repository}):
            with self.assertRaises(SurfaceCreated):
                runpy.run_path(str(Path(__file__).with_name('wayland_target.py')))
        self.assertEqual(observed, ['app.mouthtype.Acceptance'])

class FakeNode:
    def __init__(self, role='', name='', children=(), checked=False, clickable=False):
        self.role, self.name, self.children, self.checked, self.clickable = role, name, list(children), checked, clickable
        self.actions = 0

    def get_role_name(self):
        return self.role

    def get_name(self):
        return self.name

    def get_child_count(self):
        return len(self.children)

    def get_child_at_index(self, index):
        return self.children[index]

    def get_action_iface(self):
        return self if self.clickable else None

    def do_action(self, index):
        self.actions += 1
        if self.role in ('switch', 'check box'):
            self.checked = True

    def get_state_set(self):
        return self


class FakeAtspi:
    StateType = types.SimpleNamespace(CHECKED='checked')

    def __init__(self, apps):
        self.apps = FakeNode(children=apps)

    def get_desktop(self, index):
        return self.apps


FakeNode.contains = lambda self, state: self.checked


class GnomeConsentTests(unittest.TestCase):
    def dialog(self, **switches):
        return FakeNode('frame', 'Remote Desktop', [
            FakeNode('switch', 'Allow Remote Interaction', clickable=True, checked=switches.get('keyboard', False)),
            FakeNode('switch', 'Allow Clipboard Access', clickable=True),
            FakeNode('check box', 'Remember This Selection', clickable=True),
            FakeNode('button', 'Share', clickable=True)])

    def test_consent_dialog_is_found_only_under_the_portal_application(self):
        window = self.dialog()
        other = FakeNode('application', 'other', [self.dialog()])
        portal = FakeNode('application', 'xdg-desktop-portal-gnome', [FakeNode('frame', 'Settings'), window])
        self.assertIs(consent_dialog(FakeAtspi([other, portal])), window)
        self.assertIsNone(consent_dialog(FakeAtspi([other])))

    def test_answer_switches_on_the_controls_and_presses_share(self):
        window = self.dialog(keyboard=True)
        result = consent_atspi.answer(window, FakeAtspi([]))
        self.assertEqual(result['switched_on'], ['Allow Clipboard Access', 'Remember This Selection'])
        self.assertEqual(result['pressed'], 'Share')
        self.assertEqual(window.children[3].actions, 1)

    def test_answer_without_an_affirmative_button_fails_loudly(self):
        window = FakeNode('frame', 'Remote Desktop', [FakeNode('switch', 'Allow Remote Interaction', clickable=True)])
        with self.assertRaises(ValueError):
            consent_atspi.answer(window, FakeAtspi([]))


if __name__ == '__main__':
    unittest.main()
