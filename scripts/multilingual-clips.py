"""Render the multilingual fixtures as speech with macOS `say`, for the engine smoke (docs/MAC-EVALUATIONS.md approach).

Usage: python3 -I scripts/multilingual-clips.py <out-dir> [--fixtures DIR] [--languages de,fr] [--ids de-short-1]

Writes <out-dir>/<id>.wav (16 kHz mono 16-bit), <out-dir>/<id>.txt (the fixture text, the WER reference) and
<out-dir>/manifest.json. Entries whose text is only punctuation-sensitive (French no-break space cases) are included too.
TTS is cleaner than real speech, so this proves wiring (which hint, which script comes back), not accuracy.
Run the clips through the engine worker with each hint, e.g.:
  swift run mouthtype-bench engine-worker --help
"""

import argparse
import json
import os
import subprocess
import sys

# language code -> first installed voice from this list. `say -v '?'` lists what the Mac has.
VOICES = {
    "en": ["Samantha"],
    "de": ["Anna"],
    "es": ["Mónica", "Paulina"],
    "fr": ["Thomas", "Amélie"],
    "it": ["Alice"],
    "pt": ["Luciana", "Joana"],
    "nl": ["Xander", "Ellen"],
    "pl": ["Zosia"],
    "cs": ["Zuzana"],
    "da": ["Sara"],
    "ru": ["Milena"],
    "uk": ["Lesya"],
    "el": ["Melina"],
}


def installed_voices() -> set[str]:
    out = subprocess.run(["say", "-v", "?"], check=True, capture_output=True, text=True).stdout
    names = set()
    for line in out.splitlines():
        head = line.split("  ")[0].strip()
        if head:
            names.add(head)
    return names


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    default_fixtures = os.path.join(here, "..", "Tests", "Fixtures", "multilingual")
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--fixtures", default=default_fixtures)
    parser.add_argument("--languages", help="comma-separated codes; default all fixtures")
    parser.add_argument("--ids", help="comma-separated fixture ids; default all")
    args = parser.parse_args()

    wanted_langs = set(args.languages.split(",")) if args.languages else None
    wanted_ids = set(args.ids.split(",")) if args.ids else None
    voices = installed_voices()
    os.makedirs(args.out, exist_ok=True)

    manifest = []
    skipped = []
    for name in sorted(os.listdir(args.fixtures)):
        if not name.endswith(".json"):
            continue
        code = name[: -len(".json")]
        if wanted_langs and code not in wanted_langs:
            continue
        voice = next((v for v in VOICES.get(code, []) if v in voices), None)
        with open(os.path.join(args.fixtures, name), encoding="utf-8") as f:
            entries = json.load(f)
        if voice is None:
            skipped.append(code)
            continue
        for entry in entries:
            if wanted_ids and entry["id"] not in wanted_ids:
                continue
            wav = os.path.join(args.out, entry["id"] + ".wav")
            subprocess.run(["say", "-v", voice, "-o", wav, "--data-format=LEI16@16000", entry["raw"]], check=True)
            with open(os.path.join(args.out, entry["id"] + ".txt"), "w", encoding="utf-8") as f:
                f.write(entry["raw"] + "\n")
            manifest.append({"id": entry["id"], "lang": code, "voice": voice, "text": entry["raw"]})

    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    print(f"{len(manifest)} clips in {args.out}")
    if skipped:
        print("no installed voice for: " + ", ".join(skipped), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
