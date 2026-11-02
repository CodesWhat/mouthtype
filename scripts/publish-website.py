#!/usr/bin/env python3
"""Publish committed website files, checked release redirects and the signed feed."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import tempfile
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('public_release', ROOT / 'scripts/stage-public-release.py')
public = importlib.util.module_from_spec(spec)
spec.loader.exec_module(public)
run = public.release.run
DOWNLOAD_SUFFIXES = {'.zip', '.dmg', '.gz'}


def external_download_routes(assets, releases):
    published = {item['tag_name']: item for item in releases if not item['draft']}
    routes = []
    for path in sorted((assets / 'releases').glob('*/*')):
        if not path.is_file() or path.suffix not in DOWNLOAD_SUFFIXES:
            continue
        version = path.parent.name
        release = published.get('v' + version)
        asset = next((item for item in release['assets'] if item['name'] == path.name), None) if release else None
        url = f'https://github.com/CodesWhat/mouthtype/releases/download/v{quote(version, safe="")}/{quote(path.name, safe="")}'
        digest = 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()
        if not asset or asset.get('state') != 'uploaded' or asset.get('digest') != digest \
                or asset.get('size') != path.stat().st_size or asset.get('browser_download_url') != url:
            raise RuntimeError(f'Published GitHub release asset must match retained bytes: {version}/{path.name}')
        routes.append({
            'src': re.escape(f'/releases/{version}/{path.name}'),
            'headers': {'Location': url, 'Cache-Control': 'public, max-age=3600'},
            'status': 302,
        })
    return routes


def stage_public_assets(assets, website, routes):
    public_directory = website / 'public'
    public_directory.mkdir(exist_ok=True)
    shutil.copytree(assets / 'releases', public_directory / 'releases',
                    ignore=lambda directory, names: [name for name in names if Path(name).suffix in DOWNLOAD_SUFFIXES])
    shutil.copytree(assets / 'updates', public_directory / 'updates')
    config_path = website / 'vercel.json'
    config = json.loads(config_path.read_text())
    config['routes'] = config.get('routes', []) + routes
    config_path.write_text(json.dumps(config, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public-dir', required=True, type=Path)
    parser.add_argument('--production', action='store_true', help='Publish after validation; otherwise check only')
    parser.add_argument('--website-ref', default='HEAD',
                        help='Reviewed website revision to export; defaults to this checkout')
    args = parser.parse_args()
    assets = args.public_dir.resolve()
    if run(['git', 'status', '--porcelain'], cwd=ROOT).strip():
        raise RuntimeError('Publish from a clean reviewed checkout')
    source = run(['git', 'rev-parse', 'HEAD'], cwd=ROOT).strip()
    website_source = run(['git', 'rev-parse', '--verify', '--end-of-options', args.website_ref + '^{commit}'], cwd=ROOT).strip()
    redirects = {item['src']: item['headers']['Location'] for item in
                 json.loads(run(['git', 'show', f'{website_source}:website/vercel.json'], cwd=ROOT)).get('routes', [])
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
        # Releases with a DMG advertise it; the ZIP stays in the release for Sparkle only.
        if redirects.get('/download/file') == prefix + manifest.get('dmg', manifest['archive']):
            if redirects.get('/source') != prefix + source_file.name:
                raise RuntimeError('Download and source routes must describe the same release')
            selected = manifest
    if selected is None:
        raise RuntimeError('The advertised download is not among the checked artifacts (a release with a DMG must advertise the DMG)')
    feed = assets / 'updates/appcast.xml'
    public.validate_feed_build(feed, selected['build'])
    tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
    run([str(tools / 'sign_update'), '--account', 'com.codeswhat.mouthtype', '--verify', str(feed)])
    pages = json.loads(run(['gh', 'api', '--paginate', '--slurp', 'repos/CodesWhat/mouthtype/releases?per_page=100']))
    download_routes = external_download_routes(assets, [release for page in pages for release in page])
    if not args.production:
        print(f"Checked website {website_source}, publisher {source} and release {selected['version']}; {len(download_routes)} verified external downloads; nothing published")
        return
    with tempfile.TemporaryDirectory(prefix='mouthtype-website-publish-') as temporary:
        staging = Path(temporary)
        archive = staging / 'website.tar'
        run(['git', 'archive', f'--output={archive}', website_source, 'website'], cwd=ROOT)
        run(['tar', '-xf', str(archive), '-C', str(staging)])
        archive.unlink()
        stage_public_assets(assets, staging / 'website', download_routes)
        (staging / '.vercel').mkdir()
        (staging / '.vercel/project.json').write_text(json.dumps({
            'projectId': 'prj_9j2CahKVJknyYBEc2aWWVNheB3hY',
            'orgId': 'team_A8tovHIXay3cbUMOtLBijJSk',
        }))
        result = run(['vercel', 'deploy', str(staging), '--prod', '--yes', '--scope', 'codeswhat',
                      '--meta', f'sourceCommit={source}', '--meta', f'websiteCommit={website_source}',
                      '--meta', 'sourceRepository=CodesWhat/mouthtype'], timeout=600)
        print(result)
        print(f"Published release {selected['version']}; verify the public download and feed before announcing it")


if __name__ == '__main__':
    main()
