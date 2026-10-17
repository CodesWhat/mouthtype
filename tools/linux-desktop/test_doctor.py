import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import desktop


class DoctorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'linux.json'
        self.runtime = self.root / 'runtime'
        artifacts = {}
        for name in ('encoder', 'decoder', 'joiner', 'vocabulary'):
            path = self.root / name
            path.write_bytes(b'synthetic model file')
            artifacts[name] = {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        self.engine = self.root / 'engines.json'
        self.engine.write_text(json.dumps({'schema': 1, 'engines': {'speech': {'artifacts': artifacts}}}))
        self.config.write_text(json.dumps({'engine_config': 'engines.json', 'python': sys.executable}))

    def diagnose(self, **kwargs):
        from doctor import diagnose
        defaults = dict(system='Linux', machine='x86_64', which=lambda command: '/usr/bin/' + command,
                        runtime_check=lambda python: True, service_check=lambda path: {'state': 'idle'})
        return diagnose(self.config, self.runtime, **(defaults | kwargs))

    def check(self, report, name):
        return next(item for item in report['checks'] if item['name'] == name)

    def test_prepared_config_is_ready_without_creating_runtime_or_recording(self):
        before = {str(p): p.read_bytes() for p in self.root.iterdir() if p.is_file()}
        report = self.diagnose()
        self.assertTrue(report['ready'])
        self.assertFalse(report['physical_tested'])
        self.assertEqual(self.check(report, 'models')['status'], 'ok')
        self.assertFalse(self.runtime.exists())
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.iterdir() if p.is_file()})

    def test_missing_configuration_explains_setup(self):
        self.config.unlink()
        report = self.diagnose()
        self.assertFalse(report['ready'])
        self.assertIn('setup_speech.py', self.check(report, 'configuration')['action'])

    def test_malformed_and_wrong_shape_configuration(self):
        for value in ('{', '[]', '{"engine_config": null}'):
            with self.subTest(value=value):
                self.config.write_text(value)
                self.assertFalse(self.diagnose()['ready'])

    def test_missing_or_changed_model_prevents_readiness(self):
        (self.root / 'encoder').write_bytes(b'changed')
        self.assertEqual(self.check(self.diagnose(), 'models')['status'], 'error')
        (self.root / 'encoder').unlink()
        self.assertFalse(self.diagnose()['ready'])

    def test_incomplete_speech_artifact_set_is_not_ready(self):
        self.engine.write_text('{"engines":{"speech":{"artifacts":{}}}}')
        self.assertEqual(self.check(self.diagnose(), 'models')['status'], 'error')

    def test_missing_capture_helper_blocks_but_optional_notifications_do_not(self):
        report = self.diagnose(which=lambda command: None if command == 'notify-send' else '/bin/' + command)
        self.assertTrue(report['ready'])
        self.assertEqual(self.check(report, 'notifications')['status'], 'warning')
        report = self.diagnose(which=lambda command: None)
        self.assertFalse(report['ready'])
        self.assertIn('pipewire', self.check(report, 'capture')['action'].lower())

    def test_unavailable_runtime_and_wrong_platform_block(self):
        self.assertFalse(self.diagnose(runtime_check=lambda _: False)['ready'])
        self.assertFalse(self.diagnose(system='Darwin', machine='arm64')['ready'])

    def test_missing_service_is_actionable_warning(self):
        def missing(_):
            raise OSError('not running')
        report = self.diagnose(service_check=missing)
        self.assertTrue(report['ready'])
        self.assertEqual(self.check(report, 'service')['status'], 'warning')
        self.assertIn('serve', self.check(report, 'service')['action'])

    def test_type_delivery_checks_hyprland_and_wtype(self):
        self.config.write_text(json.dumps({'engine_config': 'engines.json',
            'delivery': {'mode': 'type', 'allowed_classes': ['editor'], 'allow_unknown_secure_field': True}}))
        report = self.diagnose(which=lambda command: None if command == 'wtype' else '/bin/' + command)
        self.assertFalse(report['ready'])
        self.assertEqual(self.check(report, 'delivery')['status'], 'error')

    def test_typing_without_explicit_unknown_field_opt_in_is_not_ready(self):
        self.config.write_text(json.dumps({'engine_config': 'engines.json',
            'delivery': {'mode': 'type', 'allowed_classes': ['editor']}}))
        self.assertEqual(self.check(self.diagnose(), 'delivery')['status'], 'error')

    def test_nonregular_model_file_is_rejected_without_opening_it(self):
        import os
        path = self.root / 'encoder'
        path.unlink()
        os.mkfifo(path)
        self.assertEqual(self.check(self.diagnose(), 'models')['status'], 'error')

    def test_bad_configured_libraries_block_without_reading_clipboard(self):
        config = json.loads(self.config.read_text())
        for field in ('dictionary', 'phrases'):
            with self.subTest(field=field):
                self.config.write_text(json.dumps(config | {field: 'missing.json', 'phrase_clipboard': True}))
                self.assertEqual(self.check(self.diagnose(), field)['status'], 'error')

    def test_cli_missing_config_json_and_human_output(self):
        self.config.unlink()
        command = [sys.executable, desktop.__file__, '--config', str(self.config),
                   '--runtime', str(self.runtime), 'doctor']
        result = subprocess.run(command + ['--json'], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(json.loads(result.stdout)['ready'])
        result = subprocess.run(command, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn('configuration', result.stdout)
        self.assertIn('setup_speech.py', result.stdout)
        self.assertFalse(self.runtime.exists())

    def test_runtime_probe_is_bounded_and_does_not_load_speech(self):
        from doctor import runtime_available
        with patch('doctor.subprocess.run') as run:
            run.return_value.returncode = 0
            self.assertTrue(runtime_available(sys.executable))
            args, kwargs = run.call_args
            self.assertNotIn('import sherpa_onnx', args[0][-1])
            self.assertLessEqual(kwargs['timeout'], 3)
            run.side_effect = subprocess.TimeoutExpired('python', 3)
            self.assertFalse(runtime_available(sys.executable))
