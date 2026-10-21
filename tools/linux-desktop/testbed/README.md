# Omarchy testbed

A Docker image that runs a real Omarchy desktop (Hyprland, the Omarchy Quickshell bar, Tokyo Night) with no display attached. You view it over VNC, install the Mouthtype Linux client into it with the repo's own installers, and run an end-to-end dictation test against a virtual microphone. It exists so installs and the real UI can be tested without a Linux machine. It is a test aid, not a supported way to run Mouthtype.

It targets the Mainframe NAS test engine (`~/scripts/nas-docker.sh`, amd64). Nothing here touches the NAS host Docker daemon.

## Start it

From a checkout of this repo on the Mac:

```bash
bash tools/linux-desktop/testbed/testbed.sh up
```

`up` stages the checkout on the NAS (`nas-docker.sh --sync`), builds the image, starts the `mouthtype-omarchy-testbed` Compose project, waits for the Omarchy shell to answer, and prints the VNC address. The first build takes about five minutes and pulls roughly 2 GB of Arch packages. Later builds reuse the cache.

Other commands: `status`, `resync` (restage the checkout after local edits), `install`, `uninstall [--purge-models]`, `smoke [--fresh] [--no-install]`, `screenshot FILE`, `password [--copy|--show]`, `shell`, `logs`, `down [--purge]`.

Settings, all optional environment variables: `TESTBED_PORT` (default 20010, inside the NAS testbed's 20000-20031 range), `TESTBED_HOST` (default the NAS Tailscale address), `TESTBED_RENDER` (`auto`, `gpu` or `software`), `TESTBED_VNC_PASSWORD`.

## Connect from a Mac

Open Screen Sharing, or run `open vnc://100.79.136.28:20010`, and enter the password. There is no username; Screen Sharing asks for a password only.

The password is never committed. At container start the entrypoint uses `TESTBED_VNC_PASSWORD` if you set one, and otherwise generates a random one. It is stored at `~/.config/testbed/vnc-password` inside the container (mode 0600) and is not printed or logged. `testbed.sh password` copies it to `~/.config/mouthtype-testbed/vnc-password` on the Mac (mode 0600); add `--copy` to put it on the clipboard or `--show` to print it. RFB password auth only reads the first 8 characters, so the generated one is exactly 8 and a longer `TESTBED_VNC_PASSWORD` is refused. Recreating the container (`down`, then `up`) generates a new password.

macOS Screen Sharing only speaks classic VNC password auth, which wayvnc does not offer. So wayvnc listens on container loopback with no auth, and `vnc-auth-proxy.py` owns the published port: it runs the VNC password handshake (five wrong attempts from one address and it starts stalling), then hands the connection to wayvnc. The handshake was checked from the Mac with a scripted RFB client (right password gets the 1920x1080 screen, a wrong one is refused). It has not been driven from the real Screen Sharing app.

## Run the smoke test

```bash
bash tools/linux-desktop/testbed/testbed.sh smoke          # installs first if needed
bash tools/linux-desktop/testbed/testbed.sh smoke --fresh  # uninstall, reinstall, then test
```

It runs inside the container and exits non-zero if any check fails. It checks the session (Hyprland, the 1920x1080 output, the Omarchy shell, wayvnc and its password gate, the virtual mic), installs the client from the staged checkout if it isn't installed, binds F10 as the toggle shortcut and sets paste delivery, opens the repo's synthetic GTK text field (`wayland_target.py`) and focuses it, starts a take, plays `sample.wav` ("The quick brown fox jumps over the lazy dog.") into the virtual microphone, stops the take, and compares what landed in the text field with the sentence. It ends with a `grim` screenshot, copied to `tools/linux-desktop/testbed/.last-smoke.png` on the Mac.

The first take loads the Parakeet model and is slow on the NAS's J4125. Later takes are quick.

## What is in the image

- Arch Linux with Hyprland 0.56.2 from Arch's repos, Quickshell, wayvnc, grim, foot, wtype, wl-clipboard, PipeWire, WirePlumber and pipewire-pulse.
- Omarchy v4.0.6, unmodified, at `/usr/share/omarchy`, with its `bin/` on PATH. Its default `~/.config` is copied in as a fresh install would, and its default Tokyo Night theme is rendered with `omarchy-theme-set` in headless mode. The real Omarchy shell, bar and Hyprland Lua config run.
- A virtual microphone: a PipeWire loopback whose playback side is the only audio source, so it is the default. Feed it with `pw-play --target mouthtype_mic_input some.wav`. Mouthtype's `pw-record` then records it like a real microphone.
- `install.sh` and `uninstall.sh`, which follow `website/public/linux/agent-install.md`: `tools/linux-desktop/install.py`, `setup_speech.py` (model and Python environment, kept in a Docker volume so reinstalls skip the 465 MiB download), then `tools/omarchy-plugin/install.py`. Uninstall follows the guide's Removing section and also takes out the `shell.json` entry and the shortcut block. Models stay unless `--purge-models`.

## What differs from a real Omarchy box

- **No systemd.** `systemctl --user` and `systemd-cat` are small shims in `shims/`. They are enough for the Mouthtype plugin (enable, start, stop, is-active, restart on failure) and Omarchy's shell launcher. Units live in `~/.config/systemd/user` and enabled ones start with the session, but nothing else about systemd behaves, and the journal doesn't exist.
- **Hyprland starts inside a headless mutter.** Hyprland 0.56 only starts on a DRM seat or as a window of another Wayland compositor, and the NAS has no display. mutter exists only to give Hyprland something to start against; its window never maps. The real output is a Hyprland headless output, `HEADLESS-1`, pinned to 1920x1080 by the testbed's `monitors.lua`. That one file, plus a setting that silences the "started without start-hyprland" toast, is the only change to Omarchy's user config.
- **One virtual keyboard, no real input devices.** A resident `wtype` process supplies a keyboard because Hyprland's `send_shortcut`, which Mouthtype's paste uses, refuses to run without one. wtype builds the keymap from what it types, so it types the alphabet and function keys once at session start. No window exists then to take the text.
- **No login manager, hardware, network, Bluetooth, power management or lock screen.** The bar's network, Bluetooth and power widgets show whatever Omarchy shows without them. There is no SDDM, uwsm, NetworkManager, Plymouth or disk setup, and no Omarchy-repo-only packages (aether, omacut and similar) and no browser or heavy apps.
- **Rendering.** The container gets `/dev/dri` and Hyprland renders on the NAS's Intel GPU. If the NAS engine has no `/dev/dri`, `testbed.sh` falls back to `TESTBED_RENDER=software` (llvmpipe). The fallback exists but has not been run on this NAS, because the GPU path works. Hyprland needs a render node for its buffer allocator either way, so software rendering still wants Mesa's `kms_swrast` to work in the container.
- **Not included.** No `llama-server`, so Fast and Thorough cleanup models can't be prepared (`git`, `cmake` and `base-devel` aren't in the image; Basic cleanup works). The Arch package path (`scripts/prepare-linux-arch.py` and `makepkg`) isn't exercised either, because the staged checkout has no `.git`; the testbed installs with `install.py`.

