"""Explicit, bounded Linux component acceptance using synthetic data only."""

import argparse
from array import array
import json
import math
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import traceback
import time
import wave

from desktop import PipeWireCapture, stop_process


def tone_metrics(path):
    with wave.open(str(path), 'rb') as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):
            raise ValueError('Wrong capture format')
        count = source.getnframes()
        if not 1600 <= count <= 16000 * 3:
            raise ValueError('Wrong capture duration')
        samples = array('h', source.readframes(count))
    if sys.byteorder != 'little':
        samples.byteswap()
    if len(samples) != count:
        raise ValueError('Truncated capture')
    rms = math.sqrt(sum((value / 32768) ** 2 for value in samples) / count)
    frequency = sum(a <= 0 < b for a, b in zip(samples, samples[1:])) / (count / 16000)
    if rms < .01 or abs(frequency - 440) > 8:
        raise ValueError('Expected synthetic 440 Hz source was not captured')
    return {'frames': count, 'rate': 16000, 'channels': 1, 'rms': rms, 'frequency_hz': frequency}



def file_capability(path):
    if not path:
        return None
    result = {'mode': oct(Path(path).stat().st_mode & 0o7777)}
    try:
        result['capability_hex'] = os.getxattr(path, 'security.capability').hex()
    except OSError as error:
        result['capability_read_errno'] = error.errno
    return result


def capabilities():
    return {'system': platform.system(), 'kernel': platform.release(),
            'architecture': platform.machine(), 'drm_nodes': [str(p) for p in Path('/dev/dri').glob('*')],
            'commands': {name: shutil.which(name) for name in
                         ('Hyprland', 'hyprctl', 'pipewire', 'pw-record', 'wireplumber', 'sway', 'wtype', 'wl-copy', 'wl-paste')},
            'hyprland_acceptance': False, 'omarchy_acceptance': False,
            'sway_file': file_capability(shutil.which('sway'))}


class Processes:
    def __init__(self, root, env):
        self.root, self.env, self.items = root, env, []
    def start(self, command, *, stdin=subprocess.DEVNULL):
        sys.stderr.write('acceptance start: ' + json.dumps(command) + '\n')
        log = (self.root / ('process-' + str(len(self.items)) + '.log')).open('wb')
        try:
            process = subprocess.Popen(command, stdin=stdin, stdout=log, stderr=log,
                                       env=self.env, start_new_session=True)
        except BaseException:
            log.close()
            raise
        self.items.append((process, log))
        return process
    def close(self):
        failure = None
        for process, log in reversed(self.items):
            try:
                stop_process(process)
            except (OSError, subprocess.SubprocessError) as error:
                failure = error
            finally:
                if process.stdin and not process.stdin.closed:
                    process.stdin.close()
                log.close()
        if failure:
            raise failure


def wait_for(check, seconds=8):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = check()
        if value:
            return value
        time.sleep(.05)
    raise TimeoutError('Component readiness deadline')


def run(command, env, **kwargs):
    sys.stderr.write('acceptance command: ' + json.dumps(command) + '\n')
    try:
        return subprocess.run(command, env=env, timeout=5, check=True, capture_output=True, **kwargs)
    except subprocess.CalledProcessError as error:
        for data in (error.stdout, error.stderr):
            if data:
                sys.stderr.write(data[-16384:].decode('utf-8', errors='replace') if isinstance(data, bytes) else data[-16384:])
        raise


def pipewire_component(root, env, processes):
    fragment = root / 'config/pipewire/pipewire.conf.d/90-mouthtype-test.conf'
    fragment.parent.mkdir(parents=True)
    fragment.write_text('''context.spa-libs = { audiotestsrc = audiotestsrc/libspa-audiotestsrc }
context.objects = [
 { factory = adapter args = {
   factory.name = audiotestsrc
   node.name = mouthtype-synthetic-source
   node.description = "Mouthtype synthetic acceptance source"
   media.class = Audio/Source
   audio.rate = 16000
   audio.channels = 1
   audio.position = [ MONO ]
   node.param.Props = { frequency = 440 volume = 0.1 }
 } }
]
''')
    # Policy-only profile does not enumerate/open hardware sources.
    processes.start(['pipewire'])
    wait_for(lambda: (Path(env['XDG_RUNTIME_DIR']) / 'pipewire-0').exists())
    processes.start(['wireplumber', '--profile=policy'])
    capture_log = (root / 'capture.log').open('wb')
    capture = PipeWireCapture(target='mouthtype-synthetic-source', errors=capture_log)
    capture_argv = capture.argv
    capture.argv = lambda path: capture_argv(path)[:-1] + ['--verbose', str(path)]
    previous = dict(os.environ)
    os.environ.update(env)
    try:
        capture.start(root / 'synthetic.wav')
        process = capture.process
        time.sleep(.8)
        capture.stop()
        metrics = tone_metrics(root / 'synthetic.wav')
        if process.poll() is None:
            raise ValueError('Capture process remains active')
        return {'component': 'pipewire', 'synthetic_source': True, 'capture': metrics,
                'capture_reaped': True, 'physical_microphone': False,
                'model_inference': False, 'hyprland_acceptance': False, 'omarchy_acceptance': False}
    except BaseException:
        capture_log.flush()
        sys.stderr.write((root / 'capture.log').read_bytes()[-16384:].decode('utf-8', errors='replace'))
        raise
    finally:
        capture.cancel()
        capture_log.close()
        os.environ.clear()
        os.environ.update(previous)


