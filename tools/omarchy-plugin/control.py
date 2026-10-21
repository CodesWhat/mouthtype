#!/usr/bin/env python3
"""Small JSON bridge between the Omarchy panel and Mouthtype's local CLI."""

import fcntl
import importlib.util
import inspect
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


HOME = Path.home()
LAUNCHER = HOME / ".local/bin/mouthtype-linux"
CONFIG = HOME / ".local/share/mouthtype/speech-candidate/linux.json"
RECOVERY = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "mouthtype/recovery"
LOG = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "mouthtype/omarchy-control.log"
PREFS = HOME / ".config/mouthtype/omarchy-plugin.json"
UNIT = HOME / ".config/systemd/user/mouthtype-linux.service"
BINDINGS = HOME / ".config/hypr/bindings.lua"
BIND_BEGIN = "-- Mouthtype Omarchy plugin shortcut: begin"
BIND_END = "-- Mouthtype Omarchy plugin shortcut: end"
DESKTOP = HOME / ".local/lib/mouthtype-linux/tools/linux-desktop"
ASSETS = Path(__file__).resolve().parent / "assets"
SAVE_DIALOG = Path(__file__).resolve().parent / "save_dialog.py"
CLEANUP_DIR = HOME / ".local/share/mouthtype/cleanup-candidate"
CLEANUP_LOG = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "mouthtype/cleanup-setup.log"
SETUP_PID = LOG.parent / "cleanup-setup.pid"
PLUGIN_DIR = Path(__file__).resolve().parent
CLEANUP_SIZES = {"fast": "about 480 MB", "thorough": "about 2.5 GB"}

IMPORT_ACTIVE = ("preparing", "transcribing", "cancelling")

IMPORT_MESSAGES = {
    "busy": "Finish or cancel the current file transcription first.",
    "session_active": "Finish dictation or recovery before transcribing a file.",
    "file_import_active": "Wait for the file transcription to finish or cancel it.",
    "empty": "The file contains no audio.",
    "unsupported_format": "Choose a WAV, AIFF or M4A audio file.",
    "too_long": "Choose an audio file no longer than 10 minutes.",
    "too_large": "Choose an audio file no larger than 512 MB.",
    "invalid_audio": "The audio file could not be read. Your original is unchanged.",
    "decoder_unavailable": "Install ffmpeg to transcribe audio files.",
    "decoder_timeout": "Decoding took too long. Your original is unchanged.",
    "transcription_failed": "Transcription failed. Your original file is unchanged.",
    "cannot_replace_source": "Choose a different name. The original audio file is preserved.",
    "destination_exists": "That file already exists.",
    "invalid_destination": "Choose a regular file location for the text.",
    "no_result": "No file transcript is available.",
}


SESSION_MESSAGES = {
    "recovery_full": "Dictation history is full. Forget older dictations in Dictation History, or raise the limit in Recording Settings.",
    "capture_unavailable": "The microphone could not be opened. Check PipeWire and pw-record.",
    "capture_interrupted": "The microphone stopped during the take. Audio was saved for retry.",
    "recording_limit": "The take hit the recording limit and was saved for retry.",
    "transcription_failed": "Speech recognition failed. Audio was saved; retry from Saved Recordings.",
    "dictionary_unavailable": "The saved spellings file is missing or invalid.",
    "phrases_unavailable": "The saved phrases file is missing or invalid.",
    "phrase_context_unavailable": "A phrase needs the clipboard, which could not be read.",
    "cleanup_unavailable": "The cleanup setting is invalid.",
    "command_expired": "The start request arrived too late; try again.",
    "file_import_active": "Wait for the file transcription to finish or cancel it.",
}


def cli(*args, timeout=35):
    return subprocess.run(
        [str(LAUNCHER), "--config", str(CONFIG), *args],
        text=True, capture_output=True, timeout=timeout, check=False,
    )


def cli_error(result):
    try:
        return json.loads(result.stderr).get("error")
    except (json.JSONDecodeError, AttributeError):
        return None


def capabilities():
    if not LAUNCHER.is_file():
        return {}
    try:
        result = cli("capabilities", timeout=10)
        report = json.loads(result.stdout) if result.returncode == 0 else {}
    except (OSError, json.JSONDecodeError, subprocess.SubprocessError):
        report = {}
    return report if isinstance(report, dict) else {}


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".mouthtype-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(value, output, indent=2)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


FONT_PRESETS = ("default", "sans", "serif", "mono", "custom")
FONT_ROLES = ("menu", "transcript", "pill")


