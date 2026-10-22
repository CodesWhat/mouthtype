#!/usr/bin/env python3
"""Small JSON bridge between the Omarchy panel and Mouthtype's local CLI."""

import fcntl
import importlib.util
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
def _first_existing(*paths):
    """A user-local install shadows the packaged one, as it does on PATH; with neither, name the user-local path."""
    return next((path for path in paths if path.exists()), paths[0])


LAUNCHER = _first_existing(HOME / ".local/bin/mouthtype-linux", Path("/usr/bin/mouthtype-linux"))
CONFIG = HOME / ".local/share/mouthtype/speech-candidate/linux.json"
RECOVERY = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "mouthtype/recovery"
LOG = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "mouthtype/omarchy-control.log"
PREFS = HOME / ".config/mouthtype/omarchy-plugin.json"
UNIT = HOME / ".config/systemd/user/mouthtype-linux.service"
# The Arch package ships this unit; with it present the plugin enables it instead of writing its own copy.
VENDOR_UNIT = Path("/usr/lib/systemd/user/mouthtype-linux.service")
BINDINGS = HOME / ".config/hypr/bindings.lua"
BIND_BEGIN = "-- Mouthtype Omarchy plugin shortcut: begin"
BIND_END = "-- Mouthtype Omarchy plugin shortcut: end"
TRANSFORM_BEGIN = "-- Mouthtype Omarchy plugin transform shortcut: begin"
TRANSFORM_END = "-- Mouthtype Omarchy plugin transform shortcut: end"
DESKTOP = _first_existing(HOME / ".local/lib/mouthtype-linux/tools/linux-desktop",
                          Path("/usr/lib/mouthtype-linux/tools/linux-desktop"))
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


SOCKET_ACTIONS = ("start", "stop", "toggle", "cancel", "status")
_session_client = False


def session_client():
    """The service-socket client module, or None when this install doesn't ship it (then the CLI is used)."""
    global _session_client
    if _session_client is False:
        _session_client = None
        for directory in (DESKTOP, PLUGIN_DIR.parent / "linux-desktop"):
            if (directory / "session_client.py").is_file():
                sys.path.insert(0, str(directory))
                try:
                    import session_client as module
                    _session_client = module
                except ImportError:
                    pass
                break
    return _session_client


def session_call(action, identity=None, timeout=35):
    """Run a daemon command. The hotkey path sends it to the service socket directly, the same JSON line the CLI
    sends, so no second interpreter starts. A missing socket (service down) falls back to the CLI, which reports
    that failure the way every caller already expects. Returns a CompletedProcess, like cli()."""
    client = session_client() if action in SOCKET_ACTIONS and identity is None else None
    if client is not None:
        path = client.default_socket()
        if path.exists():
            try:
                reply = client.request(path, action)
                return subprocess.CompletedProcess([action], 0, json.dumps(reply), "")
            except (OSError, ValueError):
                return subprocess.CompletedProcess([action], 2, "", json.dumps({"error": "unavailable"}))
    return cli(action, *([identity] if identity else []), timeout=timeout)


def cli_error(result):
    try:
        return json.loads(result.stderr).get("error")
    except (json.JSONDecodeError, AttributeError):
        return None


CAPABILITIES_TTL = 60


def capabilities_cache_path():
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    base = Path(runtime) if runtime else Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache"))
    return base / "mouthtype" / "capabilities.json"


def read_capabilities_cache(stamp):
    try:
        entry = json.loads(capabilities_cache_path().read_text(encoding="utf-8"))
        age = time.time() - entry["at"]
        if (entry["launcher"] == str(LAUNCHER) and entry["mtime_ns"] == stamp
                and 0 <= age < CAPABILITIES_TTL and isinstance(entry["report"], dict) and entry["report"]):
            return entry["report"]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def write_capabilities_cache(stamp, report):
    path = capabilities_cache_path()
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(path.parent, 0o700)
        fd, temporary = tempfile.mkstemp(prefix=".capabilities-", dir=path.parent)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                json.dump({"launcher": str(LAUNCHER), "mtime_ns": stamp, "at": time.time(), "report": report}, output)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    except OSError:
        pass


