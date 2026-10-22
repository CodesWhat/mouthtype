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
import threading
import traceback
import time
import wave

import session_client
from desktop import PipeWireCapture, stop_process, read_phrase_clipboard, HyprlandDelivery
from phrases import load_phrases
from cleanup import BasicCleanup
import consent_atspi


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
        raise ValueError('Expected synthetic 440 Hz source was not captured: ' +
                         json.dumps({'frames': count, 'rms': rms, 'frequency_hz': frequency}))
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


def packaged_sway_probe():
    try:
        result = subprocess.run(['sway', '--version'], capture_output=True, text=True, timeout=5)
        return {'returncode': result.returncode, 'stdout': result.stdout[-4096:], 'stderr': result.stderr[-4096:]}
    except OSError as error:
        return {'error_class': type(error).__name__, 'errno': error.errno}
    except subprocess.SubprocessError as error:
        return {'error_class': type(error).__name__}


def capabilities():
    return {'system': platform.system(), 'kernel': platform.release(),
            'architecture': platform.machine(), 'drm_nodes': [str(p) for p in Path('/dev/dri').glob('*')],
            'commands': {name: shutil.which(name) for name in
                         ('Hyprland', 'hyprctl', 'pipewire', 'pw-record', 'wireplumber', 'sway', 'wtype', 'wl-copy', 'wl-paste')},
            'hyprland_acceptance': False, 'omarchy_acceptance': False,
            'sway_file': file_capability(shutil.which('sway')),
            'packaged_sway_version_probe': packaged_sway_probe()}


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


def clipboard_ready(env, sentinel):
    try:
        return run(['wl-paste', '--no-newline'], env).stdout == sentinel
    except subprocess.CalledProcessError as error:
        if error.returncode == 1:
            return False
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
   node.param.Props = { frequency = 440 volume = 0.5 }
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


def mapped_target(tree, application):
    if tree.get('app_id') == application:
        return {'id': tree['id'], 'app_id': tree['app_id']}
    for child in tree.get('nodes', []) + tree.get('floating_nodes', []):
        found = mapped_target(child, application)
        if found:
            return found
    return None


def focused_node(tree):
    if tree.get('focused') and tree.get('app_id'):
        return {'id': tree['id'], 'app_id': tree['app_id']}
    for child in tree.get('nodes', []) + tree.get('floating_nodes', []):
        found = focused_node(child)
        if found:
            return found
    return None


def compositor_tree(root, env):
    tree = json.loads(run(['swaymsg', '-t', 'get_tree'], env).stdout)
    (root / 'tree.json').write_text(json.dumps(tree))
    return tree


