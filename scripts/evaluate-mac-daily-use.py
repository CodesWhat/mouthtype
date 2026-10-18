#!/usr/bin/env python3
"""Build a synthetic local speech corpus and run the existing engine worker."""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import platform
import random
import subprocess
import sys
import wave

ROOT = Path(__file__).resolve().parents[1]


def add_noise(samples, snr_db, seed):
    if not samples or not math.isfinite(snr_db):
        raise ValueError("Noise requires nonempty audio and finite SNR")
    signal = math.sqrt(sum(value * value for value in samples) / len(samples))
    if signal == 0:
        raise ValueError("SNR is undefined for silent audio")
    generator = random.Random(seed)
    noise = [generator.gauss(0, 1) for _ in samples]
    noise_rms = math.sqrt(sum(value * value for value in noise) / len(noise))
    scale = signal / (10 ** (snr_db / 20)) / noise_rms
    mixed = []
    clipped = 0
    for sample, value in zip(samples, noise):
        raw = round(sample + value * scale)
        clipped += int(raw < -32768 or raw > 32767)
        mixed.append(max(-32768, min(32767, raw)))
    actual = math.sqrt(sum((a - b) ** 2 for a, b in zip(mixed, samples)) / len(samples))
    return mixed, {"requested_snr_db": snr_db,
                   "actual_snr_db": 20 * math.log10(signal / actual) if actual else None,
                   "clipped_samples": clipped, "seed": seed}


def read_pcm(path):
    with wave.open(str(path), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
            raise ValueError("Expected mono 16 kHz signed 16-bit PCM")
        samples = array("h", audio.readframes(audio.getnframes()))
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def write_pcm(path, samples):
    encoded = array("h", samples)
    if sys.byteorder != "little":
        encoded.byteswap()
    with wave.open(str(path), "wb") as audio:
        audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        audio.writeframes(encoded.tobytes())


def run(args, log, timeout):
    with log.open("w") as output:
        subprocess.run(args, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True, timeout=timeout)


def synthesize(text, name, corpus, voice, rate):
    reference = corpus / (name + ".txt")
    reference.write_text(text + "\n")
    intermediate = corpus / (name + ".aiff")
    run(["/usr/bin/say", "-v", voice, "-r", str(rate), "-o", str(intermediate), "-f", str(reference)],
        corpus / (name + "-speech.log"), 180)
    destination = corpus / (name + ".wav")
    run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(intermediate),
         "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(destination)],
        corpus / (name + "-conversion.log"), 60)
    intermediate.unlink()
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="Fresh directory for corpus, manifests and results")
    parser.add_argument("--bench-path", type=Path, help="Existing benchmark binary; otherwise build it here")
    parser.add_argument("--voice", default="Samantha")
    parser.add_argument("--rate", type=int, default=160)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--long-repeats", type=int, default=6)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    if min(args.rate, args.runs, args.long_repeats) < 1:
        parser.error("Rate, runs and long repeats must be positive")
    if platform.system() != "Darwin":
        parser.error("Speech synthesis requires macOS")
    output = args.output_dir.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False)
    corpus = output / "corpus"
    corpus.mkdir()
    fixture = json.loads((ROOT / "Tests/Fixtures/daily-use-speech.json").read_text())
    synthesize(fixture["short"], "synthetic-01-clean", corpus, args.voice, args.rate)
    long_text = " ".join([fixture["long_paragraph"]] * args.long_repeats + [fixture["closing_checkpoint"]])
    synthesize(long_text, "synthetic-04-long", corpus, args.voice, args.rate)
    samples = read_pcm(corpus / "synthetic-01-clean.wav")
    noise = {}
    for name, snr, seed in [("synthetic-02-noise20", 20, 41), ("synthetic-03-noise10", 10, 42)]:
        mixed, noise[name] = add_noise(samples, snr, seed)
        write_pcm(corpus / (name + ".wav"), mixed)
        (corpus / (name + ".txt")).write_text(fixture["short"] + "\n")
    clips = []
    for audio_path in sorted(corpus.glob("*.wav")):
        with wave.open(str(audio_path), "rb") as audio:
            seconds = audio.getnframes() / audio.getframerate()
        clips.append({"name": audio_path.stem, "seconds": seconds,
                      "audio_sha256": hashlib.sha256(audio_path.read_bytes()).hexdigest(),
                      "reference_sha256": hashlib.sha256(audio_path.with_suffix(".txt").read_bytes()).hexdigest()})
    manifest = {"source_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "macos": platform.mac_ver()[0], "python": platform.python_version(), "voice": args.voice,
                "words_per_minute": args.rate, "runs": args.runs, "warmups": 1, "language_hint": "english",
                "long_repeats": args.long_repeats, "closing_checkpoint": fixture["closing_checkpoint"],
                "noise": noise, "clips": clips,
                "scope": "Synthetic TTS and additive noise; recognition-only timings, no microphone or UI delivery acceptance"}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if not args.prepare_only:
        bench = args.bench_path
        if bench is None:
            run(["swift", "build", "--product", "mouthtype-bench"], output / "build.log", 600)
            products = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True, timeout=60).strip()
            bench = Path(products) / "mouthtype-bench"
        bench = bench.expanduser().resolve(strict=True)
        manifest["benchmark_sha256"] = hashlib.sha256(bench.read_bytes()).hexdigest()
        manifest["benchmark_built_here"] = args.bench_path is None
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        result = output / "recognition.json"
        run([str(bench), "engine-worker", "parakeet-tdt-v3", "--english-hint", "--mode", "full", "--corpus", str(corpus),
             "--runs", str(args.runs), "--warmups", "1", "--result", str(result)], output / "recognition.log", 600)
        report = json.loads(result.read_text())
        if report.get("error") or len(report.get("clips", [])) != len(clips):
            raise RuntimeError("Recognition evaluation failed; inspect recognition.json and recognition.log")
    print(output)


if __name__ == "__main__":
    main()
