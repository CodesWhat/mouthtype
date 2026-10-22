"""Tests for the PySide6 host. They need PySide6 and run offscreen; without it they skip (CI installs it)."""
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
HOST = HERE / "mouthtype_desktop.py"
FIXTURE = HERE / "fixtures" / "control.py"
PAGES = ("home", "transcript", "import", "stats", "dictionary", "transforms", "style", "appearance",
         "general", "linux", "advanced", "health")

try:
    import PySide6  # noqa: F401
    HAVE_QT = True
except ImportError:
    HAVE_QT = False


def environment():
    env = dict(os.environ)
    env.update(QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software")
    return env


def run_host(*extra, timeout=60):
    return subprocess.run([sys.executable, str(HOST), "--helper", str(FIXTURE), *extra],
                          env=environment(), capture_output=True, text=True, timeout=timeout)


@unittest.skipUnless(HAVE_QT, "PySide6 is not installed")
class SelftestTests(unittest.TestCase):
    def test_every_page_loads_with_fixture_control_output(self):
        for page in PAGES:
            with self.subTest(page=page):
                result = run_host("--selftest", "--page", page)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("is not a type", result.stderr)
                self.assertNotIn("module \"MouthtypePlatform\" is not installed", result.stderr)

    def test_missing_helper_still_opens_with_the_service_off(self):
        started = time.monotonic()
        result = subprocess.run([sys.executable, str(HOST), "--selftest", "--helper", "/nonexistent/control.py"],
                                env=environment(), capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic() - started, 30)

    def test_settings_window_renders_to_a_png(self):
        with tempfile.TemporaryDirectory() as directory:
            for page in ("home", "general"):
                with self.subTest(page=page):
                    png = Path(directory) / ("%s.png" % page)
                    result = run_host("--screenshot", str(png), "--page", page)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue(png.read_bytes().startswith(b"\x89PNG"))
                    from PySide6.QtGui import QImage
                    image = QImage(str(png))
                    self.assertGreaterEqual(image.width(), 640)
                    colors = {image.pixel(x, y) for x in range(0, image.width(), 37) for y in range(0, image.height(), 29)}
                    self.assertGreater(len(colors), 3, "the render is blank")


@unittest.skipUnless(HAVE_QT, "PySide6 is not installed")
class SingleInstanceTests(unittest.TestCase):
    def test_second_launch_hands_its_page_to_the_first_and_exits(self):
        name = "mouthtype-desktop-test-%d" % os.getpid()
        first = subprocess.Popen([sys.executable, str(HOST), "--helper", str(FIXTURE), "--server-name", name],
                                 env=environment(), stderr=subprocess.PIPE, text=True)
        try:
            socket_path = None
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and first.poll() is None:
                found = [p for p in Path(tempfile.gettempdir()).glob("*%s*" % name)] + [p for p in Path("/tmp").glob("*%s*" % name)]
                if found:
                    socket_path = found[0]
                    break
                time.sleep(0.2)
            self.assertIsNotNone(socket_path, "the first instance never opened its socket")
            second = subprocess.run([sys.executable, str(HOST), "--helper", str(FIXTURE), "--server-name", name, "--page", "stats"],
                                    env=environment(), capture_output=True, text=True, timeout=30)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIsNone(first.poll(), "the first instance should keep running")
        finally:
            first.terminate()
            try:
                first.wait(10)
            except subprocess.TimeoutExpired:
                first.kill()
                first.wait()
            first.stderr.close()


@unittest.skipUnless(HAVE_QT, "PySide6 is not installed")
class BackendTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.environ.update(QT_QPA_PLATFORM="offscreen")
        sys.path.insert(0, str(HERE))
        import mouthtype_desktop
        from PySide6.QtWidgets import QApplication  # one QApplication per process; test_tray needs widgets
        cls.module = mouthtype_desktop
        cls.app = QApplication.instance() or QApplication([])
        cls.backend = cls.module.PlatformBackend()

    def collect(self, call_id, argv):
        from PySide6.QtCore import QEventLoop, QTimer
        got = []
        loop = QEventLoop()

        def on_finished(i, out, code):
            got.append((i, out, code))
            loop.quit()

        self.backend.finished.connect(on_finished)
        self.backend.run(call_id, argv)
        QTimer.singleShot(15000, loop.quit)
        loop.exec()
        self.backend.finished.disconnect(on_finished)
        return got

    def test_run_reports_stdout_and_exit_code(self):
        backend = self.backend
        self.assertEqual(self.collect(1, [sys.executable, "-c", "print('hi'); raise SystemExit(3)"]), [(1, "hi\n", 3)])

    def test_run_reports_minus_one_when_it_cannot_start(self):
        backend = self.backend
        self.assertEqual(self.collect(2, ["/nonexistent/mouthtype-binary"]), [(2, "", -1)])

    def test_run_kills_a_hung_process(self):
        self.module.PROCESS_TIMEOUT_MS, saved = 300, self.module.PROCESS_TIMEOUT_MS
        try:
            backend = self.backend
            got = self.collect(3, [sys.executable, "-c", "import time; time.sleep(60)"])
        finally:
            self.module.PROCESS_TIMEOUT_MS = saved
        self.assertEqual(got[0][0], 3)
        self.assertEqual(got[0][2], -1)

    def test_read_file_and_env(self):
        backend = self.backend
        self.assertEqual(backend.readFile("/nonexistent/file"), "")
        os.environ["MOUTHTYPE_HOST_TEST"] = "value"
        self.assertEqual(backend.env("MOUTHTYPE_HOST_TEST"), "value")
        self.assertEqual(backend.env("MOUTHTYPE_HOST_UNSET"), "")

    def test_watch_fires_on_load_and_on_change(self):
        from PySide6.QtCore import QEventLoop, QTimer
        backend = self.backend
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bar-lips"
            path.write_text("1")
            seen = []
            loop = QEventLoop()

            def on_change(changed, text):
                seen.append(text)
                if text == "2":
                    loop.quit()

            backend.changed.connect(on_change)
            backend.watch(str(path))
            QTimer.singleShot(200, lambda: path.write_text("2"))
            QTimer.singleShot(10000, loop.quit)
            loop.exec()
            backend.unwatch(str(path))
        self.assertEqual(seen[0], "1")
        self.assertIn("2", seen)

    def test_dark_follows_the_color_scheme_setter(self):
        host = self.module.Host(self.module.parse_args([]))
        changes = []
        host.darkChanged.connect(lambda: changes.append(host.dark))
        host.set_dark(True)
        host.set_dark(True)
        host.set_dark(False)
        self.assertEqual(changes, [True, False])


if __name__ == "__main__":
    unittest.main()
