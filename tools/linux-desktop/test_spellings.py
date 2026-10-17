import json
import hashlib
import os
from pathlib import Path
import tempfile
import unittest

from spellings import Spellings, load_spellings
from vendor.grapheme import graphemes


class SpellingTests(unittest.TestCase):
    def test_pinned_unicode_grapheme_conformance(self):
        path = Path(__file__).parent / 'vendor/grapheme/GraphemeBreakTest.txt'
        count = 0
        for line in path.read_text().splitlines():
            fields = line.split('#')[0].split()
            if not fields:
                continue
            expected, current = [], ''
            for field in fields:
                if field == '÷':
                    if current:
                        expected.append(current)
                        current = ''
                elif field != '×':
                    current += chr(int(field, 16))
            with self.subTest(line=count):
                self.assertEqual(list(graphemes(''.join(expected))), expected)
            count += 1
        self.assertEqual(count, 1093)

    def test_vendored_source_matches_receipt(self):
        root = Path(__file__).parent / 'vendor/grapheme'
        receipt = json.loads((root / 'provenance.json').read_text())
        for name, entry in receipt['files'].items():
            with self.subTest(name=name):
                self.assertEqual(hashlib.sha256((root / name).read_bytes()).hexdigest(), entry['sha256'])

    def test_shared_mac_matching_fixtures(self):
        cases = json.loads(Path(__file__).with_name('spelling-fixtures.json').read_text())
        for case in cases:
            with self.subTest(case=case['name']):
                self.assertEqual(Spellings(case['rules']).apply(case['input']), case['expected'])

    def test_mac_library_shape_and_unknown_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'dictionary.json'
            path.write_text(json.dumps([
                {'heard': 'api', 'written': 'API', 'starred': None, 'future': {'setting': True}},
                {'heard': 'post hog', 'written': 'PostHog', 'starred': True},
            ]))
            self.assertEqual(load_spellings(path).apply('api post hog'), 'API PostHog')

    def test_invalid_library_is_rejected(self):
        invalid = [None, {}, [None], [{}], [{'heard': 'x', 'written': 2}],
                   [{'heard': 2, 'written': 'x'}], [{'heard': 'x', 'written': 'y', 'starred': 1}],
                   [{'heard': 'x', 'written': '\ud800'}]]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'dictionary.json'
            for value in invalid:
                path.write_text(json.dumps(value))
                with self.subTest(value=repr(value)), self.assertRaises(ValueError):
                    load_spellings(path)
            path.write_text('[')
            with self.assertRaises(ValueError):
                load_spellings(path)
            with self.assertRaises(OSError):
                load_spellings(path.with_name('missing.json'))

    def test_no_dictionary_preserves_input_exactly(self):
        text = '\t cafe\u0301  ß  👩‍💻\n'
        self.assertEqual(load_spellings(None).apply(text), text)

    def test_nonregular_and_oversized_libraries_refused(self):
        from spellings import MAX_LIBRARY_BYTES
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'dictionary.json'
            os.mkfifo(path)
            with self.assertRaises(ValueError):
                load_spellings(path)
            path.unlink()
            path.write_bytes(b' ' * (MAX_LIBRARY_BYTES + 1))
            with self.assertRaises(ValueError):
                load_spellings(path)

    def test_invalid_json_constants_and_nesting_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'dictionary.json'
            for raw in ('[{"heard":"api","written":"API","future":NaN}]', '[' * 2000 + '0' + ']' * 2000):
                path.write_text(raw)
                with self.subTest(raw=raw[:80]), self.assertRaises(ValueError):
                    load_spellings(path)

    def test_large_library_matches_only_whole_terms(self):
        rules = [{'heard': 'term' + str(i), 'written': 'Value' + str(i)} for i in range(2000)]
        text = ('term1999 term10 term19990 my_term10 ' * 100)
        self.assertEqual(Spellings(rules).apply(text), 'Value1999 Value10 term19990 my_term10 ' * 100)


if __name__ == '__main__':
    unittest.main()
