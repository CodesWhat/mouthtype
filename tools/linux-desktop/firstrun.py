"""First-run setup for package installs, so installing the package and logging in is the whole procedure.

`mouthtype-linux firstrun` runs from the mouthtype-linux-firstrun systemd user unit at login. When the per-user pieces
are unset (no speech setup, or no bar plugin on an Omarchy desktop) it runs the same steps as `mouthtype-linux-setup`
(setup.py), with desktop notifications for progress. Everything it decides is recorded in firstrun.json under the XDG
state directory:

  done         setup finished, or was already complete. Nothing runs again, except the upgrade refresh below.
  uninstalled  the user ran `mouthtype-linux-setup --uninstall`. Nothing runs again until they run setup by hand.
  failed       a step failed. It retries at the next login, at most MAX_ATTEMPTS times, then stops and says so.
  running      an attempt is in progress or was killed; a stale one is retried like a failure.

Upgrades: when the state is `done` and the packaged plugin (or app) version differs from the per-user copy's
version.json, login re-runs the plugin's `install.py --update`, restarts the service and says what version it
updated to. `updated_to`, `update_target` and `update_attempts` in firstrun.json cap a failing update at
MAX_ATTEMPTS tries per version. `uninstalled` never updates.

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
import plistlib
import threading
import time

HERE = Path(__file__).resolve().parent
MAX_ATTEMPTS = 3
HOLD = ('done', 'uninstalled')
SYSTEM_PLUGIN = Path('/usr/share/mouthtype-linux/omarchy-plugin')


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


def notify(summary, body='', *, percent=None, replace_id=None, run=subprocess.run):
    """Send one notification and return its id (None when the notifier is missing or gave no id).

    percent adds the int:value hint that notification daemons draw as a progress bar; replace_id updates that
    notification in place instead of stacking a new one."""
    if shutil.which('notify-send') is None:
        return None
    command = ['notify-send', '--print-id', '--app-name=Mouthtype', '--expire-time=8000']
    if replace_id:
        command.append('--replace-id=' + str(replace_id))
    if percent is not None:
        command += ['-h', 'int:value:' + str(percent)]
    try:
        result = run(command + [summary, body], timeout=10, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, check=False, text=True)
        raw = (result.stdout or '').strip()
        return int(raw) if raw.isdigit() and 0 < int(raw) <= 4294967295 else None
    except (OSError, subprocess.SubprocessError, AttributeError):
        return None


def speech_progress_path():
    return home() / '.local/share/mouthtype/speech-candidate/speech-setup.json'


def read_percent():
    """Download percent from the progress file setup_speech writes, or None when there is no usable reading."""
    try:
        value = json.loads(speech_progress_path().read_text())
        if value.get('state') != 'downloading':
            return None
        done, total = int(value['bytes_done']), int(value['bytes_total'])
        return max(0, min(100, done * 100 // total)) if total > 0 else None
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def run_with_progress(work, notifier, title, body, *, interval=1.0, step=5, sleep=time.sleep):
    """Run work() in a thread, polling the speech progress file and updating one notification as the download goes.

    Returns (work's result, id of the notification, so the caller can replace it with the final message). The
    shown percent only moves forward and updates at most every `step` percent. A notifier without id support
    (or none at all) just means the progress message doesn't update; setup is never blocked on it."""
    outcome = []
    thread = threading.Thread(target=lambda: outcome.append(work()), daemon=True)
    identity = notifier(title, body, percent=0)
    shown = 0
    thread.start()
    while thread.is_alive():
        sleep(interval)
        percent = read_percent()
        if percent is not None and percent >= shown + step and identity:
            shown = percent
            identity = notifier(title, body, percent=percent, replace_id=identity) or identity
    thread.join()
    return outcome[0], identity


def load_setup():
    import importlib.util
    spec = importlib.util.spec_from_file_location('mouthtype_linux_setup', HERE / 'setup.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def final(notifier, identity, summary, body):
    """The closing message replaces the progress notification when there is one, so no stale bar is left behind."""
    if identity:
        notifier(summary, body, replace_id=identity)
    else:
        notifier(summary, body)


def packaged_plugin(plugin_dir=None):
    candidates = [Path(plugin_dir)] if plugin_dir else [SYSTEM_PLUGIN, HERE.parent / 'omarchy-plugin']
    return next((path for path in candidates if (path / 'install.py').is_file()), None)


def packaged_versions(plugin):
    """{'plugin', 'app'} for the packaged plugin copy. The app version comes from Version.plist, shipped next to the
    plugin directory in packages or under packaging/ in a checkout; either may be absent (None)."""
    plugin_version = app = None
    try:
        value = json.loads((plugin / 'manifest.json').read_text()).get('version')
        plugin_version = value if isinstance(value, str) else None
    except (OSError, ValueError, AttributeError):
        pass
    for path in (plugin.parent / 'Version.plist', plugin.parent.parent / 'packaging/Version.plist'):
        try:
            with open(path, 'rb') as handle:
                value = plistlib.load(handle).get('MouthtypeDisplayVersion')
            app = value if isinstance(value, str) else None
            break
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
    return {'plugin': plugin_version, 'app': app}


def installed_versions():
    try:
        value = json.loads((home() / '.config/omarchy/plugins/dstahl.mouthtype/version.json').read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def refresh_after_upgrade(state, *, notifier=notify, plugin_dir=None, run=subprocess.run):
    """Bring the per-user plugin copy up to the packaged version. Returns the exit status (0 when nothing to do)."""
    if not (home() / '.config/omarchy/plugins/dstahl.mouthtype').exists():
        return 0
    plugin = packaged_plugin(plugin_dir)
    if plugin is None:
        return 0
    packaged = packaged_versions(plugin)
    installed = installed_versions()
    if all(installed.get(key) == value for key, value in packaged.items() if value):
        return 0
    label = packaged['app'] or packaged['plugin']
    if not label:
        return 0
    tries = state.get('update_attempts', 0) if state.get('update_target') == label else 0
    if tries >= MAX_ATTEMPTS:
        print('Updating the Mouthtype plugin to ' + label + ' failed ' + str(tries) +
              ' times and will not retry on its own. Run: mouthtype-linux-setup')
        return 0
    tries += 1
    carried = {key: state[key] for key in ('attempts', 'reason', 'updated_to') if key in state}
    record('done', **{**carried, 'update_target': label, 'update_attempts': tries})
    try:
        result = run([sys.executable, str(plugin / 'install.py'), '--update', '--no-restart-shell'], timeout=300,
                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        status, output = result.returncode, (result.stderr or result.stdout or '')
    except (OSError, subprocess.SubprocessError) as error:
        status, output = 1, str(error)
    if status != 0:
        lines = [line.strip() for line in output.splitlines() if line.strip()]
        error = lines[-1] if lines else 'plugin update exited with status ' + str(status)
        record('done', **{**carried, 'update_target': label, 'update_attempts': tries, 'update_error': error})
        print('Plugin update failed: ' + error, file=sys.stderr)
        if tries >= MAX_ATTEMPTS:
            notifier('Mouthtype update failed', error[:200] + ' Run mouthtype-linux-setup to try again.')
        return 1
    try:
        run(['systemctl', '--user', 'try-restart', 'mouthtype-linux'], timeout=30, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except (OSError, subprocess.SubprocessError):
        pass
    record('done', **{**carried, 'updated_to': label, 'update_target': label, 'update_attempts': 0})
    notifier('Mouthtype updated to ' + label, 'The bar widget and dictation service are on the new version.')
    return 0


def run_first(*, setup_main=None, notifier=notify, plugin_dir=None, sleep=time.sleep, run=subprocess.run):
    """Returns the process exit status: 0 when nothing needed doing or setup finished, 1 when it failed."""
    if sys.platform != 'linux':
        return 0
    state = read_state()
    if state.get('state') == 'done':
        return refresh_after_upgrade(state, notifier=notifier, plugin_dir=plugin_dir, run=run)
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
        title = 'Setting up Mouthtype'
        body = (('First run: downloading the speech model (about 465 MiB). '
                 if reason == 'no speech setup' else 'First run: adding the Mouthtype bar widget. ')
                + 'You will get a message when it is ready.')
        log = io.StringIO()

        def work():
            try:
                setup = setup_main or load_setup().main
                return setup(argv)
            except SystemExit as stop:
                return stop.code if isinstance(stop.code, int) else 1
            except Exception as error:
                print(type(error).__name__ + ': ' + str(error), file=sys.stderr)
                return 1

        with contextlib.redirect_stderr(log):
            if reason == 'no speech setup':
                status, shown_id = run_with_progress(work, notifier, title, body, sleep=sleep)
            else:
                notifier(title, body)
                status, shown_id = work(), None
        sys.stderr.write(log.getvalue())
        if status == 0:
            record('done', attempts=attempts, reason=reason)
            try:
                bindings = (home() / '.config/hypr/bindings.lua').read_text()
            except OSError:
                bindings = ''
            keys = [text for marker, text in (('plugin shortcut: begin', 'Super+Alt+M to dictate'),
                                              ('plugin transform shortcut: begin', 'Super+Shift+T to transform a selection'))
                    if marker in bindings]
            final(notifier, shown_id, 'Mouthtype is ready', ('Press ' + ', '.join(keys) + '. ' if keys else
                                            'Pick a dictation key from the Mouthtype menu in the bar. ')
                     + 'Check anytime with: mouthtype-linux doctor')
            return 0
        lines = [line.strip() for line in log.getvalue().splitlines() if line.strip()]
        error = lines[-1] if lines else 'setup exited with status ' + str(status)
        record('failed', attempts=attempts, reason=reason, error=error)
        retry = 'It will try again at your next login.' if attempts < MAX_ATTEMPTS else 'Run mouthtype-linux-setup to try again.'
        final(notifier, shown_id, 'Mouthtype setup failed', error[:200] + ' ' + retry)
        return 1
    finally:
        lock.close()
