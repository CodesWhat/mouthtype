#!/usr/bin/env python3
"""Fail a pull request that moves a Swift package pin backwards or touches Package.resolved outside a dependency change."""
import argparse
import json
import os
import re
import subprocess
import sys

RESOLVED = 'Package.resolved'
MANIFEST = 'Package.swift'
DEPENDENCY_BRANCH_PREFIXES = ('dependabot/', 'deps/')
DEPENDENCY_LABEL = 'dependencies'
DOWNGRADE_LABEL = 'downgrade'
SEMVER = re.compile(r'v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?')


def version_key(version):
    """Sort key following semver precedence; a release sorts above its own prereleases."""
    match = SEMVER.fullmatch(version)
    if not match:
        raise ValueError(f'Not a semantic version: {version}')
    core = tuple(int(part) for part in match.group(1, 2, 3))
    if match.group(4) is None:
        return core, (1,)
    identifiers = tuple((0, int(part), '') if part.isdigit() else (1, 0, part)
                        for part in match.group(4).split('.'))
    return core, (0, identifiers)


def pins(text):
    """Map each pin identity to its (version, revision); an absent file has no pins."""
    if text is None:
        return {}
    result = {}
    for pin in json.loads(text).get('pins', []):
        identity = pin['identity']
        if identity in result:
            raise ValueError(f'Duplicate pin in {RESOLVED}: {identity}')
        state = pin.get('state', {})
        result[identity] = (state.get('version'), state.get('revision'))
    return result


def describe(state):
    version, revision = state
    return f"{version or 'no version'} ({(revision or 'no revision')[:12]})"


def compare(old_text, new_text):
    """Return (changes, backwards): every pin difference, and those that move a pin backwards."""
    if old_text is None or old_text == new_text:
        return [], []
    old, new = pins(old_text), pins(new_text)
    changes, backwards = [], []
    for identity in sorted(old.keys() | new.keys()):
        before, after = old.get(identity), new.get(identity)
        if before == after:
            continue
        if before is None:
            changes.append(f'{identity}: added at {describe(after)}')
        elif after is None:
            changes.append(f'{identity}: removed, was {describe(before)}')
        else:
            line = f'{identity}: {describe(before)} -> {describe(after)}'
            changes.append(line)
            if before[0] and after[0]:
                if before[0] == after[0]:
                    backwards.append(f'{line} [revision changed under the same version]')
                elif version_key(after[0]) < version_key(before[0]):
                    backwards.append(f'{line} [downgrade]')
    if not changes:
        changes.append(f'{RESOLVED} changed without a pin change (originHash or formatting)')
    return changes, backwards


def is_dependency_change(manifest_changed, branch, labels):
    return (manifest_changed
            or branch.startswith(DEPENDENCY_BRANCH_PREFIXES)
            or DEPENDENCY_LABEL in labels)


def check(old_text, new_text, dependency_change, allow_downgrade):
    """Return the failure lines for this change; an empty list passes."""
    changes, backwards = compare(old_text, new_text)
    failures = []
    if backwards and not allow_downgrade:
        failures.append(f'{RESOLVED} moves a pin backwards. Restore the pin, or add the '
                        f'"{DOWNGRADE_LABEL}" label if the downgrade is intended:')
        failures.extend(f'  {line}' for line in backwards)
    if changes and not dependency_change:
        failures.append(f'{RESOLVED} changed in a pull request that is not a dependency change. '
                        f'Revert it, or change {MANIFEST}, use a dependabot/ or deps/ branch, '
                        f'or add the "{DEPENDENCY_LABEL}" label:')
        failures.extend(f'  {line}' for line in changes)
    return failures


def parse_labels(value):
    """Accept a JSON array of label names (GitHub's toJSON) or a comma-separated list."""
    value = (value or '').strip()
    if not value:
        return set()
    if value.startswith('['):
        return {str(label).strip().lower() for label in json.loads(value)}
    return {label.strip().lower() for label in value.split(',') if label.strip()}


def git(*arguments):
    return subprocess.run(['git', *arguments], check=True, capture_output=True, text=True).stdout


def show(revision, path):
    """Return the file's text at a revision, or None when it does not exist there."""
    if subprocess.run(['git', 'cat-file', '-e', f'{revision}:{path}'], capture_output=True).returncode:
        return None
    return git('show', f'{revision}:{path}')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default=os.environ.get('PACKAGE_RESOLVED_BASE'), help='base ref or commit of the pull request')
    parser.add_argument('--head', default='HEAD')
    parser.add_argument('--branch', default=os.environ.get('PACKAGE_RESOLVED_BRANCH', ''), help='pull request branch name')
    parser.add_argument('--labels', default=os.environ.get('PACKAGE_RESOLVED_LABELS', ''), help='label names as a JSON array or comma-separated list')
    parser.add_argument('--allow-downgrade', action='store_true', help='permit pins to move backwards in a dependency change')
    arguments = parser.parse_args(argv)
    if not arguments.base:
        parser.error('--base or PACKAGE_RESOLVED_BASE is required')
    labels = parse_labels(arguments.labels)
    base = git('merge-base', arguments.base, arguments.head).strip()
    manifest_changed = show(base, MANIFEST) != show(arguments.head, MANIFEST)
    failures = check(show(base, RESOLVED), show(arguments.head, RESOLVED),
                     is_dependency_change(manifest_changed, arguments.branch, labels),
                     arguments.allow_downgrade or DOWNGRADE_LABEL in labels)
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        return 1
    print(f'{RESOLVED} check passed against {base[:12]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
