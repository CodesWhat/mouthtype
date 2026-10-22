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
UNIT = Path.home() / ".config/systemd/user/mouthtype-linux.service"
BINDINGS = Path.home() / ".config/hypr/bindings.lua"
PREFS = Path.home() / ".config/mouthtype/omarchy-plugin.json"
BIND_BEGIN = "-- Mouthtype Omarchy plugin shortcut: begin"
BIND_END = "-- Mouthtype Omarchy plugin shortcut: end"
TRANSFORM_BEGIN = "-- Mouthtype Omarchy plugin transform shortcut: begin"
TRANSFORM_END = "-- Mouthtype Omarchy plugin transform shortcut: end"
PLUGIN_ID = "dstahl.mouthtype"
UNIT_MARKER = "# Managed by the Mouthtype Omarchy plugin"


def read_versions(source=SOURCE):
    """The plugin version from manifest.json and, when this is a repository checkout, the app version from packaging/Version.plist."""
    plugin = app = None
    try:
        value = json.loads((source / "manifest.json").read_text(encoding="utf-8")).get("version")
        plugin = value if isinstance(value, str) else None
    except (OSError, ValueError, AttributeError):
        pass
    try:
        for path in (source.parent / "Version.plist", source.parent.parent / "packaging/Version.plist"):
            try:
                with open(path, "rb") as handle:
                    value = plistlib.load(handle).get("MouthtypeDisplayVersion")
            except OSError:
                continue
            app = value if isinstance(value, str) else None
            break
    except (ValueError, plistlib.InvalidFileException):
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


