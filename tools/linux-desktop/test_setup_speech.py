import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import setup_speech
from setup_progress import DownloadProgress


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.destination = self.root / 'speech'
        self.archive = self.root / 'fixture.tar.bz2'
        self.entries = {name: ('synthetic-' + name).encode() for name in setup_speech.SPEECH_ENTRIES}
        with tarfile.open(self.archive, 'w:bz2') as archive:
            for name, filename in setup_speech.SPEECH_ENTRIES.items():
                info = tarfile.TarInfo('fixture/' + filename)
                info.size = len(self.entries[name])
                archive.addfile(info, io.BytesIO(self.entries[name]))
        self.pins = {'parakeet': {'archive': 'fixture.tar.bz2',
                                  'source': 'https://example.invalid/fixture.tar.bz2',
                                  'sha256': hashlib.sha256(self.archive.read_bytes()).hexdigest()},
                     'sherpa': {'version': '1.13.8', 'revision': 'fixed-runtime'}}
        self.calls = []
    def tearDown(self):
        self.temp.cleanup()
    def download(self, source, path, progress=None):
        self.calls.append(('download', source))
        path.write_bytes(self.archive.read_bytes())
    def fake_run(self, command, seconds):
        self.calls.append(command)
        if command[1:3] == ['-m', 'venv']:
            executable = Path(command[3]) / 'bin/python'
            executable.parent.mkdir(parents=True)
            executable.touch()
        return 'sherpa-onnx==1.13.8\nsherpa-onnx-core==1.13.8\n'
    def setup(self):
        return setup_speech.setup(self.destination, pins=self.pins, download=self.download, run=self.fake_run)

    def test_explicit_setup_verifies_model_and_writes_recover_only_private_config(self):
        config = self.setup()
        value = json.loads(config.read_text())
        self.assertEqual(value['delivery'], {'mode': 'recover'})
        self.assertEqual(value['cleanup'], 'basic')
        self.assertEqual(Path(value['python']), self.destination.resolve() / 'venv/bin/python')
        engines = json.loads(Path(value['engine_config']).read_text())
        self.assertEqual(set(engines['engines']), {'speech'})
        for name, artifact in engines['engines']['speech']['artifacts'].items():
            self.assertEqual(Path(artifact['path']).read_bytes(), self.entries[name])
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o700)
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(Path(value['engine_config']).stat().st_mode & 0o777, 0o600)
        commands = [call for call in self.calls if isinstance(call, list)]
        self.assertTrue(any(call[1:4] == ['-m', 'pip', 'install'] for call in commands))
        install = next(call for call in commands if call[1:4] == ['-m', 'pip', 'install'])
        self.assertIn('--require-hashes', install)
        requirements = (Path(setup_speech.__file__).resolve().parents[1] / 'linux-engine-proof/requirements.txt').read_text()
        for package in ('sherpa-onnx', 'sherpa-onnx-core'):
            self.assertRegex(requirements, r'(?m)^' + package + r'==1\.13\.8 \\\n(    --hash=sha256:[0-9a-f]{64}( \\)?\n)+')
        self.assertFalse(any('serve' in call or 'sudo' in call or 'pacman' in call for call in commands))
        receipt = json.loads((self.destination / 'setup-receipt.json').read_text())
        self.assertEqual(receipt['model_sha256'], self.pins['parakeet']['sha256'])
        self.assertFalse(receipt['model_inference_tested'])

    def test_runtime_version_check_still_rejects_wrong_version_with_optimization(self):
        import sys
        self.setup()
        command = next(call for call in self.calls if isinstance(call, list) and call[1] == '-c')
        prefix = ('import sys,types,importlib.metadata\n'
                  'sys.modules["sherpa_onnx"]=types.ModuleType("sherpa_onnx")\n'
                  'importlib.metadata.version=lambda name:"wrong"\n')
        result = subprocess.run([sys.executable, '-O', '-c', prefix + command[2]],
                                capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)

    def test_model_download_allows_slow_progress_but_bounds_stalls_and_total_time(self):
        with patch('setup_speech.bounded_run') as run:
            setup_speech.download_archive('https://example.invalid/pinned-model', self.root / 'archive.bz2')
        command, deadline = run.call_args.args
        self.assertEqual(command[command.index('--speed-limit') + 1], '1024')
        self.assertEqual(command[command.index('--speed-time') + 1], '60')
        self.assertEqual(command[command.index('--max-time') + 1], '3600')
        self.assertEqual(deadline, 3610)
        self.assertEqual(command[command.index('--proto') + 1], '=https')
        self.assertEqual(command[command.index('--proto-redir') + 1], '=https')
        self.assertEqual(command[command.index('--output') + 1], str(self.root / 'archive.bz2'))
        self.assertEqual(command[-1], 'https://example.invalid/pinned-model')

    def test_setup_writes_speech_progress_file_with_monotonic_bytes(self):
        self.pins['parakeet']['bytes'] = len(self.archive.read_bytes())
        total = self.pins['parakeet']['bytes']
        status = self.destination / 'speech-setup.json'
        seen = []

        def download(source, path, progress=None):
            path.write_bytes(self.archive.read_bytes())
            for done in (total // 4, total // 2, total // 3, total * 2):
                progress(done)
                seen.append(json.loads(status.read_text()))

        with patch('setup_speech.DownloadProgress', lambda t, emit: DownloadProgress(t, emit, interval=0)):
            setup_speech.setup(self.destination, pins=self.pins, download=download, run=self.fake_run)
        done = [state['bytes_done'] for state in seen]
        self.assertEqual(done, sorted(done))
        self.assertTrue(all(state['bytes_total'] == total and state['bytes_done'] <= total for state in seen))
        self.assertEqual(json.loads(status.read_text())['state'], 'ready')

    def test_download_archive_polls_progress_with_the_archive_size(self):
        sizes = []

        def fake(command, seconds, poll=None):
            Path(command[command.index('--output') + 1]).write_bytes(b'abc')
            poll()
            poll()

        with patch('setup_speech.bounded_run', fake):
            setup_speech.download_archive('https://example.invalid/m', self.root / 'a.bz2', progress=sizes.append)
        self.assertEqual(sizes, [3, 3])

    def test_bounded_run_polls_while_the_child_runs(self):
        calls = []
        setup_speech.bounded_run([sys.executable, '-c', 'import time; time.sleep(1.2)'], 10, poll=lambda: calls.append(1))
        self.assertGreaterEqual(len(calls), 1)

    def test_existing_destination_is_preserved_before_any_download_or_child(self):
        self.destination.mkdir()
        owned = self.destination / 'existing.txt'
        owned.write_text('preserve')
        with self.assertRaises(FileExistsError):
            self.setup()
        self.assertEqual(owned.read_text(), 'preserve')
        self.assertEqual(self.calls, [])

    def test_hash_mismatch_cannot_extract_install_or_create_ready_config(self):
        self.pins['parakeet']['sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            self.setup()
        self.assertEqual(len(self.calls), 1)
        self.assertFalse((self.destination / 'linux.json').exists())
        self.assertFalse((self.destination / 'model').exists())

    def test_runtime_install_failure_leaves_no_ready_config(self):
        def unavailable(command, seconds):
            raise subprocess.CalledProcessError(1, command)
        with self.assertRaises(subprocess.CalledProcessError):
            setup_speech.setup(self.destination, pins=self.pins, download=self.download, run=unavailable)
        self.assertFalse((self.destination / 'linux.json').exists())

    def test_nonregular_archive_member_is_refused_before_runtime_install(self):
        with tarfile.open(self.archive, 'w:bz2') as archive:
            filename = next(iter(setup_speech.SPEECH_ENTRIES.values()))
            member = tarfile.TarInfo('fixture/' + filename)
            member.type = tarfile.SYMTYPE
            member.linkname = '/outside'
            archive.addfile(member)
        self.pins['parakeet']['sha256'] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        with self.assertRaises(ValueError):
            self.setup()
        self.assertEqual(len(self.calls), 1)
        self.assertFalse((self.destination / 'linux.json').exists())

    def test_failed_helper_stderr_remains_visible_to_operator(self):
        import sys
        helper = 'import sys;sys.stderr.write("synthetic wheel unavailable\\n");sys.exit(1)'
        script = ('import sys,subprocess\n'
                  'sys.path.insert(0,' + repr(str(Path(__file__).resolve().parent)) + ')\n'
                  'from setup_speech import bounded_run\n'
                  'try:\n'
                  ' bounded_run([sys.executable,"-c",' + repr(helper) + '],2)\n'
                  'except subprocess.CalledProcessError:\n sys.exit(2)\n')
        result = subprocess.run([sys.executable, '-c', script], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b'synthetic wheel unavailable', result.stderr)

    def test_timed_out_helper_is_stopped_and_reaped(self):
        import os
        import sys
        child = self.root / 'child.py'
        pidfile = self.root / 'pid'
        child.write_text('import os,sys,time\nfrom pathlib import Path\nPath(sys.argv[1]).write_text(str(os.getpid()))\ntime.sleep(30)\n')
        with self.assertRaises(subprocess.TimeoutExpired):
            setup_speech.bounded_run([sys.executable, str(child), str(pidfile)], .2)
        self.assertTrue(pidfile.exists())
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pidfile.read_text()), 0)

    def test_sigterm_cli_unwinds_and_reaps_its_running_helper(self):
        import os
        import signal
        import sys
        import time
        pidfile = self.root / 'helper.pid'
        helper = 'import os,sys,time;from pathlib import Path;Path(sys.argv[1]).write_text(str(os.getpid()));time.sleep(15)'
        script = ('import sys\n'
                  'sys.path.insert(0,' + repr(str(Path(__file__).resolve().parent)) + ')\n'
                  'import setup_speech as module\n'
                  'module.platform.system=lambda:"Linux"\n'
                  'module.platform.machine=lambda:"x86_64"\n'
                  'module.shutil.which=lambda name:"/synthetic/"+name\n'
                  'module.setup=lambda path:module.bounded_run([sys.executable,"-c",' + repr(helper) + ',' + repr(str(pidfile)) + '],20)\n'
                  'sys.exit(module.main(["--destination",' + repr(str(self.destination)) + ']))\n')
        parent = subprocess.Popen([sys.executable, '-c', script], start_new_session=True,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        child = None
        try:
            end = time.monotonic() + 2
            while not pidfile.exists() and time.monotonic() < end:
                time.sleep(.01)
            self.assertTrue(pidfile.exists())
            child = int(pidfile.read_text())
            parent.send_signal(signal.SIGTERM)
            self.assertEqual(parent.wait(timeout=5), 143)
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
        finally:
            if parent.poll() is None:
                os.killpg(parent.pid, signal.SIGKILL)
                parent.wait(timeout=2)
            if child:
                try:
                    os.killpg(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_cli_restores_previous_sigterm_handler_after_return(self):
        import signal
        previous = signal.getsignal(signal.SIGTERM)
        with patch('setup_speech.platform.system', return_value='Linux'), \
             patch('setup_speech.platform.machine', return_value='x86_64'), \
             patch('setup_speech.shutil.which', return_value='/synthetic/helper'), \
             patch('setup_speech.setup', return_value=self.destination / 'linux.json'):
            self.assertEqual(setup_speech.main(['--destination', str(self.destination)]), 0)
        self.assertEqual(signal.getsignal(signal.SIGTERM), previous)

    def test_cli_refuses_non_linux_without_creating_destination(self):
        with patch('setup_speech.platform.system', return_value='Darwin'):
            self.assertEqual(setup_speech.main(['--destination', str(self.destination)]), 2)
        self.assertFalse(self.destination.exists())


if __name__ == '__main__':
    unittest.main()
