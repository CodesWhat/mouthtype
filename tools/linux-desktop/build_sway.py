"""Build the pinned unprivileged Sway component without modifying distro files."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tarfile
import urllib.request

from desktop import stop_process

PIN = json.loads(Path(__file__).with_name('sway-build.json').read_text())


def unpack_source(data, destination, pin):
    if hashlib.sha256(data).hexdigest() != pin['sha256']:
        raise ValueError('Sway source digest mismatch')
    prefix = 'sway-' + pin['revision']
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if (not path.parts or path.parts[0] != prefix or '..' in path.parts or
                    not (member.isfile() or member.isdir())):
                raise ValueError('Unexpected Sway source member')
        destination.mkdir(mode=0o700, parents=True, exist_ok=False)
        archive.extractall(destination, filter='data')
    return destination / prefix


def build_command(command, log, seconds):
    process = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True)
    try:
        result = process.wait(timeout=seconds)
        if result:
            raise subprocess.CalledProcessError(result, command)
    finally:
        stop_process(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', required=True, type=Path)
    parser.add_argument('--receipt', required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.getuid() == 0:
        parser.error('Build only as the ordinary Linux component-test user')
    if args.work.exists() or args.receipt.exists():
        parser.error('Preserve prior source/build/receipt; choose new paths')
    try:
        with urllib.request.urlopen(PIN['archive'], timeout=30) as response:
            data = response.read(10 * 1024 * 1024)
        source = unpack_source(data, args.work, PIN)
        build = args.work / 'build'
        with args.receipt.with_suffix('.log').open('x') as log:
            build_command(['meson', 'setup', str(build), str(source), '--wrap-mode=nodownload',
                           '-Dman-pages=disabled', '-Dswaybar=false', '-Dswaynag=false',
                           '-Dtray=disabled', '-Dgdk-pixbuf=disabled', '-Ddefault-wallpaper=false'], log, 60)
            build_command(['ninja', '-C', str(build), '-j2', 'sway/sway'], log, 180)
        executable = build / 'sway/sway'
        receipt = {**PIN, 'execution_kind': 'source-built-Sway-component',
                   'executable': str(executable), 'binary_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
                   'installed_package_changed': False, 'capabilities_granted': False,
                   'jobs': 2, 'hyprland_acceptance': False, 'omarchy_acceptance': False}
        with args.receipt.open('x') as output:
            json.dump(receipt, output, indent=2)
            output.write('\n')
        print(json.dumps(receipt, indent=2))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
        print('Sway component build failed: ' + type(error).__name__, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
