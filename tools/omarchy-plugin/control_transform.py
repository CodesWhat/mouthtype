"""Transform Selection verbs for the panel, loaded by control.py. Each verb runs one `transform` CLI command.

Verbs return the CLI's JSON object unchanged (its `state` field says what happened: captured, ready, unavailable,
refused, requested, copied, timeout, cancelled, discarded, error). A verb raises RuntimeError only when the CLI could
not be run at all. The CLI is bounded and stops on SIGTERM; a call past its limit is terminated and then killed.
"""

import json
from pathlib import Path
import re
import subprocess

HOME = Path.home()
LAUNCHER = HOME / ".local/bin/mouthtype-linux"
CONFIG = HOME / ".local/share/mouthtype/speech-candidate/linux.json"

KINDS = ("clean-up", "fix-grammar", "make-shorter", "more-formal", "more-casual")
ID_PATTERN = re.compile(r"[0-9a-f]{32}")
# Seconds the CLI may run: a model load of 120 s plus up to 185 s of generation for the largest selection.
LIMITS = {"status": 10, "capture": 15, "run": 330, "accept": 50, "copy": 15, "cancel": 10}
GRACE = 5


def invoke(action, arguments=(), stdin=None):
    argv = [str(LAUNCHER), "--config", str(CONFIG), "transform", action, *arguments]
    process = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(stdin, timeout=LIMITS[action] + GRACE)
    except subprocess.TimeoutExpired:
        # SIGTERM lets the CLI cancel its model worker; SIGKILL is the backstop.
        process.terminate()
        try:
            process.communicate(timeout=GRACE)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
        raise RuntimeError("Transform Selection took too long")
    try:
        result = json.loads(stdout)
    except ValueError:
        result = None
    if not isinstance(result, dict):
        try:
            message = json.loads(stderr).get("error")
        except (ValueError, AttributeError):
            message = None
        raise RuntimeError(message or "Transform Selection is unavailable")
    return result


def identity(value):
    if not isinstance(value, str) or not ID_PATTERN.fullmatch(value):
        raise ValueError("Invalid transform id")
    return value


def transform_status():
    return invoke("status")


def transform_capture():
    return invoke("capture")


def transform_run(capture_id, kind):
    if kind not in KINDS:
        raise ValueError("Unknown transform")
    return invoke("run", [identity(capture_id), kind])


def transform_accept(capture_id, edited=None):
    """Replace the selection. `edited` is the user's edited result; without it the stored result is used."""
    if edited is None:
        return invoke("accept", [identity(capture_id)])
    return invoke("accept", [identity(capture_id), "--stdin"], stdin=edited)


def transform_copy(capture_id, which="result", edited=None):
    if which not in ("result", "original"):
        raise ValueError("Copy result or original")
    arguments = [identity(capture_id)]
    if which == "original":
        arguments.append("--original")
        edited = None
    if edited is not None:
        arguments.append("--stdin")
    return invoke("copy", arguments, stdin=edited)


def transform_cancel(capture_id=None):
    return invoke("cancel", [] if capture_id is None else [identity(capture_id)])


COMMANDS = {
    "transform-status": transform_status,
    "transform-capture": transform_capture,
    "transform-run": transform_run,
    "transform-accept": transform_accept,
    "transform-copy": transform_copy,
    "transform-cancel": transform_cancel,
}
