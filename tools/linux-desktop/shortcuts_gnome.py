"""GNOME command-shortcut fallback: one marked custom keybinding that runs `mouthtype-linux toggle`.

Used when the GlobalShortcuts portal is missing or refused. A command shortcut has no key release, so this is toggle
only and hold mode stays off. The binding is one entry in GNOME's custom-keybindings list: install appends our path
and remove takes only our path back out, so the user's own keybindings are never rewritten.
"""
import ast
import shutil
import subprocess
from pathlib import Path

SCHEMA = 'org.gnome.settings-daemon.plugins.media-keys'
ENTRY_SCHEMA = SCHEMA + '.custom-keybinding'
BASE = '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/'
MARKED_PATH = BASE + 'mouthtype-toggle/'
NAME = 'Mouthtype: start or stop dictation'
DEFAULT_BINDING = '<Control><Alt>space'
TIMEOUT = 10


class GnomeShortcutError(RuntimeError):
    """gsettings is missing, failed, or the requested binding belongs to someone else."""


def _gsettings(*args):
    try:
        done = subprocess.run(['gsettings', *args], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=TIMEOUT)
    except FileNotFoundError:
        raise GnomeShortcutError('gsettings is not installed')
    except subprocess.TimeoutExpired:
        raise GnomeShortcutError('gsettings did not answer')
    if done.returncode != 0:
        raise GnomeShortcutError((done.stderr or done.stdout).strip() or 'gsettings failed')
    return done.stdout.strip()


def _quote(text):
    return "'" + text.replace('\\', '\\\\').replace("'", "\\'") + "'"


def _parse_list(text):
    text = text.strip()
    if text.startswith('@as'):
        text = text[3:].strip()
    try:
        value = ast.literal_eval(text)
    except (ValueError, SyntaxError):
        raise GnomeShortcutError('Unexpected custom-keybindings value: ' + text)
    if not isinstance(value, (list, tuple)) or not all(isinstance(item, str) for item in value):
        raise GnomeShortcutError('Unexpected custom-keybindings value: ' + text)
    return list(value)


def _format_list(paths):
    return '[' + ', '.join(_quote(path) for path in paths) + ']' if paths else '@as []'


def _entry(path):
    return ENTRY_SCHEMA + ':' + path


def _read_list(run):
    return _parse_list(run('get', SCHEMA, 'custom-keybindings'))


def toggle_command(launcher=None):
    """The command GNOME runs. Settings-daemon has a thin PATH, so prefer an absolute launcher path."""
    if launcher:
        return str(launcher) + ' toggle'
    own = Path.home() / '.local/bin/mouthtype-linux'
    found = str(own) if own.exists() else shutil.which('mouthtype-linux')
    return (found or 'mouthtype-linux') + ' toggle'


def status(*, run=_gsettings):
    paths = _read_list(run)
    if MARKED_PATH not in paths:
        return {'backend': 'gnome-command', 'installed': False, 'binding': None, 'command': None, 'hold': False}
    return {'backend': 'gnome-command', 'installed': True, 'hold': False,
            'binding': ast.literal_eval(run('get', _entry(MARKED_PATH), 'binding')),
            'command': ast.literal_eval(run('get', _entry(MARKED_PATH), 'command'))}


def install(binding=DEFAULT_BINDING, command=None, *, run=_gsettings):
    """Add or update our keybinding. Refuses a binding another custom entry already uses."""
    if not binding or not binding.strip():
        raise GnomeShortcutError('A binding is required')
    command = command or toggle_command()
    paths = _read_list(run)
    for path in paths:
        if path != MARKED_PATH and ast.literal_eval(run('get', _entry(path), 'binding')) == binding:
            raise GnomeShortcutError('That shortcut is already used by another custom shortcut: ' + binding)
    run('set', _entry(MARKED_PATH), 'name', _quote(NAME))
    run('set', _entry(MARKED_PATH), 'command', _quote(command))
    run('set', _entry(MARKED_PATH), 'binding', _quote(binding))
    if MARKED_PATH not in paths:
        run('set', SCHEMA, 'custom-keybindings', _format_list(paths + [MARKED_PATH]))
    return status(run=run)


def remove(*, run=_gsettings):
    """Take only our keybinding out. Returns False when it wasn't there."""
    paths = _read_list(run)
    if MARKED_PATH not in paths:
        return False
    run('set', SCHEMA, 'custom-keybindings', _format_list([path for path in paths if path != MARKED_PATH]))
    for key in ('name', 'command', 'binding'):
        run('reset', _entry(MARKED_PATH), key)
    return True
