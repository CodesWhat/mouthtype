# Linux development client

A functional command-line session service for **Arch/Omarchy with Hyprland and PipeWire**. This is a development candidate, not a supported Linux release. It records only after an explicit start, supports hold and toggle commands, reuses a pinned resident Parakeet worker, and keeps recoverable audio/transcripts locally. No desktop frontend, cleanup model integration, Mac pipeline parity, X11, GNOME, or KDE adapter is provided here.

The automated tests use synthetic WAVs, fake capture/engine processes, and Unix sockets. They establish application behavior, including real child-process cleanup. They do not establish microphone, model, Hyprland, native Wayland delivery, or Omarchy compatibility. Those require a recorded Linux session test. The earlier Ubuntu model checkpoint belongs to `../linux-engine-proof/README.md`; its 5/6 exact result is not desktop acceptance.

## Install and prepare

The initial runtime target is Linux x86_64, Python 3.12 in a dedicated environment, PipeWire's `pw-record`, and optionally `hyprctl` plus `wtype` for automatic typing. Arch's `pipewire-audio`, `hyprland`, and `wtype` packages provide those commands; use the distro's normal signed package management. No root input daemon or input-device group is needed. This script does not install packages, weights, permissions, bindings, autostart, or services.

From a source checkout or the development source archive, run `python3 tools/linux-desktop/install.py --prefix "$HOME/.local"`. The new launcher is `~/.local/bin/mouthtype-linux`; ensure that directory is in the compositor's PATH. Installation refuses to overwrite an existing launcher or payload. It leaves user configuration untouched. An existing installation can be preserved by choosing a different prefix.

