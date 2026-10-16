#!/usr/bin/env python3
"""Stage a checked release, source archive and signed Sparkle feed for the website."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('package_release', ROOT / 'scripts/package-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def validate_archive(directory):
    manifest = json.loads((directory / 'release-manifest.json').read_text())
    if manifest['notarizationStatus'] != 'Accepted':
        raise RuntimeError('Accepted notarization is required')
    if not all(manifest.get(key) is True for key in (
        'signatureVerified', 'stapleVerified', 'extractedGatekeeperAccepted'
    )):
        raise RuntimeError('All distribution checks must pass')
    if manifest['archive'] != f"Mouthtype-{manifest['version']}-macos-arm64.zip":
        raise RuntimeError('Release version and archive filename must agree')
    archive = directory / manifest['archive']
    if hashlib.sha256(archive.read_bytes()).hexdigest() != manifest['archiveSHA256']:
        raise RuntimeError('Archive checksum does not match the checked release')
    if archive.stat().st_size != manifest['archiveBytes']:
        raise RuntimeError('Archive length does not match the checked release')
    return manifest


def retain_public_assets(staged, retained):
    feed = (staged / 'updates/appcast.xml').read_bytes()
    files = [path for path in (staged / 'releases').rglob('*') if path.is_file()]
    for path in files:
        destination = retained / path.relative_to(staged)
        if destination.exists() and destination.read_bytes() != path.read_bytes():
            raise RuntimeError(f'Published release files are immutable: {destination.name}')
    for path in files:
        destination = retained / path.relative_to(staged)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
    (retained / 'updates').mkdir(parents=True, exist_ok=True)
    temporary = retained / 'updates/appcast.xml.new'
    temporary.write_bytes(feed)
    os.replace(temporary, retained / 'updates/appcast.xml')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('release_directory', type=Path)
    parser.add_argument('--sparkle-account', default='com.codeswhat.mouthtype')
    parser.add_argument('--public-dir', required=True, type=Path,
                        help='Retained public artifact directory; keep it across releases')
    args = parser.parse_args()
    directory = args.release_directory.resolve()
    manifest = validate_archive(directory)
    version = manifest['version']
    metadata = release.release_metadata(ROOT)
    source = release.verify_source(ROOT, version)
    if metadata['MouthtypeDisplayVersion'] != version or source != manifest['sourceRevision']:
        raise RuntimeError('Release archive and checked source must agree')
    if metadata['CFBundleVersion'] != manifest['build']:
        raise RuntimeError('Release build numbers must agree')
    tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
    if not (tools / 'generate_appcast').is_file():
        raise RuntimeError('Resolve the pinned Sparkle package before staging')
    public_key = release.run([str(tools / 'generate_keys'), '--account', args.sparkle_account, '-p']).strip()
    with (directory / 'Mouthtype.app/Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    if info.get('SUPublicEDKey') != public_key or info.get('SURequireSignedFeed') is not True:
        raise RuntimeError('The app must require the feed signing key used for publication')
    with tempfile.TemporaryDirectory(prefix='mouthtype-public-check-') as temporary:
        extracted = Path(temporary)
        release.run(['ditto', '-x', '-k', str(directory / manifest['archive']), str(extracted)], timeout=180)
        release.verify_app(extracted / 'Mouthtype.app', directory, 'public-extracted')
        with (extracted / 'Mouthtype.app/Contents/Info.plist').open('rb') as file:
            extracted_info = plistlib.load(file)
        if extracted_info != info or info.get('MouthtypeSourceRevision') != source:
            raise RuntimeError('Extracted app metadata must match the checked source')
    output = directory / 'public'
    output.mkdir(exist_ok=False)
    releases = output / 'releases' / version
    updates = output / 'updates'
    releases.mkdir(parents=True)
    updates.mkdir()
    archive = directory / manifest['archive']
    shutil.copy2(archive, releases / archive.name)
    shutil.copy2(directory / f'{archive.name}.sha256', releases / f'{archive.name}.sha256')
    source_archive = releases / f'Mouthtype-{version}-source.tar.gz'
    release.run(['git', 'archive', '--format=tar.gz', f'--prefix=Mouthtype-{version}-source/',
                 f'--output={source_archive}', source], cwd=ROOT, timeout=180)
    source_digest = hashlib.sha256(source_archive.read_bytes()).hexdigest()
    (releases / f'{source_archive.name}.sha256').write_text(f'{source_digest}  {source_archive.name}\n')
    public_manifest = {**manifest, 'sourceArchive': source_archive.name, 'sourceSHA256': source_digest}
    (releases / 'release-manifest.json').write_text(json.dumps(public_manifest, indent=2) + '\n')
    with tempfile.TemporaryDirectory(prefix='mouthtype-appcast-') as temporary:
        feed_directory = Path(temporary)
        shutil.copy2(archive, feed_directory / archive.name)
        shutil.copy2(ROOT / 'packaging/ReleaseNotes.txt', feed_directory / f'{archive.stem}.txt')
        release.run([str(tools / 'generate_appcast'), '--account', args.sparkle_account,
                     '--download-url-prefix', f'https://mouthtype.app/releases/{version}/',
                     '--link', 'https://mouthtype.app/start/', '--embed-release-notes',
                     '--maximum-deltas', '0', str(feed_directory)], timeout=180,
                    log=directory / 'appcast-generation.log')
        feed = feed_directory / 'appcast.xml'
        release.run([str(tools / 'sign_update'), '--account', args.sparkle_account, '--verify', str(feed)])
        shutil.copy2(feed, updates / 'appcast.xml')
    retain_public_assets(output, args.public_dir.resolve())
    print(json.dumps({'publicDirectory': str(args.public_dir.resolve()), 'version': version,
                      'archiveSHA256': manifest['archiveSHA256'], 'signedFeedVerified': True,
                      'sourceSHA256': source_digest}, indent=2))


if __name__ == '__main__':
    main()
