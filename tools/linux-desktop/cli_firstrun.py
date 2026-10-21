"""`firstrun`: set up the per-user pieces once after a package install. See firstrun.py for the rules."""

from pathlib import Path
import sys

HERE = str(Path(__file__).resolve().parent)
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import firstrun


def register(subparsers):
    subparsers.add_parser('firstrun', help='Run the one-time per-user setup if it has not been done (used by the login unit)')


def run(args, context):
    return firstrun.run_first()
