"""Assess only real Arch speech inference, independently of cleanup or desktop support."""

import argparse
import json
import math
import os
from pathlib import Path
import sys


def assess(report, config, pins, fixtures, proof_exit):
    problems = []
    host = report.get('environment', {})
    if (report.get('execution_kind') != 'engine' or report.get('linux_runtime') is not True or
            host.get('system') != 'Linux' or host.get('architecture') != 'x86_64' or
            host.get('distribution', {}).get('ID') != 'arch'):
        problems.append('not-real-arch-speech')
    engine = report.get('engines', {}).get('speech', {})
    expected_hashes = {name: artifact['sha256'] for name, artifact in config['engines']['speech']['artifacts'].items()}
    if (set(report.get('engines', {})) != {'speech'} or engine.get('event') != 'ready' or
            engine.get('runtime') != 'sherpa-onnx ' + pins['sherpa']['version'] or
            engine.get('revision') != pins['sherpa']['revision'] or engine.get('artifacts') != expected_hashes or
            engine.get('provenance', {}).get('model', {}).get('sha256') != pins['parakeet']['sha256']):
        problems.append('missing-or-unpinned-speech-runtime')
    rows = report.get('results', [])
    expected = {case['id']: case['expected'] for case in fixtures}
    if len(fixtures) != 3 or sorted(row.get('id', '') for row in rows) != sorted(expected):
        problems.append('missing-duplicate-or-unexpected-cases')
    for row in rows:
        duration = row.get('duration_ms')
        if (row.get('task') != 'speech' or row.get('id') not in expected or
                row.get('expected') != expected.get(row.get('id')) or
                row.get('status') not in ('passed', 'mismatch') or not isinstance(row.get('actual'), str) or
                not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration < 0):
            problems.append('incomplete-or-altered-speech-result')
    if proof_exit not in (0, 1):
        problems.append('proof-command-failed')
    complete = not problems
    accurate = complete and proof_exit == 0 and all(
        row['status'] == 'passed' and row['actual'] == expected[row['id']] for row in rows)
    return {'speech_runtime_completed': complete, 'speech_accuracy_passed': accurate,
            'passed': sum(row.get('status') == 'passed' for row in rows), 'total': len(rows),
            'problems': problems, 'cleanup_tested': False, 'hyprland_acceptance': False,
            'omarchy_acceptance': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--proof-exit', type=int, required=True)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    config = json.loads(args.config.read_text())
    fixtures = json.loads(args.fixtures.read_text())
    pins = json.loads((Path(__file__).resolve().parents[1] / 'linux-engine-proof/pins.json').read_text())
    result = assess(report, config, pins, fixtures, args.proof_exit)
    remaining = []
    for pid in {row['worker_pid'] for row in report.get('results', []) if row.get('worker_pid')}:
        try:
            os.kill(pid, 0)
            remaining.append(pid)
        except ProcessLookupError:
            pass
    if remaining:
        result['problems'].append('owned-processes-remain')
        result['speech_runtime_completed'] = result['speech_accuracy_passed'] = False
    result['remaining_owned_pids'] = remaining
    print(json.dumps(result, indent=2))
    return 0 if result['speech_accuracy_passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
