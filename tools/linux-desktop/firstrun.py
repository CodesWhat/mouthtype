"""First-run setup for package installs, so installing the package and logging in is the whole procedure.

`mouthtype-linux firstrun` runs from the mouthtype-linux-firstrun systemd user unit at login. When the per-user pieces
are unset (no speech setup, or no bar plugin on an Omarchy desktop) it runs the same steps as `mouthtype-linux-setup`
(setup.py), with desktop notifications for progress. Everything it decides is recorded in firstrun.json under the XDG
state directory:

  done         setup finished, or was already complete. Nothing runs again.
  uninstalled  the user ran `mouthtype-linux-setup --uninstall`. Nothing runs again until they run setup by hand.
  failed       a step failed. It retries at the next login, at most MAX_ATTEMPTS times, then stops and says so.
  running      an attempt is in progress or was killed; a stale one is retried like a failure.

The unit is Type=oneshot with no Restart=, so a failure cannot loop within a session.
"""

import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
MAX_ATTEMPTS = 3
HOLD = ('done', 'uninstalled')


def home():
    return Path.home()


def state_dir():
    base = os.environ.get('XDG_STATE_HOME')
    return (Path(base) if base and os.path.isabs(base) else home() / '.local/state') / 'mouthtype'


def state_path():
    return state_dir() / 'firstrun.json'


def read_state():
    try:
        value = json.loads(state_path().read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def record(state, **fields):
    """Atomically write the marker. Never raises: a read-only state directory must not break setup itself."""
    previous = read_state()
    value = {'state': state, 'attempts': previous.get('attempts', 0), 'updated': time.time(), **fields}
    try:
        state_dir().mkdir(parents=True, exist_ok=True)
        temporary = state_path().with_suffix('.tmp')
        temporary.write_text(json.dumps(value, indent=2) + '\n')
        os.replace(temporary, state_path())
    except OSError:
        pass
    return value


def needs_setup():
    """The reason the per-user setup is unset, or None when nothing is missing."""
    if not (home() / '.local/share/mouthtype/speech-candidate/linux.json').is_file():
        return 'no speech setup'
    if (home() / '.config/omarchy/shell.json').is_file() and not (home() / '.config/omarchy/plugins/dstahl.mouthtype').exists():
        return 'no bar plugin'
    return None


def notify(summary, body='', *, run=subprocess.run):
    if shutil.which('notify-send') is None:
        return
    try:
        run(['notify-send', '--app-name=Mouthtype', '--expire-time=8000', summary, body], timeout=10,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except (OSError, subprocess.SubprocessError):
        pass


def load_setup():
    import importlib.util
    spec = importlib.util.spec_from_file_location('mouthtype_linux_setup', HERE / 'setup.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_first(*, setup_main=None, notifier=notify, plugin_dir=None):
    """Returns the process exit status: 0 when nothing needed doing or setup finished, 1 when it failed."""
    if sys.platform != 'linux':
        return 0
    state = read_state()
    if state.get('state') in HOLD:
        print('First-run setup already ' + state['state'] + '; run mouthtype-linux-setup to change that.')
        return 0
    if state.get('state') in ('failed', 'running') and state.get('attempts', 0) >= MAX_ATTEMPTS:
        print('First-run setup failed ' + str(state['attempts']) + ' times and will not retry on its own. Run: mouthtype-linux-setup')
        return 0
    reason = needs_setup()
    if reason is None:
        record('done', reason='already set up')
        print('Already set up.')
        return 0
    state_dir().mkdir(parents=True, exist_ok=True)
    lock = open(state_dir() / 'firstrun.lock', 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        lock.close()
        print('Another Mouthtype setup is running; leaving it to finish.')
        return 0
    try:
        attempts = read_state().get('attempts', 0) + 1
        record('running', attempts=attempts, reason=reason)
        omarchy = (home() / '.config/omarchy/shell.json').is_file()
        argv = ['--shortcut', 'toggle'] + ([] if omarchy else ['--skip-plugin'])
        if plugin_dir:
            argv += ['--plugin-dir', str(plugin_dir)]
        notifier('Setting up Mouthtype', ('First run: downloading the speech model (about 465 MiB). '
                                          if reason == 'no speech setup' else 'First run: adding the Mouthtype bar widget. ')
                 + 'You will get a message when it is ready.')
        log = io.StringIO()
        status = 1
        with contextlib.redirect_stderr(log):
            try:
                setup = setup_main or load_setup().main
                status = setup(argv)
            except SystemExit as stop:
                status = stop.code if isinstance(stop.code, int) else 1
            except Exception as error:
                print(type(error).__name__ + ': ' + str(error), file=sys.stderr)
        sys.stderr.write(log.getvalue())
        if status == 0:
            record('done', attempts=attempts, reason=reason)
            notifier('Mouthtype is ready', 'Press Super+Alt+M to dictate' + (', Super+Shift+T to transform a selection.' if omarchy else '.')
                     + ' Check anytime with: mouthtype-linux doctor')
            return 0
        lines = [line.strip() for line in log.getvalue().splitlines() if line.strip()]
        error = lines[-1] if lines else 'setup exited with status ' + str(status)
        record('failed', attempts=attempts, reason=reason, error=error)
        retry = 'It will try again at your next login.' if attempts < MAX_ATTEMPTS else 'Run mouthtype-linux-setup to try again.'
        notifier('Mouthtype setup failed', error[:200] + ' ' + retry)
        return 1
    finally:
        lock.close()
