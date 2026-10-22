"""`copy-last` and `paste-last`: put the newest saved transcript on the clipboard, or deliver it to the active window.

Neither verb has a delivery path of its own. paste-last hands the text to the daemon's HyprlandDelivery.submit, so the
allowed-window check, the terminal rules, the target recheck, the clipboard guard (an image or file list is never
overwritten, a password-manager hint is never restored) and the cancel event all apply exactly as they do after a take."""

from pathlib import Path
import json
import shutil
import signal
import subprocess
import sys
import threading

HERE = str(Path(__file__).resolve().parent)
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import clipboard_copy
import stats

COPY = ['wl-copy', '--type', 'text/plain;charset=utf-8']
RESTORE_WAIT_SECONDS = 5  # added to restore_delay_seconds: the helper's own deadline


def register(subparsers):
    subparsers.add_parser('copy-last', help='Copy the newest saved transcript to the clipboard')
    subparsers.add_parser('paste-last', help='Deliver the newest saved transcript to the active window')


def fail(code, **fields):
    print(json.dumps({'error': code, **fields}), file=sys.stderr)
    return 2


def run(args, context):
    latest = stats.latest_transcript(context.recovery)
    if latest is None:
        return fail('no_dictation')
    identity, text = latest
    if args.action == 'copy-last':
        return copy_last(identity, text, context)
    return paste_last(identity, text, context)


def copy_last(identity, text, context=None):
    if context is not None and clipboard_copy.copy_via_portal(text, context.request, context.config):
        print(json.dumps({'ok': True, 'id': identity, 'message': 'Copied to clipboard'}))
        return 0
    if shutil.which('wl-copy') is None:
        return fail('wl_copy_missing')
    try:
        subprocess.run(COPY, input=text.encode('utf-8'), check=True, timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return fail('copy_failed')
    print(json.dumps({'ok': True, 'id': identity, 'message': 'Copied to clipboard'}))
    return 0


def paste_last(identity, text, context):
    import desktop
    try:
        config = desktop.validate_config(json.loads(Path(context.config).read_text()))
    except (OSError, ValueError, TypeError):
        return fail('config_unavailable')
    delivery = config['delivery']
    if delivery.get('mode') not in ('type', 'paste'):
        return fail('delivery_disabled')
    try:
        status = context.request('status')
    except OSError:
        status = None
    # The daemon owns the clipboard and the paste chord while it records or delivers; a second paste would collide.
    if isinstance(status, dict) and status.get('state') not in (None, 'idle'):
        return fail('busy', state=status.get('state'))
    target = desktop.HyprlandDelivery(delivery)
    snapshot = target.snapshot()
    if snapshot is None:
        return fail('no_target')
    cancelled = threading.Event()
    previous = []
    if threading.current_thread() is threading.main_thread():
        for event in (signal.SIGINT, signal.SIGTERM):
            previous.append((event, signal.signal(event, lambda *_: cancelled.set())))
    try:
        outcome = target.submit(text, snapshot, cancelled=cancelled)
        restore = getattr(target, 'restore_thread', None)
        if restore is not None:
            # This process is short-lived; let the clipboard go back before it exits.
            restore.join(float(delivery.get('restore_delay_seconds', getattr(target, 'restore_delay_seconds', 1.5))) + RESTORE_WAIT_SECONDS)
    finally:
        for event, handler in previous:
            signal.signal(event, handler)
    if outcome == 'unknown':
        # The chord or keystrokes were sent; delivery is never verified, so this means requested, not confirmed.
        print(json.dumps({'ok': True, 'id': identity, 'outcome': outcome,
                          'message': 'Paste requested; check the target before retrying' if delivery['mode'] == 'paste'
                          else 'Typing requested; check the target before retrying'}))
        return 0
    return fail('cancelled' if outcome == 'not_attempted' else 'not_delivered', outcome=outcome, id=identity)