def sway_component(root, env, processes):
    if os.getuid() == 0:
        raise ValueError('Run compositor acceptance as an ordinary user')
    env.update(WLR_BACKENDS='headless', WLR_RENDERER='pixman', WLR_HEADLESS_OUTPUTS='1',
               WLR_LIBINPUT_NO_DEVICES='1', XDG_SESSION_TYPE='wayland', GDK_BACKEND='wayland',
               LC_ALL='C.UTF-8')
    config = root / 'sway.conf'
    config.write_text('output * resolution 1024x768\nfocus_follows_mouse no\n')
    sway = env.get('MOUTHTYPE_SWAY_BINARY', 'sway')
    version = run([sway, '--version'], env).stdout.decode().strip()
    compositor = processes.start([sway, '--config', str(config)])
    runtime = Path(env['XDG_RUNTIME_DIR'])
    ipc = wait_for(lambda: next(runtime.glob('sway-ipc.*.sock'), None))
    wayland = wait_for(lambda: next((p for p in runtime.glob('wayland-*') if not p.name.endswith('.lock')), None))
    env.update(SWAYSOCK=str(ipc), WAYLAND_DISPLAY=wayland.name)
    text_path = root / 'target.json'
    target = processes.start([sys.executable, str(Path(__file__).with_name('wayland_target.py')), str(text_path)])
    wait_for(lambda: text_path.exists())
    mapped = wait_for(lambda: mapped_target(
        compositor_tree(root, env), 'app.mouthtype.Acceptance'))
    run(['swaymsg', '[con_id=' + str(mapped['id']) + '] focus'], env)
    before = wait_for(lambda: focused_node(compositor_tree(root, env)))
    if before['app_id'] != 'app.mouthtype.Acceptance':
        raise ValueError('Native acceptance target does not have focus')
    clipboard = processes.start(['wl-copy', '--foreground', '--type', 'text/plain;charset=utf-8'], stdin=subprocess.PIPE)
    sentinel = b'Mouthtype existing clipboard'
    clipboard.stdin.write(sentinel)
    clipboard.stdin.close()
    wait_for(lambda: clipboard_ready(env, sentinel))
    phrase_path = root / 'phrases.json'
    phrase_path.write_text(json.dumps([{'trigger': 'example phrase',
                                       'expansion': 'Hello, 世界. Émilie 👋 {clipboard}'}]))
    phrases = load_phrases(phrase_path, clipboard=lambda: read_phrase_clipboard(env=env))
    multiline = BasicCleanup('basic').apply('example phrase new line next item')
    if multiline != 'Example phrase\nNext item':
        raise ValueError('Cleanup differs from the synthetic fixture')
    expanded_multiline = phrases.apply(multiline)
    if expanded_multiline != 'Hello, 世界. Émilie 👋 Mouthtype existing clipboard\nNext item':
        raise ValueError('Multiline phrase snapshot differs from the synthetic fixture')
    def refuse_helpers(*_args, **_kwargs):
        raise RuntimeError('Unsupported text must be refused before compositor/helper calls')
    delivery = HyprlandDelivery({'mode': 'type', 'allow_unknown_secure_field': True,
                                 'allowed_classes': ['app.mouthtype.Acceptance']}, run=refuse_helpers)
    if delivery.submit(expanded_multiline, {'class': 'app.mouthtype.Acceptance'}) != 'unsupported_text':
        raise ValueError('Production delivery did not refuse control-bearing text')
    if json.loads(text_path.read_text())['text'] != '':
        raise ValueError('Unsupported text reached the target')
    expected = 'Hello, 世界. Émilie 👋 Mouthtype existing clipboard.'
    single = BasicCleanup('basic').apply('example phrase period')
    if single != 'Example phrase.':
        raise ValueError('Single-line cleanup differs from the synthetic fixture')
    expanded = phrases.apply(single)
    if expanded != expected:
        raise ValueError('Phrase clipboard snapshot differs from the synthetic fixture')
    run(['wtype', '-'], env, input=expanded.encode())
    def contents():
        try:
            value = json.loads(text_path.read_text())
        except (ValueError, OSError):
            return None
        return value if value.get('text') == expected else None
    actual = wait_for(contents)
    after = focused_node(compositor_tree(root, env))
    if before != after or run(['wl-paste', '--no-newline'], env).stdout != sentinel:
        raise ValueError('Focus or clipboard changed')
    if compositor.poll() is not None or target.poll() is not None:
        raise ValueError('Component exited early')
    return {'component': 'sway-wtype', 'compositor': 'Sway headless pixman',
            'compositor_version': version,
            'runtime_build': 'source-built' if env.get('MOUTHTYPE_SWAY_BINARY') else 'distribution-package',
            'source_revision': env.get('MOUTHTYPE_SWAY_REVISION'),
            'compositor_file': file_capability(sway if '/' in sway else shutil.which(sway)),
            'native_target': 'GTK3 Wayland', 'unicode_exact': actual['text'] == expected,
            'helper_submissions': 1, 'focus_preserved': True, 'clipboard_preserved': True,
            'phrase_snapshot_exact': True, 'phrase_clipboard_snapshot': True, 'basic_cleanup_exact': True, 'multiline_delivery_guard': True,
            'hyprland_adapter_tested': False, 'hyprland_acceptance': False, 'omarchy_acceptance': False}


PORTAL_APPS = ('xdg-desktop-portal-gnome',)


def consent_dialog(atspi):
    """The portal's Remote Desktop dialog (the window offering Share), or None while it has not appeared."""
    return consent_atspi.find_dialog(atspi, PORTAL_APPS)


FOCUS_SCRIPT = (
    "(() => { const w = global.get_window_actors().map(a => a.meta_window)"
    ".find(m => m.get_gtk_application_id() === %r || m.get_wm_class() === %r);"
    " if (!w) return 'none'; w.activate(global.get_current_time()); return 'activated'; })()")


def focus_by_shell_eval(portal, app_id):
    """Activate the target's MetaWindow through org.gnome.Shell.Eval. Needs gnome-shell --unsafe-mode, which the
    testbed uses because a headless shell never focuses a new window by itself. Returns True once activated."""
    body = portal.call('org.gnome.Shell', 'Eval', 's', (FOCUS_SCRIPT % (app_id, app_id),),
                       path='/org/gnome/Shell', bus_name='org.gnome.Shell', timeout=5.0)
    sys.stderr.write('shell eval focus: %r\n' % (body,))
    return bool(body[0]) and 'activated' in str(body[1])


WINDOWS_SCRIPT = (
    "JSON.stringify([global.display.focus_window ? global.display.focus_window.get_title() : null,"
    " global.get_window_actors().map(a => { const m = a.meta_window; return [m.get_title(), m.get_wm_class(),"
    " m.get_gtk_application_id(), m.get_window_type(), m.minimized, m.has_focus(), m.get_frame_rect().x,"
    " m.get_frame_rect().y, m.get_frame_rect().width]; })])")


