"""Dictionary and Transforms library verbs for the panel.

Each verb prints the JSON the same-named desktop.py command prints (see tools/linux-desktop/README.md) and works
without the service running. The editing code lives in tools/linux-desktop/library.py.
"""

import importlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

HOME = Path.home()
CONFIG = HOME / ".local/share/mouthtype/speech-candidate/linux.json"
DESKTOP_DIRS = (HOME / ".local/lib/mouthtype-linux/tools/linux-desktop",
                Path(__file__).resolve().parent.parent / "linux-desktop")


def _drafts_dir():
    state = os.environ.get("XDG_STATE_HOME")
    base = Path(state) if state and os.path.isabs(state) else HOME / ".local/state"
    return base / "mouthtype" / "drafts"


DRAFT_VERSION = 1
DRAFT_KEEP_SECONDS = 7 * 86400
DRAFT_ID = re.compile(r"(spelling|phrase)-[0-9]{1,20}(-[0-9]{1,4})?")


def _draft_from(raw):
    """A draft dict from untrusted input, or None. Every field but `kind` is optional, like the Mac's decoder."""
    if not isinstance(raw, dict) or raw.get("kind") not in ("spelling", "phrase"):
        return None

    def text(key):
        value = raw.get(key, "")
        return value if isinstance(value, str) else ""

    forms = raw.get("heardForms", [])
    forms = [item for item in forms if isinstance(item, str)] if isinstance(forms, list) else []
    return {"version": DRAFT_VERSION, "kind": raw["kind"], "heardForms": forms, "heardInput": text("heardInput"),
            "written": text("written"), "starred": raw.get("starred") is True, "trigger": text("trigger"),
            "expansion": text("expansion")}


def _draft_is_empty(draft):
    return not (any(draft["heardForms"]) or draft["heardInput"] or draft["written"] or draft["trigger"] or draft["expansion"])


def _drafts_list(now=None):
    """Readable drafts oldest first. Prunes files past a week, removes blank ones, skips malformed and newer-version files."""
    directory = _drafts_dir()
    now = time.time() if now is None else now
    found = []
    try:
        paths = sorted(path for path in directory.iterdir() if path.suffix == ".json" and path.is_file() and not path.is_symlink())
    except OSError:
        return found
    for path in paths:
        try:
            saved = path.stat().st_mtime
            if now - saved > DRAFT_KEEP_SECONDS:
                path.unlink()
                continue
            raw = json.loads(path.read_text(encoding="utf-8"))
            if not DRAFT_ID.fullmatch(path.stem) or not isinstance(raw, dict):
                continue
            version = raw.get("version", 0)
            if isinstance(version, bool) or not isinstance(version, int) or version > DRAFT_VERSION:
                continue
            draft = _draft_from(raw)
            if draft is None:
                continue
            if _draft_is_empty(draft):
                path.unlink()
                continue
        except (OSError, ValueError):
            continue
        draft.update(id=path.stem, saved=saved)
        found.append(draft)
    found.sort(key=lambda item: (item["saved"], item["id"]))
    return found


def draft_list():
    return {"drafts": _drafts_list()}


def draft_save(payload):
    try:
        raw = json.loads(payload)
    except ValueError:
        raise RuntimeError("The draft is not valid JSON")
    draft = _draft_from(raw)
    if draft is None:
        raise RuntimeError("The draft needs a kind of spelling or phrase")
    if not _draft_is_empty(draft):
        directory = _drafts_dir()
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        stamp = int(time.time() * 1000)
        for attempt in range(1000):
            draft_id = f"{draft['kind']}-{stamp}" + (f"-{attempt}" if attempt else "")
            if not (directory / f"{draft_id}.json").exists():
                break
        fd, temp = tempfile.mkstemp(dir=directory, prefix=".draft-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(draft, handle)
            os.chmod(temp, 0o600)
            os.replace(temp, directory / f"{draft_id}.json")
        except BaseException:
            Path(temp).unlink(missing_ok=True)
            raise
    return {"drafts": _drafts_list()}


def draft_clear(draft_id=""):
    """Removes one draft by id, or every draft when no id is given."""
    directory = _drafts_dir()
    if draft_id:
        if not DRAFT_ID.fullmatch(draft_id):
            raise RuntimeError("That is not a draft id")
        (directory / f"{draft_id}.json").unlink(missing_ok=True)
    else:
        for item in _drafts_list():
            (directory / f"{item['id']}.json").unlink(missing_ok=True)
    return {"drafts": _drafts_list()}


def _library():
    for directory in DESKTOP_DIRS:
        if (directory / "library.py").is_file():
            if str(directory) not in sys.path:
                sys.path.insert(0, str(directory))
            return importlib.import_module("library")
    raise RuntimeError("The Mouthtype Linux service files are missing")


def _option(value):
    return value or None


def spellings_list():
    return _library().list_library(CONFIG, "spellings")


def spellings_add(heard, written):
    return _library().add_spelling(CONFIG, heard, written)


def spellings_edit(heard, new_heard, new_written, expect_written=""):
    return _library().edit_spelling(CONFIG, heard, new_heard, new_written, _option(expect_written))


def spellings_remove(heard, expect_written=""):
    return _library().remove_spelling(CONFIG, heard, _option(expect_written))


def spellings_import_preview(path):
    return _library().preview_import(CONFIG, path)


def spellings_import(path, expect_digest="", expect_csv_digest=""):
    return _library().import_spellings(CONFIG, path, _option(expect_digest), _option(expect_csv_digest))


def phrases_list():
    return _library().list_library(CONFIG, "phrases")


def phrases_add(trigger, expansion):
    return _library().add_phrase(CONFIG, trigger, expansion)


def phrases_edit(trigger, new_trigger, new_expansion, expect_expansion=""):
    return _library().edit_phrase(CONFIG, trigger, new_trigger, new_expansion, _option(expect_expansion))


def phrases_remove(trigger, expect_expansion=""):
    return _library().remove_phrase(CONFIG, trigger, _option(expect_expansion))


COMMANDS = {
    "spellings-list": spellings_list,
    "spellings-add": spellings_add,
    "spellings-edit": spellings_edit,
    "spellings-remove": spellings_remove,
    "spellings-import-preview": spellings_import_preview,
    "spellings-import": spellings_import,
    "phrases-list": phrases_list,
    "phrases-add": phrases_add,
    "phrases-edit": phrases_edit,
    "phrases-remove": phrases_remove,
    "draft-save": draft_save,
    "draft-list": draft_list,
    "draft-clear": draft_clear,
}
