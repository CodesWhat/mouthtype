#!/usr/bin/env python3
"""Publish only committed website files plus retained, checked public releases."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('public_release', ROOT / 'scripts/stage-public-release.py')
public = importlib.util.module_from_spec(spec)
spec.loader.exec_module(public)
run = public.release.run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public-dir', required=True, type=Path)
    parser.add_argument('--production', action='store_true', help='Publish after validation; otherwise check only')
    args = parser.parse_args()
    assets = args.public_dir.resolve()
    if run(['git', 'status', '--porcelain'], cwd=ROOT).strip():
        raise RuntimeError('Publish from a clean reviewed checkout')
    source = run(['git', 'rev-parse', 'HEAD'], cwd=ROOT).strip()
    redirects = {item['src']: item['headers']['Location'] for item in
                 json.loads((ROOT / 'website/vercel.json').read_text()).get('routes', [])
                 if item.get('status') == 302}
    manifests = list((assets / 'releases').glob('*/release-manifest.json'))
    if not manifests:
        raise RuntimeError('Retained public release artifacts are required')
    selected = None
    for path in manifests:
        manifest = public.validate_archive(path.parent)
        source_file = path.parent / f"Mouthtype-{manifest['version']}-source.tar.gz"
        if source_file.name != manifest['sourceArchive'] or hashlib.sha256(source_file.read_bytes()).hexdigest() != manifest['sourceSHA256']:
            raise RuntimeError('Corresponding source archive checksum must match')
        prefix = f"/releases/{manifest['version']}/"
        if redirects.get('/download/file') == prefix + manifest['archive']:
            if redirects.get('/source') != prefix + source_file.name:
                raise RuntimeError('Download and source routes must describe the same release')
            selected = manifest
    if selected is None:
        raise RuntimeError('The advertised download is not among the checked artifacts')
    feed = assets / 'updates/appcast.xml'
    public.validate_feed_build(feed, selected['build'])
    tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
    run([str(tools / 'sign_update'), '--account', 'com.codeswhat.mouthtype', '--verify', str(feed)])
    if not args.production:
        print(f"Checked website {source} and release {selected['version']}; nothing published")
        return
    with tempfile.TemporaryDirectory(prefix='mouthtype-website-publish-') as temporary:
        staging = Path(temporary)
        archive = staging / 'website.tar'
        run(['git', 'archive', f'--output={archive}', source, 'website'], cwd=ROOT)
        run(['tar', '-xf', str(archive), '-C', str(staging)])
        archive.unlink()
        shutil.copytree(assets / 'releases', staging / 'website/public/releases')
        shutil.copytree(assets / 'updates', staging / 'website/public/updates')
        (staging / '.vercel').mkdir()
        (staging / '.vercel/project.json').write_text(json.dumps({
            'projectId': 'prj_9j2CahKVJknyYBEc2aWWVNheB3hY',
            'orgId': 'team_A8tovHIXay3cbUMOtLBijJSk',
        }))
        result = run(['vercel', 'deploy', str(staging), '--prod', '--yes', '--scope', 'codeswhat',
                      '--meta', f'sourceCommit={source}', '--meta', 'sourceRepository=CodesWhat/mouthtype'], timeout=600)
        print(result)
        print(f"Published release {selected['version']}; verify the public download and feed before announcing it")


if __name__ == '__main__':
    main()
