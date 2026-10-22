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
