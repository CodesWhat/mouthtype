# Review follow-ups from PR #126

Three review passes on PR #126 (Claude and Codex, 2026-10-18) found these. The blocking ones were fixed in PR #129. These are the ones left open. None of them blocked the merge, but each one would hurt a real user eventually.

## Paste and delivery

- **Paste restore drops non-text and large clipboards.** `HyprlandDelivery.paste` reads the old clipboard with `wl-paste --type text` and a 1 MiB cap. If the clipboard held an image, a file or more than 1 MiB of text, `previous` is `None` and the clipboard is overwritten with nothing to restore, even with `restore_clipboard` on. A password manager's sensitive hint isn't kept on restore either. Record the offered MIME types and skip the overwrite when it isn't plain text.
- **The restore can race a slow target.** It fires 0.6 s after the chord. A target that reads the clipboard later pastes the old content. Make the delay configurable or longer.
- **Delivery runs inside the session lock.** `Session._finish` calls `delivery.submit` under `self.lock`, so `status`, `tick`, `level` and the pill stall while a paste runs, which can take several seconds, or up to 15 s for `wtype`.
- **`gnome-terminal-server` never matches `TERMINAL_EXECUTABLES`.** `/proc/<pid>/comm` truncates to 15 characters. The class list still catches it, so this only matters for a custom class.

## Service and state stream

- **A new watcher can swallow the idle update.** The `watch` handler sets the shared `last_snapshot` from the new connection's initial state. If transcription finishes in between, existing watchers never get the idle broadcast and the pill stays on processing. Only update the shared snapshot when broadcasting.
- **An orphaned llama-server outlives a SIGKILLed service.** It binds loopback only, but it holds memory until killed.

## Hold-to-talk and cleanup engine (from the final pass on #129)

- **A late stop can end a re-press.** `act()` in `control.py` sends a release's stop after the hold lock is released. If you press again within the few milliseconds (up to ~150 ms under load) between the release being processed and its stop going out, that stop ends the new hold. Only the superseded-stop path is serialised under the lock.
- **A hung daemon can wedge hold events.** `hold_settle` catches only `RuntimeError` around `deliver("stop")` while holding the flock. A `subprocess.TimeoutExpired` (35 s CLI timeout) escapes before the state is written, leaves `skipped` set, and blocks every other hold event on the lock for up to 35 s.
- **Cleanup warmup can restart during teardown.** `_recover` in `desktop.py` doesn't check `self.shutdown`, so a late `clean()` after `close()` starts a warm thread that hashes the model files and spawns a worker before it's cancelled. Add `if self.shutdown.is_set(): return`.
- **Request-time cleanup failures skip the backoff.** `clean()`'s except block sets `state = 'idle'` after `_fail` when the model file exists, so a server that dies on every request reloads once per take instead of backing off. Load-time failures do back off.

## Omarchy plugin

- **`setup_running()` uses `pgrep -f`**, which matches any process whose command line contains the string.
- **The toggle binding uses `o.bind(...)` and hold uses `hl.bind(...)`.** Confirm `o` exists in Omarchy's `bindings.lua`. The `configerrors` revert would catch a failure, but the shortcut wouldn't be set.
- **`Panel.qml` lines 364 and 827** still say alpha.8 in About.

## Repo-wide, outside tools/

- `docs/SECURITY.md` doesn't cover the new Linux boundaries: ffmpeg decode of imported files, the loopback llama.cpp server, clipboard paste and restore, and the default login service.
- `THIRD_PARTY_NOTICES.md` has no Qwen3-4B or llama.cpp entry, and the S1 GGUF revision in `pins.json` (34add00a) differs from the notice (88f6b158).
- `.github/workflows/linux-desktop.yml` path filters skip `tools/omarchy-plugin/**`, so plugin-only changes don't run its tests in CI.
- `/source` serves the rc.1 archive, which doesn't include the plugin, so the Linux guide only works from a git checkout until a newer archive is staged.

## Needs a real Linux session

The fixes in #129 were tested on macOS with fakes. Before calling hold-to-talk and paste done, check on Hyprland:

- hold-to-talk with quick taps, long holds and rapid repeats, which tests the launch-time ordering in `control.py`
- the login service starting with the graphical session after a reboot, and the migration from an older `default.target` install
- paste into a terminal and a normal app, including the dispatcher fallback
- a file import whose real length is longer than its header says