def shell_windows(portal):
    """The shell's own view of its windows, for the failure message."""
    try:
        body = portal.call('org.gnome.Shell', 'Eval', 's', (WINDOWS_SCRIPT,), path='/org/gnome/Shell',
                           bus_name='org.gnome.Shell', timeout=5.0)
        return str(body[1])
    except Exception as exc:
        return 'unavailable: %s' % exc


def focus_by_click(portal, x, y):
    """Headless mutter gives a new window no focus, so click it through the direct mutter RemoteDesktop API
    (no portal, no consent dialog): clamp the pointer to the corner, then move to the point and click."""
    import portal_probe
    bus, path, iface = portal_probe.MUTTER_BUS, portal_probe.MUTTER_PATH, portal_probe.MUTTER_SESSION_IFACE
    session = portal.call(bus, 'CreateSession', '', (), path=path, bus_name=bus)[0]
    try:
        portal.call(iface, 'Start', '', (), path=session, bus_name=bus)
        for dx, dy in ((-4000.0, -4000.0), (float(x), float(y))):
            portal.call(iface, 'NotifyPointerMotionRelative', 'dd', (dx, dy), path=session, bus_name=bus)
        for down in (True, False):
            portal.call(iface, 'NotifyPointerButton', 'ib', (0x110, down), path=session, bus_name=bus)
            time.sleep(.1)
    finally:
        portal.call(iface, 'Stop', '', (), path=session, bus_name=bus, timeout=2.0)


def atspi_outline(atspi):
    """Applications and their top-level windows with states, for the failure message."""
    outline = []
    desktop = atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app is None:
            continue
        windows = []
        for frame in range(app.get_child_count()):
            window = app.get_child_at_index(frame)
            if window is not None:
                states = window.get_state_set().get_states()
                windows.append([window.get_name(), sorted(state.value_nick for state in states)])
        outline.append([app.get_name(), windows])
    return outline


