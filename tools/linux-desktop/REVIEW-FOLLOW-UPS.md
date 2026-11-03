# Review follow-ups from PR #126

Three review passes on PR #126 (Claude and Codex, 2026-10-18) found a list of follow-ups. The blocking ones were fixed in PR #129. The rest have since been fixed on `feat/linux-parity` and checked against the code on 2026-10-21: the paste restore and its configurable delay, delivery outside the session lock, the `comm` truncation match, the shared watcher snapshot, the parent-watch that kills an orphaned llama-server, the ordered hold stop under the hold lock, the daemon-error handling in `hold_settle`, the shutdown check in `_recover`, the request-failure backoff, the `setup_running()` pidfile check, the guarded `o.bind`, the alpha.8 strings, the Linux notices and the `omarchy-plugin` CI path filters. What's left is below.

## Needs a real Linux session

The fixes in #129 were tested on macOS with fakes. Before calling hold-to-talk and paste done, check on Hyprland:

- hold-to-talk with quick taps, long holds and rapid repeats, which tests the launch-time ordering in `control.py`
- the login service starting with the graphical session after a reboot, and the migration from an older `default.target` install
- paste into a terminal and a normal app, including the dispatcher fallback
- a file import whose real length is longer than its header says
