#!/usr/bin/env python3
"""Turns boost-eval results.json into the numbers for docs/evals/vocabulary-boosting-*.md.

Usage: python3 -I scripts/boost-eval-report.py /tmp/mouthtype-boost-eval/results.json [more.json ...]
"""
import json
import re
import statistics
import sys


def words(text):
    return [w for w in re.sub(r"[^a-z0-9' ]+", " ", text.lower()).split() if w]


def edit_distance(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        prev, row[0] = row[0], i
        for j, y in enumerate(b, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (x != y))
    return row[-1]


def wer(clips, texts):
    errors = sum(edit_distance(words(c["text"]), words(texts[c["file"]])) for c in clips)
    total = sum(len(words(c["text"])) for c in clips)
    return 100 * errors / total


def found(target, text):
    stripped = " ".join(re.sub(r"[^\w' -]+", " ", text).split())
    return re.search(r"(?<!\w)" + re.escape(target) + r"(?!\w)", stripped) is not None


def recall(clips, texts):
    hits = total = 0
    for c in clips:
        for t in c["targets"]:
            total += 1
            hits += found(t, texts[c["file"]])
    return hits, total


def report(path):
    r = json.load(open(path))
    clips = {c["file"]: c for c in r["manifest"]["clips"]}
    passes = {p["label"]: p for p in r["runs"]}
    base = passes["baseline"]
    names = [c for c in clips.values() if c["group"] == "names"]
    plain = [c for c in clips.values() if c["group"] == "plain"]
    print(f"== {path}")
    print(f"engine {r['engine']}, boost model load {r['boostModelSeconds']:.1f} s")
    print(f"footprint MB before {r['rssMBBeforeBoostModel']:.0f} after {r['rssMBAfterBoostModel']:.0f}"
          f" resident before {r.get('residentMBBeforeBoostModel', 0):.0f} after {r.get('residentMBAfterBoostModel', 0):.0f}"
          f" peak {r['peakMBAfterRuns']:.0f}")
    for voice in (None, "Samantha", "Daniel"):
        subset = [c for c in names if voice in (None, c["voice"])]
        h0, n = recall(subset, base["texts"])
        line = f"names recall {voice or 'all'}: off {h0}/{n} ({100*h0/n:.0f}%)"
        for label in ("names-targets", "names-targets-plus-distractors-50"):
            h, n = recall(subset, passes[label]["texts"])
            line += f", {label} {h}/{n} ({100*h/n:.0f}%)"
        print(line)
    for label in ("names-targets",):
        print(f"names WER: off {wer(names, base['texts']):.1f}% on {wer(names, passes[label]['texts']):.1f}%")
    distractors = set(d.lower() for d in r["manifest"]["distractors"])
    print(f"plain WER off {wer(plain, base['texts']):.1f}%")
    for size in (10, 50, 200):
        if f"plain-distractors-{size}" not in passes:
            continue
        p = passes[f"plain-distractors-{size}"]
        changed = [c for c in plain if p["texts"][c["file"]] != base["texts"][c["file"]]]
        inserted = sum(
            1 for c in plain for w in words(p["texts"][c["file"]]) if w in distractors and w not in words(base["texts"][c["file"]])
        )
        print(f"plain {size} terms: clips changed {len(changed)}/{len(plain)}, distractor words inserted {inserted}, WER {wer(plain, p['texts']):.1f}%")
        for c in changed if "--verbose" in sys.argv else []:
            print(f"   - {base['texts'][c['file']]!r} -> {p['texts'][c['file']]!r}")
    for label in ("names-targets", "plain-distractors-10", "plain-distractors-50", "plain-distractors-200"):
        if label not in passes:
            continue
        p = passes[label]
        deltas = [p["medianMs"][f] - base["medianMs"][f] for f in p["medianMs"]]
        print(f"added ms {label}: median {statistics.median(deltas):.0f}, p95 {sorted(deltas)[int(0.95 * (len(deltas) - 1))]:.0f}, max {max(deltas):.0f};"
              f" baseline median {statistics.median(base['medianMs'][f] for f in p['medianMs']):.0f}")
    miss = [(c["text"], base["texts"][c["file"]], passes["names-targets"]["texts"][c["file"]]) for c in names
            if any(not found(t, passes["names-targets"]["texts"][c["file"]]) for t in c["targets"])]
    print(f"names clips still missing a target with boosting on: {len(miss)}")
    for ref, off, on in miss[:12]:
        print(f"   ref {ref!r}\n     off {off!r}\n     on  {on!r}")


for p in [a for a in sys.argv[1:] if not a.startswith('--')]:
    report(p)
