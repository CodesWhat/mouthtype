# KDE Plasma testbed (Fedora 44)

A headless Plasma Wayland session for the Mouthtype portal work: `kwin_wayland --virtual`, `xdg-desktop-portal` and `xdg-desktop-portal-kde`, no GPU, no systemd. Test aid only.

Run it on the NAS test engine, never local Docker:

```bash
cd tools/linux-desktop/testbed/kde
bash ~/scripts/nas-docker.sh build -t ld-t3-kde:test .
bash ~/scripts/nas-docker.sh run --rm --name ld-t3-run ld-t3-kde:test
```

`run.sh` starts the session, marks `app.mouthtype.Mouthtype` as mega-authorized (permission store table `kde-authorized`, id `remote-desktop`, value `yes`, which makes the KDE RemoteDesktop portal skip its consent dialog), and writes `versions.json` (rpm versions), `probe.json` (portal interface versions) and the component logs to `/var/lib/testbed`. If `/opt/mouthtype/tools/linux-desktop/portal_probe.py` is present it runs that for `probe.json`, otherwise it records portal interface versions by introspection.

The image installs with `tsflags=nocaps` because the NAS engine's storage can't set file capabilities. Record the printed package versions in any evidence: Fedora 44 ships a mix of Plasma versions.

## Portal probe

`probe.Dockerfile` layers `portal.py` and `portal_probe.py` onto this image so `run.sh` fills `probe.json` with the real probe (interface versions, Registry, shortcut bind and Activated/Deactivated timing). Build it with `tools/linux-desktop` as the context. The probe has no AT-SPI answerer, so its shortcut bind still waits on the consent dialog; the acceptance run answers it.

## Acceptance

`acceptance.Dockerfile` and `acceptance.sh` layer the daemon sources, the Qt host and the Omarchy QML on this image and run `acceptance.py kde-portal` (item A2a):

- A take started through the daemon's `toggle` command (fake capture and engine, real portal delivery), pasted into a GTK target exactly once, clipboard restored, and a password field refused when AT-SPI reports focus under kwin. RemoteDesktop is pre-authorized by the permission store.
- A GlobalShortcuts bind. The backend shows its own "Global Shortcuts Requested" window, and `consent_atspi` presses OK on it. This needs no plasmashell: the image already carries `plasma-workspace` and the run passes with `plasmashell` running or not, so `acceptance.sh` leaves it out (it also logs a `kactivitymanagerd` abort here). `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` is exported before the backend starts so the dialog exports an AT-SPI tree.
- A held Ctrl+Alt+M chord, sent through the daemon's RemoteDesktop session, that must produce exactly one `start` on Activated and one `stop` on Deactivated.
- The pill. The real Qt host (`tools/linux-qt/mouthtype_desktop.py`, PySide6) runs on the daemon's `watch` stream. `kwin_pill.py` loads a KWin script that reports `windowAdded` and `windowRemoved` over D-Bus (`workspace.windowList()` does not list layer-shell surfaces), and the run requires an overlay-layer surface that maps during the hold, sits bottom-centre of the 1280x800 output and unmaps afterwards. The host is started with `--background`, the login-autostart path (no settings window, tray only). `acceptance.py kde-portal --foreground` launches it as a normal launch instead.

```bash
cd tools
bash ~/scripts/nas-docker.sh build -f linux-desktop/testbed/kde/acceptance.Dockerfile -t ld-a2a-kde:test .
bash ~/scripts/nas-docker.sh run --rm --name ld-a2a-run ld-a2a-kde:test
```
