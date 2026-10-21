"""Transform Selection verbs for the panel, loaded by control.py. Each verb runs one `transform` CLI command.

Verbs return the CLI's JSON object unchanged (its `state` field says what happened: captured, ready, unavailable,
refused, requested, copied, timeout, cancelled, discarded, error). A verb raises RuntimeError only when the CLI could
not be run at all. The CLI is bounded and stops on SIGTERM; a call past its limit is terminated and then killed.
"""

import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import threading
import time

HOME = Path.home()
LAUNCHER = HOME / ".local/bin/mouthtype-linux"
CONFIG = HOME / ".local/share/mouthtype/speech-candidate/linux.json"

KINDS = ("clean-up", "fix-grammar", "make-shorter", "more-formal", "more-casual")
ID_PATTERN = re.compile(r"[0-9a-f]{32}")
# Seconds the CLI may run: a model load of 120 s plus up to 185 s of generation for the largest selection.
LIMITS = {"status": 10, "capture": 15, "run": 330, "accept": 50, "copy": 15, "cancel": 10}
GRACE = 5
# The floating panel watches this file. `transform-open` writes the capture reply here; it lives in the same private
# runtime directory as the captures themselves.
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()) / "mouthtype"
PANEL_REQUEST = "panel-transform.json"
ADDRESS_PATTERN = re.compile(r"0x[0-9a-f]{1,16}")


def invoke(action, arguments=(), stdin=None):
    argv = [str(LAUNCHER), "--config", str(CONFIG), "transform", action, *arguments]
    process = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
                               start_new_session=True)
    # The CLI runs in its own session, so a SIGTERM to this process (the panel's Cancel) would not reach it. Pass it on;
    # the CLI then stops its model worker and answers state "cancelled", which is returned below.
    previous = None
    if threading.current_thread() is threading.main_thread():
        previous = signal.signal(signal.SIGTERM, lambda *_: process.terminate())
    try:
        return finish(process, action, stdin)
    finally:
        if previous is not None:
            signal.signal(signal.SIGTERM, previous)


def finish(process, action, stdin):
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


def window_address(value):
    if not isinstance(value, str) or not ADDRESS_PATTERN.fullmatch(value):
        raise ValueError("Invalid window address")
    return value


def transform_open():
    """Capture the selection now and hand the reply to the floating panel through a private file.

    Bind this to a key. It must run before focus moves, so it captures first and the panel only reads the result.
    Every reply is written, failures included, so the panel can say what went wrong."""
    reply = transform_capture()
    request = dict(reply, opened_at=time.time())
    RUNTIME.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".panel-", dir=RUNTIME)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(request, stream, ensure_ascii=False)
        os.replace(temporary, RUNTIME / PANEL_REQUEST)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
    return {"state": reply.get("state"), "id": reply.get("id")}


def transform_focus(address):
    """Give keyboard focus back to the window the selection came from (Hyprland). Accept needs it first."""
    try:
        done = subprocess.run(["hyprctl", "dispatch", "focuswindow", "address:" + window_address(address)],
                              capture_output=True, text=True, timeout=3, check=False)
    except FileNotFoundError:
        raise RuntimeError("hyprctl was not found, so focus can't return to the app")
    except subprocess.TimeoutExpired:
        raise RuntimeError("Hyprland didn't answer")
    # `hyprctl dispatch` prints "ok" on success and an error message otherwise, with status 0 either way.
    if done.returncode != 0 or done.stdout.strip() != "ok":
        return {"state": "focus_failed", "message": (done.stdout or done.stderr).strip() or "Focus didn't move"}
    return {"state": "focused"}


COMMANDS = {
    "transform-open": transform_open,
    "transform-focus": transform_focus,
    "transform-status": transform_status,
    "transform-capture": transform_capture,
    "transform-run": transform_run,
    "transform-accept": transform_accept,
    "transform-copy": transform_copy,
    "transform-cancel": transform_cancel,
}
