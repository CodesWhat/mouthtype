"""Desktop backend registry: which delivery and shortcut implementation fits the running session.

Implementations register themselves by name. desktop.py registers HyprlandDelivery unchanged; the portal backends
(later items) register under 'portal'. Nothing here imports desktop.py, so the registry stays cycle-free.
"""

try:
    from typing import Protocol
except ImportError:  # pragma: no cover - Python older than 3.8
    Protocol = object

DESKTOPS = ('hyprland', 'gnome', 'kde', 'sway', 'unknown')
DELIVERY_NAMES = ('hyprland', 'portal', 'recover')
SHORTCUT_NAMES = ('hyprland', 'portal', 'command', 'none')

# What each desktop uses when the config says 'auto'. Sway keeps the wtype path through the Hyprland-style delivery
# class today, so it maps to 'hyprland' until it has a backend of its own.
AUTO_DELIVERY = {'hyprland': 'hyprland', 'gnome': 'portal', 'kde': 'portal', 'sway': 'hyprland', 'unknown': 'hyprland'}
AUTO_SHORTCUTS = {'hyprland': 'hyprland', 'gnome': 'portal', 'kde': 'portal', 'sway': 'none', 'unknown': 'none'}

_delivery = {}
_shortcuts = {}


class BackendUnavailable(RuntimeError):
    """The chosen backend has no implementation in this build."""


class Delivery(Protocol):
    """What Session needs from a delivery backend."""

    def snapshot(self, *args, **kwargs): ...
    def allowed(self, *args, **kwargs): ...
    def is_terminal(self, *args, **kwargs): ...
    def submit(self, *args, **kwargs): ...
    def paste(self, *args, **kwargs): ...
    def clipboard_types(self, *args, **kwargs): ...
    def send_paste_chord(self, *args, **kwargs): ...
    def schedule_restore(self, *args, **kwargs): ...


def detect(env):
    """Name the desktop for an environment mapping. X11 sessions on GNOME or KDE report 'unknown'."""
    if env.get('HYPRLAND_INSTANCE_SIGNATURE'):
        return 'hyprland'
    desktops = {part.strip().upper() for part in (env.get('XDG_CURRENT_DESKTOP') or '').split(':') if part.strip()}
    if (env.get('XDG_SESSION_TYPE') or '').strip().lower() == 'wayland':
        if 'GNOME' in desktops:
            return 'gnome'
        if 'KDE' in desktops:
            return 'kde'
        if 'SWAY' in desktops or env.get('SWAYSOCK'):
            return 'sway'
    elif env.get('SWAYSOCK') and not desktops - {'SWAY'}:
        return 'sway'
    return 'unknown'


def register_delivery(name, factory):
    _delivery[name] = factory


def register_shortcuts(name, factory):
    _shortcuts[name] = factory


def delivery_name(desktop, override='auto'):
    """Backend name for a detected desktop, honouring a desktop.delivery override."""
    if override != 'auto':
        if override not in DELIVERY_NAMES:
            raise ValueError('Unknown delivery backend: ' + str(override))
        return override
    return AUTO_DELIVERY[desktop]


def shortcuts_name(desktop, override='auto'):
    if override != 'auto':
        if override not in SHORTCUT_NAMES:
            raise ValueError('Unknown shortcut backend: ' + str(override))
        return override
    return AUTO_SHORTCUTS[desktop]


def make_delivery(name, *args, **kwargs):
    """Build the named delivery backend. A name with no registered implementation falls back to the Hyprland path,
    which is what every desktop ran before the registry existed, so nothing regresses until a real backend lands."""
    factory = _delivery.get(name) or _delivery.get('hyprland')
    if factory is None:
        raise BackendUnavailable('No delivery backend registered')
    return factory(*args, **kwargs)


def make_shortcuts(name, *args, **kwargs):
    """Build the named shortcut backend, or None when it has no implementation (Hyprland binds live in the config
    that control.py writes, and 'none' is deliberate)."""
    factory = _shortcuts.get(name)
    return factory(*args, **kwargs) if factory else None
