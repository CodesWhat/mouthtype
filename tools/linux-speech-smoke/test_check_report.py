import copy
import unittest

from check_report import assess


class AssessmentTests(unittest.TestCase):
    def setUp(self):
        self.pins = {'sherpa': {'version': '1.13.8', 'revision': 'fixed'},
                     'parakeet': {'sha256': 'official'}}
        self.config = {'engines': {'speech': {'artifacts': {'encoder': {'sha256': 'onnx'}}}}}
        self.fixtures = [{'id': 'one', 'expected': 'Hello'}, {'id': 'two', 'expected': 'World'},
                         {'id': 'silence', 'expected': ''}]
        self.report = {'execution_kind': 'engine', 'linux_runtime': True,
                       'environment': {'system': 'Linux', 'architecture': 'x86_64', 'distribution': {'ID': 'arch'}},
                       'engines': {'speech': {'event': 'ready', 'revision': 'fixed',
                                              'runtime': 'sherpa-onnx 1.13.8',
                                              'artifacts': {'encoder': 'onnx'},
                                              'provenance': {'model': {'sha256': 'official'}}}},
                       'results': [{'id': c['id'], 'task': 'speech', 'status': 'passed',
                                    'expected': c['expected'], 'actual': c['expected'],
                                    'duration_ms': 5} for c in self.fixtures]}
    def assess(self, report=None, status=0):
        return assess(report or self.report, self.config, self.pins, self.fixtures, status)
    def test_exact_speech_success_never_certifies_cleanup_or_desktop(self):
        result = self.assess()
        self.assertTrue(result['speech_runtime_completed'])
        self.assertTrue(result['speech_accuracy_passed'])
        self.assertFalse(result['cleanup_tested'])
        self.assertFalse(result['hyprland_acceptance'])
        self.assertFalse(result['omarchy_acceptance'])
    def test_mismatch_remains_failed_and_does_not_invalidate_runtime_completion(self):
        self.report['results'][0].update(status='mismatch', actual='Different')
        result = self.assess(status=1)
        self.assertTrue(result['speech_runtime_completed'])
        self.assertFalse(result['speech_accuracy_passed'])
    def test_missing_fake_unpinned_wrong_expected_and_unavailable_are_rejected(self):
        changes = [lambda r: r.update(execution_kind='test-double'),
                   lambda r: r['results'].pop(),
                   lambda r: r['results'][0].update(expected='Different'),
                   lambda r: r['results'][0].update(status='unavailable'),
                   lambda r: r['engines']['speech']['artifacts'].update(encoder='other'),
                   lambda r: r['engines']['speech'].update(revision='other'),
                   lambda r: r['environment'].update(system='Darwin')]
        for change in changes:
            report = copy.deepcopy(self.report)
            change(report)
            with self.subTest(change=change):
                self.assertFalse(self.assess(report)['speech_accuracy_passed'])


if __name__ == '__main__':
    unittest.main()
