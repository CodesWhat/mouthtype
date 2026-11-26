#!/usr/bin/env python3
"""Rebuild the retained public release directory from published GitHub releases.

Restores the files scripts/stage-public-release.py retains for each release (ZIP, DMG, source
archive, their .sha256 files and release-manifest.json) into <public-dir>/releases/<version>/.
Each download is checked against the SHA-256 digest GitHub reports before it is moved in. An
existing retained file with different bytes is refused, never replaced. The signed appcast in
<public-dir>/updates/ is not a release asset; restore it from a backup or the published feed.

usage: scripts/restore-public-assets.py --public-dir build/public-release-assets [--version 0.12.3 ...]
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

REPO = 'CodesWhat/mouthtype'
RETAINED = re.compile(
    r'(Mouthtype-.+-macos-arm64\.(zip|dmg)(\.sha256)?|Mouthtype-.+-source\.tar\.gz(\.sha256)?|release-manifest\.json)')


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def restore(releases, public_dir, download, versions=None):
    restored = []
    for release in releases:
        tag = release['tag_name']
        version = tag.removeprefix('v')
        if release.get('draft') or (versions and version not in versions):
            continue
        wanted = [a for a in release['assets'] if RETAINED.fullmatch(a['name'])]
        if not wanted:
            continue
        target = public_dir / 'releases' / version
        with tempfile.TemporaryDirectory(prefix='mouthtype-restore-') as temporary:
            staged = {}
            for item in wanted:
                if item.get('state') != 'uploaded':
                    raise RuntimeError(f'{tag}/{item["name"]} is not an uploaded release asset')
                path = Path(temporary) / item['name']
                download(tag, item['name'], path)
                if item.get('digest') != 'sha256:' + sha256(path) or item.get('size') != path.stat().st_size:
                    raise RuntimeError(f'{tag}/{item["name"]} does not match the digest GitHub reports')
                existing = target / item['name']
                if existing.exists() and sha256(existing) != sha256(path):
                    raise RuntimeError(f'Retained release files are immutable: {version}/{item["name"]}')
                staged[item['name']] = path
            if 'release-manifest.json' in staged:
                manifest = json.loads(staged['release-manifest.json'].read_text())
                for key, name in (('archiveSHA256', manifest.get('archive')), ('dmgSHA256', manifest.get('dmg')),
                                  ('sourceSHA256', manifest.get('sourceArchive'))):
                    if name in staged and manifest.get(key) != sha256(staged[name]):
                        raise RuntimeError(f'{tag}/{name} does not match release-manifest.json')
            target.mkdir(parents=True, exist_ok=True)
            for name, path in staged.items():
                if not (target / name).exists():
                    shutil.copy2(path, target / name)
        restored.append(version)
    return restored


def gh_download(tag, name, destination):
    subprocess.run(['gh', 'release', 'download', tag, '-R', REPO, '--pattern', name,
                    '--output', str(destination)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--public-dir', required=True, type=Path)
    parser.add_argument('--version', action='append', help='Restore only this version (repeatable)')
    args = parser.parse_args()
    out = subprocess.run(['gh', 'api', '--paginate', '--slurp', f'repos/{REPO}/releases?per_page=100'],
                         check=True, capture_output=True, text=True).stdout
    releases = [release for page in json.loads(out) for release in page]
    done = restore(releases, args.public_dir.resolve(), gh_download, args.version)
    print(f'Restored {len(done)} releases: {", ".join(done) or "none"}')


if __name__ == '__main__':
    main()
