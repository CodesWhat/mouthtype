"""Verify already-downloaded official artifacts and write a private proof config."""

import argparse
import hashlib
import json
from pathlib import Path
import sys
import tarfile

from proof import digest


PINS = json.loads(Path(__file__).with_name("pins.json").read_text())
SPEECH_ENTRIES = {"encoder": "encoder.int8.onnx", "decoder": "decoder.int8.onnx",
                  "joiner": "joiner.int8.onnx", "vocabulary": "tokens.txt"}


def prepare_settings(archive, speech_dir, s1, server, *, pins=None, speech_entries=None):
    pins = pins or PINS
    entries = speech_entries or SPEECH_ENTRIES
    engines = {}
    if archive is not None:
        if digest(archive) != pins["parakeet"]["sha256"]:
            raise ValueError("Parakeet archive SHA-256 mismatch")
        artifacts = {}
        prefix = pins["parakeet"]["archive"].removesuffix(".tar.bz2")
        with tarfile.open(archive, "r:bz2") as source:
            for name, filename in entries.items():
                member = source.getmember(prefix + "/" + filename)
                if not member.isfile():
                    raise ValueError("Expected a regular Parakeet model artifact")
                model = Path(speech_dir) / filename
                actual = digest(model)
                expected = hashlib.sha256()
                with source.extractfile(member) as content:
                    for chunk in iter(lambda: content.read(1024 * 1024), b""):
                        expected.update(chunk)
                if actual != expected.hexdigest():
                    raise ValueError(f"Extracted Parakeet {name} SHA-256 mismatch")
                artifacts[name] = {"path": str(model.resolve()), "sha256": actual}
        engines["speech"] = {"threads": 2, "artifacts": artifacts,
                             "provenance": {"model": pins["parakeet"], "runtime": pins["sherpa"]}}
    if s1 is not None:
        if digest(s1) != pins["s1"]["sha256"]:
            raise ValueError("S1-mini GGUF SHA-256 mismatch")
        engines["cleanup"] = {"threads": 2, "server": str(Path(server).resolve()),
                              "artifacts": {name: {"path": str(Path(path).resolve()), "sha256": digest(path)}
                                            for name, path in (("model", s1), ("server", server))},
                              "provenance": {"model": pins["s1"], "runtime": pins["llama"]}}
    if not engines:
        raise ValueError("Supply speech or cleanup artifacts")
    return {"schema": 1, "engines": engines}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parakeet-archive", type=Path)
    parser.add_argument("--parakeet-dir", type=Path)
    parser.add_argument("--s1", type=Path)
    parser.add_argument("--server", type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New private config file")
    args = parser.parse_args()
    if bool(args.parakeet_archive) != bool(args.parakeet_dir) or bool(args.s1) != bool(args.server):
        parser.error("Supply both Parakeet archive/directory or both S1/server paths")
    try:
        result = prepare_settings(args.parakeet_archive, args.parakeet_dir, args.s1, args.server)
        with args.output.open("x") as destination:
            json.dump(result, destination, indent=2)
            destination.write("\n")
        print(f"Verified local artifacts. Private config: {args.output}")
        return 0
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        print(f"Preparation failed: {type(error).__name__}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
