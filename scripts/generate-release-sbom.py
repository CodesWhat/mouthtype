#!/usr/bin/env python3
"""Bind the release tag's resolved Swift source inventory to checked release bytes."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def generate(manifest, resolved, revision, directory):
    if not re.fullmatch(r'[0-9a-f]{40}', revision) or manifest['sourceRevision'] != revision:
        raise ValueError('Release source revision does not match the tag')
    version = manifest['version']
    if manifest['tag'] != f'v{version}':
        raise ValueError('Release tag does not match the version')
    components = []
    seen = set()
    for pin in sorted(resolved['pins'], key=lambda item: item['identity']):
        identity = pin['identity']
        if identity in seen:
            raise ValueError(f'Duplicate resolved source: {identity}')
        seen.add(identity)
        state = pin['state']
        commit = state['revision']
        if pin['kind'] != 'remoteSourceControl' or not re.fullmatch(r'[0-9a-f]{40}', commit):
            raise ValueError(f'An exact source revision is required for {identity}')
        location = pin['location']
        if not location.startswith('https://') or '@' in location:
            raise ValueError(f'A public source URL is required for {identity}')
        components.append({
            'type': 'library', 'bom-ref': f'swift:{identity}@{commit}', 'name': identity,
            'version': state.get('version') or commit,
            'description': 'Resolved Swift source input. Inclusion in the shipped binary is not established.',
            'externalReferences': [{'type': 'vcs', 'url': f'{location}#{commit}'}],
            'properties': [{'name': 'mouthtype:source-revision', 'value': commit}],
        })
    if not components:
        raise ValueError('The resolved Swift source inventory is empty')
    for key, suffix in [('archive', 'zip'), ('dmg', 'dmg')]:
        name = manifest[key]
        if name != f'Mouthtype-{version}-macos-arm64.{suffix}' or Path(name).name != name:
            raise ValueError('Artifact filename does not match the release version')
        digest = hashlib.sha256()
        with (Path(directory) / name).open('rb') as asset:
            for chunk in iter(lambda: asset.read(1024 * 1024), b''):
                digest.update(chunk)
        if digest.hexdigest() != manifest[f'{key}SHA256']:
            raise ValueError(f'Artifact checksum mismatch: {name}')
        components.append({
            'type': 'file', 'bom-ref': f'release:{name}', 'name': name,
            'hashes': [{'alg': 'SHA-256', 'content': digest.hexdigest()}],
            'externalReferences': [{'type': 'distribution', 'url':
                f'https://github.com/CodesWhat/mouthtype/releases/download/v{version}/{name}'}],
        })
    root = {
        'type': 'application', 'bom-ref': f'mouthtype:{revision}', 'name': 'Mouthtype', 'version': version,
        'externalReferences': [{'type': 'vcs', 'url': f'https://github.com/CodesWhat/mouthtype#{revision}'}],
        'properties': [{'name': 'mouthtype:source-revision', 'value': revision}],
    }
    return {
        '$schema': 'https://cyclonedx.org/schema/bom-1.6.schema.json',
        'bomFormat': 'CycloneDX', 'specVersion': '1.6', 'version': 1,
        'metadata': {'component': root, 'properties': [{
            'name': 'mouthtype:inventory-scope',
            'value': 'Package.resolved at the release tag plus SHA-256 verified ZIP and DMG. '
                     'Not a complete binary composition, dependency graph or build provenance. '
                     'Excludes downloaded models, OS/SDK libraries, website, docs and experimental Linux.',
        }]},
        'components': components,
        'compositions': [{'aggregate': 'incomplete', 'assemblies': [root['bom-ref']]}],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--assets-dir', type=Path, required=True)
    parser.add_argument('--repository', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text())
        tag = manifest['tag']
        if tag != f"v{manifest['version']}" or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?', tag):
            raise ValueError('Invalid release tag')
        revision = subprocess.check_output(
            ['git', '-C', str(args.repository), 'rev-parse', f'refs/tags/{tag}^{{commit}}'], text=True).strip()
        resolved = json.loads(subprocess.check_output(
            ['git', '-C', str(args.repository), 'show', f'{revision}:Package.resolved'], text=True))
        result = generate(manifest, resolved, revision, args.assets_dir)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'SBOM generation failed: {error}\n')


if __name__ == '__main__':
    main()
