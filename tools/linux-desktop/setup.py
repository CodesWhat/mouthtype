"""One-command first-run setup: speech model, dictation service and the per-desktop pieces.

Run it after the client is installed (by pacman, a deb or rpm, or install.py). It does what the manual guide does
in order, skips what is already done, and stops with a plain message when a prerequisite is missing. It never
runs a package manager and never uses sudo.

On Omarchy/Hyprland it installs the bar plugin. On GNOME and KDE (Wayland) it skips the plugin, enables the
dictation service, asks the desktop portal for typing access (the one-time prompt) and adds the settings
window to the XDG autostart. --uninstall reverses whichever of those applied.
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
import backends
DEFAULT_DESTINATION = Path.home() / '.local/share/mouthtype/speech-candidate'
SYSTEM_PLUGIN = Path('/usr/share/mouthtype-linux/omarchy-plugin')
CLEANUP_DESTINATION = Path.home() / '.local/share/mouthtype/cleanup-candidate'
CLEANUP_OFFER = """AI cleanup is optional. It runs a small local model after Basic cleanup and needs llama-server.
  fast      S1-mini by Superwhisper. Download about 460 MiB.
  thorough  Qwen3-4B-Instruct. Download about 2.3 GiB.
Either one also downloads the pinned upstream llama-server release (about 17 MB, SHA-256 checked). Arch's
llama-cpp and Debian's llama.cpp packages are not that revision and the client refuses them. Nothing is built and
nothing is installed with sudo; --build-server compiles it locally instead."""
APP_ID = 'app.mouthtype.Mouthtype'
PORTAL_DESKTOPS = ('gnome', 'kde')
SERVICE = 'mouthtype-linux.service'
VENDOR_UNIT = Path('/usr/lib/systemd/user') / SERVICE
UNIT_MARKER = '# Managed by mouthtype-linux-setup'
AUTOSTART_MARKER = 'X-Mouthtype-Managed=true'
GRANT_TIMEOUT = 150
PORTAL_PROMPTS = """Your desktop will ask for two permissions, once each:
  1. Typing access (keyboard, so Mouthtype can paste into the active window). This setup asks for it now.
  2. A dictation shortcut. It appears when the Mouthtype service starts: on GNOME as a GNOME Settings dialog,
     on KDE as a Plasma dialog. Mouthtype only asks for a suggested key; whatever you accept is what it uses.
