# GNOME testbed notes

`Dockerfile` and `run.sh` are the headless GNOME 50 image (T1). `probe.Dockerfile` and `probe.sh` layer the portal probe on top (T2):

```bash
cd tools/linux-desktop
bash ~/scripts/nas-docker.sh build -t ld-t1-gnome:test testbed/gnome
bash ~/scripts/nas-docker.sh build -f testbed/gnome/probe.Dockerfile -t ld-t2-probe:test .
bash ~/scripts/nas-docker.sh run --rm --name ld-t2-gnome ld-t2-probe:test
```

`probe.json` is printed at the end. The probe runs with `--consent atspi`: `consent_atspi.py` finds the "Add Keyboard Shortcuts" window that `gnome-control-center-global-shortcuts-provider` shows for the GlobalShortcuts bind and presses Add through AT-SPI, so the chord is granted headless. `MOUTHTYPE_PROBE_DRIVER=mutter-keycode` sends evdev keycodes instead of keysyms, and `MOUTHTYPE_PROBE_MONITOR=1` also prints the session-bus `GrabAccelerators` / `AcceleratorActivated` traffic.

Headless mutter gives the stage no key focus until it sees input, so the mutter drivers click once and tap Shift_L before the chord. Without that, the accelerator is grabbed but never fires.

Results (GNOME 50, GlobalShortcuts v1) are in `evidence/`. Release latency from the key-up call to the portal's Deactivated signal, 3 rounds, 500 ms hold: keysyms mean 4.7 ms (max 6.6), keycodes mean 10.7 ms (max 23.8). Activated arrives in 2 to 6 ms. The portal timestamps differ by the hold time, so Deactivated is the real release, not a timeout.

## Acceptance image (A1)

`acceptance.Dockerfile` layers the daemon sources on the T1 image and builds with `tools/` as the context, because `desktop.py` imports the sibling `linux-engine-proof`:

```bash
cd tools
bash ~/scripts/nas-docker.sh build -f linux-desktop/testbed/gnome/acceptance.Dockerfile -t ld-a1-gnome:test .
bash ~/scripts/nas-docker.sh run --rm ld-a1-gnome:test
```

`testbed/ci-acceptance.sh <evidence-dir> gnome` does both builds and the run. The held-chord take (a mutter-driven GlobalShortcuts press after the paste and secure-field steps) runs by default. Skip it with `-e MOUTHTYPE_ACCEPTANCE_SHORTCUT_TAKE=0` or `--skip-shortcut-take`. The mutter wake click can leave the shell in popup or overview mode (modalCount above 0), where GlobalShortcuts accelerators don't fire, so the take closes the overview and date menu and waits for `Main.actionMode == 1` and `Main.modalCount == 0` before pressing the chord.
