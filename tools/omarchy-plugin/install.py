#!/usr/bin/env python3
"""Install the local Mouthtype widget into this user's Omarchy shell."""

import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time


SOURCE = Path(__file__).resolve().parent
CONFIG_ROOT = Path.home() / ".config/omarchy"
TARGET = CONFIG_ROOT / "plugins/dstahl.mouthtype"
SHELL = CONFIG_ROOT / "shell.json"


def main():
    if TARGET.exists() or TARGET.is_symlink():
        raise FileExistsError(f"Plugin already exists: {TARGET}")
    data = json.loads(SHELL.read_text())
    if data.get("version") != 1:
        raise ValueError("Unknown Omarchy shell configuration version")
    right = data["bar"]["layout"]["right"]
    if not any(entry.get("id") == "dstahl.mouthtype" for entry in right):
        index = next((i for i, entry in enumerate(right) if entry.get("id") == "dstahl.agents"), len(right))
        right.insert(index, {"id": "dstahl.mouthtype"})

    TARGET.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(SOURCE, TARGET, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    (TARGET / "control.py").chmod(0o755)

    backup = SHELL.with_name(f"shell.json.bak.mouthtype.{int(time.time())}")
    shutil.copy2(SHELL, backup)
    fd, temporary = tempfile.mkstemp(prefix=".shell-mouthtype-", dir=CONFIG_ROOT)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(data, output, indent=2)
            output.write("\n")
        os.chmod(temporary, SHELL.stat().st_mode & 0o777)
        os.replace(temporary, SHELL)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(TARGET)
    print(f"Config backup: {backup}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        print(f"Mouthtype plugin installation failed: {error}", file=sys.stderr)
        sys.exit(1)
