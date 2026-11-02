"""`stats`: dictation statistics as JSON, rebuilt from the recovery directory. See stats.py for the rules."""

from pathlib import Path
import json
import sys

HERE = str(Path(__file__).resolve().parent)
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import stats


def register(subparsers):
    subparsers.add_parser('stats', help='Words, takes, speed, streaks, hours, today\'s tape and High scores as JSON')


def run(args, context):
    print(json.dumps(stats.compute(context.recovery)))
    return 0
