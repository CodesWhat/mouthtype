#!/usr/bin/env python3
"""Mouthtype settings window for GNOME and KDE: the shared QML (AppState + MouthtypeShell) hosted by PySide6.

One instance per user session. A second launch hands its --page to the running one and exits. The window talks to the
daemon only through control.py, the same way the Omarchy panel does.
"""
import argparse
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PLUGIN = HERE.parent / "omarchy-plugin"
PROCESS_TIMEOUT_MS = 30000
HANDOFF_TIMEOUT_MS = 1500

try:
    from PySide6.QtCore import (
        QCoreApplication, QFileSystemWatcher, QLibraryInfo, QObject, QProcess, QRect, QTimer, QUrl, Property, Signal, Slot, Qt,
    )
    from PySide6.QtGui import QDesktopServices, QRegion, QWindow
    from PySide6.QtWidgets import QApplication
    from PySide6.QtNetwork import QLocalServer, QLocalSocket
    from PySide6.QtQml import QQmlApplicationEngine
except ImportError as error:  # pragma: no cover - exercised only on machines without PySide6
    sys.exit("mouthtype-desktop needs PySide6 (Ubuntu: python3-pyside6.qtquick and python3-pyside6.qtwidgets, Fedora: python3-pyside6): %s" % error)

sys.path.insert(0, str(HERE))
from tray import Tray  # noqa: E402


# The system style on KDE and GNOME refuses the property customisation the shared QML relies on.
os.environ.setdefault("QT_QUICK_CONTROLS_STYLE", "Basic")


def server_name():
    return "mouthtype-desktop-%d" % os.getuid()


def layer_shell_available(platform_name, import_paths):
    """True on a Wayland session where the LayerShellQt QML module (org.kde.layershell) is installed."""
    if platform_name != "wayland":
        return False
    return any((Path(path) / "org" / "kde" / "layershell" / "qmldir").is_file() for path in import_paths)


class PlatformBackend(QObject):
    """What MouthtypePlatform/Platform.qml calls: env, finite QProcess runs, file watching, URLs."""

    finished = Signal(int, str, int)
    changed = Signal(str, str)

    def __init__(self, layer_shell=False, parent=None):
        super().__init__(parent)
        self._layer_shell = layer_shell
        self._processes = {}
        self._watcher = QFileSystemWatcher(self)
        self._watcher.fileChanged.connect(self._file_changed)
        self._watcher.directoryChanged.connect(self._directory_changed)
        self._watched = set()

    @Property(bool, constant=True)
    def layerShell(self):
        return self._layer_shell

    @Slot(str, result=str)
    def env(self, name):
        return os.environ.get(name, "")

    @Slot(int, "QStringList")
    def run(self, call_id, argv):
        if not argv:
            self.finished.emit(call_id, "", -1)
            return
        process = QProcess(self)
        process.setProgram(argv[0])
        process.setArguments(list(argv[1:]))
        process.setStandardInputFile(QProcess.nullDevice())
        timer = QTimer(process)
        timer.setSingleShot(True)
        state = {"done": False}

        def done(out, code):
            if state["done"]:
                return
            state["done"] = True
            timer.stop()
            self._processes.pop(call_id, None)
            self.finished.emit(call_id, out, code)
            process.deleteLater()

        process.errorOccurred.connect(lambda error: done("", -1) if error == QProcess.ProcessError.FailedToStart else None)
        process.finished.connect(
            lambda code, status: done(
                bytes(process.readAllStandardOutput()).decode("utf-8", "replace"),
                code if status == QProcess.ExitStatus.NormalExit else -1,
            )
        )
        timer.timeout.connect(process.kill)
        self._processes[call_id] = process
        process.start()
        timer.start(PROCESS_TIMEOUT_MS)

    @Slot(str, result=str)
    def readFile(self, path):
        try:
            return Path(path).read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    @Slot(str)
    def watch(self, path):
        self._watched.add(path)
        parent = str(Path(path).parent)
        if Path(parent).is_dir() and parent not in self._watcher.directories():
            self._watcher.addPath(parent)
        if Path(path).exists() and path not in self._watcher.files():
            self._watcher.addPath(path)
        self.changed.emit(path, self.readFile(path))

    @Slot(str)
    def unwatch(self, path):
        self._watched.discard(path)
        if path in self._watcher.files():
            self._watcher.removePath(path)

    @Slot(str)
    def openUrl(self, url):
        QDesktopServices.openUrl(QUrl(url))

    def _file_changed(self, path):
        # Editors replace files, which drops the watch; add it back.
        if path not in self._watcher.files() and Path(path).exists():
            self._watcher.addPath(path)
        if path in self._watched:
            self.changed.emit(path, self.readFile(path))

    def _directory_changed(self, directory):
        for path in list(self._watched):
            if str(Path(path).parent) == directory and Path(path).exists() and path not in self._watcher.files():
                self._watcher.addPath(path)
                self.changed.emit(path, self.readFile(path))


