import subprocess
import sys
import unittest
from unittest.mock import patch

from desktop import read_phrase_clipboard
from phrases import PhraseContextUnavailable


class PhraseContextTests(unittest.TestCase):
    def test_utf8_and_line_endings_are_read_without_clipboard_mutation(self):
        spawn = subprocess.Popen
        children = []
        def fake_clipboard(command, **kwargs):
            self.assertEqual(command, ['wl-paste', '--no-newline', '--type', 'text'])
            self.assertTrue(kwargs['start_new_session'])
            child = spawn([sys.executable, '-c', "import sys; sys.stdout.buffer.write('café\\r\\n'.encode())"], **kwargs)
            children.append(child)
            return child
        with patch('desktop.subprocess.Popen', fake_clipboard):
            self.assertEqual(read_phrase_clipboard(), 'café\r\n')
        self.assertIsNotNone(children[0].poll())
        self.assertTrue(children[0].stdout.closed)

    def test_deadline_and_output_limits_reap_the_owned_helper(self):
        spawn = subprocess.Popen
        for code in ('import time; time.sleep(10)', "import sys; sys.stdout.write('x'*100)"):
            children = []
            def observed(command, **kwargs):
                child = spawn(command, **kwargs)
                children.append(child)
                return child
            with self.subTest(code=code), patch('desktop.subprocess.Popen', observed):
                with self.assertRaises((PhraseContextUnavailable, subprocess.TimeoutExpired)):
                    read_phrase_clipboard([sys.executable, '-c', code], seconds=.2, maximum=16)
            self.assertIsNotNone(children[0].poll())
            self.assertTrue(children[0].stdout.closed)

    def test_nonzero_and_invalid_utf8_are_rejected(self):
        with self.assertRaises(PhraseContextUnavailable):
            read_phrase_clipboard([sys.executable, '-c', 'raise SystemExit(2)'])
        with self.assertRaises(UnicodeDecodeError):
            read_phrase_clipboard([sys.executable, '-c', "import sys; sys.stdout.buffer.write(b'\\xff')"])