Prepare the Parakeet artifacts and Python environment using the exact pins and verification procedure in [the engine instructions](../linux-engine-proof/README.md#runtime-and-artifact-preparation). Only speech artifacts are required here. Model downloads are an explicit operator step. The existing preparation command writes `engines.json`; it checks the published archive and extracted model hashes. The resident service checks the configured artifact hashes again before each cold worker load. Keep the archive, weights, virtual environment, and private engine config outside the source checkout.

Copy `config.example.json` to `~/.config/mouthtype/linux.json`, set `engine_config` to the prepared JSON path, and set `python` to the dedicated environment's Python executable. Relative `engine_config` paths resolve beside this config. The default `delivery.mode` is `recover`, which makes no clipboard or keyboard changes. `capture_target` optionally selects a PipeWire node name or serial using the documented `pw-record --target` option. An unavailable target fails rather than switching silently to another device.

Start a bounded foreground session with `mouthtype-linux serve`. It exits after 12 hours or an explicit `mouthtype-linux shutdown`; `--lifetime-seconds` after `serve` selects 1 second through 24 hours. Start it again explicitly for a new session. No restart loop, recurring job, login item, or systemd unit is installed. Termination cancels active capture/inference, stops owned processes and removes the socket. Audio from an interrupted take stays recoverable. A second service cannot replace the live socket; a later service can reclaim its own stale socket after a crash.

## Hold, toggle and cancellation

Choose **unused** compositor keys. Omarchy can already bind F9 to Voxtype, so inspect/remove that conflict or choose other keys before using these examples. Nothing edits or reloads your compositor configuration automatically.

- `mouthtype-linux start` starts one recording. Repeated start is ignored.
- `mouthtype-linux stop` finalizes one recording and transcribes it. Repeated stop never duplicates insertion.
- `mouthtype-linux toggle` starts when idle and stops when recording. It does nothing during transcription/cancellation.
- `mouthtype-linux cancel` discards an active take and prevents a late inference result from being delivered.
- `mouthtype-linux status` reports state, a coarse error category and recovery ID, without transcript, window title or audio.

For Hyprland **0.55 and newer**, adapt the current Lua examples in `hyprland.lua` using `hl.bind` and nonblocking `hl.dsp.exec_cmd`. Its F9 press/release implements hold; F10 toggles; F11 cancels. `hyprland-legacy.conf` is separately labeled for **0.54 and older**. Custom modifier combinations need release-order acceptance on the chosen compositor version. The 60-second default recording cap cancels an overlong take instead of inserting a partial result. The maximum configurable cap is 120 seconds. Lost capture is preserved as interrupted audio rather than transcribed automatically.

## Recovery and deliberate delivery

Recovery lives in `$XDG_STATE_HOME/mouthtype/recovery`, default `~/.local/state/mouthtype/recovery`. Directories use mode 0700; recording/transcript files use 0600. Recordings and transcripts remain until explicitly forgotten. At 50 saved take directories, another recording is refused instead of silently deleting user data. No text is included in routine status/errors, process arguments or compositor logs.

`mouthtype-linux list` lists IDs and whether audio/text exists. `mouthtype-linux recover ID` prints the selected transcript exactly, with no automatic delivery. If a crash or model error left audio only, `mouthtype-linux transcribe ID` asks the running service to transcribe that take, always into recovery. Read the result with `recover`. Existing transcripts are never overwritten. `mouthtype-linux forget ID` explicitly deletes that take's generated files, refusing a take currently in use. Recovery is never replayed on startup.

Automatic delivery is opt-in. Set `delivery.mode` to `type`, provide a nonempty `allowed_classes` array of **exact** Hyprland window classes, and set `allow_unknown_secure_field` to `true` only after considering the limitation below. The service captures address/class/PID at recording start, checks the current unlocked target before delivery, and declines delivery if target identity changed or is unavailable. It submits one UTF-8 text stream to `wtype -` via stdin. It never borrows or overwrites the clipboard, focuses another window, synthesizes a paste chord, or retries after uncertainty. The helper has a 15-second deadline; a timeout may have typed a prefix, so read recovery and check the target before doing anything else.

**Important limitation:** Hyprland window identity does not establish editable-field identity or whether a field is a password field. AT-SPI context, secure-field detection and insertion read-back are unsupported. Automatic typing therefore requires the explicit unknown-field opt-in and a known suitable field. A helper returning success means **delivery is unknown**, not verified. Focus can change during key submission. Newline, tab, Escape and other C0/C1 control characters are refused for automatic typing because wtype turns some into Return/Tab actions. The full transcript remains available in recovery. Never enable automatic typing for a terminal or other command-executing field without understanding those limits.

## Checks and development archive

Run `python3 -W error::ResourceWarning -m unittest discover -s tools/linux-desktop -p 'test_*.py'`. No test opens a microphone, launches a compositor or loads/downloads a model.

Create a new source-only archive with `python3 tools/linux-desktop/install.py --archive /absolute/new/mouthtype-linux-development.tar.gz`. Its explicit file list includes the service, installer, bindings, engine adapter/pins/requirements, GPL license and third-party notices. It includes no model weights, user configuration, recordings or private planning. It is not a signed release package and does not promise a tested desktop baseline.

## Runtime references

- [Hyprland current binds and Lua migration](https://wiki.hypr.land/Configuring/Basics/Binds/)
- [Hyprland flags and release behavior](https://wiki.hypr.land/configuring/core/binds/flags/)
- [Hyprland command interface and JSON flag](https://wiki.hypr.land/configuring/core/advanced-configuration/using-hyprctl/)
- [PipeWire pw-record format, target and resampling options](https://docs.pipewire.org/page_man_pw-cat_1.html)
- [wtype stdin and virtual keyboard implementation](https://github.com/atx/wtype)

These sources were inspected on 2026-10-16. No Voxtype/Omarchy implementation was copied. Existing runtime/model licenses and provenance remain in the engine pins and third-party notices.

## Explicit remote component acceptance

`acceptance.py` is a separate opt-in Linux runner. Its `capabilities` command records available helpers and `/dev/dri` nodes without starting a compositor or microphone. `pipewire` starts an isolated PipeWire graph with the upstream synthetic 440 Hz test source and WirePlumber's policy-only profile, captures it through the real production adapter, checks PCM format/signal/frequency, and stops its processes. It does not load speech weights or open physical sources. Run it in an isolated D-Bus session using `dbus-run-session -- python3 tools/linux-desktop/acceptance.py pipewire`.

The separate `sway` command runs an owned headless Sway/pixman session, opens the synthetic native GTK3 Wayland target, sends one Unicode stdin stream through real wtype, and checks exact target text, focus and an existing clipboard sentinel. Run `dbus-run-session -- python3 tools/linux-desktop/acceptance.py sway` as an ordinary non-root user on the disposable runner. Its dependencies are Sway, wtype, wl-clipboard, GTK3, Python GObject bindings and D-Bus. **This is a Sway/wtype component check, not a Hyprland adapter or Omarchy acceptance check.** It has not been run when this source was initially written. A successful result must be tied to fetched runner evidence before changing that status.

Each component has a 45-second execution limit, short per-operation/readiness deadlines and owned-group cleanup before returning. All fixtures are synthetic. Logs from a failed component are bounded and emitted for investigation; no user recordings or dictation are used. The runtime scripts neither grant privileges nor disable compositor security restrictions. Current Hyprland/Aquamarine renderer paths require a DRM/dmabuf render device, including for nested sessions. An output-free session does not remove that requirement; record actual render-device availability before scheduling its desktop acceptance.

The narrow `Linux desktop components` workflow runs on PRs that change these files and supports an explicit manual dispatch. It uses the existing hosted Ubuntu 24.04 kernel with separately pinned official Ubuntu 26.04 and Arch starting userlands, normal signed package updates, ordinary-user D-Bus/component sessions and read-only repository permissions. Exact installed packages and raw component results are retained for 14 days. There are no weights, secrets, physical audio devices, paid runners or recurring schedules. Ubuntu 26.04 is used for the current WirePlumber policy-profile API rather than pretending Ubuntu 24.04's older WirePlumber has it. Passing these synthetic components still does not mark Arch/Omarchy desktop support complete.

Recording start/toggle requests carry a short local monotonic admission deadline, checked before and after target lookup. Expired or queued requests cannot begin a microphone take after their client has already timed out. Target probes have shorter individual deadlines than the client response budget. Repeated cancellation remains busy until inference has stopped. Cancelling an explicitly recovered audio take preserves its original saved WAV; only a newly recorded active take is disposable.

The first actual component runs exposed two integration mistakes and an environment boundary. Upstream `pw-record` intentionally returns exit status 1 after an operator's SIGINT closes the WAV, because success status is reserved for a drained playback stream. The adapter now accepts that status only after explicitly stopping a previously live recorder, while retaining complete PCM format/frame validation and treating a natural early exit as interruption. The native Wayland test waits for the exact app node in the compositor tree before requesting focus; a fixture file appearing is not proof the window has mapped.

Arch's signed packaged Sway 1.12 carries `cap_sys_nice`, and its executable was denied by the default hosted container boundary before startup. That failure is preserved as evidence. The Arch component job therefore builds **a separately labeled unprivileged upstream Sway 1.12 component** from immutable release commit `88869399f421d9180dd8b6ed0b5a1f4a3585d252`, verifies the source archive SHA-256 in `sway-build.json`, and builds with two jobs against the recorded signed Arch libraries. It neither changes the installed package/file capabilities nor grants container privileges. The test result identifies this source build, while capabilities evidence continues to probe the original packaged executable. This establishes no packaged-Sway, Hyprland or Omarchy support claim. Source download, build commands and owned child groups have finite deadlines; source/binary digests and build logs accompany the component evidence.
