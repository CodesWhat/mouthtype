#!/usr/bin/env python3
"""Build the Mouthtype drag-to-Applications DMG from an already signed app.

dmgbuild (pinned in scripts/dmg/requirements.txt, installed into build/dmg-venv on
first use) writes the .DS_Store window layout directly and runs hdiutil, so there is
no Finder scripting to race in CI. The volume icon is rendered from the built app's system icon. The DMG is compressed UDZO and signed when an
identity is available. Notarizing and stapling happen in scripts/package-release.py.

    python3 scripts/build-dmg.py --app build/Mouthtype.app --output build/dmg-preview/Mouthtype.dmg
"""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
VENV = ROOT / 'build/dmg-venv'
VOLUME_NAME = 'Mouthtype'
WINDOW = (660, 400)
ICON_SIZE = 128
spec = importlib.util.spec_from_file_location('dmg_background', ROOT / 'scripts/dmg/background.py')
background = importlib.util.module_from_spec(spec)
spec.loader.exec_module(background)


def ensure_dmgbuild():
    """Return the dmgbuild module, creating the pinned venv and re-exec'ing if needed."""
    python = VENV / 'bin/python3'
    if Path(sys.prefix).resolve() == VENV.resolve():
        import dmgbuild
        return dmgbuild
    if not python.exists():
        subprocess.run([sys.executable, '-m', 'venv', str(VENV)], check=True)
    subprocess.run([str(python), '-m', 'pip', 'install', '--quiet', '--disable-pip-version-check',
                    '-r', str(ROOT / 'scripts/dmg/requirements.txt')], check=True)
    os.execv(str(python), [str(python), *sys.argv])


def render_volume_icon(app, directory):
    """Volume icon from the app's own system icon, so it keeps the squircle, depth and padding."""
    tool = Path(directory) / 'volume-icon'
    subprocess.run(['swiftc', '-O', str(ROOT / 'scripts/dmg/volume-icon.swift'), '-o', str(tool)],
                   check=True, capture_output=True)
    iconset = Path(directory) / 'Volume.iconset'
    subprocess.run([str(tool), str(app), str(iconset)], check=True)
    icns = Path(directory) / 'Volume.icns'
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(icns)], check=True)
    return icns


def build_dmg(app, output, identity=None, timestamp=True):
    dmgbuild = ensure_dmgbuild()
    app, output = Path(app).resolve(), Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()
    with tempfile.TemporaryDirectory(prefix='mouthtype-dmg-') as temporary:
        background.sys.argv = ['background.py', temporary]
        background.main()
        settings = {
            'format': 'UDZO',
            'compression_level': 9,
            'filesystem': 'HFS+',
            'files': [str(app)],
            'symlinks': {'Applications': '/Applications'},
            'icon': str(render_volume_icon(app, temporary)),
            'background': str(Path(temporary) / 'background.tiff'),
            'window_rect': ((200, 160), WINDOW),
            'default_view': 'icon-view',
            'show_toolbar': False,
            'show_sidebar': False,
            'show_status_bar': False,
            'show_pathbar': False,
            'show_tab_view': False,
            'icon_size': ICON_SIZE,
            'text_size': 13,
            'arrange_by': None,
            'icon_locations': {app.name: (background.APP_X, background.ICON_Y),
                               'Applications': (background.APPS_X, background.ICON_Y)},
        }
        dmgbuild.build_dmg(str(output), VOLUME_NAME, settings=settings)
    if identity:
        stamp = '--timestamp' if timestamp else '--timestamp=none'
        subprocess.run(['codesign', '--force', stamp, '--sign', identity, str(output)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(output)], check=True)
    return output


def default_identity():
    listing = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                             capture_output=True, text=True).stdout
    for line in listing.splitlines():
        if 'Developer ID Application:' in line:
            return line.split('"')[1]
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--identity', default=os.environ.get('MOUTHTYPE_SIGN_IDENTITY') or None,
                        help='Signing identity (default: the keychain Developer ID, if any)')
    args = parser.parse_args()
    identity = args.identity or default_identity()
    timestamp = os.environ.get('MOUTHTYPE_TIMESTAMP') != 'none'
    print(build_dmg(args.app, args.output, identity, timestamp))


if __name__ == '__main__':
    main()