def capabilities():
    """The widget runs a fresh helper process per poll, so the cache lives in a file: launcher path + mtime, 60 s TTL.
    Only a non-empty answer is stored, and any cache read error falls back to asking the launcher."""
    try:
        stamp = LAUNCHER.stat().st_mtime_ns
    except OSError:
        return {}
    cached = read_capabilities_cache(stamp)
    if cached is not None:
        return cached
    try:
        result = cli("capabilities", timeout=10)
        report = json.loads(result.stdout) if result.returncode == 0 else {}
    except (OSError, json.JSONDecodeError, subprocess.SubprocessError):
        report = {}
    if not isinstance(report, dict):
        return {}
    if report:
        write_capabilities_cache(stamp, report)
    return report


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
        "welcomed": value.get("welcomed") is True,
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


def set_plugin(field, value):
    if field != "welcomed" or value not in {"on", "off"}:
        raise RuntimeError("Unsupported plugin setting")
    prefs = preferences()
    prefs["welcomed"] = value == "on"
    atomic_json(PREFS, prefs)
    return state()


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
        "slash_commands": config.get("slash_commands", True),
        "microphone": config.get("capture_target") or "default",
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
DEFAULT_TRANSFORM_SHORTCUT = "SUPER + SHIFT + T"


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


def created_cache_path():
    return capabilities_cache_path().with_name("take-created.json")


def read_created(name):
    """(created, identity) from take.json, or None when it is missing or unusable. The identity is the file's inode,
    mtime and size, which tells a reused take name from the take the cache entry was made for."""
    try:
        path = RECOVERY / name / "take.json"
        info = path.stat()
        created = json.loads(path.read_text(encoding="utf-8"))["created"]
        if type(created) in (int, float) and created == created and abs(created) != float("inf"):
            return float(created), [info.st_ino, info.st_mtime_ns, info.st_size]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def take_identity(name):
    try:
        info = (RECOVERY / name / "take.json").stat()
        return [info.st_ino, info.st_mtime_ns, info.st_size]
    except OSError:
        return None


def take_rows():
    """(id, mtime) of every take directory, newest first by creation time, from one scandir pass.

    A take's creation time never changes, so take.json is read once per take and remembered in a small cache file
    (each poll is a fresh process). An entry also carries take.json's inode, mtime and size, and is re-read when
    they differ, so a reused take name never inherits a stale time. The directory mtime is only the fallback for a
    take without take.json, because retiring a WAV rewrites it."""
    rows = []
    try:
        with os.scandir(RECOVERY) as entries:
            for entry in entries:
                name = entry.name
                if len(name) != 32 or not all(c in "0123456789abcdef" for c in name):
                    continue
                try:
                    if entry.is_dir(follow_symlinks=False):
                        rows.append((name, entry.stat(follow_symlinks=False).st_mtime))
                except OSError:
                    continue
    except OSError:
        return []
    path = created_cache_path()
    try:
        cache = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(cache, dict):
            cache = {}
    except (OSError, ValueError):
        cache = {}
    changed = False
    keyed = []
    live = set()
    for name, mtime in rows:
        live.add(name)
        entry = cache.get(name)
        identity = take_identity(name)
        created = None
        if identity is not None:
            if (isinstance(entry, list) and len(entry) == 2 and type(entry[0]) in (int, float)
                    and entry[1] == identity):
                created = entry[0]
            else:
                found = read_created(name)
                if found is not None:
                    created = found[0]
                    cache[name] = [found[0], found[1]]
                    changed = True
        if created is None and name in cache:
            del cache[name]
            changed = True
        keyed.append((created if created is not None else mtime, name, mtime))
    for name in [name for name in cache if name not in live]:
        del cache[name]
        changed = True
    if changed:
        try:
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            atomic_json(path, cache)
        except OSError:
            pass
    keyed.sort(reverse=True)
    return [(name, mtime) for _, name, mtime in keyed]


def take_entry(name, mtime, preview=True):
    transcript = RECOVERY / name / "transcript.txt"
    has_transcript = transcript.is_file()
    text = ""
    if preview and has_transcript:
        text = " ".join(transcript.read_text(encoding="utf-8").split())[:36]
    return {"id": name, "transcript": has_transcript, "audio": (RECOVERY / name / "recording.wav").is_file(),
            "preview": text, "mtime": mtime}