def gnome_portal_component(root, env, processes):
    """Portal paste on a headless GNOME session: consent through AT-SPI, a persisted grant that restarts without a
    prompt, then clipboard + Ctrl+V into the GTK target, with the earlier clipboard put back."""
    import portal as portal_module
    from atspi_target import AtspiTargets, load_atspi
    from delivery_portal import GrantStore, PortalClipboard, PortalDelivery, PortalKeyboard, RemoteDesktopSession
    atspi = load_atspi()
    if atspi is None:
        raise ValueError('AT-SPI is not available')
    runtime = Path(env['XDG_RUNTIME_DIR'])
    wayland = wait_for(lambda: next((p for p in runtime.glob('wayland-*') if not p.name.endswith('.lock')), None))
    env.update(WAYLAND_DISPLAY=wayland.name, GDK_BACKEND='wayland', XDG_SESSION_TYPE='wayland',
               XDG_CURRENT_DESKTOP='GNOME', LC_ALL='C.UTF-8')
    previous_env = dict(os.environ)
    os.environ.update(env)
    text_path = root / 'target.json'
    expected = 'Hello, 世界. Émilie 👋 from the portal.'
    sentinel = 'Mouthtype existing clipboard'
    store = GrantStore(root / 'state/mouthtype/portal.json')
    portal = remote = clipboard = None
    try:
        targets = AtspiTargets()
        portal = portal_module.Portal()
        portal.connect()
        portal.register()
        remote = RemoteDesktopSession(portal, store, start_timeout=40)
        outcome = {}
        starter = threading.Thread(target=lambda: outcome.setdefault('status', remote.start(interactive=True)))
        starter.start()
        dialog = wait_for(lambda: consent_dialog(atspi), 20)
        answered = consent_atspi.answer(dialog, atspi)
        starter.join(30)
        if outcome.get('status') != 'active':
            raise ValueError('Grant did not become active: ' + json.dumps(remote.snapshot()))
        if not store.load():
            raise ValueError('No restore grant was stored')
        remote.close()
        started = time.monotonic()
        restored = remote.start(interactive=False)
        if restored != 'active' or consent_dialog(atspi) is not None:
            raise ValueError('Stored grant did not restart silently: ' + json.dumps(remote.snapshot()))
        restart_seconds = round(time.monotonic() - started, 2)
        clicked = []
        def focused_snapshot():
            try:
                focus_by_shell_eval(portal, 'app.mouthtype.Acceptance')
            except Exception as exc:
                sys.stderr.write('shell eval focus failed: %s\n' % exc)
            try:
                PortalKeyboard(remote).tap(0xffe1)  # Shift_L: mutter only hands the client keyboard focus on input
            except Exception as exc:
                sys.stderr.write('nudge failed: %s\n' % exc)
            if not clicked:
                clicked.append(1)
                try:
                    focus_by_click(portal, 640, 400)
                except Exception as exc:
                    sys.stderr.write('click failed: %s\n' % exc)
            time.sleep(.3)
            snap = targets.snapshot()
            return snap if snap.get('class') not in (None, 'unknown') else None
        # Headless mutter has no seat keyboard until a RemoteDesktop session adds a virtual one, so the target
        # starts after the grant is active: a window created earlier never receives keyboard focus.
        clipboard = PortalClipboard(remote).start()
        env['MOUTHTYPE_TARGET_CLIPBOARD'] = sentinel
        processes.start([sys.executable, str(Path(__file__).with_name('wayland_target.py')), str(text_path)])
        wait_for(lambda: text_path.exists())
        try:
            target = wait_for(focused_snapshot, 20)
        except TimeoutError:
            raise ValueError('AT-SPI never reported the target as focused: ' + json.dumps(atspi_outline(atspi))
                             + ' shell: ' + shell_windows(portal))
        def earlier_clipboard():
            PortalKeyboard(remote).tap(0xffe1)
            time.sleep(.3)
            return clipboard.read_current().get('text/plain;charset=utf-8')
        try:
            taken = wait_for(earlier_clipboard, 10)
        except TimeoutError:
            taken = None
        if taken != sentinel.encode():
            raise ValueError('Target did not take the earlier clipboard: ' + repr(clipboard._owner_mimes))
        delivery = PortalDelivery({'mode': 'paste', 'allow_unknown_secure_field': True, 'restore_delay_seconds': .5,
                                   'allowed_classes': [target['class']]}, remote, clipboard, targets=targets)
        if delivery.paste(expected, delivery.snapshot()) != 'unknown':
            raise ValueError('Portal paste did not complete')
        def contents():
            try:
                value = json.loads(text_path.read_text())
            except (ValueError, OSError):
                return None
            return value if value.get('text') else None
        wait_for(contents, 10)
        time.sleep(1)
        actual = contents()
        if actual is None or actual['text'] != expected:
            raise ValueError('Target text differs: ' + json.dumps(actual, ensure_ascii=False))
        if delivery.restore_thread is None:
            raise ValueError('No clipboard restore was scheduled')
        delivery.restore_thread.join(5)
        def restored_clipboard():
            # read_current is empty while this session owns the selection, which a restore makes true.
            with clipboard._lock:
                offers = dict(clipboard._offers)
            return offers.get('text/plain;charset=utf-8')
        if wait_for(restored_clipboard, 5) != sentinel.encode():
            raise ValueError('Clipboard was not restored')
        first_target = processes.items[-1][0]
        secure_target = secure_refusal(processes, first_target, env, root, delivery, clipboard, targets, focused_snapshot)
        secure = secure_target.pop('result')
        # The chord goes last, with no client window open: a focused GTK window kept the grab from firing here.
        stop_process(secure_target.pop('process'))
        wait_for(lambda: not mapped_windows(portal), 10)
        shortcut_take = os.environ.get('MOUTHTYPE_ACCEPTANCE_SHORTCUT_TAKE') != '0'
        shortcut = shortcut_hold_take(root, portal, delivery, atspi) if shortcut_take else None
        return {'component': 'gnome-portal', 'compositor': 'GNOME Shell headless',
                'native_target': 'GTK3 Wayland', 'target_class': target['class'],
                'consent': answered, 'grant_persisted': True, 'silent_restart': True,
                'restart_seconds': restart_seconds, 'unicode_exact': True, 'delivered_once': True,
                'clipboard_restored': True, 'secure_field': secure, 'shortcut_press': shortcut if shortcut_take else {'checked': False, 'reason': 'skipped'},
                'fake_engine_take': shortcut_take,
                'hyprland_acceptance': False, 'omarchy_acceptance': False}
    finally:
        for closer in (getattr(clipboard, 'close', None), getattr(remote, 'close', None), getattr(portal, 'close', None)):
            if closer:
                try:
                    closer()
                except Exception:
                    pass
        os.environ.clear()
        os.environ.update(previous_env)


def hold_take_result(calls, state, granted):
    """Check the commands a held chord sent the session: one start on Activated, then one stop on Deactivated, and
    the take back at idle. Returns the evidence dict, raises ValueError otherwise."""
    if calls != ['start', 'stop']:
        raise ValueError('Held chord did not start then stop one take: ' + json.dumps(calls))
    if state != 'idle':
        raise ValueError('Take did not finish after release: ' + str(state))
    return {'commands': list(calls), 'final_state': state, 'triggers': dict(granted)}


