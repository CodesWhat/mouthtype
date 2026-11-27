#!/usr/bin/env python3
"""Require a full-suite receipt line in a promotion PR body.

Hosted CI skips suites that need a free desktop, so the full `swift test` run happens locally once per promotion into main.
The PR body records it as: `Full suite receipt: <commit sha> <N> tests, 0 failures`. The commit must be the PR head or an
ancestor with only documentation changes (*.md files, docs/) between it and the head, N must be positive and failures must be zero.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

RECEIPT = re.compile(
    r'^\s*Full suite receipt:\s*([0-9a-f]{40})\s+([0-9][0-9,]*)\s+tests?,\s*([0-9]+)\s+failures?\s*$',
    re.IGNORECASE | re.MULTILINE)


def check(body, head, root):
    matches = RECEIPT.findall(body or '')
    if not matches:
        raise RuntimeError('Promotion PR body needs a line: "Full suite receipt: <commit sha> <N> tests, 0 failures"')
    sha, tests, failures = matches[-1]
    if int(tests.replace(',', '')) < 1:
        raise RuntimeError('Full suite receipt reports no tests')
    if int(failures) != 0:
        raise RuntimeError(f'Full suite receipt reports {failures} failures')
    ancestor = subprocess.run(['git', 'merge-base', '--is-ancestor', sha.lower(), head], cwd=root,
                              capture_output=True, text=True)
    if ancestor.returncode:
        raise RuntimeError(f'Full suite receipt commit {sha} is not the PR head or one of its ancestors')
    changed = subprocess.run(['git', 'diff', '--name-only', sha.lower(), head], cwd=root,
                             capture_output=True, text=True)
    if changed.returncode:
        raise RuntimeError(f'Could not diff full suite receipt commit {sha} against the PR head')
    code = [path for path in changed.stdout.splitlines() if not (path.endswith('.md') or path.startswith('docs/'))]
    if code:
        raise RuntimeError(f'Full suite receipt commit {sha} predates non-documentation changes: {", ".join(code[:5])}')
    return sha.lower()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--head', required=True, help='PR head commit')
    parser.add_argument('--body-env', default='PR_BODY', help='Environment variable holding the PR body')
    args = parser.parse_args()
    try:
        sha = check(os.environ.get(args.body_env, ''), args.head, Path(__file__).resolve().parent.parent)
    except RuntimeError as error:
        print(f'::error::{error}')
        sys.exit(1)
    print(f'Full suite receipt accepted for {sha}')


if __name__ == '__main__':
    main()
