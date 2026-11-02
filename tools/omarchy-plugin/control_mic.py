"""`microphones` and `mic-test` verbs for the panel (see tools/linux-desktop/microphones.py)."""

import importlib.util
import json
import sys
from pathlib import Path

HOME = Path.home()
HERE = Path(__file__).resolve().parent
CONFIG = HOME / ".local/share/mouthtype/speech-candidate/linux.json"
# The installed layout first, then the source checkout beside this plugin.
DESKTOP_DIRS = (HOME / ".local/lib/mouthtype-linux/tools/linux-desktop",
                Path("/usr/lib/mouthtype-linux/tools/linux-desktop"),
                HERE.parent / "linux-desktop")


def load_microphones():
    for directory in DESKTOP_DIRS:
        source = directory / "microphones.py"
        if source.is_file() and not source.is_symlink():
            if str(directory) not in sys.path:
                sys.path.insert(0, str(directory))
            spec = importlib.util.spec_from_file_location("mouthtype_microphones_engine", source)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module, directory
    raise RuntimeError("Microphone support is unavailable in this install")


def configured_target():
    try:
        target = json.loads(CONFIG.read_text(encoding="utf-8")).get("capture_target")
    except (OSError, ValueError):
        return None
    return target if isinstance(target, str) and target else None


def microphones():
    module, _ = load_microphones()
    target = configured_target()
    sources = module.list_sources()
    names = [item["name"] for item in sources]
    return {"sources": sources, "selected": target if target in names else "default",
            "configured": target, "missing": bool(target) and target not in names,
            "muted": module.default_muted()}


def mic_test():
    module, _ = load_microphones()
    from desktop import PipeWireCapture
    return module.level_test(PipeWireCapture(configured_target()))


COMMANDS = {"microphones": microphones, "mic-test": mic_test}