def mapped_windows(portal):
    """True while the shell still lists a client window."""
    return json.loads(json.loads(shell_windows(portal) or '[null, []]'))[1]


CLOSE_SCRIPT = ("Main.overview.hide(); Main.panel.statusArea.dateMenu.menu.close();"
                " Main.panel.closeQuickSettings && Main.panel.closeQuickSettings(); 'closed'")
MODE_SCRIPT = "JSON.stringify([Main.actionMode, Main.modalCount])"


def shell_eval(portal, script):
    """Run script in GNOME Shell through org.gnome.Shell.Eval; returns the JSON-decoded result, or None on failure."""
    try:
        body = portal.call('org.gnome.Shell', 'Eval', 's', (script,), path='/org/gnome/Shell',
                           bus_name='org.gnome.Shell', timeout=5.0)
        return json.loads(body[1]) if body[0] else None
    except Exception:
        return None


def shell_mode(portal):
    raw = shell_eval(portal, MODE_SCRIPT)
    return json.loads(raw) if isinstance(raw, str) else None


def shortcut_hold_take(root, portal, delivery, atspi):
    """Bind the dictate-hold chord through GlobalShortcuts (consent answered through AT-SPI), press and hold it with
    the mutter RemoteDesktop driver, and check a fake-engine take starts on Activated and stops on Deactivated."""
    import desktop
    import portal_probe
    import shortcuts_portal
    session = desktop.Session(FixedCapture(), FixedEngine(), delivery, root / 'state/recovery-shortcut', maximum_seconds=10)
    calls = []
    real_command = session.command
    def recording(action, **kwargs):
        if action != 'status':
            calls.append(action)
        return real_command(action, **kwargs)
    session.command = recording
    shortcuts = shortcuts_portal.PortalShortcuts(session)
    driver = portal_probe.MutterDriver(portal)
    outcome = {}
    def bind():
        try:
            shortcuts.start()
            outcome['bound'] = True
        except BaseException as exc:
            outcome['error'] = exc
    starter = threading.Thread(target=bind, name='acceptance-bind')
    starter.start()
    try:
        answered = None
        end = time.monotonic() + 40
        while starter.is_alive() and time.monotonic() < end:
            dialog = consent_atspi.find_dialog(atspi)
            if dialog is not None:
                answered = consent_atspi.answer(dialog, atspi)
                break
            time.sleep(.5)
        starter.join(40)
        if outcome.get('error') is not None or not outcome.get('bound'):
            raise ValueError('GlobalShortcuts bind failed: ' + repr(outcome.get('error'))
                             + ' outline: ' + json.dumps(atspi_outline(atspi)))
        status = shortcuts.status()
        if shortcuts_portal.HOLD not in status['triggers']:
            raise ValueError('dictate-hold was not granted: ' + json.dumps(status))
        driver.open()  # one click and a Shift_L tap wake the stage, as T2b found
        # The wake click can leave the shell in popup or overview mode (modalCount > 0), and GlobalShortcuts
        # accelerators only fire in normal mode. Put it back before the chord.
        shell_eval(portal, CLOSE_SCRIPT)
        wait_for(lambda: shell_mode(portal) == [1, 0], 10)
        for keysym in portal_probe.CHORD_KEYSYMS:
            driver.key(keysym, True)
        try:
            wait_for(lambda: session.state == 'recording', 10)
        except TimeoutError:
            raise ValueError('Held chord never started a take: ' + json.dumps({'shortcuts': shortcuts.status(), 'calls': calls}))
        time.sleep(.5)
        for keysym in reversed(portal_probe.CHORD_KEYSYMS):
            driver.key(keysym, False)
        wait_for(lambda: session.state == 'idle' and 'stop' in calls, 15)
        time.sleep(1)
        result = hold_take_result(calls, session.state, status['triggers'])
        result['consent'] = answered
        return result
    finally:
        driver.close()
        shortcuts.stop()
        session.close()


