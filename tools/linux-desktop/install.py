"""Install or archive the Linux development client without changing the desktop."""

import argparse
import fnmatch
import io
import os
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile

DESKTOP = ('doctor.py', 'test_doctor.py', 'imports.py', 'test_imports.py', 'smart.py', 'test_smart.py',
           'setup_cleanup.py', 'test_setup_cleanup.py', 'test_model_cleanup.py',
           'desktop.py', 'install.py', 'README.md', 'config.example.json',
           'spellings.py', 'test_spellings.py', 'test_spelling_session.py',
           'phrases.py', 'test_phrases.py', 'test_phrase_session.py', 'test_phrase_context.py', 'phrase-fixtures.json',
           'spelling-fixtures.json', 'spelling-unicode.json',
           'cleanup.py', 'cleanup-commands.json', 'cleanup-fixtures.json', 'tone-fixtures.json',
           'test_cleanup.py', 'test_cleanup_session.py',
           'hyprland.lua', 'hyprland-legacy.conf', 'test_desktop.py',
           'setup_speech.py', 'test_setup_speech.py',
           'test_install.py', 'test_acceptance.py', 'acceptance.py', 'wayland_target.py', 'run-ci.sh',
           'build_sway.py', 'sway-build.json', 'test_build_sway.py', 'backends/__init__.py', 'test_backends.py')
ENGINE = ('proof.py', 'worker.py', 'prepare.py', 'pins.json', 'requirements.txt', 'README.md')
GRAPHEME = ('__init__.py', 'api.py', 'finder.py', 'grapheme_property_group.py', 'incb_property_group.py',
            'data/derived_core_property.json', 'data/grapheme_break_property.json',
            'LICENSE', 'UNICODE-LICENSE', 'provenance.json', 'GraphemeBreakTest.txt')
APP_ID = 'app.mouthtype.Mouthtype'
# Source under tools/linux-desktop/share, destination relative to the install prefix. The desktop portals
# match an unsandboxed caller to the .desktop basename, so this id is the one portal.py registers.
SYMBOLIC_DIR = 'icons/hicolor/symbolic/apps/'
# One per tray state (tray.py names them by icon-theme name so GNOME and Plasma can recolour them to the panel).
SYMBOLIC = tuple(APP_ID + suffix + '-symbolic.svg'
                 for suffix in ('', '-recording0', '-recording1', '-recording2', '-processing', '-unavailable'))
SHARE = (('app.mouthtype.Mouthtype.desktop', 'share/applications/' + APP_ID + '.desktop'),
         ('app.mouthtype.Mouthtype.png', 'share/icons/hicolor/128x128/apps/' + APP_ID + '.png')) + tuple(
    (SYMBOLIC_DIR + name, 'share/' + SYMBOLIC_DIR + name) for name in SYMBOLIC)
FILES = (['LICENSE', 'THIRD_PARTY_NOTICES.md'] +
         ['tools/linux-desktop/' + name for name in DESKTOP] +
         ['tools/linux-desktop/share/' + name for name, _ in SHARE] +
         ['tools/linux-desktop/vendor/grapheme/' + name for name in GRAPHEME] +
         ['tools/linux-engine-proof/' + name for name in ENGINE])
# Modules the daemon loads at runtime (cli_*.py, library.py, stats.py, transform_worker.py, ...) and their
# test_*.py files are found by scanning, so a new slice ships without editing the lists above. Tests ship on
# purpose: the Arch package runs them in check() and the install tests run them from the payload. Dev
# scripts and tests that need the repository root (test_arch_bundle.py) stay out. Python packages beside them
# (backends/, testing/) are scanned the same way, so a new backend or test helper ships without a list edit.
SCAN_EXCLUDED = ('check_*.py', 'verify_*.py', 'conftest.py', 'test_arch_bundle.py')
SCAN_PACKAGES_SKIPPED = ('vendor',)


def payload_files(source):
    source = Path(source)
    root = source / 'tools/linux-desktop'
    found = [name for name in sorted(path.name for path in root.glob('*.py'))
             if not any(fnmatch.fnmatchcase(name, pattern) for pattern in SCAN_EXCLUDED)]
    for package in sorted(path.parent for path in root.glob('*/__init__.py') if path.parent.name not in SCAN_PACKAGES_SKIPPED):
        found += [package.name + '/' + path.name for path in sorted(package.glob('*.py'))
                  if not any(fnmatch.fnmatchcase(path.name, pattern) for pattern in SCAN_EXCLUDED)]
    return FILES + ['tools/linux-desktop/' + name for name in found
                    if 'tools/linux-desktop/' + name not in FILES]


LAUNCHER_MARKER = 'import desktop\nsys.exit(desktop.main())\n'


def uninstall(prefix):
    """Remove the launcher and payload this installer made below prefix. Config, models and recordings are not touched."""
    prefix = Path(prefix).expanduser().resolve()
    payload, launcher = prefix / 'lib/mouthtype-linux', prefix / 'bin/mouthtype-linux'
    if launcher.exists() and LAUNCHER_MARKER not in launcher.read_text():
        raise FileExistsError('Not removing ' + str(launcher) + ': it is not a Mouthtype launcher')
    removed = []
    for _, relative in SHARE:
        if (prefix / relative).is_file():
            (prefix / relative).unlink()
            removed.append(prefix / relative)
    if launcher.exists() or launcher.is_symlink():
        launcher.unlink()
        removed.append(launcher)
    if payload.exists():
        shutil.rmtree(payload)
        removed.append(payload)
    return removed