def focused_node(tree):
    if tree.get('focused') and tree.get('app_id'):
        return {'id': tree['id'], 'app_id': tree['app_id']}
    for child in tree.get('nodes', []) + tree.get('floating_nodes', []):
        found = focused_node(child)
        if found:
            return found
    return None


def sway_component(root, env, processes):
    if os.getuid() == 0:
        raise ValueError('Run compositor acceptance as an ordinary user')
    env.update(WLR_BACKENDS='headless', WLR_RENDERER='pixman', WLR_HEADLESS_OUTPUTS='1',
               WLR_LIBINPUT_NO_DEVICES='1', XDG_SESSION_TYPE='wayland', GDK_BACKEND='wayland',
               LC_ALL='C.UTF-8')
    config = root / 'sway.conf'
    config.write_text('output * resolution 1024x768\nfocus_follows_mouse no\n')
    compositor = processes.start(['sway', '--config', str(config)])
    runtime = Path(env['XDG_RUNTIME_DIR'])
    ipc = wait_for(lambda: next(runtime.glob('sway-ipc.*.sock'), None))
    wayland = wait_for(lambda: next((p for p in runtime.glob('wayland-*') if not p.name.endswith('.lock')), None))
    env.update(SWAYSOCK=str(ipc), WAYLAND_DISPLAY=wayland.name)
    text_path = root / 'target.json'
    target = processes.start([sys.executable, str(Path(__file__).with_name('wayland_target.py')), str(text_path)])
    wait_for(lambda: text_path.exists())
    run(['swaymsg', '[app_id="app.mouthtype.Acceptance"] focus'], env)
    before = wait_for(lambda: focused_node(json.loads(run(['swaymsg', '-t', 'get_tree'], env).stdout)))
    if before['app_id'] != 'app.mouthtype.Acceptance':
        raise ValueError('Native acceptance target does not have focus')
    clipboard = processes.start(['wl-copy', '--foreground', '--type', 'text/plain;charset=utf-8'], stdin=subprocess.PIPE)
    sentinel = b'Mouthtype existing clipboard'
    clipboard.stdin.write(sentinel)
    clipboard.stdin.close()
    wait_for(lambda: run(['wl-paste', '--no-newline'], env).stdout == sentinel)
    expected = 'Hello, 世界. Émilie 👋'
    run(['wtype', '-'], env, input=expected.encode())
    def contents():
        try:
            value = json.loads(text_path.read_text())
        except (ValueError, OSError):
            return None
        return value if value.get('text') == expected else None
    actual = wait_for(contents)
    after = focused_node(json.loads(run(['swaymsg', '-t', 'get_tree'], env).stdout))
    if before != after or run(['wl-paste', '--no-newline'], env).stdout != sentinel:
        raise ValueError('Focus or clipboard changed')
    if compositor.poll() is not None or target.poll() is not None:
        raise ValueError('Component exited early')
    return {'component': 'sway-wtype', 'compositor': 'Sway headless pixman',
            'native_target': 'GTK3 Wayland', 'unicode_exact': actual['text'] == expected,
            'helper_submissions': 1, 'focus_preserved': True, 'clipboard_preserved': True,
            'hyprland_adapter_tested': False, 'hyprland_acceptance': False, 'omarchy_acceptance': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('component', choices=('capabilities', 'pipewire', 'sway'))
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('Explicit Linux component acceptance only')
    if args.component == 'capabilities':
        print(json.dumps(capabilities(), indent=2))
        return 0
    def deadline(*_):
        raise TimeoutError('Acceptance lifetime limit')
    for event in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT):
        signal.signal(event, deadline)
    signal.alarm(45)
    try:
        with tempfile.TemporaryDirectory(prefix='mouthtype-acceptance-') as temp:
            root = Path(temp)
            env = {**os.environ, 'XDG_RUNTIME_DIR': str(root / 'runtime'),
                   'XDG_CONFIG_HOME': str(root / 'config'), 'XDG_STATE_HOME': str(root / 'state'),
                   'XDG_CACHE_HOME': str(root / 'cache')}
            Path(env['XDG_RUNTIME_DIR']).mkdir(mode=0o700)
            env.pop('WAYLAND_DISPLAY', None)
            env.pop('WAYLAND_SOCKET', None)
            env.pop('DISPLAY', None)
            env.pop('SWAYSOCK', None)
            for name in ('PIPEWIRE_NODE', 'PIPEWIRE_CONFIG_DIR', 'PIPEWIRE_CONFIG_NAME',
                         'WIREPLUMBER_CONFIG_DIR', 'WIREPLUMBER_STATE_DIR'):
                env.pop(name, None)
            env['PIPEWIRE_RUNTIME_DIR'] = env['XDG_RUNTIME_DIR']
            env['PIPEWIRE_REMOTE'] = 'pipewire-0'
            processes = Processes(root, env)
            try:
                check = pipewire_component if args.component == 'pipewire' else sway_component
                result = check(root, env, processes)
            except BaseException:
                traceback.print_exc(file=sys.stderr)
                for _process, log in processes.items:
                    log.flush()
                    data = Path(log.name).read_bytes()[-16384:]
                    sys.stderr.write(data.decode('utf-8', errors='replace'))
                raise
            finally:
                signal.alarm(0)
                processes.close()
            print(json.dumps({'passed': True, **result}, indent=2))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({'passed': False, 'component': args.component, 'error_class': type(error).__name__,
                          'error_message': str(error)}))
        return 1
    finally:
        signal.alarm(0)


if __name__ == '__main__':
    sys.exit(main())