def secure_refusal(processes, previous, env, root, delivery, clipboard, targets, focus):
    """Swap the target for a password GtkEntry. AT-SPI must mark it secure, paste must answer recover_only, the
    entry must stay empty and the clipboard must be untouched. Returns the evidence and the target's process."""
    stop_process(previous)
    secure_path = root / 'secure.json'
    env['MOUTHTYPE_TARGET_SECURE'] = '1'
    env.pop('MOUTHTYPE_TARGET_CLIPBOARD', None)
    started = processes.start([sys.executable, str(Path(__file__).with_name('wayland_target.py')), str(secure_path)])
    wait_for(lambda: secure_path.exists())
    def secure_snapshot():
        snap = focus()
        return snap if snap and snap.get('secure') else None
    try:
        snapshot = wait_for(secure_snapshot, 20)
    except TimeoutError:
        raise ValueError('AT-SPI never marked the password entry secure: ' + json.dumps(targets.snapshot()))
    delivery.config['allowed_classes'] = [snapshot['class']]
    with clipboard._lock:
        before = dict(clipboard._offers)
    outcome = delivery.paste('Mouthtype secret', snapshot)
    time.sleep(1)
    with clipboard._lock:
        after = dict(clipboard._offers)
    text = json.loads(secure_path.read_text()).get('text') or ''
    result = secure_field_result(snapshot, outcome, text)
    if after != before:
        raise ValueError('Secure refusal touched the clipboard')
    result['clipboard_untouched'] = True
    return {'result': result, 'process': started}


KDE_TAKE_TEXT = 'Hello, 世界. Émilie 👋 from the portal.'


class FixedCapture:
    """Capture double for the daemon path: writes 0.1 s of silence, so the take is real but no microphone is used."""
    def start(self, path):
        with wave.open(str(path), 'wb') as audio:
            audio.setparams((1, 2, 16000, 0, 'NONE', ''))
            audio.writeframes(b'\0\0' * 1600)
    def stop(self):
        pass
    def cancel(self):
        pass
    def running(self):
        return True


class FixedEngine:
    """Speech engine double that returns one fixed transcript."""
    def __init__(self, text=KDE_TAKE_TEXT):
        self.text = text
    def transcribe(self, _path, _cancelled):
        return self.text
    def warm(self):
        pass
    def stop(self):
        pass
    def close(self):
        pass


def wayland_display(env, runtime):
    """The compositor socket name: WAYLAND_DISPLAY when that socket exists in runtime, else the first wayland-*."""
    runtime = Path(runtime)
    named = env.get('WAYLAND_DISPLAY')
    if named and (runtime / named).exists():
        return named
    found = next((p for p in sorted(runtime.glob('wayland-*')) if not p.name.endswith('.lock')), None)
    return found.name if found else None


def enable_accessibility(call):
    """Switch on toolkit accessibility on the session's AT-SPI bus, so GTK and Qt apps started afterwards export a
    tree. call(argv) runs a command. Returns the argv used."""
    argv = ['gdbus', 'call', '--session', '--dest', 'org.a11y.Bus', '--object-path', '/org/a11y/bus',
            '--method', 'org.freedesktop.DBus.Properties.Set', 'org.a11y.Status', 'IsEnabled', '<true>']
    call(argv)
    return argv


def toggle_take(socket_path, seconds=15, request=session_client.request, sleep=time.sleep, clock=time.monotonic):
    """Run one take through the daemon's toggle command: toggle starts it, toggle stops it, then wait for the
    session to go idle. Returns the final status. Raises ValueError when a toggle does not change state as expected."""
    started = request(socket_path, 'toggle')
    if started.get('state') != 'recording':
        raise ValueError('Toggle did not start a take: ' + json.dumps({k: started.get(k) for k in ('state', 'error')}))
    sleep(.3)
    stopped = request(socket_path, 'toggle')
    if stopped.get('state') not in ('transcribing', 'idle'):
        raise ValueError('Second toggle did not stop the take: ' + json.dumps({k: stopped.get(k) for k in ('state', 'error')}))
    end = clock() + seconds
    while clock() < end:
        status = request(socket_path, 'status')
        if status.get('state') == 'idle':
            return status
        sleep(.1)
    raise TimeoutError('Take did not finish')


def secure_field_result(snapshot, delivery, text):
    """Classify the secure-field check from the target snapshot AT-SPI gave, the take's delivery outcome and the
    text that reached the target. An unreported or non-password focus is reported, not failed; a password field that
    received text or was not refused raises."""
    if snapshot.get('class') in (None, 'unknown'):
        return {'checked': False, 'reason': 'atspi_reported_no_focus'}
    if not snapshot.get('secure'):
        return {'checked': False, 'reason': 'atspi_focus_without_password_role', 'target_class': snapshot.get('class')}
    if text:
        raise ValueError('Secure field received text')
    if delivery != 'recover_only':
        raise ValueError('Secure field was not refused: ' + str(delivery))
    return {'checked': True, 'refused': True, 'delivery': delivery, 'target_class': snapshot['class']}


