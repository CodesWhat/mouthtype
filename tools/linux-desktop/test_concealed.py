import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import concealed

TYPE = 'text/plain;charset=utf-8'


def helper(stdout='', stderr='', error=None):
    def run(argv, **kwargs):
        run.calls.append(argv)
        if error:
            raise error
        return SimpleNamespace(stdout=stdout, stderr=stderr, returncode=0)
    run.calls = []
    return run


class OfferTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(concealed, '_supported', None)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_new_wl_copy_offers_the_sensitive_hint_with_the_text_type(self):
        run = helper(stdout='Usage: wl-copy\n\t    --sensitive\t\tHint that the content is sensitive.\n')
        self.assertEqual(concealed.copy_command(run), ['wl-copy', '--sensitive', '--type', TYPE])

    def test_old_wl_copy_falls_back_to_the_plain_command(self):
        run = helper(stdout='Usage: wl-copy\n\t-p, --primary\n')
        self.assertEqual(concealed.copy_command(run), ['wl-copy', '--type', TYPE])

    def test_missing_or_hung_probe_falls_back_to_plain(self):
        for error in (FileNotFoundError(), subprocess.TimeoutExpired('wl-copy', 2)):
            concealed._supported = None
            self.assertEqual(concealed.copy_command(helper(error=error)), ['wl-copy', '--type', TYPE])

    def test_support_is_probed_once(self):
        run = helper(stdout='--sensitive')
        concealed.copy_command(run)
        concealed.copy_command(run)
        self.assertEqual(len(run.calls), 1)

    def test_a_failed_probe_is_retried_later(self):
        concealed.copy_command(helper(error=FileNotFoundError()))
        self.assertIsNone(concealed._supported)

    def test_callers_get_their_own_list(self):
        run = helper(stdout='--sensitive')
        concealed.copy_command(run).append('x')
        self.assertEqual(concealed.copy_command(run), ['wl-copy', '--sensitive', '--type', TYPE])


SWAY = os.environ.get('MOUTHTYPE_SWAY_BINARY', 'sway')


def sway_ready():
    if not (shutil.which(SWAY) and shutil.which('wl-copy') and shutil.which('wl-paste')):
        return False
    try:
        # Packaged sway can carry file capabilities that an unprivileged build or CI user may not exec.
        subprocess.run([SWAY, '--version'], capture_output=True, check=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return False
    return concealed.sensitive_supported()


@unittest.skipUnless(sway_ready(), 'needs sway and wl-clipboard 2.3 or newer')
class HeadlessWaylandTests(unittest.TestCase):
    """Real wl-copy under a headless sway: both types are offered and watchers see the sensitive state."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        runtime = Path(self.temp.name)
        runtime.chmod(0o700)
        self.env = {**os.environ, 'XDG_RUNTIME_DIR': str(runtime), 'WLR_BACKENDS': 'headless',
                    'WLR_RENDERER': 'pixman', 'WLR_LIBINPUT_NO_DEVICES': '1'}
        self.env.pop('WAYLAND_DISPLAY', None)
        config = runtime / 'sway.conf'
        config.write_text('')
        self.sway = subprocess.Popen([SWAY, '--unsupported-gpu', '-c', str(config)], env=self.env,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop, self.sway)
        deadline = time.monotonic() + 15
        while True:
            sockets = [p for p in runtime.glob('wayland-*') if not p.name.endswith('.lock')]
            if sockets:
                self.env['WAYLAND_DISPLAY'] = sockets[0].name
                break
            self.assertIsNone(self.sway.poll(), 'sway exited')
            self.assertLess(time.monotonic(), deadline, 'sway socket never appeared')
            time.sleep(.1)

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    def paste(self, *args):
        return subprocess.run(['wl-paste', *args], env=self.env, capture_output=True, text=True, timeout=5)

    def test_concealed_copy_offers_text_and_the_hint_and_pastes_normally(self):
        subprocess.run(concealed.copy_command(), input=b'dictated words', env=self.env, check=True, timeout=5)
        types = self.paste('--list-types').stdout.split()
        self.assertIn(TYPE, types)
        self.assertIn('x-kde-passwordManagerHint', types)
        self.assertEqual(self.paste('--no-newline', '--type', TYPE).stdout, 'dictated words')
        self.assertEqual(self.paste('--no-newline', '--type', 'x-kde-passwordManagerHint').stdout, 'secret')

    def test_watchers_see_the_sensitive_state_only_for_concealed_copies(self):
        watcher = subprocess.Popen(
            ['wl-paste', '--watch', 'sh', '-c', 'echo "${CLIPBOARD_STATE:-none}" >> "$0"', str(Path(self.temp.name) / 'seen')],
            env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop, watcher)
        seen = Path(self.temp.name) / 'seen'
        subprocess.run(['wl-copy', 'ordinary'], env=self.env, check=True, timeout=5)
        subprocess.run(concealed.copy_command(), input=b'hidden', env=self.env, check=True, timeout=5)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            states = seen.read_text().split() if seen.exists() else []
            if 'sensitive' in states:
                break
            time.sleep(.1)
        self.assertIn('sensitive', states)
        self.assertNotIn('none', states[states.index('sensitive'):])


if __name__ == '__main__':
    unittest.main()
