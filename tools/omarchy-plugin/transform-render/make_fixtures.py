#!/usr/bin/env python3
"""Regenerate ../transform/fixtures/*.json. Each file is a scene: the control.py replies the panel would see, in order,
with diffs produced by the real backend (tools/linux-desktop/transform.py). test_transform_panel.py checks they still match.

Usage: python3 make_fixtures.py
"""

import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "linux-desktop"))
from transform import MAX_UNITS, diff_segments, units  # noqa: E402

OUT = HERE.parent / "transform" / "fixtures"
ID = "0123456789abcdef0123456789abcdef"
SLACK = {"class": "Slack", "name": "Slack", "pid": 4242, "address": "0x55d1c0a3b2f0"}

KINDS = (("clean-up", "Clean up", False), ("fix-grammar", "Fix grammar", True), ("make-shorter", "Make shorter", True),
         ("more-formal", "More formal", True), ("more-casual", "More casual", True))
MODEL_MISSING = ("AI transforms need the Thorough cleanup model, and its files are missing. Run setup_cleanup.py "
                 "--level thorough, then try again.")


def capture(text, app=SLACK):
    return {"state": "captured", "id": ID, "source": "primary", "fallback": False, "app": app, "text": text,
            "units": units(text), "expires_in": 600}


def status(ready=True):
    kinds = [{"id": key, "title": title, "description": "", "needs_model": model, "available": ready or not model,
              "reason": None if ready or not model else MODEL_MISSING} for key, title, model in KINDS]
    model = {"level": "thorough", "name": "Thorough", "state": "ready" if ready else "absent",
             "reason": None if ready else MODEL_MISSING}
    return {"state": "status", "interface": 1, "kinds": kinds, "model": model,
            "limits": {"source_units": MAX_UNITS, "diff_characters": 2000, "capture_seconds": 600}}


def ready(kind, original, text, message):
    title = dict((key, name) for key, name, _ in KINDS)[kind]
    return {"state": "ready", "id": ID, "kind": kind, "title": title, "model": kind != "clean-up", "text": text,
            "original": original, "changed": text != original, "diff": diff_segments(original, text), "app": SLACK,
            "source": "primary", "elapsed_ms": 420, "message": message}


BASIC = "Basic cleanup preview. Review it before accepting. Names and numbers are not rewritten."
SPOKEN = "um so the meeting is uh at three pm tomorrow. i think we should bring the report."
CLEANED = "So the meeting is at three pm tomorrow. I think we should bring the report."
DRAFT = "their going to send the the invoice tomorow, and me and Priya will review it before it goes out"
FIXED = "They're going to send the invoice tomorrow, and Priya and I will review it before it goes out."
LONG_IN = "um so we shipped the build uh on friday and the team was happy with it. " * 30
LONG_OUT = "So we shipped the build on friday and the team was happy with it. " * 30
REFUSED = ("The focused window changed since the selection was captured, so Mouthtype won't write into Slack. "
           "Copy the result instead.")

SCENES = {
    "normal": [
        {"op": "capture", "reply": capture(SPOKEN)}, {"op": "status", "reply": status()},
        {"op": "run", "reply": ready("clean-up", SPOKEN, CLEANED, BASIC)}],
    "ai-ready": [
        {"op": "capture", "reply": capture(DRAFT)}, {"op": "status", "reply": status()},
        {"op": "run", "reply": ready("clean-up", DRAFT, DRAFT, BASIC)},
        {"op": "start", "kind": "fix-grammar"},
        {"op": "run", "reply": ready("fix-grammar", DRAFT, FIXED,
                                     "Fix grammar preview from the local model. Review and edit it before accepting.")}],
    "ai-busy": [
        {"op": "capture", "reply": capture(DRAFT)}, {"op": "status", "reply": status()},
        {"op": "run", "reply": ready("clean-up", DRAFT, DRAFT, BASIC)},
        {"op": "start", "kind": "fix-grammar"}],
    "refused": [
        {"op": "capture", "reply": capture(SPOKEN)}, {"op": "status", "reply": status()},
        {"op": "run", "reply": ready("clean-up", SPOKEN, CLEANED, BASIC)},
        {"op": "accepting"},
        {"op": "accept", "reply": {"state": "refused", "id": ID, "reason": "window_changed", "message": REFUSED,
                                   "app": SLACK, "primary_action": "copy-result", "offer": ["copy-result"]}}],
    "model-missing": [
        {"op": "capture", "reply": capture(SPOKEN)}, {"op": "status", "reply": status(False)},
        {"op": "run", "reply": ready("clean-up", SPOKEN, CLEANED, BASIC)}],
    "over-cap": [
        {"op": "capture", "reply": capture(LONG_IN)}, {"op": "status", "reply": status()},
        {"op": "run", "reply": ready("clean-up", LONG_IN, LONG_OUT, BASIC)}],
    "accepted": [
        {"op": "capture", "reply": capture(SPOKEN)}, {"op": "status", "reply": status()},
        {"op": "run", "reply": ready("clean-up", SPOKEN, CLEANED, BASIC)},
        {"op": "accepting"},
        {"op": "accept", "reply": {"state": "requested", "id": ID, "app": SLACK, "outcome": "pasted",
                                   "message": "Replacement requested. Check the original field. To undo, press Ctrl-Z in "
                                              "that app, or copy the original text from here."}}],
    "capture-error": [
        {"op": "capture", "reply": {"state": "error", "error": "nothing_selected",
                                    "message": "Select up to 16,000 characters of text, then try again. Apps that don't "
                                               "set the primary selection need the text copied first."}}],
}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, steps in SCENES.items():
        (OUT / (name + ".json")).write_text(json.dumps({"name": name, "steps": steps}, indent=1, ensure_ascii=False) + "\n",
                                            encoding="utf-8")
    print("wrote %d scenes to %s" % (len(SCENES), OUT))


if __name__ == "__main__":
    main()
