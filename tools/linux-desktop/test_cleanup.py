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
