import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import backends
import desktop


class DetectTests(unittest.TestCase):
    def test_matrix(self):
        cases = [
            ({'HYPRLAND_INSTANCE_SIGNATURE': 'x', 'XDG_CURRENT_DESKTOP': 'GNOME', 'XDG_SESSION_TYPE': 'wayland'}, 'hyprland'),
            ({'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME', 'XDG_SESSION_TYPE': 'wayland'}, 'gnome'),
            ({'XDG_CURRENT_DESKTOP': 'GNOME', 'XDG_SESSION_TYPE': 'x11'}, 'unknown'),
            ({'XDG_CURRENT_DESKTOP': 'KDE', 'XDG_SESSION_TYPE': 'wayland'}, 'kde'),
            ({'XDG_CURRENT_DESKTOP': 'KDE', 'XDG_SESSION_TYPE': 'x11'}, 'unknown'),
            ({'XDG_CURRENT_DESKTOP': 'KDE'}, 'unknown'),
            ({'XDG_CURRENT_DESKTOP': 'sway', 'XDG_SESSION_TYPE': 'wayland'}, 'sway'),
            ({'SWAYSOCK': '/run/sway.sock'}, 'sway'),
            ({'XDG_CURRENT_DESKTOP': 'GNOME', 'SWAYSOCK': '/s'}, 'unknown'),
            ({'XDG_CURRENT_DESKTOP': 'gnome', 'XDG_SESSION_TYPE': 'Wayland'}, 'gnome'),
            ({'HYPRLAND_INSTANCE_SIGNATURE': ''}, 'unknown'),
            ({}, 'unknown'),
        ]
        for env, expected in cases:
            with self.subTest(env=env):
                self.assertEqual(backends.detect(env), expected)


class RegistryTests(unittest.TestCase):
    def test_auto_names(self):
        self.assertEqual(backends.delivery_name('hyprland'), 'hyprland')
        self.assertEqual(backends.delivery_name('gnome'), 'portal')
        self.assertEqual(backends.shortcuts_name('kde'), 'portal')
        self.assertEqual(backends.shortcuts_name('hyprland'), 'hyprland')
        self.assertEqual(backends.shortcuts_name('unknown'), 'none')

    def test_overrides(self):
        self.assertEqual(backends.delivery_name('gnome', 'recover'), 'recover')
        self.assertEqual(backends.shortcuts_name('gnome', 'command'), 'command')
        with self.assertRaises(ValueError):
            backends.delivery_name('gnome', 'bogus')
        with self.assertRaises(ValueError):
            backends.shortcuts_name('gnome', 'bogus')

    def test_every_desktop_has_a_default(self):
        for name in backends.DESKTOPS:
            self.assertIn(backends.delivery_name(name), backends.DELIVERY_NAMES)
            self.assertIn(backends.shortcuts_name(name), backends.SHORTCUT_NAMES)

    def test_hyprland_registered_unchanged(self):
        delivery = backends.make_delivery('hyprland', {}, run=lambda *a, **k: None)
        self.assertIsInstance(delivery, desktop.HyprlandDelivery)

    def test_unimplemented_backend_falls_back_to_hyprland(self):
        delivery = backends.make_delivery('portal', {}, run=lambda *a, **k: None)
        self.assertIsInstance(delivery, desktop.HyprlandDelivery)

    def test_shortcuts_without_implementation_is_none(self):
        self.assertIsNone(backends.make_shortcuts('portal'))

    def test_registered_factory_is_used(self):
        backends.register_delivery('probe', lambda *a, **k: ('probe', a))
        try:
            self.assertEqual(backends.make_delivery('probe', 1), ('probe', (1,)))
        finally:
            backends._delivery.pop('probe')


if __name__ == '__main__':
    unittest.main()
