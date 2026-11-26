#!/usr/bin/env python3
"""Fail when a published version string disagrees with packaging/Version.plist."""
import json
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parent.parent


def problems(root):
    with (root / 'packaging/Version.plist').open('rb') as file:
        plist = plistlib.load(file)
    version = plist['MouthtypeDisplayVersion']
    build = plist['CFBundleVersion']
    found = []

    def read(relative):
        return (root / relative).read_text()

    def expect(relative, ok, message):
        if not ok:
            found.append(f'{relative}: {message}')

    expect('packaging/Version.plist', plist['CFBundleShortVersionString'] == version,
           f'CFBundleShortVersionString must equal MouthtypeDisplayVersion {version}')
    expect('website/package.json', json.loads(read('website/package.json')).get('version') == version,
           f'version must be {version}')
    expect('README.md', f'badge/version-{version}-' in read('README.md'),
           f'version badge must say {version}')
    changelog = re.search(r'^## \[(?!Unreleased)([^\]]+)\]', read('CHANGELOG.md'), re.M)
    expect('CHANGELOG.md', bool(changelog) and changelog.group(1) == version,
           f'newest released section must be {version}')
    readiness = read('docs/RELEASE-READINESS.md')
    expect('docs/RELEASE-READINESS.md', readiness.startswith(f'# Mac {version} release readiness'),
           f'title must be "Mac {version} release readiness"')
    expect('docs/RELEASE-READINESS.md', f'Stable {version} (build {build})' in readiness,
           f'needs a "Stable {version} (build {build})" entry')
    expect('docs/READ-ME.md', read('docs/READ-ME.md').startswith(f'# Mouthtype {version}\n'),
           f'title must be "Mouthtype {version}"')
    expect('docs/KNOWN-LIMITS.md', read('docs/KNOWN-LIMITS.md').startswith(f'# Known limits for {version}\n'),
           f'title must be "Known limits for {version}"')
    routes = {item['src']: item['headers'].get('Location', '')
              for item in json.loads(read('website/vercel.json')).get('routes', []) if 'headers' in item}
    for source in ('/download/file', '/source'):
        expect('website/vercel.json', f'/releases/{version}/' in routes.get(source, ''),
               f'{source} must point into /releases/{version}/')
    return found


def main():
    found = problems(ROOT)
    for line in found:
        print(f'::error::{line}')
    if found:
        sys.exit(1)
    print('version strings agree with packaging/Version.plist')


if __name__ == '__main__':
    main()
