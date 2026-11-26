import importlib.util
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('promotion_receipt', ROOT / 'scripts/check-promotion-receipt.py')
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)


class PromotionReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mouthtype-promotion-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.first = self.commit('one')
        self.head = self.commit('two')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def commit(self, name):
        (self.root / 'f.txt').write_text(name)
        self.git('add', 'f.txt')
        self.git('commit', '-qm', name)
        return self.git('rev-parse', 'HEAD')

    def test_receipt_for_head_or_ancestor_is_accepted(self):
        for sha in (self.head, self.first):
            body = f'## Verification\n\nFull suite receipt: {sha} 2,741 tests, 0 failures\n'
            self.assertEqual(receipt.check(body, self.head, self.root), sha)

    def test_missing_receipt_is_rejected(self):
        for body in ('', None, 'ran the tests, trust me'):
            with self.assertRaisesRegex(RuntimeError, 'needs a line'):
                receipt.check(body, self.head, self.root)

    def test_failures_or_zero_tests_are_rejected(self):
        with self.assertRaisesRegex(RuntimeError, '3 failures'):
            receipt.check(f'Full suite receipt: {self.head} 10 tests, 3 failures', self.head, self.root)
        with self.assertRaisesRegex(RuntimeError, 'no tests'):
            receipt.check(f'Full suite receipt: {self.head} 0 tests, 0 failures', self.head, self.root)

    def test_commit_outside_the_pr_history_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'not the PR head'):
            receipt.check(f'Full suite receipt: {"c" * 40} 5 tests, 0 failures', self.head, self.root)
        self.git('checkout', '-q', '-b', 'other', self.first)
        side = self.commit('side')
        with self.assertRaisesRegex(RuntimeError, 'not the PR head'):
            receipt.check(f'Full suite receipt: {side} 5 tests, 0 failures', self.head, self.root)


if __name__ == '__main__':
    unittest.main()