def install(source, prefix, *, destdir=None, update=False):
    source, prefix = Path(source).resolve(), Path(prefix).expanduser()
    if destdir is not None and not prefix.is_absolute():
        raise ValueError('A staged runtime prefix must be absolute')
    runtime_prefix = prefix.resolve()
    destination = (Path(destdir).expanduser().resolve() / runtime_prefix.relative_to('/')
                   if destdir is not None else runtime_prefix)
    destination_root = destination
    payload, launcher = destination / 'lib/mouthtype-linux', destination / 'bin/mouthtype-linux'
    if payload.exists() or launcher.exists() or launcher.is_symlink():
        if not update or destdir is not None:
            raise FileExistsError('Existing Linux client is preserved')
        uninstall(runtime_prefix)
    staged_parents = set()
    if destdir is not None:
        staged_root = Path(destdir).expanduser().resolve()
        for directory in (payload.parent, launcher.parent):
            while directory != staged_root:
                if not directory.exists():
                    staged_parents.add(directory)
                directory = directory.parent
    payload.parent.mkdir(parents=True, exist_ok=True)
    launcher.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.mouthtype-install-', dir=payload.parent))
    placed = False
    share_files, share_parents = [], []
    try:
        for name in payload_files(source):
            destination = staging / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / name, destination)
        if destdir is not None:
            for path in staging.rglob('*'):
                path.chmod(0o755 if path.is_dir() else 0o644)
            staging.chmod(0o755)
            for directory in staged_parents:
                directory.chmod(0o755)
        os.rename(staging, payload)
        placed = True
        for name, relative in SHARE:
            target = destination_root / relative
            directory = target.parent
            while not directory.exists():
                share_parents.append(directory)
                directory = directory.parent
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / 'tools/linux-desktop/share' / name, target)
            share_files.append(target)
            if destdir is not None:
                target.chmod(0o644)
                for created in share_parents:
                    created.chmod(0o755)
        # Imported as a module, not run with runpy.run_path, so Python keeps bytecode for desktop.py and its imports.
        content = ('#!/usr/bin/env python3\nimport os, sys\n'
                   'SCRIPT = ' + repr(str(runtime_prefix / 'lib/mouthtype-linux/tools/linux-desktop/desktop.py')) + '\n'
                   'sys.path.insert(0, os.path.dirname(SCRIPT))\n'
                   'import desktop\n'
                   'sys.exit(desktop.main())\n')
        with launcher.open('x') as output:
            output.write(content)
        launcher.chmod(0o755)
        return launcher
    except BaseException:
        if placed:
            shutil.rmtree(payload)
        for target in share_files:
            target.unlink(missing_ok=True)
        raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def package(source, output):
    source, output = Path(source).resolve(), Path(output)
    # Exclusive creation prevents overwriting an earlier artifact or another task's output.
    with output.open('xb') as destination:
        with tarfile.open(fileobj=destination, mode='w:gz') as archive:
            for name in payload_files(source):
                data = (source / name).read_bytes()
                info = tarfile.TarInfo('mouthtype-linux/' + name)
                info.size, info.mode = len(data), 0o644
                archive.addfile(info, io.BytesIO(data))
    return output


def _remove_gnome_shortcut():
    """Drop the GNOME fallback keybinding if this machine has one. Best effort: no gsettings means nothing to remove."""
    import shortcuts_gnome
    try:
        if shortcuts_gnome.remove():
            print('Removed the Mouthtype GNOME keyboard shortcut.')
    except shortcuts_gnome.GnomeShortcutError:
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, default=Path.home() / '.local')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--archive', type=Path)
    mode.add_argument('--destdir', type=Path, help='Stage files below this root, retaining the final --prefix')
    mode.add_argument('--uninstall', action='store_true', help='Remove the launcher and payload below --prefix')
    parser.add_argument('--update', action='store_true', help='Replace an existing installation below --prefix')
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[2]
    try:
        if args.uninstall:
            removed = uninstall(args.prefix)
            _remove_gnome_shortcut()
            print('\n'.join(map(str, removed)) if removed else 'Nothing to remove below ' + str(args.prefix))
            print('Models, configuration and recordings were left in place.')
            return 0
        result = package(source, args.archive) if args.archive else install(source, args.prefix, destdir=args.destdir, update=args.update)
        print(result)
        if not args.archive and args.destdir is None:
            print('Next: python3 ' + str(Path(__file__).resolve().with_name('setup.py')))
            if str(Path(result).parent) not in os.environ.get('PATH', '').split(os.pathsep):
                print('Note: ' + str(Path(result).parent) + ' is not on PATH in this shell; Omarchy sessions include ~/.local/bin.')
        return 0
    except FileExistsError as error:
        print('Linux client install failed: ' + (str(error) or 'a file already exists') +
              '. Re-run with --update to replace it, or --uninstall to remove it.', file=sys.stderr)
        return 2
    except (OSError, ValueError) as error:
        print('Linux client packaging failed: ' + type(error).__name__ + ': ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
