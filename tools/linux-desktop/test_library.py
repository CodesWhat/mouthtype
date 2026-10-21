import contextlib
import io
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import threading
import unittest
from unittest import mock

import desktop
import library
from phrases import load_phrases
from spellings import load_spellings


class Base(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config = self.root / 'linux.json'
        self.config.write_text(json.dumps({'engine_config': 'engines.json'}))
        self.dictionary = self.root / 'dictionary.json'
        self.phrases = self.root / 'phrases.json'

    def heard(self, result):
        return [entry['heard'] for entry in result['entries']]

    def disk(self, path):
        return json.loads(path.read_text())


class SpellingTests(Base):
    def test_missing_library_lists_empty_and_unconfigured(self):
        result = library.list_library(self.config, 'spellings')
        self.assertEqual((result['exists'], result['configured'], result['entries'], result['problem'], result['writable']),
                         (False, False, [], None, True))
        self.assertFalse(self.dictionary.exists())

    def test_first_add_creates_the_file_and_points_the_config_at_it(self):
        result = library.add_spelling(self.config, 'post   hog', ' PostHog ')
        self.assertEqual(result['result'], 'added')
        self.assertEqual(result['entry'], {'heard': 'post hog', 'written': 'PostHog', 'starred': False, 'warning': None})
        self.assertTrue(result['configured'] and result['adopted_config'])
        self.assertEqual(self.disk(self.config), {'engine_config': 'engines.json', 'dictionary': 'dictionary.json'})
        self.assertEqual(len(list(self.root.glob('linux.json.bak.*'))), 1)
        self.assertEqual(stat.S_IMODE(self.dictionary.stat().st_mode), 0o600)
        self.assertEqual(load_spellings(self.dictionary).apply('open post hog now'), 'open PostHog now')
        self.assertEqual(library.list_library(self.config, 'spellings')['digest'], result['digest'])

    def test_configured_path_is_used_and_config_is_left_alone(self):
        target = self.root / 'sub' / 'words.json'
        self.config.write_text(json.dumps({'dictionary': 'sub/words.json'}))
        before = self.config.read_text()
        result = library.add_spelling(self.config, 'a', 'Ay')
        self.assertFalse(result['adopted_config'])
        self.assertTrue(target.is_file())
        self.assertEqual(self.config.read_text(), before)

    def test_edit_keeps_order_extra_keys_and_starred(self):
        self.dictionary.write_text('[{"heard":"mouth type","written":"Mouthtype","starred":true,"note":"keep me"},'
                                   '{"heard":"b","written":"B"}]')
        self.config.write_text(json.dumps({'dictionary': 'dictionary.json'}))
        result = library.edit_spelling(self.config, 'MOUTH TYPE', 'mouth  type', 'MouthType', 'Mouthtype')
        self.assertEqual(result['result'], 'updated')
        self.assertEqual(self.disk(self.dictionary), [
            {'heard': 'mouth type', 'written': 'MouthType', 'starred': True, 'note': 'keep me'},
            {'heard': 'b', 'written': 'B', 'starred': False}])
        self.assertEqual(library.edit_spelling(self.config, 'b', 'b', 'B')['result'], 'unchanged')

    def test_edit_and_remove_refuse_when_the_entry_moved(self):
        library.add_spelling(self.config, 'shawn', 'Sean')
        before = self.dictionary.read_bytes()
        for call in (lambda: library.edit_spelling(self.config, 'shawn', 'shawn', 'Shaun', 'Seán'),
                     lambda: library.edit_spelling(self.config, 'nobody', 'x', 'X'),
                     lambda: library.remove_spelling(self.config, 'shawn', 'Seán'),
                     lambda: library.remove_spelling(self.config, 'nobody')):
            with self.assertRaisesRegex(ValueError, 'changed outside the editor'):
                call()
        self.assertEqual(self.dictionary.read_bytes(), before)

    def test_remove_and_duplicates(self):
        library.add_spelling(self.config, 'a', 'Ay')
        library.add_spelling(self.config, 'b', 'Bee')
        with self.assertRaisesRegex(ValueError, 'already exists'):
            library.add_spelling(self.config, ' A ', 'Other')
        with self.assertRaisesRegex(ValueError, 'already exists'):
            library.edit_spelling(self.config, 'b', 'A', 'Bee')
        result = library.remove_spelling(self.config, 'a', 'Ay')
        self.assertEqual((result['result'], self.heard(result)), ('removed', ['b']))
        self.assertEqual(library.remove_spelling(self.config, 'b')['entries'], [])
        self.assertEqual(self.dictionary.read_text(), '[]\n')

    def test_validation_messages_match_the_editor(self):
        cases = [(' ', 'x', 'Enter the word or phrase Mouthtype gets wrong.'),
                 ('x', ' \n', 'Enter the spelling to use.'),
                 ('x' * 129, 'x', 'Keep each phrase and spelling under 129 characters.'),
                 ('x', 'y' * 129, 'Keep each phrase and spelling under 129 characters.')]
        for heard, written, message in cases:
            with self.subTest(heard=heard[:3], written=written[:3]):
                with self.assertRaises(ValueError) as caught:
                    library.add_spelling(self.config, heard, written)
                self.assertEqual(str(caught.exception), message)
        library.add_spelling(self.config, 'x' * 128, 'y' * 128)
        with self.assertRaisesRegex(ValueError, 'valid UTF-8'):
            library.add_spelling(self.config, 'bad\udc80', 'x')

    def test_unreadable_library_is_a_problem_and_never_overwritten(self):
        for text in ('not json', '{"a":1}', '[{"heard":"a"}]', '[{"heard":"a","written":"A"},{"heard":" A ","written":"B"}]',
                     '[{"heard":"a","written":" "}]', '[{"heard":"a","written":"A","starred":"yes"}]'):
            with self.subTest(text=text):
                self.dictionary.write_text(text)
                self.config.write_text(json.dumps({'dictionary': 'dictionary.json'}))
                listed = library.list_library(self.config, 'spellings')
                self.assertFalse(listed['writable'])
                self.assertIn('Fix dictionary.json and reload it.', listed['problem'])
                with self.assertRaises(ValueError):
                    library.add_spelling(self.config, 'new', 'New')
                self.assertEqual(self.dictionary.read_text(), text)

    def test_non_regular_library_is_refused(self):
        os.mkfifo(self.root / 'pipe.json')
        self.config.write_text(json.dumps({'dictionary': 'pipe.json'}))
        self.assertIn('regular JSON file', library.list_library(self.config, 'spellings')['problem'])

    def test_write_goes_through_a_symlink_and_keeps_the_mode(self):
        real = self.root / 'real.json'
        real.write_text('[]')
        real.chmod(0o640)
        self.dictionary.symlink_to(real)
        self.config.write_text(json.dumps({'dictionary': 'dictionary.json'}))
        library.add_spelling(self.config, 'a', 'Ay')
        self.assertTrue(self.dictionary.is_symlink())
        self.assertEqual(self.disk(real)[0]['heard'], 'a')
        self.assertEqual(stat.S_IMODE(real.stat().st_mode), 0o640)

    def test_no_temporary_files_remain_and_size_cap_holds(self):
        library.add_spelling(self.config, 'a', 'Ay')
        self.assertEqual(sorted(path.name for path in self.root.iterdir() if path.name.startswith('.')), [])
        before = self.dictionary.read_bytes()
        with mock.patch.dict(library.KINDS['spellings'], {'limit': 60}):
            with self.assertRaisesRegex(ValueError, 'limit'):
                library.add_spelling(self.config, 'bbbbbbbbbb', 'Bee')
        self.assertEqual(self.dictionary.read_bytes(), before)
        self.assertEqual(sorted(path.name for path in self.root.iterdir() if path.name.startswith('.')), [])

    def test_concurrent_writers_lose_nothing(self):
        library.add_spelling(self.config, 'seed', 'Seed')
        errors = []

        def add(index):
            try:
                library.add_spelling(self.config, f'word{index}', f'Word{index}')
            except Exception as error:
                errors.append(error)
        threads = [threading.Thread(target=add, args=(index,)) for index in range(24)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(errors, [])
        self.assertEqual(len(self.disk(self.dictionary)), 25)

    def test_everyday_word_warnings(self):
        warn = library.everyday_warning
        self.assertEqual(warn('their', 'Thair'), '‘their’ is an everyday word, so every ‘their’ you say becomes Thair.')
        self.assertEqual(warn('good  morning', 'Gud Mornin'),
                         '‘good morning’ is an everyday phrase, so every ‘good morning’ you say becomes Gud Mornin.')
        for heard, written in (('post hog', 'PostHog'), ('mouth type', 'Mouthtype'), ('the', 'The'), ('s3', 'Bucket'),
                               ('c++', 'Cee'), ('zzyzx', 'Zed'), ('', 'x'), ('their', ' ')):
            with self.subTest(heard=heard):
                self.assertIsNone(warn(heard, written))
        result = library.add_spelling(self.config, 'cat', 'Kat')
        self.assertIn('everyday word', result['entry']['warning'])
        self.assertEqual(result['result'], 'added')

    def test_ordinary_word_list_matches_the_mac(self):
        source = Path(__file__).resolve().parents[2] / 'Sources/MouthtypeCore/OrdinaryWords.swift'
        if not source.is_file():
            self.skipTest('Core sources are not in this archive')
        block = re.search(r'private static let list = """\n(.*?)\n    """', source.read_text(), re.S).group(1)
        self.assertEqual(library._ORDINARY_WORDS, frozenset(block.split()))


class CsvTests(Base):
    def preview(self, text, raw=None):
        csv = self.root / 'in.csv'
        csv.write_bytes(raw if raw is not None else text.encode())
        return library.preview_import(self.config, csv)

    def import_csv(self, text, digest=None):
        csv = self.root / 'in.csv'
        csv.write_bytes(text.encode())
        return library.import_spellings(self.config, csv, digest)

    def test_preview_then_import_preserves_existing_fields(self):
        original = '[{"heard":"mouth type","written":"Mouthtype","starred":true,"note":"keep me"}]'
        self.dictionary.write_text(original)
        self.config.write_text(json.dumps({'dictionary': 'dictionary.json'}))
        preview = self.preview('heard,written\r\nshawn,Sean\r\nMOUTH   TYPE,Mouthtype\r\nshawn,Sean\r\n')
        self.assertTrue(preview['can_import'])
        self.assertEqual([row['result'] for row in preview['rows']], ['add', 'existing', 'duplicate'])
        self.assertEqual([row['row'] for row in preview['rows']], [2, 3, 4])
        self.assertEqual(preview['counts'], {'add': 1, 'existing': 1, 'duplicate': 1, 'invalid': 0})
        self.assertEqual(self.dictionary.read_text(), original)
        result = self.import_csv('heard,written\r\nshawn,Sean\r\nMOUTH   TYPE,Mouthtype\r\nshawn,Sean\r\n', preview['digest'])
        self.assertEqual((result['result'], result['imported'], result['skipped']), ('imported', 1, 2))
        self.assertEqual(self.disk(self.dictionary), [
            {'heard': 'mouth type', 'written': 'Mouthtype', 'starred': True, 'note': 'keep me'},
            {'heard': 'shawn', 'written': 'Sean', 'starred': False}])
        self.assertEqual(load_spellings(self.dictionary).apply('shawn'), 'Sean')

    def test_names_and_quoted_aliases_normalize_without_guessing(self):
        names = self.preview('﻿name\nSean\nYakback\n')
        self.assertEqual([(row['heard'], row['written']) for row in names['rows']], [('Sean', 'Sean'), ('Yakback', 'Yakback')])
        aliases = self.preview('written,heard\n"Acme, Inc."," acme   incorporated "\n"Say ""hello""",greeting\n"first\nsecond",two lines\n')
        self.assertTrue(aliases['can_import'])
        self.assertEqual([row['written'] for row in aliases['rows']], ['Acme, Inc.', 'Say "hello"', 'first\nsecond'])
        self.assertEqual(aliases['rows'][0]['heard'], 'acme incorporated')
        self.assertEqual([row['row'] for row in aliases['rows']], [2, 3, 4])

    def test_quoted_newline_advances_the_row_counter(self):
        preview = self.preview('heard,written\n"a\nb",X\nc,Y\n')
        self.assertEqual([row['row'] for row in preview['rows']], [2, 4])

    def test_invalid_rows_and_conflicts_block_the_whole_import(self):
        library.add_spelling(self.config, 'shawn', 'Sean')
        before = self.dictionary.read_bytes()
        bad = ['heard,written\nnew,New\nSHAWN,Shaun', 'heard,written\nnew,New\nNEW,Other', 'heard,written\nnew,New\n,Blank',
               'heard,written\nnew,New\n' + 'x' * 129 + ',Long']
        for csv in bad:
            with self.subTest(csv=csv[-12:]):
                preview = self.preview(csv)
                self.assertFalse(preview['can_import'])
                self.assertEqual(preview['counts']['invalid'], 1)
                with self.assertRaises(ValueError):
                    self.import_csv(csv)
                self.assertEqual(self.dictionary.read_bytes(), before)
        self.assertEqual(self.preview(bad[0])['rows'][1]['label'], 'Conflicts with the saved spelling “Sean”.')
        self.assertEqual(self.preview(bad[1])['rows'][1]['label'], 'Conflicts with another CSV row.')

    def test_malformed_csv_and_headers_are_problems_not_writes(self):
        cases = ['', 'word,alias\na,b', 'heard,written,extra\na,b,c', 'heard,heard\na,b', 'heard,written\n"unfinished,b',
                 'heard,written\na,"b"junk', 'heard,written\na,b,c', 'heard,written\nqu"ote,b', 'heard,written\nonly-one',
                 'name\nSea\0n', 'name\n' + '\n'.join(['Sean'] * 5001), 'name\n']
        for csv in cases:
            with self.subTest(csv=csv[:20]):
                preview = self.preview(csv)
                self.assertFalse(preview['can_import'])
                self.assertTrue(preview['problem'] or preview['counts']['invalid'])
        self.assertIsNotNone(self.preview('', raw=b'\xff')['problem'])
        self.assertIsNotNone(self.preview('', raw=b'a' * (library.MAX_CSV_BYTES + 1))['problem'])
        self.assertFalse(self.dictionary.exists())

    def test_quote_errors_name_the_row(self):
        self.assertEqual(self.preview('heard,written\nqu"ote,b')['problem'], 'Row 2: a quote must start a quoted field.')
        self.assertEqual(self.preview('heard,written\na,"b"junk')['problem'], 'Row 2: unexpected text after a closing quote.')
        self.assertEqual(self.preview('heard,written\n\n"x,b')['problem'], 'Row 3: a quoted field was not closed.')

    def test_five_thousand_rows_is_the_limit(self):
        self.assertTrue(self.preview('name\n' + '\n'.join(f'n{i}' for i in range(5000)))['can_import'])

    def test_everyday_warning_rides_on_add_rows(self):
        rows = self.preview('heard,written\ntheir,Thair\nbook,Book\npost hog,PostHog\n')['rows']
        self.assertIn('everyday word', rows[0]['warning'])
        self.assertIsNone(rows[1]['warning'])
        self.assertIsNone(rows[2]['warning'])

    def test_confirm_refuses_a_library_that_changed_after_the_preview(self):
        preview = self.preview('name\nSean')
        library.add_spelling(self.config, 'other', 'Other')
        before = self.dictionary.read_bytes()
        with self.assertRaisesRegex(ValueError, 'changed after this preview'):
            self.import_csv('name\nSean', preview['digest'])
        self.assertEqual(self.dictionary.read_bytes(), before)
        self.assertEqual(self.import_csv('name\nSean')['imported'], 1)

    def test_confirm_refuses_a_csv_that_changed_after_the_preview(self):
        preview = self.preview('heard,written\nshawn,Sean')
        csv = self.root / 'in.csv'
        csv.write_text('heard,written\ntheir,Thair')
        with self.assertRaisesRegex(ValueError, 'CSV changed after this preview'):
            library.import_spellings(self.config, csv, preview['digest'], preview['csv_digest'])
        self.assertFalse(self.dictionary.exists())
        csv.write_text('heard,written\nshawn,Sean')
        self.assertEqual(library.import_spellings(self.config, csv, preview['digest'], preview['csv_digest'])['imported'], 1)

    def test_missing_library_digest_and_unreadable_library(self):
        self.assertEqual(self.preview('name\nSean')['digest'], 'missing')
        self.import_csv('name\nSean', 'missing')
        self.dictionary.write_text('broken')
        with self.assertRaises(ValueError):
            self.preview('name\nSean')

    def test_directory_and_missing_csv_are_errors(self):
        with self.assertRaises(OSError):
            library.preview_import(self.config, self.root / 'absent.csv')
        with self.assertRaises(ValueError):
            library.preview_import(self.config, self.root)


class PhraseTests(Base):
    def test_crud_round_trip_through_the_service_loader(self):
        added = library.add_phrase(self.config, ' my   address ', 'First Street\n  Apt 2')
        self.assertEqual(added['entry'], {'trigger': 'my address', 'expansion': 'First Street\n  Apt 2'})
        self.assertEqual(self.disk(self.config)['phrases'], 'phrases.json')
        library.add_phrase(self.config, 'sig', 'Thanks, {date}')
        self.assertEqual(load_phrases(self.phrases, now=lambda: __import__('datetime').datetime(2026, 10, 17)).apply('my address'),
                         'First Street\n  Apt 2')
        edited = library.edit_phrase(self.config, 'MY ADDRESS', 'my home', 'Second Street', 'First Street\n  Apt 2')
        self.assertEqual([entry['trigger'] for entry in edited['entries']], ['my home', 'sig'])
        self.assertEqual(library.edit_phrase(self.config, 'sig', 'sig', 'Thanks, {date}')['result'], 'unchanged')
        removed = library.remove_phrase(self.config, 'sig')
        self.assertEqual((removed['result'], removed['count']), ('removed', 1))
        self.assertEqual(self.disk(self.phrases), [{'expansion': 'Second Street', 'trigger': 'my home'}])

    def test_validation_and_duplicates(self):
        library.add_phrase(self.config, 'a', 'x')
        cases = [(' ', 'x', 'Enter a phrase to say.'), ('b', ' \n', 'Enter the text to insert.'),
                 ('t' * 129, 'x', 'Keep the spoken phrase under 129 characters.'),
                 ('b', 'x' * 16001, 'Keep the replacement under 16,001 characters.'),
                 ('A', 'y', 'A phrase with this trigger already exists.')]
        for trigger, expansion, message in cases:
            with self.subTest(message=message):
                with self.assertRaises(ValueError) as caught:
                    library.add_phrase(self.config, trigger, expansion)
                self.assertEqual(str(caught.exception), message)
        library.add_phrase(self.config, 't' * 128, 'x' * 16000)
        with self.assertRaisesRegex(ValueError, 'already exists'):
            library.edit_phrase(self.config, 't' * 128, 'a', 'x')

    def test_changed_entry_is_refused(self):
        library.add_phrase(self.config, 'a', 'x')
        with self.assertRaisesRegex(ValueError, 'changed outside the editor'):
            library.edit_phrase(self.config, 'a', 'a', 'y', 'stale')
        with self.assertRaisesRegex(ValueError, 'changed outside the editor'):
            library.remove_phrase(self.config, 'gone')

    def test_unreadable_library_is_never_overwritten(self):
        self.config.write_text(json.dumps({'phrases': 'phrases.json'}))
        for text in ('nope', '{}', '[{"trigger":"a"}]', '[{"trigger":"a","expansion":"x"},{"trigger":"A","expansion":"y"}]',
                     '[{"trigger":" ","expansion":"y"}]'):
            with self.subTest(text=text):
                self.phrases.write_text(text)
                listed = library.list_library(self.config, 'phrases')
                self.assertFalse(listed['writable'])
                self.assertIn('Fix phrases.json and reload it.', listed['problem'])
                with self.assertRaises(ValueError):
                    library.add_phrase(self.config, 'new', 'x')
                self.assertEqual(self.phrases.read_text(), text)

    def test_one_mib_limit(self):
        library.add_phrase(self.config, 'a', 'x')
        with mock.patch.dict(library.KINDS['phrases'], {'limit': 40}):
            with self.assertRaisesRegex(ValueError, 'limit'):
                library.add_phrase(self.config, 'b', 'y' * 40)
        self.assertEqual(len(self.disk(self.phrases)), 1)


class CliTests(Base):
    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = desktop.main(['--config', str(self.config), *argv])
        return code, out.getvalue(), err.getvalue()

    def test_commands_are_registered_by_the_loader(self):
        code, out, err = self.run_cli('spellings', 'list')
        self.assertEqual((code, err), (0, ''))
        self.assertEqual(json.loads(out)['entries'], [])
        code, out, _ = self.run_cli('phrases', 'list')
        self.assertEqual((code, json.loads(out)['kind']), (0, 'phrases'))

    def test_spelling_commands(self):
        self.assertEqual(json.loads(self.run_cli('spellings', 'add', 'post hog', 'PostHog')[1])['result'], 'added')
        self.assertEqual(json.loads(self.run_cli('spellings', 'edit', 'post hog', 'post hog', 'Posthog', '--expect-written', 'PostHog')[1])['result'], 'updated')
        csv = self.root / 'in.csv'
        csv.write_text('name\nSean\n')
        code, out, _ = self.run_cli('spellings', 'import', str(csv), '--dry-run')
        preview = json.loads(out)
        self.assertEqual((code, preview['can_import']), (0, True))
        self.assertEqual(len(self.disk(self.dictionary)), 1)
        code, out, _ = self.run_cli('spellings', 'import', str(csv), '--expect-digest', preview['digest'])
        self.assertEqual((code, json.loads(out)['imported']), (0, 1))
        code, out, _ = self.run_cli('spellings', 'remove', 'sean')
        self.assertEqual((code, json.loads(out)['count']), (0, 1))

    def test_phrase_commands(self):
        self.run_cli('phrases', 'add', 'sig', 'Thanks')
        code, out, _ = self.run_cli('phrases', 'edit', 'sig', 'signoff', 'Cheers', '--expect-expansion', 'Thanks')
        self.assertEqual((code, json.loads(out)['entry']['trigger']), (0, 'signoff'))
        code, out, _ = self.run_cli('phrases', 'remove', 'signoff')
        self.assertEqual((code, json.loads(out)['count']), (0, 0))

    def test_errors_print_json_on_stderr_and_exit_one(self):
        code, out, err = self.run_cli('spellings', 'remove', 'nobody')
        self.assertEqual((code, out), (1, ''))
        self.assertIn('changed outside the editor', json.loads(err)['error'])
        code, _out, err = self.run_cli('spellings', 'import', str(self.root / 'absent.csv'), '--dry-run')
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(err)['error'], 'No such file or directory')


if __name__ == '__main__':
    unittest.main()
