"""Focused-target identity on GNOME and KDE through AT-SPI (the accessibility bus).

Neither mutter nor KWin tells an unsandboxed Wayland client which window has focus, so PortalDelivery asks
AT-SPI instead: the focused application's name, whether the focused widget is a terminal, and whether it is a
password field. It is best effort. An app with no AT-SPI focus reports {'class': 'unknown'}, and so does a
missing gi/Atspi or an unreachable accessibility bus; the unknown-secure-field opt-in in the config then decides.

gi is imported lazily so Hyprland and Sway installs never need gir1.2-atspi-2.0.
"""
import logging

UNKNOWN = 'unknown'
# Bounds on the focus search so a huge or hostile accessibility tree can't stall a take.
MAX_NODES = 4000
MAX_DEPTH = 40

log = logging.getLogger('mouthtype.atspi_target')


def load_atspi():
    """The Atspi module, or None when PyGObject or the typelib isn't installed."""
    try:
        import gi
        gi.require_version('Atspi', '2.0')
        from gi.repository import Atspi
    except (ImportError, ValueError):
        return None
    return Atspi


class AtspiTargets:
    """snapshot() and is_terminal(target) for PortalDelivery.

    snapshot() returns {'class': app name, 'pid': int, 'secure': bool, 'terminal': bool}; every field is stable
    for as long as the same widget keeps focus, so a changed snapshot means the target changed. Secure is True for
    a password field, and delivery refuses those. 'unknown' is {'class': 'unknown'} alone.
    """

    def __init__(self, atspi=None, loader=load_atspi, max_nodes=MAX_NODES, max_depth=MAX_DEPTH):
        self._atspi = atspi
        self._loader = loader
        self._loaded = atspi is not None
        self.max_nodes = max_nodes
        self.max_depth = max_depth

    def available(self):
        return self._module() is not None

    def _module(self):
        if not self._loaded:
            self._loaded = True
            self._atspi = self._loader()
            if self._atspi is not None:
                try:
                    self._atspi.init()
                except Exception:
                    log.exception('AT-SPI init failed')
                    self._atspi = None
        return self._atspi

    def snapshot(self):
        atspi = self._module()
        if atspi is None:
            return {'class': UNKNOWN}
        try:
            found = self._focused(atspi)
            if found is None:
                return {'class': UNKNOWN}
            app, widget = found
            name = app.get_name()
            if not isinstance(name, str) or not name:
                return {'class': UNKNOWN}
            role = widget.get_role()
            target = {'class': name, 'secure': role == atspi.Role.PASSWORD_TEXT,
                      'terminal': role == atspi.Role.TERMINAL}
            pid = app.get_process_id()
            if type(pid) is int and pid > 0:
                target['pid'] = pid
            return target
        except Exception:
            # GLib.Error when the bus goes away or an object dies mid-walk. Unknown, never a guess.
            log.debug('AT-SPI query failed', exc_info=True)
            return {'class': UNKNOWN}

    def is_terminal(self, target):
        return bool(target.get('terminal'))

    def _focused(self, atspi):
        """(application, focused widget) for the active window, or None."""
        desktop = atspi.get_desktop(0)
        budget = [self.max_nodes]
        for index in range(desktop.get_child_count()):
            app = desktop.get_child_at_index(index)
            if app is None:
                continue
            for window_index in range(app.get_child_count()):
                window = app.get_child_at_index(window_index)
                if window is None or not window.get_state_set().contains(atspi.StateType.ACTIVE):
                    continue
                widget = self._find_focus(atspi, window, budget, 0)
                if widget is not None:
                    return app, widget
        return None

    def _find_focus(self, atspi, node, budget, depth):
        budget[0] -= 1
        if budget[0] < 0 or depth > self.max_depth:
            return None
        states = node.get_state_set()
        if states.contains(atspi.StateType.FOCUSED):
            return node
        # Skip subtrees that can't hold a visible focused widget.
        if not states.contains(atspi.StateType.SHOWING) and depth > 0:
            return None
        for index in range(node.get_child_count()):
            child = node.get_child_at_index(index)
            if child is None:
                continue
            found = self._find_focus(atspi, child, budget, depth + 1)
            if found is not None:
                return found
        return None
