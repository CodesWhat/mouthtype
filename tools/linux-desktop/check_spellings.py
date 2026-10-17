"""Compare shared spelling fixtures with the real Core matcher in a full repository checkout."""

from pathlib import Path
import tempfile
import unicodedata

from setup_speech import bounded_run


def main():
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix='mouthtype-spellings-check-') as directory:
        binary = Path(directory) / 'verify-spellings'
        bounded_run(['swiftc', '-o', str(binary),
                     str(root / 'Sources/MouthtypeCore/Text/TextScan.swift'),
                     str(root / 'Sources/MouthtypeCore/Text/PhraseMatcher.swift'),
                     str(root / 'tools/linux-desktop/verify_spellings.swift')], 45)
        print(bounded_run([str(binary), str(root / 'tools/linux-desktop/spelling-fixtures.json')], 5), end='')
    print('Python lowercase database: Unicode ' + unicodedata.unidata_version)


if __name__ == '__main__':
    main()
