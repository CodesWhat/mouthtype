#!/usr/bin/env python3
"""Small JSON bridge between the Omarchy panel and Mouthtype's local CLI."""

import fcntl
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


def setup_running():
    try:
        result = subprocess.run(["pgrep", "-f", "setup_cleanup.py --destination"], capture_output=True, text=True, timeout=5)
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def config_summary():
    config = json.loads(CONFIG.read_text(encoding="utf-8"))
    delivery = config.get("delivery", {"mode": "recover"})
    return {
        "cleanup": config.get("cleanup", "off"),
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
    return {"running": running, "state": status.get("state", "off") if running else "off",
            "error": status.get("error") if running else None,
            "recent": transcripts[:5], "has_transcript": bool(transcripts),
            "saved": [entry for entry in entries if entry["audio"] and not entry["transcript"]],
            "words_today": words_today(entries),
            "config": config_summary(), "sounds": preferences()["sounds"],
            "pill": preferences()["pill"], "font": preferences()["font"],
            "cleanup": {**cleanup_models(), "service": status.get("cleanup") if running else None},
            "autostart": unit_enabled(),
            "shortcut": shortcut_mode(), "shortcut_keys": shortcut_info()["keys"],
            "interface": report.get("interface"), "capabilities": report.get("features", {}),
            "file_import": file_import}


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
HOLD_EARLY_SECONDS = 2.0


def hold_update(change):
    """Serialise the press and release processes, which start within milliseconds of each other."""
    HOLD.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(HOLD.with_suffix(".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            data = json.loads(HOLD.read_text(encoding="utf-8")) if HOLD.is_file() else {}
        except (OSError, json.JSONDecodeError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        result = change(data)
        atomic_json(HOLD, data)
        return result
    finally:
        os.close(fd)


def hold_press():
    """Register a press. Returns its id, or None when its release already arrived."""
    def change(data):
        data["press"] = data.get("press", 0) + 1
        early, data["early_release"] = data.get("early_release"), None
        if isinstance(early, (int, float)) and 0 <= time.time() - early < HOLD_EARLY_SECONDS:
            data["released"] = data["press"]
            return None
        return data["press"]
    return hold_update(change)


def hold_release():
    def change(data):
        if data.get("released", 0) < data.get("press", 0):
            data["released"] = data["press"]
        else:
            # The release outran its press process; the press will find this and not start.
            data["early_release"] = time.time()
    hold_update(change)


def hold_released(press):
    return hold_update(lambda data: data.get("released", 0) >= press)


def deliver(command, identity=None):
    result = cli(command, *([identity] if identity else []))
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


def hold_start():
    press = hold_press()
    if press is None:
        return state()
    try:
        response = deliver("start")
    except RuntimeError:
        if state()["running"]:
            raise
        start_service()
        if hold_released(press):
            return state()
        response = deliver("start")
    if hold_released(press):
        # The key came up before the recording began, so its stop was a no-op. Stop now.
        deliver("stop")
        cue("stop")
        return state()
    if response.get("state") == "recording":
        cue("start")
    return state()


def act(command, identity=None):
    if identity is not None and (len(identity) != 32 or any(c not in "0123456789abcdef" for c in identity)):
        raise RuntimeError("Invalid recording ID")
    if command == "start":
        return hold_start()
    if command == "stop":
        hold_release()
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
        subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, close_fds=True)
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
            block = f'o.bind("{spec}", "Toggle Mouthtype dictation", "{command} toggle")'
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
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in VALID_ACTIONS or (
        sys.argv[1] in {"recover", "transcribe", "set-sounds", "set-autostart", "import-start", "cleanup-setup"}
        and len(sys.argv) != 3
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