def quiet_notifications():
    """The bar pill already shows recording and transcribing, so move a default `notifications: true` to "errors".

    Only the untouched default changes: an explicit false, or a value already set, stands. Returns True when the file changed."""
    config = Path.home() / ".local/share/mouthtype/speech-candidate/linux.json"
    try:
        data = json.loads(config.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    if not isinstance(data, dict) or data.get("notifications") is not True:
        return False
    data["notifications"] = "errors"
    fd, temporary = tempfile.mkstemp(prefix=".linux-", dir=config.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2)
            handle.write("\n")
        os.chmod(temporary, config.stat().st_mode & 0o777)
        os.replace(temporary, config)
    except OSError:
        return False
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def parse(argv):
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true", help="Replace an existing installed plugin's files in place")
    parser.add_argument("--uninstall", action="store_true",
                        help="Remove the plugin, its bar entry, login service, shortcut block and settings file")
    parser.add_argument("--purge", action="store_true",
                        help="With --uninstall, also delete models, recordings and configuration under ~/.local/share|state|.config/mouthtype")
    parser.add_argument("--no-transform-shortcut", action="store_true",
                        help="Do not bind Super+Shift+T to open Transform Selection (refused anyway if Hyprland already uses it)")
    parser.add_argument("--copy", action="store_true",
                        help="Copy the plugin into ~/.config/omarchy/plugins instead of using Omarchy's `omarchy plugin add`")
    parser.add_argument("--no-autostart", action="store_true", help="Do not enable the login service that starts dictation at boot")
    parser.add_argument("--no-restart-shell", action="store_true", help="Do not restart the Omarchy shell afterwards")
    parser.add_argument("--shortcut", choices=("toggle", "hold"),
                        help="Also bind the default dictation key (toggle: Super+Alt+M, hold: F10), refusing a key Hyprland already uses")
    return parser.parse_args(argv)


def load_shell():
    if not SHELL.is_file():
        raise ValueError(f"Omarchy shell configuration not found at {SHELL}. This installer is for Omarchy's "
                         "Quickshell desktop; run it on an Omarchy install after the shell has started once.")
    try:
        data = json.loads(SHELL.read_text())
    except ValueError as error:
        raise ValueError(f"{SHELL} is not valid JSON ({error}); fix or restore it, then run this again") from error
    if not isinstance(data, dict) or data.get("version") != 1:
        raise ValueError(f"Unknown Omarchy shell configuration version in {SHELL}; this plugin supports version 1")
    return data


def write_shell(data):
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
    return backup


def restart_shell(args):
    if not args.no_restart_shell and shutil.which("omarchy-restart-shell"):
        subprocess.run(["omarchy-restart-shell"], check=False, timeout=90, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    return False


def uninstall(args):
    """Undo install: service, shortcut block, bar entry, plugin files, plugin settings. Models and recordings stay unless --purge."""
    systemctl = shutil.which("systemctl")
    if not UNIT.exists() and systemctl and Path("/usr/lib/systemd/user/mouthtype-linux.service").is_file():
        # The packaged unit is not ours to delete; just stop it and drop this user's enable link.
        for verb in ("disable", "stop"):
            subprocess.run([systemctl, "--user", verb, "mouthtype-linux.service"], check=False, timeout=20,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if UNIT.exists():
        if UNIT_MARKER in UNIT.read_text(encoding="utf-8"):
            if systemctl:
                for verb in ("disable", "stop"):
                    subprocess.run([systemctl, "--user", verb, UNIT.name], check=False, timeout=20,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            UNIT.unlink()
            if systemctl:
                subprocess.run([systemctl, "--user", "daemon-reload"], check=False, timeout=20,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print(f"Removed {UNIT}")
        else:
            print(f"Left {UNIT} alone: the Mouthtype plugin did not create it", file=sys.stderr)
    for begin, end, label in ((BIND_BEGIN, BIND_END, "shortcut"), (TRANSFORM_BEGIN, TRANSFORM_END, "transform shortcut")):
        if not (BINDINGS.is_file() and begin in BINDINGS.read_text(encoding="utf-8")):
            continue
        original = BINDINGS.read_text(encoding="utf-8")
        before, _, rest = original.partition(begin)
        if end in rest:
            updated = before.rstrip() + rest.split(end, 1)[1]
            backup = BINDINGS.with_name(f"bindings.lua.bak.mouthtype.{int(time.time())}")
            shutil.copy2(BINDINGS, backup)
            BINDINGS.write_text(updated.rstrip() + "\n", encoding="utf-8")
            if shutil.which("hyprctl"):
                subprocess.run(["hyprctl", "reload"], check=False, timeout=10, capture_output=True)
            print(f"Removed the Mouthtype {label} block from {BINDINGS} (backup: {backup})")
        else:
            print(f"The Mouthtype {label} block in {BINDINGS} is incomplete; remove it by hand.", file=sys.stderr)
    if SHELL.is_file():
        data = load_shell()
        changed = False
        for section in data.get("bar", {}).get("layout", {}).values():
            if isinstance(section, list):
                kept = [entry for entry in section if not (isinstance(entry, dict) and entry.get("id") == "dstahl.mouthtype")]
                changed = changed or len(kept) != len(section)
                section[:] = kept
        if changed:
            print(f"Removed the bar entry from {SHELL} (backup: {write_shell(data)})")
    if TARGET.exists() or TARGET.is_symlink():
        shutil.rmtree(TARGET) if TARGET.is_dir() and not TARGET.is_symlink() else TARGET.unlink()
        print(f"Removed {TARGET}")
    if PREFS.exists():
        PREFS.unlink()
    if args.purge:
        for directory in (Path.home() / ".local/share/mouthtype", Path.home() / ".local/state/mouthtype",
                          Path.home() / ".config/mouthtype"):
            if directory.is_dir():
                shutil.rmtree(directory)
                print(f"Deleted {directory}")
    else:
        print("Models, recordings and settings under ~/.local/share/mouthtype, ~/.local/state/mouthtype and "
              "~/.config/mouthtype were kept. Add --purge to delete them.")
    if restart_shell(args):
        print("Omarchy shell restarted.")


def add_with_omarchy():
    """Install through Omarchy's own `omarchy plugin add` (validates the manifest, rescans and enables it in the running shell).

    That command only takes a git URL or path to a repository whose root is the plugin, and our plugin is a subfolder of the
    Mouthtype repository (or a packaged copy with no git history). So a one-commit repository of the plugin files is made in a
    temporary directory and handed to it. Returns True when the plugin is in place; False means use the file copy."""
    command = shutil.which("omarchy-plugin-add")
    git = shutil.which("git")
    if not command or not git:
        return False
    with tempfile.TemporaryDirectory(prefix="mouthtype-plugin-") as scratch:
        stage = Path(scratch) / "plugin"
        shutil.copytree(SOURCE, stage, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".git"))
        try:
            for step in (["init", "-q"], ["add", "-A"],
                         ["-c", "user.name=Mouthtype", "-c", "user.email=mouthtype@localhost", "commit", "-q", "-m", "Mouthtype plugin"]):
                subprocess.run([git, "-C", str(stage)] + step, check=True, timeout=60, capture_output=True)
            result = subprocess.run([command, str(stage), "--yes", "--enable"], timeout=180, capture_output=True, text=True)
        except (OSError, subprocess.SubprocessError):
            return False
    if result.returncode or not (TARGET / "manifest.json").is_file():
        print("omarchy plugin add did not complete (" + (result.stderr.strip().splitlines() or ["no output"])[-1] +
              "); copying the files instead.", file=sys.stderr)
        if TARGET.is_dir() and not TARGET.is_symlink():
            shutil.rmtree(TARGET, ignore_errors=True)
        return False
    print("Added through `omarchy plugin add`; update it with this installer's --update, not `omarchy plugin update`.")
    return True


def main(argv=None):
    args = parse(argv)
    if args.uninstall:
        return uninstall(args)
    if (TARGET.exists() or TARGET.is_symlink()) and not args.update:
        raise FileExistsError(f"Plugin already exists: {TARGET} (use --update to replace its files)")
    load_shell()
    # Omarchy's own command first: it validates, registers and enables the plugin in the running shell. The copy below is the fallback.
    added = not args.update and not args.copy and add_with_omarchy()
    data = load_shell()
    right = data.get("bar", {}).get("layout", {}).get("right")
    if not isinstance(right, list):
        raise ValueError(f"{SHELL} has no bar layout to add the widget to (expected bar.layout.right)")
    entry_added = False
    if not any(entry.get("id") == PLUGIN_ID for entry in right):
        index = next((i for i, entry in enumerate(right) if entry.get("id") == "dstahl.agents"), len(right))
        right.insert(index, {"id": PLUGIN_ID})
        entry_added = True
    launcher = shutil.which("mouthtype-linux") or next(
        (str(path) for path in (Path.home() / ".local/bin/mouthtype-linux", Path("/usr/bin/mouthtype-linux")) if path.is_file()), None)
    if launcher is None:
        print("Warning: mouthtype-linux is not installed, so the widget will show Unavailable until it is "
              "(install the package, or tools/linux-desktop/install.py).", file=sys.stderr)
    elif not (Path.home() / ".local/share/mouthtype/speech-candidate/linux.json").is_file():
        print("Warning: no speech setup yet, so the widget will show Unavailable until you run "
              "tools/linux-desktop/setup.py (or setup_speech.py).", file=sys.stderr)

    if not added:
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
    if quiet_notifications():
        print('Desktop notifications set to errors only (the bar pill shows the rest); change it in Settings.')
        subprocess.run(["systemctl", "--user", "try-restart", "mouthtype-linux.service"], check=False, timeout=20,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print(TARGET)
    if not added or entry_added:
        print(f"Config backup: {write_shell(data)}")
    if not args.no_autostart:
        # Default: the dictation service starts with the graphical session and is supervised by systemd.
        result = subprocess.run([sys.executable, str(TARGET / "control.py"), "set-autostart", "on"],
                                capture_output=True, text=True, timeout=60)
        try:
            outcome = json.loads(result.stdout or "{}")
        except json.JSONDecodeError:
            outcome = {}
        if result.returncode or outcome.get("error"):
            print("Launch at login was not enabled: " + str(outcome.get("error") or result.stderr.strip() or "systemctl failed"),
                  file=sys.stderr)
        else:
            print("Launch at login enabled (systemd user service mouthtype-linux); disable it from the menu or with --no-autostart.")
            if not outcome.get("running"):
                subprocess.run(["systemctl", "--user", "start", "mouthtype-linux.service"], check=False, timeout=20,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if args.shortcut:
        result = subprocess.run([sys.executable, str(TARGET / "control.py"), "set-shortcut", args.shortcut],
                                capture_output=True, text=True, timeout=60)
        try:
            outcome = json.loads(result.stdout or "{}")
        except json.JSONDecodeError:
            outcome = {}
        if result.returncode or outcome.get("error"):
            print("Shortcut was not bound: " + str(outcome.get("error") or result.stderr.strip() or "unknown error") +
                  ". Choose a key from the Mouthtype menu instead.", file=sys.stderr)
        else:
            print(f"Dictation shortcut bound ({args.shortcut}); change it from the menu.")
    if not args.no_transform_shortcut:
        result = subprocess.run([sys.executable, str(TARGET / "control.py"), "set-transform-shortcut", "on"],
                                capture_output=True, text=True, timeout=60)
        try:
            outcome = json.loads(result.stdout or "{}")
        except json.JSONDecodeError:
            outcome = {}
        if result.returncode or outcome.get("error"):
            print("Transform shortcut was not bound: " + str(outcome.get("error") or result.stderr.strip() or "unknown error") +
                  ". Bind control.py transform-open to a free key yourself, or ignore this.", file=sys.stderr)
        else:
            print("Transform Selection shortcut bound (Super+Shift+T); skip it with --no-transform-shortcut.")
    if restart_shell(args):
        print("Omarchy shell restarted; the Mouthtype glyph is on the right side of the bar.")


if __name__ == "__main__":
    try:
        main()
    except FileExistsError as error:
        print(f"Mouthtype plugin installation failed: {error}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError) as error:
        print(f"Mouthtype plugin installation failed: {error}", file=sys.stderr)
        sys.exit(1)