def words_today(entries=None):
    today = time.localtime().tm_yday
    year = time.localtime().tm_year
    total = 0
    for entry in entries if entries is not None else recent_dictations(limit=None, previews=False):
        if not entry["transcript"]:
            continue
        stamp = time.localtime(entry["mtime"])
        if stamp.tm_yday == today and stamp.tm_year == year:
            transcript = RECOVERY / entry["id"] / "transcript.txt"
            total += len(transcript.read_text(encoding="utf-8").split())
    return total


def recent_dictations(limit=5, previews=True):
    """Newest takes first. Only the rows returned are opened: file flags for each, transcript text for the preview."""
    return [take_entry(name, mtime, previews) for name, mtime in (take_rows() if limit is None else take_rows()[:limit])]


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


def client_missing():
    """True when the packaged or user-local client is gone, e.g. after `pacman -R` without the setup uninstall."""
    return not LAUNCHER.exists()


def state():
    if client_missing():
        return {"running": False, "state": "unavailable", "client": "missing"}
    if not LAUNCHER.is_file() or not CONFIG.is_file():
        return {"running": False, "state": "unavailable", "error": "Mouthtype installation is missing"}
    result = session_call("status", timeout=5)
    try:
        status = json.loads(result.stdout)
    except json.JSONDecodeError:
        status = {}
    running = result.returncode == 0 and status.get("error") != "unavailable"
    entries = recent_dictations(limit=None, previews=False)
    transcripts = [entry for entry in entries if entry["transcript"]]
    for entry in transcripts[:5]:
        entry["preview"] = " ".join((RECOVERY / entry["id"] / "transcript.txt").read_text(encoding="utf-8").split())[:36]
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
            "welcomed": preferences().get("welcomed") is True,
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
    result = session_call(command, identity, timeout=timeout)
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
    elif field == "microphone" and value == "default":
        config.pop("capture_target", None)
    elif field == "microphone" and value:
        if value not in [item["name"] for item in module_commands()["microphones"]()["sources"]]:
            raise RuntimeError("That microphone is not connected")
        config["capture_target"] = value
    elif field == "slash_commands" and value in {"on", "off"}:
        config["slash_commands"] = value == "on"
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


def cleanup_cancel():
    if not setup_running():
        raise RuntimeError("Cleanup preparation is not running")
    CLEANUP_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    (CLEANUP_DIR / "cleanup-cancel").write_text("", encoding="utf-8")
    time.sleep(0.5)
    output = state()
    output["page"] = "cleanup"
    output["message"] = "Cancelling cleanup preparation"
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


def systemctl_user(*arguments, timeout=10, quiet=False):
    """Run systemctl --user, turning a failure into a message that says why (usually: no systemd user session)."""
    result = subprocess.run(["systemctl", "--user", *arguments], capture_output=True, text=True, timeout=timeout)
    if result.returncode and not quiet:
        detail = (result.stderr or result.stdout).strip().splitlines()
        reason = detail[-1] if detail else f"exit status {result.returncode}"
        raise RuntimeError(f"systemctl --user {arguments[0]} failed: {reason}. "
                           "It needs a logged-in systemd user session (a graphical Omarchy login).")
    return result


def set_autostart(value):
    if value not in {"on", "off"}:
        raise RuntimeError("Unsupported login setting")
    if UNIT.exists() and UNIT_MARKER not in UNIT.read_text(encoding="utf-8"):
        raise RuntimeError("An existing Mouthtype user service was not changed")
    if value == "on":
        if shutil.which("systemctl") is None:
            raise RuntimeError("systemd user services are unavailable")
        if not UNIT.exists() and VENDOR_UNIT.is_file():
            systemctl_user("enable", UNIT.name)
            return state()
        if legacy_unit_enabled():
            # Older installs linked into default.target; unlink it while the old unit still names that target.
            systemctl_user("disable", UNIT.name)
        existed = UNIT.exists()
        UNIT.parent.mkdir(parents=True, exist_ok=True)
        unit = ("[Unit]\nDescription=Mouthtype Linux dictation service\n"
                "PartOf=graphical-session.target\n"
                "After=graphical-session.target pipewire.service\n\n"
                "[Service]\nType=simple\n" + UNIT_MARKER + "\n"
                f"ExecStart={unit_quote(LAUNCHER)} --config {unit_quote(CONFIG)} serve --lifetime-seconds 86400\n"
                "Restart=always\nRestartSec=2\n\n"
                "[Install]\nWantedBy=graphical-session.target\n")
        UNIT.write_text(unit, encoding="utf-8")
        try:
            systemctl_user("daemon-reload")
            systemctl_user("enable", UNIT.name)
        except (RuntimeError, subprocess.SubprocessError):
            if not existed:
                UNIT.unlink(missing_ok=True)  # Leave nothing half-installed when systemd was not reachable.
            raise
    else:
        if UNIT.exists() or unit_enabled():
            systemctl_user("disable", UNIT.name)
    return state()


