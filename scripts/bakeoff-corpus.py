#!/usr/bin/env python3
"""Assembles the ASR bake-off corpus: one directory of audio files with same-basename .txt references.

Usage: python3 -I scripts/bakeoff-corpus.py OUT_DIR LIBRISPEECH_AND_SYNTH_DIR

Pulls together three sets, each prefixed so the bench report can group them:
  real-*       LibriSpeech test-clean utterances (copied from the bench corpus, usually bench-cache/corpus)
  synthetic-*  the bench corpus `say` clips, plus the daily-use fixture clips (clean, two noise levels, long)
  custom-*     the vocabulary clips from scripts/boost-eval-clips.py (tricky names and ordinary sentences)

Run with: mouthtype-bench run --engines parakeet-tdt-v3,parakeet-ultra,nemotron-unified --corpus OUT_DIR --english-hint
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    out = Path(sys.argv[1]).expanduser().resolve()
    bench_corpus = Path(sys.argv[2]).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=False)
    for audio in bench_corpus.iterdir():
        if audio.suffix in {".flac", ".aiff", ".wav", ".txt"}:
            shutil.copy2(audio, out / audio.name)
    with tempfile.TemporaryDirectory(prefix="bakeoff-") as scratch:
        daily = Path(scratch) / "daily"
        subprocess.run([sys.executable, "-I", str(ROOT / "scripts/evaluate-mac-daily-use.py"), "--output-dir", str(daily), "--prepare-only"], check=True)
        for path in (daily / "corpus").glob("synthetic-*"):
            if path.suffix in {".wav", ".txt"}:
                shutil.copy2(path, out / path.name)
        names = Path(scratch) / "names"
        subprocess.run([sys.executable, "-I", str(ROOT / "scripts/boost-eval-clips.py"), str(names)], check=True)
        manifest = json.loads((names / "manifest.json").read_text())
        for clip in manifest["clips"]:
            stem = "custom-" + Path(clip["file"]).stem
            shutil.copy2(names / clip["file"], out / (stem + ".wav"))
            (out / (stem + ".txt")).write_text(clip["text"] + "\n")
    print(f"{len(list(out.glob('*.txt')))} clips in {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
