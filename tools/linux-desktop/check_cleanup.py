"""Check portable formatting fixtures and command data against actual Core sources."""

import argparse
import hashlib
import json
from pathlib import Path
import tempfile

from setup_speech import bounded_run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write-table', action='store_true', help='Regenerate committed command data from Core')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    core = root / 'Sources/MouthtypeCore'
    records = (core / 'Store/DictationTypes.swift').read_text()
    start = records.index('public struct EditOp:')
    end = records.index('\npublic enum CorrectionKind:', start)
    with tempfile.TemporaryDirectory(prefix='mouthtype-cleanup-check-') as directory:
        temporary = Path(directory)
        record = temporary / 'EditOp.swift'
        record.write_text(records[start:end])
        binary = temporary / 'verify-cleanup'
        names = ['Text/TextScan.swift', 'Text/SpokenCommandTable.swift', 'Text/SpokenCommands.swift',
                 'Text/TextSpan.swift', 'Text/BlendStage.swift', 'Text/WhitespaceNormalizer.swift', 'TextMetrics.swift']
        sources = [core / name for name in names]
        bounded_run(['swiftc', '-o', str(binary), *map(str, sources), str(record),
                     str(root / 'tools/linux-desktop/verify_cleanup.swift')], 45)
        table = json.loads(bounded_run([str(binary), 'table'], 5))
        table['sourcesSHA256'] = {name: hashlib.sha256((core / name).read_bytes()).hexdigest() for name in names}
        path = root / 'tools/linux-desktop/cleanup-commands.json'
        if args.write_table:
            path.write_text(json.dumps(table, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
            print('Command data regenerated from actual Core sources')
            return
        assert json.loads(path.read_text()) == table, 'Portable command data is stale relative to Core'
        print(bounded_run([str(binary), str(root / 'tools/linux-desktop/cleanup-fixtures.json')], 5), end='')
        from cleanup import spoken_commands, whitespace
        inputs = []
        for entry in table['commands']:
            phrase = ' '.join(entry['words'])
            for before in ('', 'the ', 'add ', 'before ', 'one period ', 'bullet item '):
                for after in ('', ' next', ' Next', ', next', '\nnext', ' new line next'):
                    inputs.append(before + phrase + after)
        for word in ('iPhone', 'ßeta', 'éclair', 'Σίσυφος', 'e\u0301clair', 'ǅelta', 'ǆelta',
                     'ʰello', 'ᵃbc', 'ⅳ', '①', '१', '_test', 'İstanbul', '你好', '👩\u200d💻'):
            for phrase in ('new line', 'period', 'question mark', 'bullet', 'numbered list', 'new paragraph'):
                inputs.append('start ' + phrase + ' ' + word)
        probes = [{'name': 'differential-' + str(index), 'input': value, 'expected': '',
                   'stage': 'commandsWhitespace'} for index, value in enumerate(inputs)]
        probe = temporary / 'probes.json'
        probe.write_text(json.dumps(probes, ensure_ascii=False))
        observations = json.loads(bounded_run([str(binary), str(probe), '--emit'], 10))
        for case, actual in zip(probes, observations, strict=True):
            result = whitespace(spoken_commands(case['input']))
            assert result == actual['output'], (case['input'], result, actual['output'])
        print(f'Core command-context/Unicode differential checks: {len(probes)} passed')



if __name__ == '__main__':
    main()