def assert_key_free(spec, mask, key, ours):
    """Refuse a key Hyprland already binds, unless the existing binding is the Mouthtype block being rewritten."""
    result = subprocess.run(["hyprctl", "-j", "binds"], text=True, capture_output=True,
                            check=True, timeout=5)
    for binding in json.loads(result.stdout):
        bound = str(binding.get("key", ""))
        same_key = bound.upper() == key.upper() or (key.startswith("code:") and str(binding.get("keycode")) == key[5:])
        if same_key and binding.get("modmask") == mask and not ours:
            raise RuntimeError(spec + " is already bound in Hyprland; choose another key")


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
        assert_key_free(spec, mask, key, ours)
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


def transform_shortcut_keys():
    if not BINDINGS.is_file():
        return ""
    contents = BINDINGS.read_text(encoding="utf-8")
    if TRANSFORM_BEGIN not in contents or TRANSFORM_END not in contents:
        return ""
    match = re.search(r'bind\("([^"]+)"', contents.split(TRANSFORM_BEGIN, 1)[1].split(TRANSFORM_END, 1)[0])
    return match.group(1) if match else ""


def set_transform_shortcut(value, keys=None):
    """Bind (on) or unbind (off) the key that opens the Transform Selection panel, in its own marked block."""
    if value not in {"off", "on"}:
        raise RuntimeError("Unsupported transform shortcut")
    if not BINDINGS.is_file():
        raise RuntimeError("Hyprland bindings file is missing")
    spec, mask, key = parse_shortcut(keys or DEFAULT_TRANSFORM_SHORTCUT) if value == "on" else ("", 0, "")
    original = BINDINGS.read_text(encoding="utf-8")
    before, separator, after = original.partition(TRANSFORM_BEGIN)
    if separator:
        if TRANSFORM_END not in after:
            raise RuntimeError("Existing Mouthtype transform shortcut block is incomplete")
        base = before.rstrip() + after.split(TRANSFORM_END, 1)[1]
    else:
        base = original.rstrip() + "\n"
    if value == "on":
        current = transform_shortcut_keys()
        assert_key_free(spec, mask, key, bool(current) and parse_shortcut(current)[0] == spec)
        dictation = shortcut_info()["keys"]
        if dictation and parse_shortcut(dictation)[0] == spec:
            raise RuntimeError(spec + " is already the dictation shortcut; choose another key")
        command = Path(__file__).resolve()
        block = (f'if type(o) == "table" and type(o.bind) == "function" then\n'
                 f'  o.bind("{spec}", "Mouthtype transform selection", "{command} transform-open")\n'
                 f'else\n'
                 f'  hl.bind("{spec}", hl.dsp.exec_cmd("{command} transform-open"))\n'
                 f'end')
        updated = base.rstrip() + "\n\n" + TRANSFORM_BEGIN + "\n" + block + "\n" + TRANSFORM_END + "\n"
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
        raise RuntimeError("Transform shortcut change was reverted because Hyprland rejected it")
    return state()


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
    entries = [{"id": name, "mtime": mtime} for name, mtime in reversed(take_rows())]
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


def concealed_copy_command():
    """wl-copy argv that keeps the text out of clipboard history; plain when wl-copy predates --sensitive."""
    if str(DESKTOP) not in sys.path:
        sys.path.insert(0, str(DESKTOP))
    import concealed
    return concealed.copy_command()


