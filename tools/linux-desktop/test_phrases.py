import datetime
import json
import os
from pathlib import Path
import tempfile
import unittest

from phrases import Phrases, PhraseContextUnavailable, load_phrases


class PhraseTests(unittest.TestCase):
    def test_shared_core_fixtures(self):
        fixtures = json.loads(Path(__file__).with_name('phrase-fixtures.json').read_text())
        for fixture in fixtures:
            with self.subTest(case=fixture['name']):
                phrases = Phrases(fixture['rules'], date_text='October 17, 2026', clipboard=fixture.get('clipboard'))
                self.assertEqual(phrases.apply(fixture['input']), fixture['expected'])

    def test_context_is_snapshotted_once_and_only_when_requested(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'phrases.json'
            path.write_text(json.dumps([{'trigger': 'today', 'expansion': '{DATE} {clipboard} {date}'}]))
            calls = []
            phrases = load_phrases(path, now=lambda: datetime.datetime(2026, 10, 17),
                                   clipboard=lambda: calls.append('read') or 'unchanged {date}\r\n')
            self.assertEqual(calls, ['read'])
            self.assertEqual(phrases.apply('today'), 'October 17, 2026 unchanged {date}\r\n October 17, 2026')
            self.assertEqual(calls, ['read'])
            path.write_text('[{"trigger":"address","expansion":"First Street"}]')
            self.assertEqual(load_phrases(path, clipboard=lambda: self.fail('unexpected clipboard read')).apply('address'), 'First Street')

    def test_clipboard_variable_requires_explicit_context_and_failed_reads_do_not_erase_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'phrases.json'
            path.write_text('[{"trigger":"insert clip","expansion":"{clipboard}"}]')
            for reader in (None, lambda: None):
                with self.subTest(reader=reader), self.assertRaises(PhraseContextUnavailable):
                    load_phrases(path, clipboard=reader)
            self.assertEqual(load_phrases(path, clipboard=lambda: '').apply('insert clip'), '')

    def test_invalid_libraries_and_limits_are_rejected(self):
        invalid = [{}, [None], [{'trigger': 1, 'expansion': 'x'}], [{'trigger': 'x', 'expansion': None}],
                   [{'trigger': ' ', 'expansion': 'x'}], [{'trigger': 'x', 'expansion': '\n'}],
                   [{'trigger': 'x' * 129, 'expansion': 'x'}], [{'trigger': 'x', 'expansion': 'x' * 16001}],
                   [{'trigger': '\ud800', 'expansion': 'x'}], [{'trigger': 'x', 'expansion': '\ud800'}],
                   [{'trigger': 'My  Address', 'expansion': 'one'}, {'trigger': 'my\taddress', 'expansion': 'two'}]]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'phrases.json'
            for value in invalid:
                path.write_text(json.dumps(value))
                with self.subTest(value=repr(value)[:120]), self.assertRaises(ValueError):
                    load_phrases(path)
            path.write_bytes(b' ' * (1024 * 1024 + 1))
            with self.assertRaises(ValueError):
                load_phrases(path)
            path.unlink()
            os.mkfifo(path)
            with self.assertRaises(ValueError):
                load_phrases(path)

    def test_missing_optional_library_is_unchanged_but_configured_missing_file_is_an_error(self):
        self.assertEqual(load_phrases(None).apply('Keep this exactly.\r\n'), 'Keep this exactly.\r\n')
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(OSError):
            load_phrases(Path(directory) / 'missing.json')

    def test_expansion_limit_fails_before_allocating_a_large_result(self):
        phrases = Phrases([{'trigger': 'x', 'expansion': 'café' * 4000}])
        with self.assertRaises(ValueError):
            phrases.apply('x ' * 150)
