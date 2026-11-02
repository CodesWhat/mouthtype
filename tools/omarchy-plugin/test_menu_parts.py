"""Checks that the menu parts stay free of the Omarchy shell imports. Plain stdlib, no Qt needed."""
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PARTS = ("ControlButton.qml", "MenuRow.qml", "MenuDivider.qml")


class MenuPartsTests(unittest.TestCase):
    def test_parts_import_nothing_from_the_shell(self):
        for name in PARTS:
            text = (HERE / name).read_text()
            with self.subTest(part=name):
                self.assertNotIn("qs.", text)
                self.assertNotIn("import Quickshell", text)
                self.assertIn("property var style: MenuStyle {}", text)
                self.assertNotRegex(text, r"(?<![\w.])(Style|Color)\.")

    def test_default_style_is_shell_free_and_the_shell_adapter_matches_its_shape(self):
        default = (HERE / "MenuStyle.qml").read_text()
        shell = (HERE / "ShellMenuStyle.qml").read_text()
        self.assertNotIn("qs.", default)
        self.assertIn("import qs.Commons", shell)
        for member in ("accent", "mutedBackground", "foreground", "font", "function space("):
            with self.subTest(member=member):
                self.assertIn(member, default)
                self.assertIn(member, shell)


if __name__ == "__main__":
    unittest.main()
