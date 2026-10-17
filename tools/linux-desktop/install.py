"""Install or archive the Linux development client without changing the desktop."""

import argparse
import io
import os
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile

DESKTOP = ('desktop.py', 'install.py', 'README.md', 'config.example.json',
           'spellings.py', 'test_spellings.py', 'test_spelling_session.py',
           'phrases.py', 'test_phrases.py', 'test_phrase_session.py', 'test_phrase_context.py', 'phrase-fixtures.json',
           'spelling-fixtures.json', 'spelling-unicode.json',
           'cleanup.py', 'cleanup-commands.json', 'cleanup-fixtures.json',
           'test_cleanup.py', 'test_cleanup_session.py',
           'hyprland.lua', 'hyprland-legacy.conf', 'test_desktop.py',
           'setup_speech.py', 'test_setup_speech.py',
           'test_install.py', 'test_acceptance.py', 'acceptance.py', 'wayland_target.py', 'run-ci.sh',
           'build_sway.py', 'sway-build.json', 'test_build_sway.py')
ENGINE = ('proof.py', 'worker.py', 'prepare.py', 'pins.json', 'requirements.txt', 'README.md')
GRAPHEME = ('__init__.py', 'api.py', 'finder.py', 'grapheme_property_group.py', 'incb_property_group.py',
            'data/derived_core_property.json', 'data/grapheme_break_property.json',
            'LICENSE', 'UNICODE-LICENSE', 'provenance.json', 'GraphemeBreakTest.txt')
FILES = (['LICENSE', 'THIRD_PARTY_NOTICES.md'] +
         ['tools/linux-desktop/' + name for name in DESKTOP] +
         ['tools/linux-desktop/vendor/grapheme/' + name for name in GRAPHEME] +
         ['tools/linux-engine-proof/' + name for name in ENGINE])


def install(source, prefix, *, destdir=None):
    source, prefix = Path(source).resolve(), Path(prefix).expanduser()
    if destdir is not None and not prefix.is_absolute():
        raise ValueError('A staged runtime prefix must be absolute')
    runtime_prefix = prefix.resolve()
    destination = (Path(destdir).expanduser().resolve() / runtime_prefix.relative_to('/')
                   if destdir is not None else runtime_prefix)
    payload, launcher = destination / 'lib/mouthtype-linux', destination / 'bin/mouthtype-linux'
    if payload.exists() or launcher.exists() or launcher.is_symlink():
        raise FileExistsError('Existing Linux client is preserved')
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
    try:
        for name in FILES:
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
        content = ('#!/usr/bin/env python3\nimport runpy\n'
                   'runpy.run_path(' + repr(str(runtime_prefix / 'lib/mouthtype-linux/tools/linux-desktop/desktop.py')) + ', run_name="__main__")\n')
        with launcher.open('x') as output:
            output.write(content)
        launcher.chmod(0o755)
        return launcher
    except BaseException:
        if placed:
            shutil.rmtree(payload)
        raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def package(source, output):
    source, output = Path(source).resolve(), Path(output)
    # Exclusive creation prevents overwriting an earlier artifact or another task's output.
    with output.open('xb') as destination:
        with tarfile.open(fileobj=destination, mode='w:gz') as archive:
            for name in FILES:
                data = (source / name).read_bytes()
                info = tarfile.TarInfo('mouthtype-linux/' + name)
                info.size, info.mode = len(data), 0o644
                archive.addfile(info, io.BytesIO(data))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, default=Path.home() / '.local')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--archive', type=Path)
    mode.add_argument('--destdir', type=Path, help='Stage files below this root, retaining the final --prefix')
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[2]
    try:
        result = package(source, args.archive) if args.archive else install(source, args.prefix, destdir=args.destdir)
        print(result)
        return 0
    except (OSError, ValueError) as error:
        print('Linux client packaging failed: ' + type(error).__name__, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