## Known limits

- **A wtype F10 press is unreliable.** A key press through `wtype -k F10` does reach Hyprland's binds, but on a headless session only some presses register. In testing the first press after the resident keyboard restarted usually worked and later ones often didn't, with no pattern that held. The smoke test therefore triggers dictation by running the exact command the F10 bind runs (`control.py toggle`) through `hyprctl dispatch`. A real Omarchy box with a physical keyboard doesn't have this problem.
- **Delivery is checked at the text field only.** Linux can't read back insertion, so a pass means the pasted text arrived in the GTK field, not that every app accepts it.
- **Screenshots and VNC show Hyprland's output**, not the mutter host.

## Troubleshooting

- **`up` says the session did not come up.** Run `testbed.sh logs`. `session.log` names the stage that failed (mutter, Hyprland, the output, wayvnc).
- **The bar is empty or has no wallpaper right after `up`.** The Omarchy shell takes about a minute to load on this CPU. `up` waits up to two minutes for it to answer.
- **VNC refuses the password.** Run `testbed.sh password` for the current one. It changes when the container is recreated. Check the port with `testbed.sh status`.
- **Can't reach the VNC address.** Ports 20000-20031 are published on the NAS and proxied over Tailscale. Check that Tailscale is up on the Mac and that nothing else holds `TESTBED_PORT`.
- **The smoke test fails at "take finished".** The first take loads the model, up to 180 seconds is allowed. Check `mouthtype-linux status` and the service log at `~/.local/state/testbed/units/mouthtype-linux.service.log` in the container (`testbed.sh shell`).
- **Smoke passes but the text is wrong.** `mouthtype-linux list` and `mouthtype-linux recover ID` show what the recognizer heard. `sample.wav` is macOS `say` output at 16 kHz mono.
- **The NAS is busy.** The NAS shares disk and CPU with other work. Build one image at a time and check `nas-docker.sh system df`.
- **Clean up.** `testbed.sh down` removes the container and network and keeps the model volume. `down --purge` also removes the volume. Both touch only the `mouthtype-omarchy-testbed` project.
