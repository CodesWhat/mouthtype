#!/usr/bin/env python3
"""Mark an app id as mega-authorized for the KDE RemoteDesktop portal.

xdg-desktop-portal-kde skips its consent dialog when the permission store
table `kde-authorized`, id `remote-desktop`, holds ["yes"] for the app id
(src/remotedesktop.cpp, isAppMegaAuthorized). Usage: seed-permission-store.py APP_ID
"""
import subprocess
import sys

app_id = sys.argv[1]
subprocess.run(
    ['gdbus', 'call', '--session',
     '--dest', 'org.freedesktop.impl.portal.PermissionStore',
     '--object-path', '/org/freedesktop/impl/portal/PermissionStore',
     '--method', 'org.freedesktop.impl.portal.PermissionStore.SetPermission',
     'kde-authorized', 'true', 'remote-desktop', app_id, "['yes']"],
    check=True, timeout=10)
out = subprocess.run(
    ['gdbus', 'call', '--session',
     '--dest', 'org.freedesktop.impl.portal.PermissionStore',
     '--object-path', '/org/freedesktop/impl/portal/PermissionStore',
     '--method', 'org.freedesktop.impl.portal.PermissionStore.Lookup',
     'kde-authorized', 'remote-desktop'],
    check=True, timeout=10, capture_output=True, text=True).stdout
if app_id not in out or 'yes' not in out:
    sys.exit(f'permission store lookup does not show {app_id}: {out}')
print(out.strip())