def kde_portal_component(root, env, processes):
    """Portal paste on a headless KDE session, started through the daemon's toggle command. The RemoteDesktop
    grant is pre-authorized in the permission store, so no dialog. GlobalShortcuts needs plasmashell and is out of scope."""
    import portal as portal_module
    import desktop
    from atspi_target import AtspiTargets, load_atspi
    from delivery_portal import GrantStore, PortalClipboard, PortalKeyboard, RemoteDesktopSession, make_delivery
    atspi = load_atspi()
    if atspi is None:
        raise ValueError('AT-SPI is not available')
    runtime = Path(env['XDG_RUNTIME_DIR'])
    display = wait_for(lambda: wayland_display(env, runtime))
    env.update(WAYLAND_DISPLAY=display, GDK_BACKEND='wayland', XDG_SESSION_TYPE='wayland',
               XDG_CURRENT_DESKTOP='KDE', LC_ALL='C.UTF-8', QT_LINUX_ACCESSIBILITY_ALWAYS_ON='1')
    enable_accessibility(lambda argv: run(argv, env))
    previous_env = dict(os.environ)
    os.environ.update(env)
    sentinel = 'Mouthtype existing clipboard'
    store = GrantStore(root / 'state/mouthtype/portal.json')
    portal = remote = None
    delivery = session = None
    stopped = threading.Event()
    server = None
    try:
        # Grant first, the way setup does: an interactive start (pre-authorized, so no dialog) stores the restore value
        # the daemon's silent start reuses.
        portal = portal_module.Portal()
        portal.connect()
        portal.register()
        remote = RemoteDesktopSession(portal, store, start_timeout=40)
        status = remote.start(interactive=True)
        if status != 'active':
            raise ValueError('Pre-authorized RemoteDesktop did not become active: ' + json.dumps(remote.snapshot()))
        grant_persisted = store.load() is not None
        remote.close()
        remote = None
        portal.close()
        portal = None
        factory = None
        if not grant_persisted:
            class Interactive(RemoteDesktopSession):
                def start(self, interactive=False):
                    return super().start(interactive=True)
            factory = Interactive
        targets = AtspiTargets()
        delivery = make_delivery({'mode': 'paste', 'allow_unknown_secure_field': True, 'restore_delay_seconds': .5},
                                 session_factory=factory, store_factory=lambda: store, targets=targets)
        if not delivery.remote.active:
            raise ValueError('Daemon delivery has no active RemoteDesktop session: ' + json.dumps(delivery.remote.snapshot()))
        text_path = root / 'target.json'
        env['MOUTHTYPE_TARGET_CLIPBOARD'] = sentinel
        first = processes.start([sys.executable, str(Path(__file__).with_name('wayland_target.py')), str(text_path)])
        wait_for(lambda: text_path.exists())
        def focused_snapshot():
            PortalKeyboard(delivery.remote).tap(0xffe1)  # Shift_L: the target sets its sentinel selection on a key press
            time.sleep(.3)
            snap = targets.snapshot()
            return snap if snap.get('class') not in (None, 'unknown') else None
        try:
            target = wait_for(focused_snapshot, 20)
        except TimeoutError:
            raise ValueError('AT-SPI never reported the target as focused under kwin: ' + json.dumps(atspi_outline(atspi)))
        delivery.config['allowed_classes'] = [target['class']]
        def earlier_clipboard():
            PortalKeyboard(delivery.remote).tap(0xffe1)
            time.sleep(.3)
            return delivery.clipboard.read_current().get('text/plain;charset=utf-8')
        try:
            taken = wait_for(earlier_clipboard, 10)
        except TimeoutError:
            taken = None
        if taken != sentinel.encode():
            raise ValueError('Target did not take the earlier clipboard')
        session = desktop.Session(FixedCapture(), FixedEngine(), delivery, root / 'state/recovery', maximum_seconds=10)
        socket_path = root / 'session.sock'
        server = threading.Thread(target=lambda: desktop.serve(socket_path, session, stopped, lifetime_seconds=100),
                                  name='acceptance-daemon')
        server.start()
        wait_for(lambda: socket_path.exists())
        final = toggle_take(socket_path)
        if final.get('delivery') != 'unknown':
            raise ValueError('Take was not delivered: ' + json.dumps({k: final.get(k) for k in ('state', 'error', 'delivery')}))
        def contents(path):
            try:
                value = json.loads(path.read_text())
            except (ValueError, OSError):
                return None
            return value if value.get('text') else None
        wait_for(lambda: contents(text_path), 10)
        time.sleep(1)
        actual = contents(text_path)
        if actual is None or actual['text'] != KDE_TAKE_TEXT:
            raise ValueError('Target text differs: ' + json.dumps(actual, ensure_ascii=False))
        if delivery.restore_thread is None:
            raise ValueError('No clipboard restore was scheduled')
        delivery.restore_thread.join(5)
        def restored_clipboard():
            with delivery.clipboard._lock:
                offers = dict(delivery.clipboard._offers)
            return offers.get('text/plain;charset=utf-8')
        if wait_for(restored_clipboard, 5) != sentinel.encode():
            raise ValueError('Clipboard was not restored')
        # Secure field: swap in a password entry and take again. The text must not reach it.
        stop_process(first)
        secure_path = root / 'secure.json'
        env['MOUTHTYPE_TARGET_SECURE'] = '1'
        env.pop('MOUTHTYPE_TARGET_CLIPBOARD', None)
        processes.start([sys.executable, str(Path(__file__).with_name('wayland_target.py')), str(secure_path)])
        wait_for(lambda: secure_path.exists())
        try:
            wait_for(lambda: (PortalKeyboard(delivery.remote).tap(0xffe1), time.sleep(.3),
                              targets.snapshot().get('class') not in (None, 'unknown'))[2], 15)
        except TimeoutError:
            pass
        secure_snapshot = targets.snapshot()
        if secure_snapshot.get('class') in (None, 'unknown'):
            secure = secure_field_result(secure_snapshot, None, '')
            secure['atspi_outline'] = atspi_outline(atspi)
        else:
            delivery.config['allowed_classes'] = [secure_snapshot['class']]
            secure_final = toggle_take(socket_path)
            time.sleep(1)
            secure = secure_field_result(secure_snapshot, secure_final.get('delivery'),
                                         (json.loads(secure_path.read_text()).get('text') or ''))
        return {'component': 'kde-portal', 'compositor': 'kwin_wayland --virtual',
                'native_target': 'GTK3 Wayland', 'target_class': target['class'],
                'remote_desktop': 'pre-authorized', 'grant_persisted': grant_persisted,
                'start_path': 'daemon toggle command', 'unicode_exact': True, 'delivered_once': True,
                'clipboard_restored': True, 'secure_field': secure, 'shortcut_press': False,
                'fake_engine_take': True, 'pill_check': False,
                'hyprland_acceptance': False, 'omarchy_acceptance': False}
    finally:
        stopped.set()
        if server is not None:
            server.join(5)
        for closer in (getattr(session, 'close', None), getattr(delivery, 'close', None),
                       getattr(remote, 'close', None), getattr(portal, 'close', None)):
            if closer:
                try:
                    closer()
                except Exception:
                    pass
        os.environ.clear()
        os.environ.update(previous_env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('component', choices=('capabilities', 'pipewire', 'sway', 'gnome-portal', 'kde-portal'))
    parser.add_argument('--skip-shortcut-take', action='store_true',
                        help='gnome-portal only: skip the held-chord take (same as MOUTHTYPE_ACCEPTANCE_SHORTCUT_TAKE=0)')
    args = parser.parse_args()
    if args.skip_shortcut_take:
        os.environ['MOUTHTYPE_ACCEPTANCE_SHORTCUT_TAKE'] = '0'
    if sys.platform != 'linux':
        parser.error('Explicit Linux component acceptance only')
    if args.component == 'capabilities':
        print(json.dumps(capabilities(), indent=2))
        return 0
    def deadline(*_):
        raise TimeoutError('Acceptance lifetime limit')
    for event in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT):
        signal.signal(event, deadline)
    signal.alarm(180 if args.component == 'gnome-portal' else 120 if args.component == 'kde-portal' else 45)
    try:
        with tempfile.TemporaryDirectory(prefix='mouthtype-acceptance-') as temp:
            root = Path(temp)
            env = {**os.environ, 'XDG_RUNTIME_DIR': str(root / 'runtime'),
                   'XDG_CONFIG_HOME': str(root / 'config'), 'XDG_STATE_HOME': str(root / 'state'),
                   'XDG_CACHE_HOME': str(root / 'cache')}
            if args.component in ('gnome-portal', 'kde-portal'):
                # Runs inside the testbed's live GNOME or KDE session, so keep its runtime dir and bus.
                env['XDG_RUNTIME_DIR'] = os.environ['XDG_RUNTIME_DIR']
                env['XDG_STATE_HOME'] = str(root / 'state')
                env.pop('DISPLAY', None)
            else:
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
                check = {'pipewire': pipewire_component, 'sway': sway_component,
                         'gnome-portal': gnome_portal_component, 'kde-portal': kde_portal_component}[args.component]
                result = check(root, env, processes)
            except BaseException:
                traceback.print_exc(file=sys.stderr)
                evidence = os.environ.get('MOUTHTYPE_ACCEPTANCE_EVIDENCE')
                if evidence:
                    for name in ('synthetic.wav', 'tree.json', 'target.json'):
                        fixture = root / name
                        if fixture.is_file() and fixture.stat().st_size <= 4 * 1024 * 1024:
                            destination = Path(evidence) / (args.component + '-' + name)
                            with fixture.open('rb') as source, destination.open('xb') as saved:
                                shutil.copyfileobj(source, saved)
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
