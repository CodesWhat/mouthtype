#!/usr/bin/env python3
"""Build and notarize a ZIP from a clean, exact release tag without launching the app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


def run(args, *, cwd=None, timeout=60, log=None):
    if log:
        with Path(log).open('w') as output:
            subprocess.run(args, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, check=True, timeout=timeout)
        return ''
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stdout}{result.stderr}')
    return result.stdout


def release_metadata(root):
    with (root / 'packaging/Version.plist').open('rb') as file:
        metadata = plistlib.load(file)
    version = metadata.get('MouthtypeDisplayVersion', '')
    number = r'(?:0|[1-9][0-9]*)'
    if not re.fullmatch(rf'{number}\.{number}\.{number}(?:-(?:alpha|beta|rc)\.[1-9][0-9]*)?', version):
        raise RuntimeError('Invalid release display version')
    if metadata.get('CFBundleShortVersionString') != version.split('-')[0]:
        raise RuntimeError('Marketing version must match the release version')
    if not re.fullmatch(r'[1-9][0-9]*', metadata.get('CFBundleVersion', '')):
        raise RuntimeError('Build number must be a positive integer')
    return metadata


def verify_source(root, version):
    if run(['git', 'status', '--porcelain'], cwd=root).strip():
        raise RuntimeError('Release source must be clean, including untracked files')
    head = run(['git', 'rev-parse', 'HEAD'], cwd=root).strip()
    tagged = run(['git', 'rev-parse', f'refs/tags/v{version}^{{commit}}'], cwd=root).strip()
    if head != tagged:
        raise RuntimeError('HEAD must match the exact release tag')
    return head


def create_output(base, version):
    output = base / version
    output.mkdir(parents=True, exist_ok=False)
    return output


def verify_app(app, output, label):
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    run(['xcrun', 'stapler', 'validate', str(app)], log=output / f'{label}-staple.log')
    run(['spctl', '--assess', '--type', 'execute', '--verbose=2', str(app)], log=output / f'{label}-gatekeeper.log')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--notary-profile', required=True)
    parser.add_argument('--output-dir', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    metadata = release_metadata(root)
    version = metadata['MouthtypeDisplayVersion']
    source = verify_source(root, version)
    if run(['uname', '-m']).strip() != 'arm64':
        raise RuntimeError('Build this release on an Apple Silicon Mac')
    output = create_output(args.output_dir.resolve(), version)
    app = output / 'Mouthtype.app'
    print(f'Building {version} from {source}', flush=True)
    env = os.environ.copy()
    env['MOUTHTYPE_BUILD_DIR'] = str(output)
    with (output / 'build.log').open('w') as log:
        subprocess.run(['bash', 'scripts/build-app.sh'], cwd=root, env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1200)
    with (app / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    for key in ('MouthtypeDisplayVersion', 'CFBundleShortVersionString', 'CFBundleVersion'):
        if info.get(key) != metadata[key]:
            raise RuntimeError(f'Built app has the wrong {key}')
    if info.get('MouthtypeSourceRevision') != source:
        raise RuntimeError('Built app does not identify the release source')
    identity = subprocess.run(['codesign', '-dvv', str(app)], capture_output=True, text=True, check=True).stderr
    if 'Authority=Developer ID Application:' not in identity or 'TeamIdentifier=3524374A2S' not in identity:
        raise RuntimeError('A CodesWhat Developer ID signature is required')
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    upload = output / 'notarization-upload.zip'
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(upload)], timeout=180)
    print('Submitting the signed app to Apple', flush=True)
    submitted = run(['xcrun', 'notarytool', 'submit', str(upload), '--keychain-profile',
                     args.notary_profile, '--output-format', 'json'], timeout=300)
    (output / 'notarization-submit-output.json').write_text(submitted)
    submission = json.loads(submitted)
    (output / 'notarization-submission.json').write_text(json.dumps(submission, indent=2) + '\n')
    submission_id = submission['id']
    print(f'Apple submission {submission_id}; waiting up to ten minutes', flush=True)
    try:
        status = json.loads(run(['xcrun', 'notarytool', 'wait', submission_id, '--keychain-profile',
                                 args.notary_profile, '--output-format', 'json', '--timeout', '10m'], timeout=630))
    except Exception:
        run(['xcrun', 'notarytool', 'info', submission_id, '--keychain-profile', args.notary_profile,
             '--output-format', 'json'], log=output / 'notarization-last-status.json')
        raise
    (output / 'notarization-result.json').write_text(json.dumps(status, indent=2) + '\n')
    if status.get('status') != 'Accepted':
        run(['xcrun', 'notarytool', 'log', submission_id, '--keychain-profile', args.notary_profile],
            log=output / 'notarization-rejection.json')
        raise RuntimeError(f'Apple did not accept this app: {status.get("status")}')
    run(['xcrun', 'stapler', 'staple', str(app)], log=output / 'stapling.log')
    verify_app(app, output, 'original')
    print('Apple accepted the app; building and checking the final ZIP', flush=True)
    filename = f'Mouthtype-{version}-macos-arm64.zip'
    archive = output / filename
    with tempfile.TemporaryDirectory(prefix='mouthtype-package-') as temporary:
        staging = Path(temporary) / f'Mouthtype-{version}'
        staging.mkdir()
        run(['ditto', str(app), str(staging / 'Mouthtype.app')], timeout=180)
        shutil.copy2(root / 'docs/ALPHA.md', staging / 'Read Me.txt')
        shutil.copy2(root / 'LICENSE', staging / 'LICENSE')
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(staging), str(archive)], timeout=180)
        extracted = Path(temporary) / 'extracted'
        run(['ditto', '-x', '-k', str(archive), str(extracted)], timeout=180)
        verify_app(extracted / staging.name / 'Mouthtype.app', output, 'extracted')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / f'{filename}.sha256').write_text(f'{digest}  {filename}\n')
    manifest = {'version': version, 'build': metadata['CFBundleVersion'], 'tag': f'v{version}',
                'sourceRevision': source, 'architecture': 'arm64', 'minimumMacOS': '26.0',
                'archive': filename, 'archiveSHA256': digest, 'archiveBytes': archive.stat().st_size,
                'notarizationID': submission_id, 'notarizationStatus': status['status'],
                'signatureVerified': True, 'stapleVerified': True, 'extractedGatekeeperAccepted': True,
                'freshInstallVerified': False}
    (output / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    upload.unlink()
    print(json.dumps(manifest, indent=2), flush=True)


if __name__ == '__main__':
    main()
