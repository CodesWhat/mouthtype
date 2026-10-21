#!/usr/bin/env python3
"""Install the local Mouthtype widget into this user's Omarchy shell."""

import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


SOURCE = Path(__file__).resolve().parent
CONFIG_ROOT = Path.home() / ".config/omarchy"
TARGET = CONFIG_ROOT / "plugins/dstahl.mouthtype"
SHELL = CONFIG_ROOT / "shell.json"


def read_versions(source=SOURCE):
    """The plugin version from manifest.json and, when this is a repository checkout, the app version from packaging/Version.plist."""
    plugin = app = None
    try:
        value = json.loads((source / "manifest.json").read_text(encoding="utf-8")).get("version")
        plugin = value if isinstance(value, str) else None
    except (OSError, ValueError, AttributeError):
        pass
    try:
        with open(source.parent.parent / "packaging/Version.plist", "rb") as handle:
            value = plistlib.load(handle).get("MouthtypeDisplayVersion")
        app = value if isinstance(value, str) else None
    except (OSError, ValueError, plistlib.InvalidFileException):
        pass
    return {"plugin": plugin, "app": app}


def write_versions(target, versions):
    fd, temporary = tempfile.mkstemp(prefix=".version-", dir=target)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(versions, output, indent=2)
            output.write("\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, target / "version.json")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def parse(argv):
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true", help="Replace an existing installed plugin's files in place")
    parser.add_argument("--no-autostart", action="store_true", help="Do not enable the login service that starts dictation at boot")
    parser.add_argument("--no-restart-shell", action="store_true", help="Do not restart the Omarchy shell afterwards")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse(argv)
    if (TARGET.exists() or TARGET.is_symlink()) and not args.update:
        raise FileExistsError(f"Plugin already exists: {TARGET} (use --update to replace its files)")
    data = json.loads(SHELL.read_text())
    if data.get("version") != 1:
        raise ValueError("Unknown Omarchy shell configuration version")
    right = data["bar"]["layout"]["right"]
    if not any(entry.get("id") == "dstahl.mouthtype" for entry in right):
        index = next((i for i, entry in enumerate(right) if entry.get("id") == "dstahl.agents"), len(right))
        right.insert(index, {"id": "dstahl.mouthtype"})

    TARGET.parent.mkdir(parents=True, exist_ok=True)
    if args.update and TARGET.exists():
        staging = TARGET.with_name(TARGET.name + ".updating")
        if staging.exists():
            shutil.rmtree(staging)
        shutil.copytree(SOURCE, staging, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        shutil.rmtree(TARGET)
        os.rename(staging, TARGET)
    else:
        shutil.copytree(SOURCE, TARGET, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    write_versions(TARGET, read_versions())
    (TARGET / "control.py").chmod(0o755)
    (TARGET / "save_dialog.py").chmod(0o755)

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
    if not args.no_autostart:
        # Default: the dictation service starts with the graphical session and is supervised by systemd.
        result = subprocess.run([sys.executable, str(TARGET / "control.py"), "set-autostart", "on"],
                                capture_output=True, text=True, timeout=60)
        try:
            outcome = json.loads(result.stdout or "{}")
        except json.JSONDecodeError:
            outcome = {}
        if result.returncode or outcome.get("error"):
            print("Launch at login was not enabled: " + str(outcome.get("error") or "systemctl failed"), file=sys.stderr)
        else:
            print("Launch at login enabled (systemd user service mouthtype-linux); disable it from the menu or with --no-autostart.")
            if not outcome.get("running"):
                subprocess.run(["systemctl", "--user", "start", "mouthtype-linux.service"], check=False, timeout=20,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not args.no_restart_shell and shutil.which("omarchy-restart-shell"):
        subprocess.run(["omarchy-restart-shell"], check=False, timeout=90, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print("Omarchy shell restarted; the Mouthtype glyph is on the right side of the bar.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        print(f"Mouthtype plugin installation failed: {error}", file=sys.stderr)
        sys.exit(1)
