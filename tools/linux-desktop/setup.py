"""One-command first-run setup: speech model, dictation service and the Omarchy bar plugin.

Run it after the client is installed (by pacman or by install.py). It does what the manual guide does in
order, skips what is already done, and stops with a plain message when a prerequisite is missing. It never
runs a package manager and never uses sudo.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
DEFAULT_DESTINATION = Path.home() / '.local/share/mouthtype/speech-candidate'
SYSTEM_PLUGIN = Path('/usr/share/mouthtype-linux/omarchy-plugin')
CLEANUP_DESTINATION = Path.home() / '.local/share/mouthtype/cleanup-candidate'
CLEANUP_OFFER = """AI cleanup is optional. It runs a small local model after Basic cleanup and needs llama-server.
  fast      S1-mini by Superwhisper. Download about 460 MiB.
  thorough  Qwen3-4B-Instruct. Download about 2.3 GiB.
Either one also builds the pinned llama.cpp for the CPU (estimate: about 150 MB cloned, around 1 GB of disk while
building, 10 to 30 minutes depending on cores). Arch's llama-cpp and Debian's llama.cpp packages are not that
revision and the client refuses them, so the build is the supported path. Nothing is installed with sudo."""
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


def set_aside_incomplete(destination):
    """A speech directory with no linux.json is what an interrupted or failed download leaves, and setup_speech.py refuses to
    reuse it, which would make every retry fail the same way. Move it to <name>.incomplete (replacing an older one)."""
    if destination.name != 'speech-candidate' or not destination.is_dir() or (destination / 'linux.json').exists():
        return
    parked = destination.with_name(destination.name + '.incomplete')
    if parked.exists():
        shutil.rmtree(parked)
    destination.rename(parked)
    print('Moved the incomplete earlier speech setup aside to ' + str(parked) + ' (delete it when you like).')


def record_firstrun(state):
    """Tell the login first-run unit that setup was finished or removed on purpose, so it does not redo or undo that."""
    try:
        import firstrun
        firstrun.record(state)
    except ImportError:
        pass


def set_cleanup_config(config, engine, level):
    """Point linux.json at the prepared cleanup models (after a .bak copy), the step setup_cleanup.py leaves to the user."""
    data = json.loads(config.read_text())
    data['cleanup_engine'] = str(engine)
    data['cleanup'] = level
    backup = config.with_name(config.name + '.bak.' + str(int(time.time())))
    shutil.copy2(config, backup)
    temporary = config.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    os.replace(temporary, config)


def offer_cleanup(args, config, *, run, ask=input, cleanup=None):
    """Offer the AI cleanup build. Asks only on a terminal; a login unit or --cleanup skip never prompts."""
    level = args.cleanup
    if level == 'skip':
        return
    if level is None:
        if not (sys.stdin.isatty() and sys.stdout.isatty()):
            print('AI cleanup (optional, needs a pinned llama-server build): re-run with --cleanup fast or --cleanup thorough.')
            return
        data = json.loads(config.read_text()) if config.is_file() else {}
        if data.get('cleanup') in ('fast', 'thorough'):
            return
        print('\n' + CLEANUP_OFFER)
        answer = ask('Prepare AI cleanup now? [f]ast / [t]horough / [N]o: ').strip().lower()
        level = {'f': 'fast', 'fast': 'fast', 't': 'thorough', 'thorough': 'thorough'}.get(answer)
        if level is None:
            print('Skipped. Later: mouthtype-linux-setup --cleanup fast')
            return
    missing = missing_packages({'git': 'git', 'cmake': 'cmake', 'c++': 'base-devel'})
    if missing:
        print('Building llama-server needs: sudo pacman -S --needed ' + ' '.join(missing) + '\nThen run: mouthtype-linux-setup --cleanup ' + level)
        return
    if cleanup is None:
        import setup_cleanup
        cleanup = setup_cleanup.main
    destination = CLEANUP_DESTINATION
    print('Building the pinned llama-server and downloading the ' + level + ' model. This takes a while; output is in ' +
          str(destination / 'build.log') + '.')
    status = cleanup(['--destination', str(destination), '--level', level])
    if status:
        print('AI cleanup was not prepared (see above). Basic cleanup still works; retry with --cleanup ' + level, file=sys.stderr)
        return
    set_cleanup_config(config, destination / 'cleanup.json', level)
    run(['systemctl', '--user', 'try-restart', 'mouthtype-linux.service'], timeout=30)
    print('AI cleanup (' + level + ') is configured. Check it with: mouthtype-linux doctor')


def main(argv=None, *, run=subprocess.run, speech=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=DEFAULT_DESTINATION, help='Speech setup directory')
    parser.add_argument('--plugin-dir', type=Path, help='Omarchy plugin source (default: the packaged or checkout copy)')
    parser.add_argument('--skip-plugin', action='store_true', help='Prepare speech only; no bar plugin or login service')
    parser.add_argument('--no-autostart', action='store_true')
    parser.add_argument('--uninstall', action='store_true',
                        help='Remove the per-user pieces: bar plugin, login service, shortcut block, plugin settings')
    parser.add_argument('--purge', action='store_true', help='With --uninstall, also delete models, recordings and configuration')
    parser.add_argument('--no-restart-shell', action='store_true')
    parser.add_argument('--no-transform-shortcut', action='store_true',
                        help='Do not bind Super+Shift+T for Transform Selection')
    parser.add_argument('--cleanup', choices=('fast', 'thorough', 'skip'),
                        help='Build llama-server and download the AI cleanup model without asking (skip: do not offer)')
    parser.add_argument('--shortcut', choices=('toggle', 'hold'), help='Also bind the default dictation key')
    args = parser.parse_args(argv)
    if sys.platform != 'linux':
        print('This setup is for Linux (Arch/Omarchy).', file=sys.stderr)
        return 2
    if args.uninstall:
        plugin = find_plugin(args.plugin_dir)
        if plugin is None:
            print('The Omarchy plugin source was not found; use --plugin-dir.', file=sys.stderr)
            return 2
        command = [sys.executable, str(plugin / 'install.py'), '--uninstall'] + (['--purge'] if args.purge else [])
        status = run(command, timeout=300).returncode
        if not status:
            record_firstrun('uninstalled')
            print('Per-user pieces removed. Remove the program itself with: sudo pacman -R mouthtype-linux-git '
                  '(or python3 tools/linux-desktop/install.py --uninstall for a source install).')
        return 2 if status else 0
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
    if plugin is not None and not (Path.home() / '.config/omarchy/shell.json').is_file():
        print('Omarchy shell configuration (~/.config/omarchy/shell.json) not found, so the bar plugin cannot be installed. '
              'Run this on Omarchy, or add --skip-plugin to prepare speech only. Nothing was downloaded.', file=sys.stderr)
        return 2
    config = args.destination.expanduser() / 'linux.json'
    if config.is_file():
        print('Speech is already prepared: ' + str(config))
    else:
        set_aside_incomplete(args.destination.expanduser())
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
        if args.no_transform_shortcut:
            command.append('--no-transform-shortcut')
        if run(command, timeout=300).returncode:
            return 2
    offer_cleanup(args, config, run=run)
    record_firstrun('done')
    print('\nDone. Next:')
    if not args.shortcut:
        print('  1. Pick a dictation key: open the Mouthtype menu in the bar, Change Dictation Shortcut.')
    print('  2. To paste into the active window, open Paste Options and choose Paste into the active window.')
    print('  3. Check anytime with: mouthtype-linux doctor')
    return 0


if __name__ == '__main__':
    sys.exit(main())
