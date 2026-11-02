"""Clipboard writes that clipboard managers should skip, the Linux twin of the Mac concealed pasteboard marker.

wl-clipboard 2.3 added `wl-copy --sensitive`. It offers the `x-kde-passwordManagerHint` type with `secret` beside the
text and tells `wl-paste --watch` consumers (cliphist and similar) `CLIPBOARD_STATE=sensitive`. Older wl-copy builds
reject the flag, so the plain command is the fallback and the copy still works."""
import subprocess

TEXT_TYPE = 'text/plain;charset=utf-8'
PLAIN = ['wl-copy', '--type', TEXT_TYPE]
CONCEALED = ['wl-copy', '--sensitive', '--type', TEXT_TYPE]

_supported = None


def sensitive_supported(run=subprocess.run):
    """True when the installed wl-copy knows --sensitive. Probed once per process; a failed probe means plain."""
    global _supported
    if _supported is None:
        try:
            result = run(['wl-copy', '--help'], capture_output=True, text=True, check=False, timeout=2)
            _supported = '--sensitive' in ((result.stdout or '') + (result.stderr or ''))
        except (OSError, subprocess.SubprocessError):
            return False
    return _supported


def copy_command(run=subprocess.run):
    """The wl-copy argv for text that should stay out of clipboard history."""
    return list(CONCEALED if sensitive_supported(run) else PLAIN)
