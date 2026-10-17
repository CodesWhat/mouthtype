import json
from pathlib import Path
import unittest

from cleanup import BasicCleanup, spoken_commands, whitespace


class CleanupTests(unittest.TestCase):
    def test_core_fixtures_and_explicit_literal_preservation(self):
        fixtures = json.loads(Path(__file__).with_name('cleanup-fixtures.json').read_text())
        for case in fixtures:
            with self.subTest(case=case['name']):
                if case['stage'] == 'commands':
                    actual = spoken_commands(case['input'])
                elif case['stage'] == 'commandsWhitespace':
                    actual = whitespace(spoken_commands(case['input']))
                elif case['stage'] == 'whitespace':
                    actual = whitespace(case['input'])
                else:
                    actual = BasicCleanup('basic').apply(case['input'])
                self.assertEqual(actual, case['expected'])

    def test_off_is_exact_and_does_not_even_normalize_line_endings(self):
        for text in ('  a  , b\r\n', 'new line period', '```\n    keep  this\n```', 'e\u0301', ''):
            self.assertEqual(BasicCleanup('off').apply(text), text)

    def test_invalid_mode_and_size_limits_are_actionable(self):
        for mode in (None, False, 1, {}, 'fast', 'unknown'):
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                BasicCleanup(mode)
        with self.assertRaises(ValueError):
            BasicCleanup('basic').apply('x' * (2 * 1024 * 1024 + 1))

    def test_quoted_contractions_stay_exact(self):
        clean = BasicCleanup('basic')
        self.assertEqual(clean.apply("'don't  turn new line into layout'"), "'don't  turn new line into layout'")
    def test_attached_path_punctuation_stays_exact(self):
        for source, expected in [('src/file, new line next', 'src/file,\nNext'),
                                 ('src/file, bullet one', 'src/file,\n- One')]:
            with self.subTest(source=source):
                self.assertEqual(BasicCleanup('basic').apply(source), expected)

    def test_swift_casing_treats_cased_invariant_modifier_letters_as_uppercase(self):
        self.assertEqual(spoken_commands('start period ʰello'), 'start. ʰello')
        self.assertEqual(spoken_commands('one new line eʰello'), 'one\neʰello')


class CleanupAcceptanceTests(unittest.TestCase):
    def test_component_never_bypasses_the_production_control_character_guard(self):
        import io
        import subprocess
        import tempfile
        from types import SimpleNamespace
        from unittest.mock import patch
        import acceptance
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / 'runtime'
            runtime.mkdir()
            target = root / 'target.json'
            target.write_text('{"text":""}')
            submitted = []
            sentinel = b'Mouthtype existing clipboard'
            class Processes:
                def start(self, *_args, **_kwargs):
                    (runtime / 'sway-ipc.unit.sock').touch()
                    (runtime / 'wayland-unit').touch()
                    return SimpleNamespace(stdin=io.BytesIO(), poll=lambda: None)
            def run(command, _env, **kwargs):
                if command[0] == 'wtype':
                    text = kwargs['input'].decode('utf-8')
                    self.assertFalse(any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in text),
                                     'The component must not submit Return/Tab actions that production refuses')
                    submitted.append(text)
                    target.write_text(json.dumps({'text': text}))
                return subprocess.CompletedProcess(command, 0, stdout=sentinel)
            tree = {'id': 17, 'app_id': 'app.mouthtype.Acceptance', 'focused': True}
            with patch('acceptance.os.getuid', return_value=1000), patch('acceptance.run', run), \
                    patch('acceptance.compositor_tree', return_value=tree), \
                    patch('acceptance.file_capability', return_value={'mode': '0o755'}), \
                    patch('acceptance.read_phrase_clipboard', return_value=sentinel.decode()) as reader:
                result = acceptance.sway_component(root, {'XDG_RUNTIME_DIR': str(runtime)}, Processes())
            self.assertEqual(len(submitted), 1)
            self.assertTrue(result['basic_cleanup_exact'])
            self.assertTrue(result['multiline_delivery_guard'])
            self.assertFalse(result['hyprland_adapter_tested'])
            reader.assert_called_once()