class PillFeed(QObject):
    """The `PillFeed` context property: lines of the daemon's `watch --retry` stream, which PillWindow.qml turns into pill states."""

    line = Signal(str)

    def __init__(self, launcher, config, parent=None):
        super().__init__(parent)
        self._argv = [launcher, "--config", config, "watch", "--retry"]
        self._process = None
        self._buffer = b""
        self._stopped = False

    def start(self):
        self._stopped = False
        process = QProcess(self)
        program, arguments = self._argv[0], self._argv[1:]
        if shutil.which("setpriv"):  # the stream dies with this process
            program, arguments = "setpriv", ["--pdeathsig", "TERM", self._argv[0]] + arguments
        process.setProgram(program)
        process.setArguments(arguments)
        process.setStandardInputFile(QProcess.nullDevice())
        process.readyReadStandardOutput.connect(self._read)
        process.finished.connect(lambda *_: self._exited())
        process.errorOccurred.connect(lambda error: self._exited() if error == QProcess.ProcessError.FailedToStart else None)
        self._process = process
        process.start()

    def stop(self):
        self._stopped = True
        if self._process is not None:
            self._process.finished.disconnect()
            self._process.kill()
            self._process.waitForFinished(1000)
            self._process = None

    def _read(self):
        self._buffer += bytes(self._process.readAllStandardOutput())
        *lines, self._buffer = self._buffer.split(b"\n")
        for raw in lines:
            if raw.strip():
                self.line.emit(raw.decode("utf-8", "replace"))

    def _exited(self):
        if self._process is not None:
            self._process.deleteLater()
            self._process = None
        self._buffer = b""
        if not self._stopped:
            QTimer.singleShot(3000, lambda: None if self._stopped or self._process is not None else self.start())


