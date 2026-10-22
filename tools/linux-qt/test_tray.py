"""Tests for the tray. The glyph and menu logic runs anywhere; the QSystemTrayIcon wiring needs PySide6 (offscreen)."""
import os
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import tray  # noqa: E402


class GlyphTests(unittest.TestCase):
    def test_every_state_has_a_shipped_glyph(self):
        for name in tray.GLYPHS:
            with self.subTest(glyph=name):
                self.assertTrue(tray.glyph_path(name).is_file(), tray.glyph_path(name))

    def test_unknown_state_shows_unavailable(self):
        self.assertEqual(tray.glyph_name("bogus"), "unavailable")
        self.assertEqual(tray.glyph_name(""), "unavailable")

    def test_tooltips(self):
        self.assertEqual(tray.tooltip("recording2"), "Mouthtype: listening")
        self.assertEqual(tray.tooltip("unavailable"), "Mouthtype: service not running")


class VariantTests(unittest.TestCase):
    def test_dark_panel_gets_the_light_glyph(self):
        self.assertEqual(tray.variant_for(0, 0, 0), "light")
        self.assertEqual(tray.variant_for(36, 36, 36), "light")  # GNOME top bar, Breeze Dark

    def test_light_panel_gets_the_dark_glyph(self):
        self.assertEqual(tray.variant_for(255, 255, 255), "dark")
        self.assertEqual(tray.variant_for(239, 240, 241), "dark")  # Breeze Light window colour

    def test_every_variant_has_a_tint(self):
        for variant in ("light", "dark"):
            self.assertIn(variant, tray.VARIANT_RGB)


class MenuTests(unittest.TestCase):
    def test_entries_are_start_open_settings_quit(self):
        self.assertEqual([a for a, _, _ in tray.menu_entries("idle")], ["toggle", "open", "settings", "quit"])

    def test_toggle_reads_the_state(self):
        self.assertEqual(tray.menu_entries("idle")[0], ("toggle", "Start dictation", True))
        self.assertEqual(tray.menu_entries("recording1")[0], ("toggle", "Stop dictation", True))
        self.assertEqual(tray.menu_entries("processing")[0][2], True)

    def test_toggle_is_disabled_when_the_service_is_down(self):
        self.assertEqual(tray.menu_entries("unavailable")[0], ("toggle", "Start dictation", False))
        self.assertTrue(all(enabled for _, _, enabled in tray.menu_entries("unavailable")[1:]))


@unittest.skipUnless(tray.HAVE_QT, "PySide6 is not installed")
class TrayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from PySide6.QtWidgets import QApplication
        cls.app = QApplication.instance() or QApplication([])

    def make(self, available):
        state = {"available": available}
        item = tray.Tray(availability=lambda: state["available"])
        changes = []
        item.availableChanged.connect(lambda: changes.append(item.available))
        return item, state, changes

    def test_unavailable_tray_sets_the_flag_and_builds_no_icon(self):
        item, _, changes = self.make(False)
        item.check()
        self.assertFalse(item.available)
        self.assertIsNone(item._icon)
        self.assertEqual(changes, [])  # still False, nothing changed
        item.setGlyph("recording0")  # must not raise without an icon

    def test_available_tray_builds_the_icon_and_menu(self):
        item, _, changes = self.make(True)
        item.check()
        self.assertTrue(item.available)
        self.assertEqual(changes, [True])
        self.assertEqual(list(item._actions), ["toggle", "open", "settings", "quit"])

    def test_glyph_updates_the_menu_label_and_enabled_state(self):
        item, _, _ = self.make(True)
        item.check()
        item.setGlyph("recording1")
        self.assertEqual(item._actions["toggle"].text(), "Stop dictation")
        item.setGlyph("unavailable")
        self.assertFalse(item._actions["toggle"].isEnabled())
        self.assertEqual(item._icon.toolTip(), "Mouthtype: service not running")

    def test_a_tray_host_that_appears_later_is_picked_up(self):
        item, state, changes = self.make(False)
        item.start()
        self.assertTrue(item._timer.isActive())
        state["available"] = True
        item.check()
        self.assertTrue(item.available)
        self.assertFalse(item._timer.isActive())
        self.assertEqual(changes, [True])

    def test_glyph_is_tinted_for_the_variant_and_keeps_alpha(self):
        for variant, rgb in tray.VARIANT_RGB.items():
            image = tray.glyph_icon("idle", variant).pixmap(32, 30).toImage()
            seen = [image.pixelColor(x, y) for x in range(image.width()) for y in range(image.height())]
            opaque = [c for c in seen if c.alpha() > 200]
            self.assertTrue(opaque)
            self.assertTrue(all((c.red(), c.green(), c.blue()) == rgb for c in opaque))
            self.assertTrue(any(c.alpha() == 0 for c in seen))

    def test_menu_actions_are_emitted(self):
        item, _, _ = self.make(True)
        item.check()
        item.setGlyph("idle")  # Start is disabled while the service is down
        got = []
        item.actionRequested.connect(got.append)
        for name in ("toggle", "open", "settings", "quit"):
            item._actions[name].trigger()
        self.assertEqual(got, ["toggle", "open", "settings", "quit"])


if __name__ == "__main__":
    unittest.main()
