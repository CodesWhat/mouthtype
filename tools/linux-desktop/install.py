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
           'hyprland.lua', 'hyprland-legacy.conf', 'test_desktop.py',
           'test_install.py', 'test_acceptance.py', 'acceptance.py', 'wayland_target.py', 'run-ci.sh',
           'build_sway.py', 'sway-build.json', 'test_build_sway.py')
ENGINE = ('proof.py', 'worker.py', 'prepare.py', 'pins.json', 'requirements.txt', 'README.md')
FILES = (['LICENSE', 'THIRD_PARTY_NOTICES.md'] +
         ['tools/linux-desktop/' + name for name in DESKTOP] +
         ['tools/linux-engine-proof/' + name for name in ENGINE])


def install(source, prefix):
    source, prefix = Path(source).resolve(), Path(prefix).expanduser().resolve()
    payload, launcher = prefix / 'lib/mouthtype-linux', prefix / 'bin/mouthtype-linux'
    if payload.exists() or launcher.exists() or launcher.is_symlink():
        raise FileExistsError('Existing Linux client is preserved')
    payload.parent.mkdir(parents=True, exist_ok=True)
    launcher.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.mouthtype-install-', dir=payload.parent))
    placed = False
    try:
        for name in FILES:
            destination = staging / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / name, destination)
        os.rename(staging, payload)
        placed = True
        content = ('#!/usr/bin/env python3\nimport runpy\n'
                   'runpy.run_path(' + repr(str(payload / 'tools/linux-desktop/desktop.py')) + ', run_name="__main__")\n')
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
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[2]
    try:
        result = package(source, args.archive) if args.archive else install(source, args.prefix)
        print(result)
        return 0
    except OSError as error:
        print('Linux client packaging failed: ' + type(error).__name__, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
