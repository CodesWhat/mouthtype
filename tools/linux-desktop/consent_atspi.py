"""Answer a portal consent dialog through AT-SPI on a headless GNOME session.

GNOME shows the GlobalShortcuts bind dialog from org.gnome.Settings.GlobalShortcutsProvider (gnome-control-center)
and the RemoteDesktop dialog from xdg-desktop-portal-gnome. Nobody is there to click them in a container, so the
probe finds the dialog's accessibility node, switches on whatever toggles it offers and presses the affirmative
button. Every poll also records an outline of the windows it saw, so a dialog whose labels differ from the guessed
ones still shows up in the evidence.

gi is imported lazily through atspi_target.load_atspi, so nothing here costs a Hyprland or Sway install anything.
"""
import threading
import time

# Button labels that grant, in preference order. Matching is case-insensitive and exact.
AFFIRMATIVE = ('allow', 'share', 'accept', 'add', 'bind', 'confirm', 'ok', 'continue')
SWITCH_ROLES = ('switch', 'check box', 'toggle button')
APPS = ('gnome-control-center-global-shortcuts-provider', 'org.gnome.Settings', 'gnome-control-center',
        'xdg-desktop-portal-gnome')
# KDE shows the GlobalShortcuts bind dialog from the portal backend itself, a 'Global Shortcuts Requested' window with an OK button.
KDE_APPS = ('xdg-desktop-portal-kde',)
MAX_NODES = 4000
MAX_DEPTH = 30


def walk(node, visit, budget=None, depth=0):
    """Depth-first over an AT-SPI tree. visit(node) returning a truthy value stops the walk with that value."""
    budget = [MAX_NODES] if budget is None else budget
    budget[0] -= 1
    if budget[0] < 0 or depth > MAX_DEPTH:
        return None
    found = visit(node)
    if found:
        return found
    for index in range(node.get_child_count()):
        child = node.get_child_at_index(index)
        if child is not None:
            found = walk(child, visit, budget, depth + 1)
            if found:
                return found
    return None


def outline(atspi):
    """Applications with their top-level windows, for evidence and failure messages."""
    result = []
    desktop = atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app is None:
            continue
        windows = []
        for frame in range(app.get_child_count()):
            window = app.get_child_at_index(frame)
            if window is not None:
                windows.append(window.get_name())
        result.append([app.get_name(), windows])
    return result


def controls(window):
    """Every button and toggle under a window as (role, name, node)."""
    found = []

    def collect(node):
        role = node.get_role_name()
        if role in SWITCH_ROLES or role == 'button':
            found.append((role, node.get_name() or '', node))
        return None
    walk(window, collect)
    return found


def dialog_controls(atspi, apps=APPS):
    """[app, window, [[role, name], ...]] for every window of a portal-provider application, for evidence."""
    result = []
    desktop = atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app is None or app.get_name() not in apps:
            continue
        for frame in range(app.get_child_count()):
            window = app.get_child_at_index(frame)
            if window is not None:
                result.append([app.get_name(), window.get_name(), [[r, n] for r, n, _ in controls(window)]])
    return result


def find_dialog(atspi, apps=APPS):
    """First top-level window of a portal-provider application that offers an affirmative button, or None."""
    desktop = atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app is None or app.get_name() not in apps:
            continue
        for frame in range(app.get_child_count()):
            window = app.get_child_at_index(frame)
            if window is not None and _affirmative(controls(window)) is not None:
                return window
    return None


def _affirmative(found):
    for label in AFFIRMATIVE:
        for role, name, node in found:
            if role == 'button' and name.strip().lower() == label:
                return name, node
    return None


def answer(window, atspi):
    """Switch on every unchecked toggle, then press the affirmative button.

    Returns {'dialog', 'buttons', 'switched_on', 'pressed'} so the evidence shows what was answered."""
    found = controls(window)
    pressed = _affirmative(found)
    if pressed is None:
        raise ValueError('dialog has no affirmative button: ' + repr([name for _, name, _ in found]))
    switched = []
    for role, name, node in found:
        if role not in SWITCH_ROLES:
            continue
        checked = node.get_state_set().contains(atspi.StateType.CHECKED)
        action = node.get_action_iface()
        # A toggle can export an action interface with no actions yet, which do_action(0) rejects.
        if not checked and action and action.get_n_actions() > 0:
            action.do_action(0)
            switched.append(name)
            time.sleep(.2)
    pressed[1].get_action_iface().do_action(0)
    return {'dialog': window.get_name(), 'buttons': sorted(name for role, name, _ in found if role == 'button'),
            'switched_on': sorted(switched), 'pressed': pressed[0]}


class ConsentAnswerer(threading.Thread):
    """Polls for a consent dialog and answers it. Stop with stop(); read .answers, .seen and .error afterwards."""

    def __init__(self, atspi, timeout=60.0, interval=.5, apps=APPS):
        super().__init__(name='mouthtype-consent', daemon=True)
        self.atspi, self.timeout, self.interval, self.apps = atspi, timeout, interval, apps
        self.answers, self.seen, self.dialogs, self.error = [], [], [], None
        self._stop_event = threading.Event()

    def stop(self):
        self._stop_event.set()
        self.join(5)

    def run(self):
        deadline = time.monotonic() + self.timeout
        while not self._stop_event.is_set() and time.monotonic() < deadline:
            try:
                snapshot = outline(self.atspi)
                if not self.seen or self.seen[-1] != snapshot:
                    self.seen.append(snapshot)
                    del self.seen[:-20]
                dialogs = dialog_controls(self.atspi, self.apps)
                if dialogs and (not self.dialogs or self.dialogs[-1] != dialogs):
                    self.dialogs.append(dialogs)
                    del self.dialogs[:-10]
                window = find_dialog(self.atspi, self.apps)
                if window is not None:
                    self.answers.append(answer(window, self.atspi))
                    time.sleep(1)
            except Exception as exc:
                self.error = f'{type(exc).__name__}: {exc}'
            self._stop_event.wait(self.interval)

    def evidence(self):
        return {'answers': self.answers, 'error': self.error, 'dialogs_seen': self.dialogs, 'windows_seen': self.seen}
