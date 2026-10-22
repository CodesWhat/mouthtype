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


def variant_for(red, green, blue):
    """Which glyph tint reads on a panel of this colour: "light" glyph on a dark panel, "dark" on a light one.
    The shipped glyphs are black on transparent, so they vanish on a dark panel unless recoloured."""
    luma = 0.299 * red + 0.587 * green + 0.114 * blue
    return "light" if luma < 140 else "dark"


VARIANT_RGB = {"light": (255, 255, 255), "dark": (0, 0, 0)}


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
    from PySide6.QtGui import QAction, QGuiApplication, QIcon, QImage, QPainter, QPalette, QPixmap, QColor
    from PySide6.QtWidgets import QMenu, QSystemTrayIcon
    HAVE_QT = True
except ImportError:  # pragma: no cover - exercised only on machines without PySide6
    HAVE_QT = False


if HAVE_QT:
    def palette_variant():
        """Pick the tint from the application palette's window colour (which follows the KDE colour scheme)."""
        color = QGuiApplication.palette().color(QPalette.ColorRole.Window)
        return variant_for(color.red(), color.green(), color.blue())

    def glyph_icon(glyph, variant):
        """The shipped glyph recoloured to the variant, keeping its alpha. Falls back to the raw file if it won't load."""
        image = QImage(str(glyph_path(glyph)))
        if image.isNull():
            return QIcon(str(glyph_path(glyph)))
        image = image.convertToFormat(QImage.Format.Format_ARGB32_Premultiplied)
        painter = QPainter(image)
        painter.setCompositionMode(QPainter.CompositionMode.CompositionMode_SourceIn)
        painter.fillRect(image.rect(), QColor(*VARIANT_RGB[variant]))
        painter.end()
        return QIcon(QPixmap.fromImage(image))

    class Tray(QObject):
        """The `Tray` context property of Main.qml. QML pushes the glyph in and handles actionRequested."""

        availableChanged = Signal()
        actionRequested = Signal(str)

        def __init__(self, availability=None, parent=None):
            super().__init__(parent)
            self._probe = availability or QSystemTrayIcon.isSystemTrayAvailable
            self._glyph = "unavailable"
            self._variant = palette_variant()
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
                self._icon.setIcon(glyph_icon(self._glyph, self._variant))
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
            self._icon.setIcon(glyph_icon(self._glyph, self._variant))
            self._icon.setToolTip(tooltip(self._glyph))
            QGuiApplication.instance().paletteChanged.connect(self._palette_changed)

        def _palette_changed(self, *_):
            variant = palette_variant()
            if variant != self._variant:
                self._variant = variant
                if self._icon is not None:
                    self._icon.setIcon(glyph_icon(self._glyph, variant))