class Host(QObject):
    """The `Host` context property of Main.qml."""

    pageRequested = Signal(str)
    darkChanged = Signal()

    def __init__(self, args, parent=None):
        super().__init__(parent)
        self._args = args
        self._dark = False
        self.exit_code = None

    @Property(str, constant=True)
    def helper(self):
        return self._args.helper

    @Property(str, constant=True)
    def startPage(self):
        return self._args.page

    @Property(int, constant=True)
    def settleMs(self):
        return self._args.settle_ms

    @Property(str, constant=True)
    def screenshotPath(self):
        return self._args.screenshot or ""

    @Property(str, constant=True)
    def pillScreenshotPath(self):
        return self._args.pill_screenshot or ""

    @Property(str, constant=True)
    def pillConfig(self):
        return self._args.config or ""

    @Property(bool, constant=True)
    def watchdog(self):
        return self._args.selftest or bool(self._args.screenshot) or bool(self._args.pill_screenshot)

    @Slot(QObject, int, int, int, int)
    def setInputRegion(self, window, x, y, width, height):
        """Limit the pill surface's input to one rectangle so clicks elsewhere reach the app below (Wayland input region)."""
        if isinstance(window, QWindow):
            window.setMask(QRegion(QRect(x, y, max(width, 1), max(height, 1))))

    @Property(bool, notify=darkChanged)
    def dark(self):
        return self._dark

    def set_dark(self, value):
        if value != self._dark:
            self._dark = value
            self.darkChanged.emit()

    @Slot()
    def loaded(self):
        if self._args.selftest or self._args.screenshot or self._args.pill_screenshot:
            self.finish(0)

    @Slot(str)
    def failed(self, reason):
        print("mouthtype-desktop: %s" % reason, file=sys.stderr)
        self.finish(1)

    def finish(self, code):
        self.exit_code = code
        QTimer.singleShot(0, QCoreApplication.quit)


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="mouthtype-desktop", description="Mouthtype settings window for GNOME and KDE.")
    parser.add_argument("--page", default="home", help="page to open: home, stats, dictionary, transforms, style, appearance, a settings tab, ...")
    parser.add_argument("--helper", default=str(PLUGIN / "control.py"), help="control.py to run (default: the one next to the QML)")
    parser.add_argument("--selftest", action="store_true", help="load the page, wait for the first state reply, exit 0 (1 on failure)")
    parser.add_argument("--screenshot", metavar="PNG", help="save the window to PNG once the page has settled, then exit")
    parser.add_argument("--pill-screenshot", metavar="PNG", help="show the pill (needs --force-pill and a --launcher that reports a recording take), save it to PNG, exit")
    parser.add_argument("--launcher", default=str(Path.home() / ".local" / "bin" / "mouthtype-linux"), help="mouthtype-linux launcher whose `watch` stream feeds the pill")
    parser.add_argument("--config", default="", help="linux.json passed to the launcher (default: the speech-candidate one)")
    parser.add_argument("--no-pill", action="store_true", help="never show the floating pill")
    parser.add_argument("--force-pill", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--settle-ms", type=int, default=300, help=argparse.SUPPRESS)
    parser.add_argument("--server-name", default=None, help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def hand_off(name, page):
    """True when a running instance took the page; False when there is none."""
    socket = QLocalSocket()
    socket.connectToServer(name)
    if not socket.waitForConnected(HANDOFF_TIMEOUT_MS):
        return False
    socket.write(page.encode("utf-8"))
    socket.flush()
    socket.waitForBytesWritten(HANDOFF_TIMEOUT_MS)
    socket.disconnectFromServer()
    return True


def listen(name):
    server = QLocalServer()
    server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
    if not server.listen(name):
        QLocalServer.removeServer(name)  # stale socket from a crashed instance
        if not server.listen(name):
            return None
    return server


def color_scheme_is_dark(app):
    return app.styleHints().colorScheme() == Qt.ColorScheme.Dark


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    app = QApplication([sys.argv[0]])
    app.setApplicationName("Mouthtype")
    app.setDesktopFileName("app.mouthtype.Mouthtype")

    name = args.server_name or server_name()
    server = None
    if not (args.selftest or args.screenshot or args.pill_screenshot):
        if hand_off(name, args.page):
            return 0
        server = listen(name)

    engine = QQmlApplicationEngine()
    engine.addImportPath(str(HERE / "platform" / "qt"))
    layer_shell = not args.no_pill and (args.force_pill or layer_shell_available(
        app.platformName(), [QLibraryInfo.path(QLibraryInfo.LibraryPath.QmlImportsPath)] + engine.importPathList()))
    backend = PlatformBackend(layer_shell)
    host = Host(args)
    host.set_dark(color_scheme_is_dark(app))
    app.styleHints().colorSchemeChanged.connect(lambda scheme: host.set_dark(scheme == Qt.ColorScheme.Dark))
    engine.rootContext().setContextProperty("PlatformBackend", backend)
    engine.rootContext().setContextProperty("Host", host)
    tray = Tray()
    engine.rootContext().setContextProperty("Tray", tray)
    config = args.config or str(Path.home() / ".local" / "share" / "mouthtype" / "speech-candidate" / "linux.json")
    feed = PillFeed(args.launcher, config)
    engine.rootContext().setContextProperty("PillFeed", feed)
    tray.actionRequested.connect(lambda action: app.quit() if action == "quit" else None)

    if server is not None:
        def accept():
            while server.hasPendingConnections():
                socket = server.nextPendingConnection()
                socket.readyRead.connect(lambda s=socket: host.pageRequested.emit(bytes(s.readAll()).decode("utf-8", "replace").strip() or "home"))
                socket.disconnected.connect(socket.deleteLater)
        server.newConnection.connect(accept)

    engine.load(QUrl.fromLocalFile(str(HERE / "Main.qml")))
    if not engine.rootObjects():
        print("mouthtype-desktop: Main.qml failed to load", file=sys.stderr)
        return 1

    if layer_shell and not args.screenshot:
        feed.start()
        app.aboutToQuit.connect(feed.stop)

    if not (args.selftest or args.screenshot or args.pill_screenshot):
        tray.start()
        # With a tray icon the host keeps running after the window closes; without one, closing the window ends it.
        tray.availableChanged.connect(lambda: app.setQuitOnLastWindowClosed(not tray.available))
        app.setQuitOnLastWindowClosed(not tray.available)

    code = app.exec()
    return host.exit_code if host.exit_code is not None else code


if __name__ == "__main__":
    sys.exit(main())
