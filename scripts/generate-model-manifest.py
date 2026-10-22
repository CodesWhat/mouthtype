#!/usr/bin/env python3
"""Regenerate Sources/MouthtypeCore/Resources/ModelManifest.json from the Hugging Face tree API.

Run after bumping a pin in Sources/MouthtypeCore/ModelPins.swift:

    python3 -I scripts/generate-model-manifest.py

For each pinned repo it lists the tree at the pinned commit and keeps the files FluidAudio 0.17.7 downloads
for the model we load (ModelHub.download with repoIncludeRule and getRequiredModelNames): every file under a
required .mlmodelc bundle, plus the repo's root-level .json and .txt files. Each entry records the size and the
content id the Hub publishes, which is the LFS sha256 or, for plain files, the git blob sha1.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PINS = ROOT / "Sources/MouthtypeCore/ModelPins.swift"
OUT = ROOT / "Sources/MouthtypeCore/Resources/ModelManifest.json"

# Pin name in ModelPins.swift -> required bundles. WhisperKit isn't listed: it downloads through the Hub client,
# which already verifies and reuses cached files.
REQUIRED = {
    "parakeetV3": ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"],
    "parakeetV2": ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc"],
    "ctc110m": ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"],
    "sileroVAD": ["silero-vad-unified-256ms-v6.2.1.mlmodelc"],
}


def read_pins():
    text = PINS.read_text()
    found = {}
    for name, repo, revision in re.findall(r'static let (\w+) = Pin\(repo: "([^"]+)", revision: "([0-9a-f]{40})"\)', text):
        found[name] = (repo, revision)
    return found


def fetch_tree(repo, revision):
    url = f"https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=1"
    entries = []
    while url:
        with urllib.request.urlopen(url, timeout=60) as response:
            entries += json.load(response)
            link = response.headers.get("Link", "")
        match = re.search(r'<([^>]+)>;\s*rel="next"', link)
        url = match.group(1) if match else None
    return entries


def wanted(path, bundles):
    if "/" not in path:
        return path.endswith(".json") or path.endswith(".txt")
    return any(path.startswith(bundle + "/") for bundle in bundles)


def main():
    pins = read_pins()
    manifest = {"schema": 1, "repos": {}}
    for name, bundles in REQUIRED.items():
        if name not in pins:
            sys.exit(f"ModelPins.swift has no pin named {name}")
        repo, revision = pins[name]
        files = []
        for entry in fetch_tree(repo, revision):
            if entry["type"] != "file" or not wanted(entry["path"], bundles):
                continue
            record = {"path": entry["path"], "size": entry["size"]}
            if "lfs" in entry:
                record["sha256"] = entry["lfs"]["oid"]
            else:
                record["blob"] = entry["oid"]
            files.append(record)
        files.sort(key=lambda f: f["path"])
        missing = [b for b in bundles if not any(f["path"].startswith(b + "/") for f in files)]
        if missing:
            sys.exit(f"{repo}@{revision} has no files under {missing}")
        manifest["repos"][repo] = {"revision": revision, "files": files}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}: " + ", ".join(f"{r} {len(v['files'])} files" for r, v in manifest["repos"].items()))


if __name__ == "__main__":
    main()
