"""`stats` verb for the panel: the Stats page JSON, rebuilt from the recovery directory (see stats.py for the shape)."""

import importlib.util
import os
from pathlib import Path

HOME = Path.home()
HERE = Path(__file__).resolve().parent
RECOVERY = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "mouthtype/recovery"
# The installed layout first, then the source checkout beside this plugin.
STATS_SOURCES = (HOME / ".local/lib/mouthtype-linux/tools/linux-desktop/stats.py",
                 HERE.parent / "linux-desktop/stats.py")


def load_stats():
    for source in STATS_SOURCES:
        if source.is_file() and not source.is_symlink():
            spec = importlib.util.spec_from_file_location("mouthtype_stats_engine", source)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    raise RuntimeError("Mouthtype stats are unavailable in this install")


def stats():
    return load_stats().compute(RECOVERY)


COMMANDS = {"stats": stats}