def preferences():
    value = {}
    if PREFS.is_file():
        try:
            value = json.loads(PREFS.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            value = {}
    if not isinstance(value, dict):
        value = {}
    pill = value.get("pill") if isinstance(value.get("pill"), dict) else {}
    font = value.get("font") if isinstance(value.get("font"), dict) else {}
    overrides = font.get("overrides") if isinstance(font.get("overrides"), dict) else {}
    return {
        "sounds": value.get("sounds") is True,
        "pill": {"enabled": pill.get("enabled") is not False,
                 "skin": "hifi" if pill.get("skin") == "hifi" else "classic",
                 "size": 2 if pill.get("size") == 2 else 1},
        "font": {"preset": font.get("preset") if font.get("preset") in FONT_PRESETS else "default",
                 "family": font.get("family") if isinstance(font.get("family"), str) else "",
                 "overrides": {role: overrides.get(role) if isinstance(overrides.get(role), str) else ""
                               for role in FONT_ROLES}},
    }


def valid_family(value):
    value = (value or "").strip()
    if len(value) > 80 or any(ord(c) < 32 for c in value):
        raise RuntimeError("Enter a font family name")
    return value


def set_pill(field, value):
    prefs = preferences()
    if field == "enabled" and value in {"on", "off"}:
        prefs["pill"]["enabled"] = value == "on"
    elif field == "skin" and value in {"classic", "hifi"}:
        prefs["pill"]["skin"] = value
    elif field == "size" and value in {"1", "2"}:
        prefs["pill"]["size"] = int(value)
    else:
        raise RuntimeError("Unsupported pill setting")
    atomic_json(PREFS, prefs)
    output = state()
    output["page"] = "pill"
    return output


def set_font(field, value, extra=None):
    prefs = preferences()
    if field == "preset" and value in FONT_PRESETS:
        prefs["font"]["preset"] = value
    elif field == "family":
        prefs["font"]["family"] = valid_family(value)
        prefs["font"]["preset"] = "custom" if prefs["font"]["family"] else "default"
    elif field == "override" and value in FONT_ROLES:
        prefs["font"]["overrides"][value] = "" if extra in (None, "-", "") else valid_family(extra)
    else:
        raise RuntimeError("Unsupported font setting")
    atomic_json(PREFS, prefs)
    output = state()
    output["page"] = "fonts"
    return output


def cleanup_models():
    """Which model levels are prepared on disk, plus any running setup progress. Nothing is loaded."""
    engines = {}
    path = CLEANUP_DIR / "cleanup.json"
    if path.is_file():
        try:
            engines = json.loads(path.read_text(encoding="utf-8")).get("engines", {})
        except (OSError, json.JSONDecodeError):
            engines = {}
    models = {}
    for level in ("fast", "thorough"):
        entry = engines.get(level) if isinstance(engines, dict) else None
        prepared = isinstance(entry, dict) and all(
            Path(item.get("path", "")).is_file() for item in (entry.get("artifacts") or {}).values())
        models[level] = "prepared" if prepared else "absent"
    progress = None
    progress_path = CLEANUP_DIR / "cleanup-setup.json"
    if progress_path.is_file():
        try:
            progress = json.loads(progress_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            progress = None
    if isinstance(progress, dict) and progress.get("state") in ("preparing", "building", "downloading"):
        if time.time() - float(progress.get("updated", 0)) > 3 * 3600 or not setup_running():
            progress = {"state": "failed", "error": "interrupted", "levels": progress.get("levels", [])}
    return {"models": models, "setup": progress, "path": str(path)}


def process_start(pid):
    """Start time of a process in clock ticks since boot, or None when it is gone or /proc is unreadable."""
    try:
        stat = Path(f"/proc/{int(pid)}/stat").read_text(encoding="utf-8")
        return int(stat[stat.rindex(")") + 2:].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def process_command(pid):
    try:
        return Path(f"/proc/{int(pid)}/cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace")
    except (OSError, ValueError):
        return ""


def setup_running():
    """Whether the cleanup setup this plugin started is still alive, judged from the pidfile it wrote.

    The pid alone can be reused by an unrelated process, so the start time and command line must match too."""
    try:
        recorded = json.loads(SETUP_PID.read_text(encoding="utf-8"))
        pid, started = recorded["pid"], recorded["start"]
    except (OSError, ValueError, KeyError, TypeError):
        return False
    if not (isinstance(pid, int) and isinstance(started, int)) or isinstance(pid, bool):
        return False
    return process_start(pid) == started and "setup_cleanup.py" in process_command(pid)


def config_summary():
    config = json.loads(CONFIG.read_text(encoding="utf-8"))
    delivery = config.get("delivery", {"mode": "recover"})
    return {
        "cleanup": config.get("cleanup", "off"),
        "maximum_recovery_takes": config.get("maximum_recovery_takes", 200),
        "audio_retention_days": config.get("audio_retention_days", 90),
        "history_keep": config.get("history_keep"),
        "notifications": config.get("notifications", True),
        "maximum_recording_seconds": config.get("maximum_recording_seconds", 60),
        "delivery_mode": delivery.get("mode", "recover"),
        "allowed_classes": delivery.get("allowed_classes", []),
    }


MODIFIER_MASKS = {"SHIFT": 1, "CTRL": 4, "ALT": 8, "SUPER": 64}
MODIFIER_ALIASES = {"CONTROL": "CTRL", "META": "SUPER", "WIN": "SUPER", "MOD4": "SUPER", "OPTION": "ALT", "MOD1": "ALT"}
NAMED_KEYS = {
    "space", "Return", "Tab", "BackSpace", "Delete", "Insert", "Home", "End", "Page_Up", "Page_Down", "Print", "Pause",
    "Scroll_Lock", "Menu", "Up", "Down", "Left", "Right", "grave", "minus", "equal", "bracketleft", "bracketright",
    "semicolon", "apostrophe", "comma", "period", "slash", "backslash", "Caps_Lock", "Escape",
}
NAMED_LOOKUP = {name.lower(): name for name in NAMED_KEYS}
# A modifier key on its own is a valid Hyprland key; its own modifier must be in the mask, as the Hyprland docs bind Super_L.
MODIFIER_KEYSYMS = {"Control_L": "CTRL", "Control_R": "CTRL", "Shift_L": "SHIFT", "Shift_R": "SHIFT",
                    "Alt_L": "ALT", "Alt_R": "ALT", "Super_L": "SUPER", "Super_R": "SUPER"}
MODIFIER_KEYSYM_LOOKUP = {name.lower(): name for name in MODIFIER_KEYSYMS}
DEFAULT_SHORTCUTS = {"toggle": "SUPER + ALT + M", "hold": "F10"}


def parse_shortcut(spec):
    """Normalize a Hyprland key spec such as 'super+shift+d' to 'SUPER + SHIFT + D' plus its modifier mask and key."""
    parts = [part.strip() for part in str(spec or "").replace("-", "+").split("+")]
    parts = [part for part in parts if part]
    if not parts or len(parts) > 5:
        raise RuntimeError("Enter a key with optional SUPER, ALT, CTRL or SHIFT modifiers")
    modifiers, key = [], parts[-1]
    for part in parts[:-1]:
        name = MODIFIER_ALIASES.get(part.upper(), part.upper())
        if name not in MODIFIER_MASKS or name in modifiers:
            raise RuntimeError("Modifiers must be SUPER, ALT, CTRL or SHIFT, each once")
        modifiers.append(name)
    if re.fullmatch(r"[A-Za-z0-9]", key):
        key = key.upper()
    elif re.fullmatch(r"[Ff]([1-9]|1[0-9]|2[0-4])", key):
        key = key.upper()
    elif key.lower() in NAMED_LOOKUP:
        key = NAMED_LOOKUP[key.lower()]
    elif key.lower() in MODIFIER_KEYSYM_LOOKUP:
        key = MODIFIER_KEYSYM_LOOKUP[key.lower()]
        if MODIFIER_KEYSYMS[key] not in modifiers:
            modifiers.append(MODIFIER_KEYSYMS[key])
    elif re.fullmatch(r"code:[0-9]{1,3}", key.lower()):
        key = key.lower()
    elif re.fullmatch(r"XF86[A-Za-z0-9]{1,40}", key):
        pass
    else:
        raise RuntimeError("Unsupported key; use a letter, digit, F-key, a named key such as Insert, or a modifier key such as Control_R")
    order = [name for name in ("SUPER", "ALT", "CTRL", "SHIFT") if name in modifiers]
    mask = sum(MODIFIER_MASKS[name] for name in order)
    return " + ".join(order + [key]), mask, key


def shortcut_block():
    if not BINDINGS.is_file():
        return None
    contents = BINDINGS.read_text(encoding="utf-8")
    if BIND_BEGIN not in contents or BIND_END not in contents:
        return None
    return contents.split(BIND_BEGIN, 1)[1].split(BIND_END, 1)[0]


def shortcut_info():
    block = shortcut_block()
    if block is None:
        return {"mode": "off", "keys": ""}
    match = re.search(r'bind\("([^"]+)"', block)
    keys = match.group(1) if match else ""
    return {"mode": "hold" if "release = true" in block else "toggle", "keys": keys}


def shortcut_mode():
    return shortcut_info()["mode"]


def words_today(entries=None):
    today = time.localtime().tm_yday
    year = time.localtime().tm_year
    total = 0
    for entry in entries if entries is not None else recent_dictations(limit=None):
        if not entry["transcript"]:
            continue
        stamp = time.localtime(entry["mtime"])
        if stamp.tm_yday == today and stamp.tm_year == year:
            transcript = RECOVERY / entry["id"] / "transcript.txt"
            total += len(transcript.read_text(encoding="utf-8").split())
    return total


def recent_dictations(limit=5):
    if not RECOVERY.is_dir():
        return []
    takes = [p for p in RECOVERY.iterdir()
             if p.is_dir() and not p.is_symlink() and len(p.name) == 32
             and all(c in "0123456789abcdef" for c in p.name)]
    recent = []
    for path in sorted(takes, key=lambda p: p.stat().st_mtime, reverse=True)[:limit]:
        transcript = path / "transcript.txt"
        preview = ""
        if transcript.is_file():
            preview = " ".join(transcript.read_text(encoding="utf-8").split())[:36]
        recent.append({"id": path.name, "transcript": transcript.is_file(),
                       "audio": (path / "recording.wav").is_file(),
                       "preview": preview, "mtime": path.stat().st_mtime})
    return recent


def versions():
    """Plugin and app versions. install.py writes version.json beside the plugin; a source checkout falls back to manifest.json."""
    found = {"plugin": None, "app": None}
    for name in ("version.json", "manifest.json"):
        try:
            data = json.loads((PLUGIN_DIR / name).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        for key, field in (("plugin", "plugin" if name == "version.json" else "version"), ("app", "app")):
            if found[key] is None and isinstance(data.get(field), str):
                found[key] = data[field]
    return found


def state():
    if not LAUNCHER.is_file() or not CONFIG.is_file():
        return {"running": False, "state": "unavailable", "error": "Mouthtype installation is missing"}
    result = cli("status", timeout=5)
    try:
        status = json.loads(result.stdout)
    except json.JSONDecodeError:
        status = {}
    running = result.returncode == 0 and status.get("error") != "unavailable"
    entries = recent_dictations(limit=None)
    transcripts = [entry for entry in entries if entry["transcript"]]
    report = capabilities()
    file_import = status.get("file_import") if running else None
    if not isinstance(file_import, dict):
        file_import = {"state": "off", "error": None, "duration_seconds": None}
    file_import["message"] = IMPORT_MESSAGES.get(file_import.get("error") or "", "")
    # A failed replacement keeps the previous result readable through import-result.
    file_import["retained"] = bool(file_import.get("retained_id"))
    code = status.get("error") if running else None
    return {"running": running, "state": status.get("state", "off") if running else "off",
            "error": SESSION_MESSAGES.get(code, code) if code else None, "error_code": code,
            "history": {"takes": len(entries), "maximum": status.get("maximum_takes") if running else config_summary().get("maximum_recovery_takes")},
            "recent": transcripts[:5], "has_transcript": bool(transcripts),
            "saved": [entry for entry in entries if entry["audio"] and not entry["transcript"]],
            "words_today": words_today(entries),
            "config": config_summary(), "sounds": preferences()["sounds"],
            "pill": preferences()["pill"], "font": preferences()["font"],
            "cleanup": {**cleanup_models(), "service": status.get("cleanup") if running else None},
            "autostart": unit_enabled(),
            "shortcut": shortcut_mode(), "shortcut_keys": shortcut_info()["keys"],
            "interface": report.get("interface"), "capabilities": report.get("features", {}),
            "file_import": file_import, "versions": versions()}


def unit_enabled():
    return (UNIT.parent / "graphical-session.target.wants" / UNIT.name).is_symlink()


def legacy_unit_enabled():
    return (UNIT.parent / "default.target.wants" / UNIT.name).is_symlink()


def unit_active():
    try:
        return subprocess.run(["systemctl", "--user", "is-active", "--quiet", UNIT.name], timeout=5).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def start_service():
    current = state()
    if current["running"]:
        return current
    if unit_enabled():
        # The login daemon owns the service; let systemd start and supervise it.
        subprocess.run(["systemctl", "--user", "start", UNIT.name], check=False, timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(25):
            time.sleep(0.2)
            current = state()
            if current["running"]:
                return current
        raise RuntimeError("The Mouthtype service did not start. Check: systemctl --user status mouthtype-linux")
    LOG.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        with os.fdopen(fd, "w") as log:
            subprocess.Popen(
                [str(LAUNCHER), "--config", str(CONFIG), "serve"],
                stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                start_new_session=True, close_fds=True,
            )
    except OSError:
        raise RuntimeError("Could not start Mouthtype. Check the local control log.")
    for _ in range(15):
        time.sleep(0.2)
        current = state()
        if current["running"]:
            return current
    raise RuntimeError("Mouthtype did not become ready. Check the local control log.")


def cue(name):
    if not preferences()["sounds"] or shutil.which("pw-play") is None:
        return
    sound = ASSETS / f"{name}.wav"
    if sound.is_file():
        try:
            subprocess.Popen(["pw-play", str(sound)], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True, close_fds=True)
        except OSError:
            pass


HOLD = LOG.parent / "hold.json"
PROCESS_FALLBACK_TIME = time.monotonic()


def event_time():
    """When this process was launched, in clock ticks since boot.

    Lock arrival order is not key order: a press and a release can reach the lock in either order.
    Launch time is stamped by the kernel before any of our code runs, so it orders the key events."""
    try:
        stat = Path("/proc/self/stat").read_text(encoding="utf-8")
        # comm (field 2) may contain spaces and parentheses, so count fields from the last ')'.
        return int(stat[stat.rindex(")") + 2:].split()[19])
    except (OSError, ValueError, IndexError):
        return PROCESS_FALLBACK_TIME


def boot_id():
    try:
        return Path("/proc/sys/kernel/random/boot_id").read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def hold_normalise(data):
    """The saved hold state, or a fresh one when the file is malformed or left by an earlier boot."""
    fresh = {"boot": boot_id(), "seq": 0, "press": None, "last_release_t": None}
    if not isinstance(data, dict) or data.get("boot") != fresh["boot"] or not isinstance(data.get("seq"), int):
        return fresh
    press = data.get("press")
    if press is not None:
        if (not isinstance(press, dict) or not isinstance(press.get("id"), int) or not number(press.get("t"))
                or not all(isinstance(press.get(key), bool) for key in ("started", "released"))):
            press = None
    last = data.get("last_release_t")
    return {**fresh, "seq": data["seq"], "press": press,
            "last_release_t": last if number(last) else None}


def hold_update(change):
    """Serialise the press and release processes, which start within milliseconds of each other."""
    HOLD.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(HOLD.with_suffix(".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            data = json.loads(HOLD.read_text(encoding="utf-8")) if HOLD.is_file() else {}
        except (OSError, ValueError):
            data = {}
        data = hold_normalise(data)
        result = change(data)
        atomic_json(HOLD, data)
        return result
    finally:
        os.close(fd)


def hold_press(t):
    """Register a press launched at t. Returns its id, or None when it must not start a recording."""
    def change(data):
        data["seq"] += 1
        mine = data["seq"]
        press, last = data["press"], data["last_release_t"]
        if press is not None and press["t"] > t:
            return None  # a newer press already owns the session
        if last is not None and last >= t:
            # The release of this very press was processed first. Nothing to start.
            data["press"] = {"id": mine, "t": t, "started": False, "released": True, "skipped": True}
            return None
        data["press"] = {"id": mine, "t": t, "started": False, "released": False}
        return mine
    return hold_update(change)


def release_change(data, t):
    last = data["last_release_t"]
    data["last_release_t"] = t if last is None else max(last, t)
    press = data["press"]
    if press is None:
        return True
    if press["t"] > t:
        return False  # a late release for an older press; the current press is still held
    press["released"] = True
    return True


def hold_release(t):
    """Register a release launched at t. Returns False when it belongs to a press that is already over."""
    return hold_update(lambda data: release_change(data, t))


def hold_alive(mine):
    def change(data):
        press = data["press"]
        return press is not None and press["id"] == mine and not press["released"]
    return hold_update(change)


# A stop sent while the hold lock is held must not wedge the next key event behind a hung daemon.
HOLD_STOP_TIMEOUT = 10
DAEMON_ERRORS = (RuntimeError, OSError, subprocess.SubprocessError)


def stop_under_lock(failures):
    """Send stop while the hold lock is held, so a newer press cannot start in between and get stopped.

    Failures are collected rather than raised: the caller is inside hold_update, which must still save the state."""
    try:
        return deliver("stop", timeout=HOLD_STOP_TIMEOUT)
    except DAEMON_ERRORS as error:
        failures.append(error if isinstance(error, RuntimeError) else RuntimeError("Mouthtype did not respond to the stop request"))
        return None


def hold_settle(mine):
    """After the start request returned: True when the key already came up and the recording was stopped."""
    failures = []

    def change(data):
        press = data["press"]
        if press is None:
            return False
        if press["id"] != mine:
            if press["released"] and press.get("skipped"):
                # The newest press came and went without starting; this start would otherwise leak.
                press["skipped"] = False
                stop_under_lock([])
                cue("stop")
            return False
        if press["released"]:
            # The key came up before the recording began, so its stop was a no-op. Stop now.
            stop_under_lock(failures)
            return True
        press["started"] = True
        return False
    settled = hold_update(change)
    if failures:
        raise failures[0]
    return settled


def hold_stop(t):
    """Handle a release launched at t. Returns the daemon's reply, or None when the release was stale.

    The stop goes out under the hold lock. Sent after the lock was freed, it could land on a press that
    began in between and end that recording."""
    failures = []

    def change(data):
        if not release_change(data, t):
            return None
        return stop_under_lock(failures) or {}
    response = hold_update(change)
    if failures:
        raise failures[0]
    return response


def deliver(command, identity=None, timeout=35):
    result = cli(command, *([identity] if identity else []), timeout=timeout)
    if result.returncode:
        raise RuntimeError("Mouthtype command failed")
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError:
        response = {}
    if response.get("error") == "unavailable":
        raise RuntimeError("Mouthtype is not running")
    if response.get("error") == "file_import_active":
        raise import_error("file_import_active", "A file transcription is running")
    return response


def hold_start(t):
    mine = hold_press(t)
    if mine is None:
        return state()
    try:
        response = deliver("start")
    except RuntimeError:
        if state()["running"]:
            raise
        start_service()
        if not hold_alive(mine):
            return state()
        response = deliver("start")
    if hold_settle(mine):
        cue("stop")
        return state()
    if response.get("state") == "recording":
        cue("start")
    return state()


def act(command, identity=None):
    t = event_time() if command in {"start", "stop"} else None
    if identity is not None and (len(identity) != 32 or any(c not in "0123456789abcdef" for c in identity)):
        raise RuntimeError("Invalid recording ID")
    if command == "start":
        return hold_start(t)
    if command == "stop":
        response = hold_stop(t)
        if response is None:
            return state()
        if response.get("state") != "recording":
            cue("stop")
        return state()
    if command in {"toggle", "transcribe"} and not state()["running"]:
        start_service()
    if command == "shutdown" and unit_active():
        # Stopping through systemd keeps Restart=always from bringing the service straight back.
        subprocess.run(["systemctl", "--user", "stop", UNIT.name], check=False, timeout=20,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return state()
    response = deliver(command, identity)
    if command == "toggle" and response.get("state") == "recording":
        cue("start")
    elif command in {"stop", "cancel", "toggle"} and response.get("state") != "recording":
        cue("stop")
    return state()


def set_config(field, value, extra=None):
    current = state()
    if current["running"] and current["state"] != "idle":
        raise RuntimeError("Finish the current dictation before changing settings")
    config = json.loads(CONFIG.read_text(encoding="utf-8"))
    if field == "cleanup" and value in {"off", "basic"}:
        config["cleanup"] = value
        config.pop("cleanup_engine", None)
    elif field == "cleanup" and value in {"fast", "thorough"}:
        if cleanup_models()["models"][value] != "prepared":
            raise RuntimeError("Prepare the " + ("Fast" if value == "fast" else "Thorough") + " cleanup model first")
        config["cleanup"] = value
        config["cleanup_engine"] = str(CLEANUP_DIR / "cleanup.json")
    elif field == "notifications" and value in {"on", "off"}:
        config["notifications"] = value == "on"
    elif field == "maximum_recording_seconds" and value in {"30", "60", "120"}:
        config["maximum_recording_seconds"] = int(value)
    elif field == "maximum_recovery_takes" and value in {"100", "200", "500", "1000"}:
        config["maximum_recovery_takes"] = int(value)
    elif field == "audio_retention_days" and value in {"14", "30", "90", "none"}:
        config["audio_retention_days"] = None if value == "none" else int(value)
    elif field == "history_keep" and value in {"off", "5", "20", "50"}:
        config["history_keep"] = None if value == "off" else int(value)
    elif field == "delivery" and value == "recover":
        config["delivery"] = {"mode": "recover"}
    elif field == "delivery" and value == "paste":
        if not all(shutil.which(name) for name in ("wl-copy", "wl-paste", "wtype", "hyprctl")):
            raise RuntimeError("Pasting needs wl-clipboard and wtype installed")
        config["delivery"] = {"mode": "paste", "any_window": True, "allow_unknown_secure_field": True,
                              "restore_clipboard": True}
    elif field == "delivery" and value == "type":
        window_class = (extra or "").strip()
        if not window_class or len(window_class) > 128 or "*" in window_class or any(ord(c) < 33 for c in window_class):
            raise RuntimeError("Enter one exact window class without spaces or wildcards")
        config["delivery"] = {"mode": "type", "allowed_classes": [window_class],
                              "allow_unknown_secure_field": True}
    else:
        raise RuntimeError("Unsupported setting")
    sys.path.insert(0, str(DESKTOP))
    from desktop import validate_config
    validate_config(config)
    if config == json.loads(CONFIG.read_text(encoding="utf-8")):
        return state()
    if current["running"] and current["file_import"].get("state") in IMPORT_ACTIVE:
        # Applying the change restarts the service, which would cancel the running file transcription.
        raise RuntimeError("Wait for the file transcription to finish or cancel it before changing settings")
    backup = CONFIG.with_name(f"linux.json.bak.{int(time.time())}")
    shutil.copy2(CONFIG, backup)
    atomic_json(CONFIG, config)
    if current["running"]:
        act("shutdown")
        start_service()
    return state()


def cleanup_setup(level):
    if level not in {"fast", "thorough"}:
        raise RuntimeError("Unsupported cleanup level")
    if setup_running():
        raise RuntimeError("Cleanup preparation is already running")
    script = DESKTOP / "setup_cleanup.py"
    if not script.is_file():
        raise RuntimeError("The installed Mouthtype client cannot prepare cleanup models")
    for tool in ("curl", "git", "cmake", "c++"):
        if shutil.which(tool) is None:
            raise RuntimeError("Preparing cleanup needs " + tool + " installed")
    CLEANUP_LOG.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(CLEANUP_LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    command = ["/usr/bin/python3", str(script), "--destination", str(CLEANUP_DIR), "--level", level]
    existing = CLEANUP_DIR / "cleanup.json"
    if existing.is_file():
        try:
            engines = json.loads(existing.read_text(encoding="utf-8")).get("engines", {})
            server = next((e.get("server") for e in engines.values() if isinstance(e, dict) and Path(e.get("server", "")).is_file()), None)
            if server:
                command += ["--server", server]
        except (OSError, json.JSONDecodeError):
            pass
    with os.fdopen(fd, "w") as log:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, close_fds=True)
    started = process_start(child.pid)
    if started is not None:
        atomic_json(SETUP_PID, {"pid": child.pid, "start": started})
    time.sleep(0.5)
    output = state()
    output["page"] = "cleanup"
    output["message"] = "Preparing " + ("Fast" if level == "fast" else "Thorough") + " cleanup (" + CLEANUP_SIZES[level] + " download)"
    return output


def set_sounds(value):
    if value not in {"on", "off"}:
        raise RuntimeError("Unsupported sound setting")
    prefs = preferences()
    prefs["sounds"] = value == "on"
    atomic_json(PREFS, prefs)
    return state()


UNIT_MARKER = "# Managed by the Mouthtype Omarchy plugin"


def unit_quote(value):
    value = str(value)
    if not any(c in value for c in " \t\"'\\%"):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"'


def set_autostart(value):
    if value not in {"on", "off"}:
        raise RuntimeError("Unsupported login setting")
    if UNIT.exists() and UNIT_MARKER not in UNIT.read_text(encoding="utf-8"):
        raise RuntimeError("An existing Mouthtype user service was not changed")
    if value == "on":
        if shutil.which("systemctl") is None:
            raise RuntimeError("systemd user services are unavailable")
        if legacy_unit_enabled():
            # Older installs linked into default.target; unlink it while the old unit still names that target.
            subprocess.run(["systemctl", "--user", "disable", UNIT.name], check=True, timeout=10,
                           stdout=subprocess.DEVNULL)
        UNIT.parent.mkdir(parents=True, exist_ok=True)
        unit = ("[Unit]\nDescription=Mouthtype Linux dictation service\n"
                "PartOf=graphical-session.target\n"
                "After=graphical-session.target pipewire.service\n\n"
                "[Service]\nType=simple\n" + UNIT_MARKER + "\n"
                f"ExecStart={unit_quote(LAUNCHER)} --config {unit_quote(CONFIG)} serve --lifetime-seconds 86400\n"
                "Restart=always\nRestartSec=2\n\n"
                "[Install]\nWantedBy=graphical-session.target\n")
        UNIT.write_text(unit, encoding="utf-8")
        subprocess.run(["systemctl", "--user", "daemon-reload"], check=True, timeout=10)
        subprocess.run(["systemctl", "--user", "enable", UNIT.name], check=True, timeout=10,
                       stdout=subprocess.DEVNULL)
    else:
        if UNIT.exists():
            subprocess.run(["systemctl", "--user", "disable", UNIT.name], check=True, timeout=10,
                           stdout=subprocess.DEVNULL)
    return state()


def set_shortcut(value, keys=None):
    if value not in {"off", "toggle", "hold"}:
        raise RuntimeError("Unsupported shortcut")
    if not BINDINGS.is_file():
        raise RuntimeError("Hyprland bindings file is missing")
    spec, mask, key = parse_shortcut(keys or DEFAULT_SHORTCUTS.get(value, "F10")) if value != "off" else ("", 0, "")
    current = shortcut_info()
    original = BINDINGS.read_text(encoding="utf-8")
    before, separator, after = original.partition(BIND_BEGIN)
    if separator:
        if BIND_END not in after:
            raise RuntimeError("Existing Mouthtype shortcut block is incomplete")
        after = after.split(BIND_END, 1)[1]
        base = before.rstrip() + after
    else:
        base = original.rstrip() + "\n"
    if value != "off":
        ours = current["mode"] != "off" and parse_shortcut(current["keys"])[0] == spec if current["keys"] else False
        result = subprocess.run(["hyprctl", "-j", "binds"], text=True, capture_output=True,
                                check=True, timeout=5)
        for binding in json.loads(result.stdout):
            bound = str(binding.get("key", ""))
            same_key = bound.upper() == key.upper() or (key.startswith("code:") and str(binding.get("keycode")) == key[5:])
            if same_key and binding.get("modmask") == mask and not ours:
                raise RuntimeError(spec + " is already bound in Hyprland; choose another key")
        command = Path(__file__).resolve()
        if value == "toggle":
            # Omarchy's `o` helper is not guaranteed to exist in every bindings.lua; fall back to a plain Hyprland bind.
            block = (f'if type(o) == "table" and type(o.bind) == "function" then\n'
                     f'  o.bind("{spec}", "Toggle Mouthtype dictation", "{command} toggle")\n'
                     f'else\n'
                     f'  hl.bind("{spec}", hl.dsp.exec_cmd("{command} toggle"))\n'
                     f'end')
        else:
            block = (f'hl.bind("{spec}", hl.dsp.exec_cmd("{command} start"))\n'
                     f'hl.bind("{spec}", hl.dsp.exec_cmd("{command} stop"), {{ release = true }})')
        updated = base.rstrip() + "\n\n" + BIND_BEGIN + "\n" + block + "\n" + BIND_END + "\n"
    else:
        updated = base.rstrip() + "\n"
    if updated == original:
        return state()
    backup = BINDINGS.with_name(f"bindings.lua.bak.mouthtype.{int(time.time())}")
    shutil.copy2(BINDINGS, backup)
    BINDINGS.write_text(updated, encoding="utf-8")
    try:
        subprocess.run(["hyprctl", "reload"], check=True, timeout=10, capture_output=True)
        errors = subprocess.run(["hyprctl", "configerrors"], check=True, timeout=10,
                                text=True, capture_output=True).stdout.strip()
        if errors and errors.lower() not in {"no errors", "ok"}:
            raise RuntimeError("Hyprland reported configuration errors")
    except (OSError, RuntimeError, subprocess.SubprocessError):
        shutil.copy2(backup, BINDINGS)
        subprocess.run(["hyprctl", "reload"], timeout=10, capture_output=True)
        raise RuntimeError("Shortcut change was reverted because Hyprland rejected it")
    output = state()
    output["page"] = "shortcut"
    return output


def forget(identity):
    if len(identity) != 32 or any(c not in "0123456789abcdef" for c in identity):
        raise RuntimeError("Invalid recording ID")
    result = cli("forget", identity, timeout=10)
    if result.returncode:
        raise RuntimeError("That dictation is in use or could not be forgotten")
    output = state()
    output["page"] = "menu"
    return output


def prune(rule, value):
    """Forget saved dictations by rule: keep-N newest, older-N days, or all. The active take is never touched."""
    entries = recent_dictations(limit=None)
    entries.sort(key=lambda e: e["mtime"])
    try:
        number = int(value)
    except (TypeError, ValueError):
        number = 0
    if rule == "keep":
        targets = entries[:-number] if number > 0 else entries
    elif rule == "older":
        cutoff = time.time() - max(1, number) * 86400
        targets = [e for e in entries if e["mtime"] < cutoff]
    elif rule == "all":
        targets = entries
    else:
        raise RuntimeError("Unsupported history rule")
    forgotten = 0
    for entry in targets:
        if cli("forget", entry["id"], timeout=10).returncode == 0:
            forgotten += 1
    output = state()
    output["page"] = "history"
    output["message"] = f"Forgot {forgotten} dictation{'s' if forgotten != 1 else ''}"
    return output


def recover(identity):
    if len(identity) != 32 or any(c not in "0123456789abcdef" for c in identity):
        raise RuntimeError("Invalid recording ID")
    result = cli("recover", identity)
    if result.returncode:
        raise RuntimeError("Could not read the saved transcript")
    return {"id": identity, "text": result.stdout}


def latest_transcript(identity=None):
    if identity is None:
        identity = next((entry["id"] for entry in recent_dictations(limit=None)
                         if entry["transcript"]), None)
    if identity is None:
        raise RuntimeError("No saved dictation is available")
    return recover(identity)["text"]


def copy_transcript(identity=None):
    if shutil.which("wl-copy") is None:
        raise RuntimeError("wl-copy is not installed")
    text = latest_transcript(identity)
    subprocess.run(["wl-copy", "--type", "text/plain;charset=utf-8"], input=text.encode("utf-8"),
                   check=True, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = state()
    result["message"] = "Copied to clipboard"
    return result


def paste_last():
    config = json.loads(CONFIG.read_text(encoding="utf-8"))
    delivery = config.get("delivery", {"mode": "recover"})
    if delivery.get("mode") not in ("type", "paste"):
        raise RuntimeError("Enable pasting or guarded typing in Paste Options first")
    text = latest_transcript()
    sys.path.insert(0, str(DESKTOP))
    from desktop import HyprlandDelivery
    target = HyprlandDelivery(delivery)
    snapshot = target.snapshot()
    if snapshot is None:
        raise RuntimeError("No eligible unlocked target window")
    outcome = target.submit(text, snapshot)
    if outcome == "recover_only":
        raise RuntimeError("That app is not allowed for typing")
    if outcome == "unsupported_text":
        raise RuntimeError("This transcript contains line breaks or control characters")
    if outcome == "target_changed":
        raise RuntimeError("The target window changed; nothing was typed")
    if getattr(target, "restore_thread", None) is not None:
        # This process is short-lived; let the clipboard restore finish before exiting.
        target.restore_thread.join(3)
    result = state()
    result["message"] = ("Paste requested; check the target before retrying" if delivery.get("mode") == "paste"
                         else "Typing requested; check the target before retrying")
    return result


def import_error(code, fallback):
    return RuntimeError(IMPORT_MESSAGES.get(code or "", fallback))


def import_start(path):
    if not path or not Path(path).is_file():
        raise import_error("invalid_audio", "The chosen file could not be read.")
    if not state()["capabilities"].get("file_transcription"):
        raise RuntimeError("The installed Mouthtype client cannot transcribe files")
    if not state()["running"]:
        start_service()
    result = cli("import", path, timeout=35)
    if result.returncode:
        raise import_error(cli_error(result), "Mouthtype could not start the file transcription")
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError:
        response = {}
    if response.get("error") == "unavailable":
        raise RuntimeError("Mouthtype is not running")
    if response.get("accepted") is not True:
        raise import_error(response.get("error"), "Mouthtype refused the file")
    output = state()
    output["page"] = "import"
    return output


def import_pick():
    chooser = shutil.which("omarchy-file-select")
    if chooser is None:
        raise RuntimeError("The Omarchy file chooser is unavailable")
    extensions = state()["capabilities"].get("file_transcription", {}).get("extensions") or ["wav", "aiff", "aif", "m4a"]
    picked = subprocess.run([chooser, "--title", "Transcribe Audio File", "--extensions", " ".join(extensions)],
                            text=True, capture_output=True, timeout=620, check=False, stdin=subprocess.DEVNULL)
    if picked.returncode == 1:
        output = state()
        output["message"] = "No file was chosen"
        return output
    if picked.returncode:
        raise RuntimeError("The file chooser could not be opened")
    return import_start(picked.stdout.splitlines()[0].strip() if picked.stdout.strip() else "")


def import_control(action):
    result = cli(action, timeout=10)
    if result.returncode:
        raise import_error(cli_error(result), "Mouthtype is not running")
    output = state()
    if action == "import-forget":
        output["page"] = "menu"
    return output


def import_result():
    result = cli("import-result", timeout=10)
    if result.returncode:
        raise import_error(cli_error(result), "Could not read the file transcript")
    return {"text": result.stdout}


def import_copy():
    if shutil.which("wl-copy") is None:
        raise RuntimeError("wl-copy is not installed")
    text = import_result()["text"]
    subprocess.run(["wl-copy", "--type", "text/plain;charset=utf-8"], input=text.encode("utf-8"),
                   check=True, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    output = state()
    output["message"] = "Copied to clipboard"
    output["page"] = "import"
    return output


def import_save():
    import_result()
    picked = subprocess.run(["/usr/bin/python3", str(SAVE_DIALOG), "--title", "Save Transcript", "--name", "Transcript.txt"],
                            text=True, capture_output=True, timeout=620, check=False, stdin=subprocess.DEVNULL)
    output = state()
    output["page"] = "import"
    if picked.returncode == 1:
        output["message"] = "Nothing was saved"
        return output
    if picked.returncode or not picked.stdout.strip():
        raise RuntimeError("The save dialog could not be opened")
    destination = picked.stdout.splitlines()[0].strip()
    # The portal dialog has already confirmed replacing an existing text file.
    saved = cli("import-save", destination, "--overwrite", timeout=10)
    if saved.returncode:
        raise import_error(cli_error(saved), "The transcript could not be saved")
    output["message"] = "Saved " + Path(destination).name
    return output


VALID_ACTIONS = {
    "state", "start-service", "shutdown", "start", "stop", "cancel", "toggle",
    "recover", "transcribe", "copy", "paste-last", "set-config", "set-sounds",
    "set-autostart", "set-shortcut", "import-pick", "import-start", "import-cancel",
    "import-forget", "import-result", "import-copy", "import-save", "set-pill", "set-font", "cleanup-setup"
,
    "forget", "prune"
}

MODULE_PATTERN = re.compile(r"control_[a-z0-9_]+\.py")
_module_commands = None


def log_note(message):
    """Best-effort line in the local control log; never lets logging break a command."""
    try:
        LOG.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as log:
            log.write(time.strftime("%Y-%m-%d %H:%M:%S ") + message + "\n")
    except OSError:
        pass


def module_commands():
    """Verbs contributed by sibling control_<name>.py modules, as {verb: function}.

    A module exposes COMMANDS = {"verb": function}. The function takes the remaining command-line
    arguments as strings and returns a JSON-serialisable dict, or raises RuntimeError, OSError or
    ValueError with a message the panel can show. A verb cannot shadow a built-in action or a verb
    from an earlier module (alphabetical). A module that fails to import is logged and skipped."""
    global _module_commands
    if _module_commands is not None:
        return _module_commands
    commands = {}
    for path in sorted(PLUGIN_DIR.glob("control_*.py")):
        if not MODULE_PATTERN.fullmatch(path.name) or path.is_symlink() or not path.is_file():
            continue
        try:
            name = "mouthtype_" + path.stem
            spec = importlib.util.spec_from_file_location(name, path)
            module = importlib.util.module_from_spec(spec)
            # dataclasses and typing look the module up by name while it executes.
            sys.modules[name] = module
            try:
                spec.loader.exec_module(module)
                table = module.COMMANDS
                if not isinstance(table, dict):
                    raise TypeError("COMMANDS must be a dict")
            except BaseException:
                sys.modules.pop(name, None)
                raise
        except Exception as error:
            log_note(f"{path.name} was not loaded: {type(error).__name__}: {error}")
            continue
        for verb, function in table.items():
            if not isinstance(verb, str) or not re.fullmatch(r"[a-z][a-z0-9-]*", verb) or not callable(function):
                log_note(f"{path.name}: ignored invalid command {verb!r}")
            elif verb in VALID_ACTIONS or verb in commands:
                log_note(f"{path.name}: ignored command {verb!r}, already defined")
            else:
                commands[verb] = function
    _module_commands = commands
    return commands


def available_actions():
    return VALID_ACTIONS | set(module_commands())


def run_module_command(verb, args):
    function = module_commands()[verb]
    try:
        inspect.signature(function).bind(*args)
    except TypeError:
        raise RuntimeError("Invalid control arguments")
    return function(*args)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] not in VALID_ACTIONS and sys.argv[1] in module_commands():
        try:
            print(json.dumps(run_module_command(sys.argv[1], sys.argv[2:])))
            return 0
        except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
            print(json.dumps({"error": str(error)}))
            return 1
    if len(sys.argv) < 2 or sys.argv[1] not in VALID_ACTIONS or (
        sys.argv[1] in {"recover", "transcribe", "set-sounds", "set-autostart", "import-start", "cleanup-setup", "forget"}
        and len(sys.argv) != 3
    ) or (sys.argv[1] == "prune" and len(sys.argv) != 4
    ) or (sys.argv[1] == "set-shortcut" and len(sys.argv) not in {3, 4}
    ) or (sys.argv[1] == "copy" and len(sys.argv) not in {2, 3}) or (
        sys.argv[1] in {"set-config", "set-font"} and len(sys.argv) not in {4, 5}
    ) or (
        sys.argv[1] == "set-pill" and len(sys.argv) != 4
    ) or (sys.argv[1] in {"state", "start-service", "shutdown", "start", "stop", "cancel", "toggle", "paste-last",
                          "import-pick", "import-cancel", "import-forget", "import-result", "import-copy", "import-save"}
          and len(sys.argv) != 2):
        print(json.dumps({"error": "Unknown control action"}))
        return 2
    try:
        action = sys.argv[1]
        if action == "state":
            output = state()
        elif action == "import-pick":
            output = import_pick()
        elif action == "import-start":
            output = import_start(sys.argv[2])
        elif action in {"import-cancel", "import-forget"}:
            output = import_control(action)
        elif action == "import-result":
            output = import_result()
        elif action == "import-copy":
            output = import_copy()
        elif action == "import-save":
            output = import_save()
        elif action == "start-service":
            output = start_service()
        elif action == "recover":
            output = recover(sys.argv[2])
        elif action == "transcribe":
            output = act("transcribe", sys.argv[2])
        elif action == "copy":
            output = copy_transcript(sys.argv[2] if len(sys.argv) == 3 else None)
        elif action == "paste-last":
            output = paste_last()
        elif action == "set-config" and len(sys.argv) in {4, 5}:
            output = set_config(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) == 5 else None)
        elif action == "forget":
            output = forget(sys.argv[2])
        elif action == "prune":
            output = prune(sys.argv[2], sys.argv[3])
        elif action == "cleanup-setup":
            output = cleanup_setup(sys.argv[2])
        elif action == "set-pill":
            output = set_pill(sys.argv[2], sys.argv[3])
        elif action == "set-font":
            output = set_font(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) == 5 else None)
        elif action == "set-sounds" and len(sys.argv) == 3:
            output = set_sounds(sys.argv[2])
        elif action == "set-autostart" and len(sys.argv) == 3:
            output = set_autostart(sys.argv[2])
        elif action == "set-shortcut":
            output = set_shortcut(sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
        elif len(sys.argv) == 2:
            output = act(action)
        else:
            raise RuntimeError("Invalid control arguments")
        print(json.dumps(output))
        return 0
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({"error": str(error)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
