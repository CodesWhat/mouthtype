"""One-command first-run setup: speech model, dictation service and the Omarchy bar plugin.

Run it after the client is installed (by pacman or by install.py). It does what the manual guide does in
order, skips what is already done, and stops with a plain message when a prerequisite is missing. It never
runs a package manager and never uses sudo.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
DEFAULT_DESTINATION = Path.home() / '.local/share/mouthtype/speech-candidate'
SYSTEM_PLUGIN = Path('/usr/share/mouthtype-linux/omarchy-plugin')
REQUIRED = {'pw-record': 'pipewire-audio', 'curl': 'curl'}
RECOMMENDED = {'wl-copy': 'wl-clipboard', 'wtype': 'wtype', 'notify-send': 'libnotify', 'ffmpeg': 'ffmpeg'}


def find_launcher(which=shutil.which):
    found = which('mouthtype-linux')
    for candidate in (Path.home() / '.local/bin/mouthtype-linux', Path('/usr/bin/mouthtype-linux')):
        if found is None and candidate.is_file():
            found = str(candidate)
    return found


def find_plugin(explicit=None):
    candidates = [Path(explicit)] if explicit else [SYSTEM_PLUGIN, HERE.parent / 'omarchy-plugin']
    return next((path for path in candidates if (path / 'install.py').is_file()), None)


def missing_packages(table, which=shutil.which):
    return sorted({package for command, package in table.items() if which(command) is None})


def main(argv=None, *, run=subprocess.run, speech=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=DEFAULT_DESTINATION, help='Speech setup directory')
    parser.add_argument('--plugin-dir', type=Path, help='Omarchy plugin source (default: the packaged or checkout copy)')
    parser.add_argument('--skip-plugin', action='store_true', help='Prepare speech only; no bar plugin or login service')
    parser.add_argument('--no-autostart', action='store_true')
    parser.add_argument('--no-restart-shell', action='store_true')
    parser.add_argument('--shortcut', choices=('toggle', 'hold'), help='Also bind the default dictation key')
    args = parser.parse_args(argv)
    if sys.platform != 'linux':
        print('This setup is for Linux (Arch/Omarchy).', file=sys.stderr)
        return 2
    launcher = find_launcher()
    if launcher is None:
        print('mouthtype-linux is not installed. Install the package, or run: python3 ' +
              str(HERE / 'install.py') + ' --prefix "$HOME/.local"', file=sys.stderr)
        return 2
    packages = missing_packages(REQUIRED)
    if packages:
        print('Missing helpers. Install them first: sudo pacman -S --needed ' + ' '.join(packages), file=sys.stderr)
        return 2
    optional = missing_packages(RECOMMENDED)
    if optional:
        print('Optional helpers missing (paste, typing, notifications, audio files): sudo pacman -S --needed ' +
              ' '.join(optional))
    plugin = None if args.skip_plugin else find_plugin(args.plugin_dir)
    if not args.skip_plugin and plugin is None:
        print('The Omarchy plugin source was not found. Use --plugin-dir, or --skip-plugin to prepare speech only.',
              file=sys.stderr)
        return 2
    config = args.destination.expanduser() / 'linux.json'
    if config.is_file():
        print('Speech is already prepared: ' + str(config))
    else:
        if speech is None:
            import setup_speech
            speech = setup_speech.main
        status = speech(['--destination', str(args.destination.expanduser())])
        if status:
            return status
    doctor = run([launcher, '--config', str(config), 'doctor'], text=True, capture_output=True, timeout=120)
    print(doctor.stdout.rstrip())
    if doctor.returncode:
        print('Fix the ERROR lines above, then run this setup again.', file=sys.stderr)
        return 2
    if plugin is not None:
        installed = Path.home() / '.config/omarchy/plugins/dstahl.mouthtype'
        command = [sys.executable, str(plugin / 'install.py')]
        if installed.exists() or installed.is_symlink():
            command.append('--update')
        if args.no_autostart:
            command.append('--no-autostart')
        if args.no_restart_shell:
            command.append('--no-restart-shell')
        if args.shortcut:
            command += ['--shortcut', args.shortcut]
        if run(command, timeout=300).returncode:
            return 2
    print('\nDone. Next:')
    if not args.shortcut:
        print('  1. Pick a dictation key: open the Mouthtype menu in the bar, Change Dictation Shortcut.')
    print('  2. To paste into the active window, open Paste Options and choose Paste into the active window.')
    print('  3. Check anytime with: mouthtype-linux doctor')
    return 0


if __name__ == '__main__':
    sys.exit(main())
