"""Compare portable phrase fixtures with the actual Core stage, without starting the app."""

from pathlib import Path
import tempfile

from setup_speech import bounded_run


def main():
    root = Path(__file__).resolve().parents[2]
    core = root / 'Sources/MouthtypeCore'
    # Copy the exact edit record definition; its owning file also imports GRDB.
    # All matching, expansion, span rewriting and metrics use the unchanged Core source files.
    records = (core / 'Store/DictationTypes.swift').read_text()
    start = records.index('public struct EditOp:')
    end = records.index('\npublic enum CorrectionKind:', start)
    with tempfile.TemporaryDirectory(prefix='mouthtype-phrases-check-') as directory:
        temporary = Path(directory)
        record = temporary / 'EditOp.swift'
        record.write_text(records[start:end])
        binary = temporary / 'verify-phrases'
        sources = [core / 'Text/TextScan.swift', core / 'Text/PhraseMatcher.swift',
                   core / 'Text/SnippetExpander.swift', core / 'Text/TextSpan.swift', core / 'TextMetrics.swift',
                   record, root / 'tools/linux-desktop/verify_phrases.swift']
        bounded_run(['swiftc', '-o', str(binary), *map(str, sources)], 45)
        print(bounded_run([str(binary), str(root / 'tools/linux-desktop/phrase-fixtures.json')], 5), end='')


if __name__ == '__main__':
    main()
