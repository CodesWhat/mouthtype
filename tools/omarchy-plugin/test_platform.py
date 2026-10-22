"""Checks that the MouthtypePlatform implementations expose the same module and API. Plain stdlib, no Qt needed."""
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
IMPLEMENTATIONS = {
    "quickshell": HERE / "platform" / "quickshell" / "MouthtypePlatform",
    "fake": HERE / "design" / "render" / "fake" / "MouthtypePlatform",
}
FUNCTIONS = ("env", "run", "watch", "readFile", "openUrl")
PROPERTIES = ("focusedScreen", "isLayerShell")


class PlatformShimTests(unittest.TestCase):
    def test_qmldir_declares_one_singleton_module(self):
        for name, directory in IMPLEMENTATIONS.items():
            with self.subTest(implementation=name):
                lines = [l.strip() for l in (directory / "qmldir").read_text().splitlines() if l.strip()]
                self.assertEqual(lines, ["module MouthtypePlatform", "singleton Platform 1.0 Platform.qml"])

    def test_every_implementation_is_a_singleton(self):
        for name, directory in IMPLEMENTATIONS.items():
            with self.subTest(implementation=name):
                self.assertTrue((directory / "Platform.qml").read_text().startswith("pragma Singleton"))

    def test_api_names_match(self):
        for name, directory in IMPLEMENTATIONS.items():
            text = (directory / "Platform.qml").read_text()
            for fn in FUNCTIONS:
                with self.subTest(implementation=name, name=fn):
                    self.assertRegex(text, r"(?m)^\s*function %s\(" % fn)
            for prop in PROPERTIES:
                with self.subTest(implementation=name, name=prop):
                    self.assertRegex(text, r"(?m)^\s*(readonly )?property \w+ %s\b" % prop)

    def test_quickshell_implementation_leaves_the_pages_alone(self):
        # Pages reach the host through `host`/`backend`; only the shim may import Quickshell.
        for page in (HERE / "pages").glob("*.qml"):
            with self.subTest(page=page.name):
                self.assertNotIn("import Quickshell", page.read_text())

    def test_app_state_imports_only_qtquick_and_the_shim(self):
        imports = [l.strip() for l in (HERE / "AppState.qml").read_text().splitlines() if l.startswith("import ")]
        self.assertEqual([i for i in imports if not i.startswith("import \"")], ["import QtQuick", "import MouthtypePlatform"])


if __name__ == "__main__":
    unittest.main()
