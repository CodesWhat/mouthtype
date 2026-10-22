"""Tray icon for the GNOME and KDE host: a StatusNotifierItem showing the glyph states, with Start/Stop, Open, Settings, Quit.

The icon and menu logic is plain Python so it can be tested without a display. `Tray` wires it to QSystemTrayIcon, which
Qt exports as a StatusNotifierItem on D-Bus (native in Plasma; GNOME needs the AppIndicator extension). When no
StatusNotifierWatcher is on the bus the app still works and `available` is False, which Settings > Linux reports.
"""
from pathlib import Path

ASSETS = Path(__file__).resolve().parent.parent / "omarchy-plugin" / "assets"
GLYPHS = ("idle", "recording0", "recording1", "recording2", "processing", "unavailable")
RECHECK_MS = 5000


def glyph_name(glyph):
    """The asset name for an AppState.glyphState value; anything unknown shows the unavailable glyph."""
    return glyph if glyph in GLYPHS else "unavailable"


def glyph_path(glyph):
    return ASSETS / ("glyph-%s@2x.png" % glyph_name(glyph))


def tooltip(glyph):
    name = glyph_name(glyph)
    if name.startswith("recording"):
        return "Mouthtype: listening"
    return {"idle": "Mouthtype", "processing": "Mouthtype: working", "unavailable": "Mouthtype: service not running"}[name]


def menu_entries(glyph):
    """(action, label, enabled) for the tray menu, in order. Start/Stop reads the state; with the service down it is disabled."""
    name = glyph_name(glyph)
    recording = name.startswith("recording")
    return [
        ("toggle", "Stop dictation" if recording else "Start dictation", name in ("idle", "processing") or recording),
        ("open", "Open Mouthtype", True),
        ("settings", "Settings", True),
        ("quit", "Quit", True),
    ]


try:
    from PySide6.QtCore import QObject, QTimer, Property, Signal, Slot
    from PySide6.QtGui import QAction, QIcon
    from PySide6.QtWidgets import QMenu, QSystemTrayIcon
    HAVE_QT = True
except ImportError:  # pragma: no cover - exercised only on machines without PySide6
    HAVE_QT = False


if HAVE_QT:
    class Tray(QObject):
        """The `Tray` context property of Main.qml. QML pushes the glyph in and handles actionRequested."""

        availableChanged = Signal()
        actionRequested = Signal(str)

        def __init__(self, availability=None, parent=None):
            super().__init__(parent)
            self._probe = availability or QSystemTrayIcon.isSystemTrayAvailable
            self._glyph = "unavailable"
            self._available = False
            self._icon = None
            self._menu = None
            self._actions = {}
            self._timer = QTimer(self)
            self._timer.setInterval(RECHECK_MS)
            self._timer.timeout.connect(self.check)

        @Property(bool, notify=availableChanged)
        def available(self):
            return self._available

        @Slot()
        def start(self):
            self.check()
            if not self._available:
                self._timer.start()  # a tray host (the GNOME AppIndicator extension) can come up after we do

        @Slot()
        def check(self):
            available = bool(self._probe())
            if available and self._icon is None:
                self._build()
            if self._icon is not None:
                self._icon.setVisible(available)
            if available:
                self._timer.stop()
            if available != self._available:
                self._available = available
                self.availableChanged.emit()

        @Slot(str)
        def setGlyph(self, glyph):
            self._glyph = glyph_name(glyph)
            if self._icon is not None:
                self._icon.setIcon(QIcon(str(glyph_path(self._glyph))))
                self._icon.setToolTip(tooltip(self._glyph))
                for action, label, enabled in menu_entries(self._glyph):
                    self._actions[action].setText(label)
                    self._actions[action].setEnabled(enabled)

        def _build(self):
            self._menu = QMenu()
            for action, label, enabled in menu_entries(self._glyph):
                item = QAction(label, self._menu)
                item.setEnabled(enabled)
                item.triggered.connect(lambda checked=False, name=action: self.actionRequested.emit(name))
                self._menu.addAction(item)
                self._actions[action] = item
            self._icon = QSystemTrayIcon(self)
            self._icon.setContextMenu(self._menu)
            self._icon.activated.connect(
                lambda reason: self.actionRequested.emit("open") if reason == QSystemTrayIcon.ActivationReason.Trigger else None)
            self._icon.setIcon(QIcon(str(glyph_path(self._glyph))))
            self._icon.setToolTip(tooltip(self._glyph))
