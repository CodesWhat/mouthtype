"""Prepare a local-source Arch test-package bundle without building or installing it."""

import importlib.util
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('linux_installer', ROOT / 'tools/linux-desktop/install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def prepare(source, destination, *, version, revision):
    if not re.fullmatch(r'[0-9][A-Za-z0-9._+]*', version) or not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('Invalid test-package version or source revision')
    source, destination = Path(source).resolve(), Path(destination).expanduser().resolve()
    destination.mkdir(mode=0o700, parents=True)
    archive = installer.package(source, destination / 'mouthtype-linux-source.tar.gz')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    recipe = (source / 'packaging/arch/PKGBUILD.in').read_text()
    if recipe.count('@VERSION@') != 1 or recipe.count('@SOURCE_SHA256@') != 1:
        raise ValueError('Invalid package recipe markers')
    (destination / 'PKGBUILD').write_text(recipe.replace('@VERSION@', version).replace('@SOURCE_SHA256@', digest))
    shutil.copyfile(source / 'packaging/arch/README.md', destination / 'README.md')
    receipt = {'version': version, 'revision': revision, 'source_sha256': digest,
               'payload_sha256': {name: hashlib.sha256((source / name).read_bytes()).hexdigest()
                                  for name in installer.FILES},
               'physical_desktop_tested': False, 'model_weights_included': False}
    (destination / 'BUILD-SOURCE.json').write_text(json.dumps(receipt, indent=2) + '\n')
    names = ('mouthtype-linux-source.tar.gz', 'PKGBUILD', 'README.md', 'BUILD-SOURCE.json')
    (destination / 'SHA256SUMS.txt').write_text(''.join(
        hashlib.sha256((destination / name).read_bytes()).hexdigest() + '  ' + name + '\n' for name in names))
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True, type=Path)
    args = parser.parse_args()
    try:
        inputs = installer.FILES + ['scripts/prepare-linux-arch.py', 'packaging/Version.plist',
                                    'packaging/arch/PKGBUILD.in', 'packaging/arch/README.md']
        def git(*arguments):
            return subprocess.check_output(['git', *arguments], cwd=ROOT, text=True, timeout=5).strip()
        if git('status', '--porcelain', '--', *inputs):
            raise ValueError('Commit the package inputs before preparing a source bundle')
        revision = git('rev-parse', 'HEAD')
        stamp = git('show', '-s', '--format=%ct', 'HEAD')
        with (ROOT / 'packaging/Version.plist').open('rb') as source:
            base = plistlib.load(source)['CFBundleShortVersionString']
        if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', base) or not stamp.isdigit():
            raise ValueError('Invalid base version')
        version = base + 'test.r' + stamp + '.' + revision[:12]
        print(prepare(ROOT, args.destination, version=version, revision=revision))
        return 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('Arch bundle preparation failed: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