def latest_transcript(identity=None):
    if identity is None:
        # Newest by creation time, so retiring an old take's WAV cannot promote it.
        identity = next((name for name, _ in take_rows() if (RECOVERY / name / "transcript.txt").is_file()), None)
    if identity is None:
        raise RuntimeError("No saved dictation is available")
    return recover(identity)["text"]


def copy_transcript(identity=None):
    if shutil.which("wl-copy") is None:
        raise RuntimeError("wl-copy is not installed")
    text = latest_transcript(identity)
    subprocess.run(concealed_copy_command(), input=text.encode("utf-8"),
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
    subprocess.run(concealed_copy_command(), input=text.encode("utf-8"),
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
    "set-autostart", "set-shortcut", "set-transform-shortcut", "import-pick", "import-start", "import-cancel",
    "import-forget", "import-result", "import-copy", "import-save", "set-pill", "set-font", "cleanup-setup", "cleanup-cancel", "set-plugin"
,
    "forget", "prune", "remove-leftovers"
}

# The verbs the shortcut and the bar widget send; with the client gone they notify instead of failing silently.
SHORTCUT_VERBS = {"start", "stop", "toggle", "cancel", "paste-last"}
REMOVED_NOTICE = LOG.parent / "removed-notice"
REMOVED_TEXT = "Mouthtype was removed. Open its bar menu to clean up."


def notify_removed(now=None):
    """One notify-send saying the client is gone, at most once a minute. Returns True when it sent one."""
    now = time.time() if now is None else now
    try:
        if now - REMOVED_NOTICE.stat().st_mtime < 60:
            return False
    except OSError:
        pass
    command = shutil.which("notify-send")
    if command is None:
        return False
    try:
        REMOVED_NOTICE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        REMOVED_NOTICE.touch()
        os.utime(REMOVED_NOTICE, (now, now))
        subprocess.run([command, "-a", "Mouthtype", "Mouthtype", REMOVED_TEXT], check=False, timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return False
    return True


def remove_leftovers():
    """Run this plugin copy's own installer --uninstall, detached: it deletes this directory and restarts the shell."""
    installer = PLUGIN_DIR / "install.py"
    if not installer.is_file():
        raise RuntimeError("The plugin installer is missing")
    subprocess.Popen([sys.executable, str(installer), "--uninstall"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    return {"message": "Removing the widget and shortcuts"}

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
    import inspect
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
    ) or (sys.argv[1] in {"set-shortcut", "set-transform-shortcut"} and len(sys.argv) not in {3, 4}
    ) or (sys.argv[1] == "copy" and len(sys.argv) not in {2, 3}) or (
        sys.argv[1] in {"set-config", "set-font"} and len(sys.argv) not in {4, 5}
    ) or (
        sys.argv[1] in {"set-pill", "set-plugin"} and len(sys.argv) != 4
    ) or (sys.argv[1] in {"state", "start-service", "shutdown", "start", "stop", "cancel", "toggle", "paste-last",
                          "import-pick", "import-cancel", "import-forget", "import-result", "import-copy", "import-save",
                          "remove-leftovers"}
          and len(sys.argv) != 2):
        print(json.dumps({"error": "Unknown control action"}))
        return 2
    try:
        action = sys.argv[1]
        if action in SHORTCUT_VERBS and client_missing():
            notify_removed()
            print(json.dumps({"client": "missing", "error": "Mouthtype was removed"}))
            return 1
        if action == "state":
            output = state()
        elif action == "remove-leftovers":
            output = remove_leftovers()
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
        elif action == "cleanup-cancel" and len(sys.argv) == 2:
            output = cleanup_cancel()
        elif action == "set-plugin":
            output = set_plugin(sys.argv[2], sys.argv[3])
        elif action == "set-pill":
            output = set_pill(sys.argv[2], sys.argv[3])
        elif action == "set-font":
            output = set_font(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) == 5 else None)
        elif action == "set-sounds" and len(sys.argv) == 3:
            output = set_sounds(sys.argv[2])
        elif action == "set-autostart" and len(sys.argv) == 3:
            output = set_autostart(sys.argv[2])
        elif action == "set-transform-shortcut":
            output = set_transform_shortcut(sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
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
