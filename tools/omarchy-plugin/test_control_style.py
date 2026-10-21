import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

PLUGIN = Path(__file__).resolve().parent
sys.path.insert(0, str(PLUGIN))
import control_style  # noqa: E402


class ControlStyleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = Path(self.directory.name) / 'linux.json'
        self.config.write_text(json.dumps({'engine_config': 'x.json'}))
        patch = mock.patch.object(control_style, '_paths', lambda: (self.config, PLUGIN.parent / 'linux-desktop'))
        patch.start()
        self.addCleanup(patch.stop)

    def test_state_is_the_inert_default(self):
        state = control_style.style_state()
        self.assertEqual([c['id'] for c in state['contexts']], ['personal', 'work', 'email', 'other'])
        self.assertIsNone(state['default_tone'])
        self.assertNotIn('styles', json.loads(self.config.read_text()))

    def test_edits_round_trip(self):
        state = control_style.style_set_tone('work', 'casual')
        self.assertNotIn('restart_required', state)
        self.assertEqual(state['contexts'][1]['tone'], 'casual')
        control_style.style_set_cleanup('other', 'basic')
        control_style.style_add_app('personal', 'foot', 'Terminal')
        self.assertEqual(control_style.style_resolve('foot')['context'], 'personal')
        control_style.style_rule('foot', 'none', 'off')
        self.assertEqual(control_style.style_resolve('foot')['cleanup'], 'off')
        control_style.style_rule('foot')
        control_style.style_remove_app('personal', 'app:foot')
        control_style.style_set_cleanup('other', 'none')
        control_style.style_set_tone('work', 'none')
        self.assertEqual(json.loads(self.config.read_text()), {'engine_config': 'x.json'})

    def test_bad_arguments_raise_value_error(self):
        for call in (lambda: control_style.style_set_tone('work', 'loud'),
                     lambda: control_style.style_set_cleanup('work', 'max'),
                     lambda: control_style.style_set_tone('other', 'casual'),
                     lambda: control_style.style_preview('loud', 'x'),
                     lambda: control_style.style_add_app('work', 'a*')):
            with self.assertRaises(ValueError):
                call()

    def test_preview_and_command_table(self):
        self.assertEqual(control_style.style_preview('casual', 'See you Friday.'), {'text': 'See you Friday'})
        self.assertEqual(set(control_style.COMMANDS), {
            'style-state', 'style-preview', 'style-resolve', 'style-set-default-tone', 'style-set-tone',
            'style-set-cleanup', 'style-add-app', 'style-remove-app', 'style-rule'})

    def test_loads_through_the_control_loader(self):
        import control
        with mock.patch.object(control, 'PLUGIN_DIR', PLUGIN), mock.patch.object(control, '_module_commands', None):
            commands = control.module_commands()
        self.assertIn('style-state', commands)


if __name__ == '__main__':
    unittest.main()
