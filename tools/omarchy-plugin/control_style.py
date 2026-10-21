"""Style page verbs for the Omarchy panel: tone, swearing softening and Style contexts.

Every verb prints one JSON object. Edits write the `styles` block of linux.json and return the same shape as
`style-state`; the service picks the change up at the start of its next take. The logic lives in
tools/linux-desktop/styles.py and tone.py; this file only locates them and parses arguments.
"""

import importlib
from pathlib import Path
import sys

PLUGIN_DIR = Path(__file__).resolve().parent
TONES = ("formal", "casual", "very_casual")
LEVELS = ("off", "basic", "fast", "thorough")


def _paths():
    """(linux.json, directory holding styles.py and tone.py). Tests replace this."""
    if str(PLUGIN_DIR) not in sys.path:
        sys.path.insert(0, str(PLUGIN_DIR))
    control = importlib.import_module("control")
    desktop = control.DESKTOP if (control.DESKTOP / "styles.py").is_file() else PLUGIN_DIR.parent / "linux-desktop"
    return control.CONFIG, desktop


def _modules():
    config, desktop = _paths()
    if str(desktop) not in sys.path:
        sys.path.insert(0, str(desktop))
    return config, importlib.import_module("styles"), importlib.import_module("tone")


def _none(value, allowed, label):
    if value == "none":
        return None
    if value not in allowed:
        raise ValueError(f"{label} must be none or one of {', '.join(allowed)}")
    return value


def _edit(change):
    config, styles, _ = _modules()
    return styles.describe(styles.update_config(config, lambda block: change(styles, block)))


def style_state():
    config, styles, _ = _modules()
    return styles.describe(styles.read_block(config))


def style_preview(tone_name, text):
    _, _, tone = _modules()
    if tone_name not in TONES:
        raise ValueError("Unknown tone")
    return {"text": tone.apply(text, tone_name)}


def style_resolve(app=None):
    config, styles, _ = _modules()
    return styles.resolve(styles.read_block(config), app or None)


def style_set_default_tone(value):
    value = _none(value, TONES, "tone")
    return _edit(lambda styles, block: styles.set_default_tone(block, value))


def style_set_tone(context, value):
    value = _none(value, TONES, "tone")
    return _edit(lambda styles, block: styles.set_context(block, context, "tone", value))


def style_set_cleanup(context, value):
    value = _none(value, LEVELS, "cleanup")
    return _edit(lambda styles, block: styles.set_context(block, context, "cleanup", value))


def style_add_app(context, app, name=""):
    return _edit(lambda styles, block: styles.add_app(block, context, app, name or None))


def style_remove_app(context, member):
    return _edit(lambda styles, block: styles.remove_app(block, context, member))


def style_rule(app, tone_value="none", cleanup_value="none", name=""):
    tone_value = _none(tone_value, TONES, "tone")
    cleanup_value = _none(cleanup_value, LEVELS, "cleanup")
    return _edit(lambda styles, block: styles.set_rule(block, app, name or None, tone_value, cleanup_value))


COMMANDS = {
    "style-state": style_state,
    "style-preview": style_preview,
    "style-resolve": style_resolve,
    "style-set-default-tone": style_set_default_tone,
    "style-set-tone": style_set_tone,
    "style-set-cleanup": style_set_cleanup,
    "style-add-app": style_add_app,
    "style-remove-app": style_remove_app,
    "style-rule": style_rule,
}
