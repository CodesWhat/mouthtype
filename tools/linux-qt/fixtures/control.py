#!/usr/bin/env python3
"""Stand-in for control.py in the host tests: `state` returns a canned reply, every other verb an empty object."""
import json
import sys

STATE = {
    "running": True, "state": "idle", "recent": [], "saved": [], "has_transcript": False, "words_today": 128,
    "sounds": True, "autostart": False, "shortcut": "toggle", "shortcut_keys": "CTRL+ALT+M",
    "config": {"cleanup": "basic"}, "capabilities": {"file_transcription": True},
    "pill": {"enabled": True, "skin": "classic", "size": 1},
    "cleanup": {"models": {"fast": "prepared", "thorough": "absent"}, "setup": None, "service": None},
    "history": {"takes": 3, "maximum": 200}, "versions": {"plugin": "0.5.0", "app": "0.5.0"},
}

if len(sys.argv) > 1 and sys.argv[1] == "state":
    print(json.dumps(STATE))
else:
    print("{}")
