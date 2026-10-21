"""Dictionary and Transforms library verbs for the panel.

Each verb prints the JSON the same-named desktop.py command prints (see tools/linux-desktop/README.md) and works
without the service running. The editing code lives in tools/linux-desktop/library.py.
"""

import importlib
from pathlib import Path
import sys

HOME = Path.home()
CONFIG = HOME / ".local/share/mouthtype/speech-candidate/linux.json"
DESKTOP_DIRS = (HOME / ".local/lib/mouthtype-linux/tools/linux-desktop",
                Path(__file__).resolve().parent.parent / "linux-desktop")


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
}