Approve both. Nothing is typed anywhere until you dictate."""
REQUIRED = {'pw-record': 'pipewire-audio', 'curl': 'curl'}
PORTAL_RECOMMENDED = {'notify-send': 'libnotify', 'ffmpeg': 'ffmpeg'}
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


def detect_desktop():
    return backends.detect(os.environ)


def missing_commands(table, which=shutil.which):
    return sorted(command for command in table if which(command) is None)


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
            print('AI cleanup (optional, needs the pinned llama-server): re-run with --cleanup fast or --cleanup thorough.')
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
    build = bool(getattr(args, 'build_server', False))
    missing = missing_packages({'git': 'git', 'cmake': 'cmake', 'c++': 'base-devel'}) if build else []
    if missing:
        print('Building llama-server needs: sudo pacman -S --needed ' + ' '.join(missing) + '\nThen run: mouthtype-linux-setup --cleanup ' + level + ' --build-server')
        return
    if cleanup is None:
        import setup_cleanup
        cleanup = setup_cleanup.main
    destination = CLEANUP_DESTINATION
    if build:
        print('Building the pinned llama-server and downloading the ' + level + ' model. This takes a while; output is in ' +
              str(destination / 'build.log') + '.')
    else:
        print('Downloading the pinned llama-server and the ' + level + ' model. This takes a few minutes.')
    status = cleanup(['--destination', str(destination), '--level', level] + (['--build-server'] if build else []))
    if status:
        print('AI cleanup was not prepared (see above). Basic cleanup still works; retry with --cleanup ' + level, file=sys.stderr)
        return
    set_cleanup_config(config, destination / 'cleanup.json', level)
    run(['systemctl', '--user', 'try-restart', 'mouthtype-linux.service'], timeout=30)
    print('AI cleanup (' + level + ') is configured. Check it with: mouthtype-linux doctor')


def find_host(explicit=None):
    """The Qt settings window launcher (or script), or None when the desktop package is not installed."""
    if explicit:
        return Path(explicit) if Path(explicit).is_file() else None
    found = shutil.which('mouthtype-desktop')
    candidates = [Path(found)] if found else []
    candidates += [Path.home() / '.local/bin/mouthtype-desktop', Path('/usr/bin/mouthtype-desktop'),
                   Path('/usr/lib/mouthtype-linux/tools/linux-qt/mouthtype_desktop.py'),
                   HERE.parent / 'linux-qt/mouthtype_desktop.py']
    return next((path for path in candidates if path.is_file()), None)


def config_home():
    base = os.environ.get('XDG_CONFIG_HOME')
    return Path(base) if base and os.path.isabs(base) else Path.home() / '.config'


def autostart_path():
    return config_home() / 'autostart' / (APP_ID + '.desktop')


def user_unit_path():
    return config_home() / 'systemd/user' / SERVICE


def autostart_entry(host):
    command = str(host) if os.access(host, os.X_OK) and host.suffix != '.py' else sys.executable + ' ' + str(host)
    return ('[Desktop Entry]\nType=Application\nName=Mouthtype\nComment=Dictation settings window and tray icon\n'
            'Exec=' + command + ' --page home --background\nIcon=' + APP_ID + '\nTerminal=false\n'
            'X-GNOME-Autostart-enabled=true\n' + AUTOSTART_MARKER + '\n')


def write_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(text)
    os.replace(temporary, path)


def enable_autostart(host):
    """Add the Qt host to the XDG autostart. A file we did not write is left alone."""
    path = autostart_path()
    if path.is_file() and AUTOSTART_MARKER not in path.read_text(errors='replace'):
        print('Left ' + str(path) + ' alone: Mouthtype setup did not create it.')
        return False
    write_atomic(path, autostart_entry(host))
    print('Autostart enabled: ' + str(path))
    return True


def disable_autostart():
    path = autostart_path()
    if not path.is_file():
        return
    if AUTOSTART_MARKER in path.read_text(errors='replace'):
        path.unlink()
        print('Removed ' + str(path))
    else:
        print('Left ' + str(path) + ' alone: Mouthtype setup did not create it.', file=sys.stderr)


def enable_service(launcher, config, *, run):
    """Enable and start the daemon user unit. Uses the packaged unit when there is one, else writes a managed copy."""
    unit = user_unit_path()
    if not VENDOR_UNIT.is_file() and not unit.exists():
        write_atomic(unit, UNIT_MARKER + '\n[Unit]\nDescription=Mouthtype Linux dictation service\nPartOf=graphical-session.target\n'
                     'After=graphical-session.target pipewire.service\n\n[Service]\nType=simple\nExecStart=' + str(launcher) +
                     ' --config ' + str(config) + ' serve --lifetime-seconds 86400\nRestart=always\nRestartSec=2\n\n'
                     '[Install]\nWantedBy=graphical-session.target\n')
        run(['systemctl', '--user', 'daemon-reload'], timeout=30)
    result = run(['systemctl', '--user', 'enable', '--now', SERVICE], timeout=60)
    if result.returncode:
        print('Could not enable the Mouthtype service. Try: systemctl --user enable --now ' + SERVICE, file=sys.stderr)
        return False
    print('Dictation service enabled and started (' + SERVICE + ').')
    return True


def disable_service(*, run):
    for verb in ('disable', 'stop'):
        run(['systemctl', '--user', verb, SERVICE], timeout=30)
    unit = user_unit_path()
    if unit.is_file() and UNIT_MARKER in unit.read_text(errors='replace'):
        unit.unlink()
        run(['systemctl', '--user', 'daemon-reload'], timeout=30)
        print('Removed ' + str(unit))


def grant_typing(*, portal_factory=None, session_factory=None, store_factory=None):
    """Ask the desktop portal for keyboard access now, so the first dictation never prompts mid-take.

    Returns the session status ('active', 'needs_grant', 'unavailable'). The restore value lands in portal.json, which
    the daemon reuses, so the prompt is one-time. Never raises: a refusal leaves delivery in recover-only."""
    try:
        import delivery_portal
        import portal as portal_module
    except ImportError as error:
        print('Typing access was not requested: ' + str(error) + '. Install python3-jeepney, then run mouthtype-linux-setup --grant.',
              file=sys.stderr)
        return 'unavailable'
    portal_factory = portal_factory or portal_module.Portal
    store_factory = store_factory or (lambda: delivery_portal.GrantStore(delivery_portal.grant_store_path()))
    session_factory = session_factory or delivery_portal.RemoteDesktopSession
    portal = None
    try:
        portal = portal_factory().connect()
        portal.register()
        session = session_factory(portal, store_factory())
        try:
            return session.start(interactive=True)
        finally:
            # Closing the session keeps the persisted grant; the daemon opens its own from portal.json.
            session.close()
    except portal_module.PortalError as error:
        print('Typing access was not requested: ' + str(error), file=sys.stderr)
        return 'unavailable'
    finally:
        if portal is not None:
            portal.close()


def portal_uninstall(args, *, run):
    disable_service(run=run)
    disable_autostart()
    try:
        import shortcuts_gnome
        try:
            if shortcuts_gnome.remove():
                print('Removed the Mouthtype GNOME keyboard shortcut.')
        except shortcuts_gnome.GnomeShortcutError:
            pass
    except ImportError:
        pass
    if args.purge:
        try:
            import delivery_portal
            path = delivery_portal.grant_store_path()
            if path.is_file():
                path.unlink()
                print('Removed the stored typing grant ' + str(path) + '. Revoke the app in your desktop settings to forget it there too.')
        except ImportError:
            pass
    record_firstrun('uninstalled')
    print('Per-user pieces removed. Models, recordings and configuration under ~/.local/share/mouthtype were left in place. '
          'Remove the program itself with your package manager (apt remove mouthtype-linux, dnf remove mouthtype-linux) '
          'or python3 tools/linux-desktop/install.py --uninstall for a source install.')
    return 0


def portal_setup(args, desktop, launcher, config, *, run, speech=None, grant=None):
    """GNOME and KDE: no bar plugin. Service, typing grant and autostart instead."""
    if os.environ.get('XDG_SESSION_TYPE', 'wayland').lower() == 'x11':
        print('X11 sessions are not supported. Log in to the Wayland session of ' + desktop.upper() + ' and run this again.',
              file=sys.stderr)
        return 2
    absent = missing_commands(REQUIRED)
    if absent:
        print('Missing helpers: ' + ', '.join(absent) + '. Install them with your package manager first '
              '(PipeWire audio tools for pw-record).', file=sys.stderr)
        return 2
    optional = missing_commands(PORTAL_RECOMMENDED)
    if optional:
        print('Optional helpers missing (notifications, audio files): ' + ', '.join(optional))
    destination = args.destination.expanduser()
    if config.is_file():
        print('Speech is already prepared: ' + str(config))
    else:
        set_aside_incomplete(destination)
        if speech is None:
            import setup_speech
            speech = setup_speech.main
        status = speech(['--destination', str(destination)])
        if status:
            return status
    doctor = run([launcher, '--config', str(config), 'doctor'], text=True, capture_output=True, timeout=120)
    print(doctor.stdout.rstrip())
    if doctor.returncode:
        print('Fix the ERROR lines above, then run this setup again.', file=sys.stderr)
        return 2
    print('\n' + PORTAL_PROMPTS + '\n')
    interactive = sys.stdin.isatty() and sys.stdout.isatty()
    if args.skip_grant:
        print('Typing access skipped. Later: mouthtype-linux-setup --grant')
    elif not (interactive or args.grant):
        print('Not asking for typing access without a terminal. Run mouthtype-linux-setup --grant when you are at the desktop.')
    else:
        print('Waiting for the typing access prompt (up to ' + str(GRANT_TIMEOUT) + ' seconds)...')
        outcome = (grant or grant_typing)()
        if outcome == 'active':
            print('Typing access granted.')
        else:
            print('Typing access was not granted (' + str(outcome) + '). Dictation still records and keeps the text for '
                  'recovery; run mouthtype-linux-setup --grant to try again.')
    if not enable_service(launcher, config, run=run):
        return 2
    host = find_host(args.host)
    if args.no_autostart:
        pass
    elif host is None:
        print('The Mouthtype settings window (mouthtype-linux-desktop) is not installed, so no autostart entry was added.')
    else:
        enable_autostart(host)
    record_firstrun('done')
    print('\nDone. Next:')
    print('  1. Approve the shortcut prompt if your desktop shows one now.')
    print('  2. Open Mouthtype from the application menu for settings' + (' (tray icon: needs AppIndicator support on GNOME).'
          if desktop == 'gnome' else '.'))
    print('  3. Check anytime with: mouthtype-linux doctor')
    return 0


def main(argv=None, *, run=subprocess.run, speech=None, grant=None):
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
                        help='Download llama-server and the AI cleanup model without asking (skip: do not offer)')
    parser.add_argument('--build-server', action='store_true',
                        help='With --cleanup, compile llama-server locally instead of downloading the pinned release')
    parser.add_argument('--shortcut', choices=('toggle', 'hold'), help='Also bind the default dictation key (Omarchy; GNOME and KDE use the portal)')
    parser.add_argument('--desktop', choices=('auto',) + backends.DESKTOPS, default='auto',
                        help='Treat this session as that desktop instead of detecting it')
    parser.add_argument('--host', type=Path, help='GNOME/KDE: the mouthtype-desktop launcher to autostart (default: found automatically)')
    parser.add_argument('--grant', action='store_true', help='GNOME/KDE: ask for typing access even without a terminal')
    parser.add_argument('--skip-grant', action='store_true', help='GNOME/KDE: do not ask for typing access now')
    args = parser.parse_args(argv)
    if sys.platform != 'linux':
        print('This setup is for Linux (Arch/Omarchy).', file=sys.stderr)
        return 2
    desktop = detect_desktop() if args.desktop == 'auto' else args.desktop
    if args.uninstall and desktop in PORTAL_DESKTOPS:
        return portal_uninstall(args, run=run)
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
    if desktop in PORTAL_DESKTOPS:
        return portal_setup(args, desktop, launcher, args.destination.expanduser() / 'linux.json', run=run, speech=speech, grant=grant)
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
