"""The daemon's backend selection per desktop environment, end to end through the registry."""
import sys
import unittest
from unittest import mock

import backends
import delivery_portal
import desktop
import shortcuts_portal
import atspi_target
import doctor
import portal as portal_module

ENVIRONMENTS = {
    'hyprland': {'HYPRLAND_INSTANCE_SIGNATURE': 'x', 'XDG_CURRENT_DESKTOP': 'Hyprland', 'XDG_SESSION_TYPE': 'wayland'},
    'gnome': {'XDG_CURRENT_DESKTOP': 'GNOME', 'XDG_SESSION_TYPE': 'wayland'},
    'kde': {'XDG_CURRENT_DESKTOP': 'KDE', 'XDG_SESSION_TYPE': 'wayland'},
    'sway': {'XDG_CURRENT_DESKTOP': 'sway', 'XDG_SESSION_TYPE': 'wayland'},
    'unknown': {'XDG_SESSION_TYPE': 'x11'},
}


class FakePortal:
    registered = False

    def connect(self):
        return self

    def register(self):
        self.registered = True
        return True

    def watch_restarts(self, callback):
        self.restart_callback = callback

    def close(self):
        pass


class FakeRemote:
    def __init__(self, portal, store):
        self.portal, self.store, self.session, self.detail = portal, store, None, 'no stored keyboard grant'
        self.active = False

    def start(self, interactive=False, timeout=None):
        assert interactive is False
        return 'needs_grant'

    def check(self):
        return 'needs_grant'

    def close(self):
        pass


class SelectionTests(unittest.TestCase):
    def setUp(self):
        # A real AT-SPI init aborts the process when no accessibility bus is running (CI), so never let a test reach it.
        patch = mock.patch.object(atspi_target.AtspiTargets, '_module', lambda self: None)
        patch.start()
        self.addCleanup(patch.stop)

    def build(self, name):
        desktop_name = backends.detect(ENVIRONMENTS[name])
        self.assertEqual(desktop_name, name)
        chosen = backends.delivery_name(desktop_name)
        with mock.patch.object(portal_module, 'Portal', FakePortal), \
                mock.patch.object(delivery_portal, 'RemoteDesktopSession', FakeRemote):
            return chosen, backends.make_delivery(chosen, {'mode': 'paste'}, store_factory=lambda: mock.Mock()) \
                if chosen == 'portal' else backends.make_delivery(chosen, {}, run=lambda *a, **k: None)

    def test_delivery_class_per_desktop(self):
        for name, cls in (('hyprland', desktop.HyprlandDelivery), ('sway', desktop.HyprlandDelivery),
                          ('unknown', desktop.HyprlandDelivery), ('gnome', delivery_portal.PortalDelivery),
                          ('kde', delivery_portal.PortalDelivery)):
            with self.subTest(name):
                chosen, delivery = self.build(name)
                self.assertIs(type(delivery), cls)

    def test_portal_delivery_gets_atspi_targets(self):
        for name in ('gnome', 'kde'):
            with self.subTest(name):
                _, delivery = self.build(name)
                self.assertIsInstance(delivery.targets, atspi_target.AtspiTargets)
                self.assertIsNone(delivery.snapshot().get('secure'))
                delivery.close()

    def test_portal_registers_before_the_session_and_stays_recover_only_without_a_grant(self):
        _, delivery = self.build('gnome')
        self.assertTrue(delivery.portal.registered)
        self.assertEqual(delivery.submit('hi', {'class': 'x'}), 'recover_only')

    def test_unreachable_portal_leaves_recover_only_delivery(self):
        class Down:
            def connect(self):
                raise portal_module.PortalUnavailable('no bus')
        delivery = delivery_portal.make_delivery({'mode': 'paste'}, portal_factory=Down, targets=mock.Mock(),
                                                 store_factory=lambda: mock.Mock())
        self.assertIsInstance(delivery, delivery_portal.PortalDelivery)
        self.assertEqual(delivery.submit('hi', {'class': 'x'}), 'recover_only')
        delivery.close()

    def test_shortcut_backend_per_desktop(self):
        for name in ENVIRONMENTS:
            with self.subTest(name):
                chosen = backends.shortcuts_name(name)
                made = backends.make_shortcuts(chosen, mock.Mock())
                if name in ('gnome', 'kde'):
                    self.assertIsInstance(made, shortcuts_portal.PortalShortcuts)
                else:
                    self.assertIsNone(made)

    def test_attach_only_starts_portal_shortcuts_on_gnome_and_kde(self):
        with mock.patch.object(shortcuts_portal.PortalShortcuts, 'start', lambda self: self):
            for name in ENVIRONMENTS:
                with self.subTest(name):
                    attached = shortcuts_portal.attach(mock.Mock(), ENVIRONMENTS[name])
                    self.assertEqual(attached is not None, name in ('gnome', 'kde'))

    def test_main_builds_delivery_through_the_registry(self):
        self.assertIs(backends._delivery['portal'], desktop._portal_delivery)
        self.assertIs(backends._delivery['hyprland'], desktop.HyprlandDelivery)


class RegistryDiagnosticTests(unittest.TestCase):
    def run_check(self, error):
        class P(FakePortal):
            def register(self):
                if error:
                    raise error
        checks = []
        doctor.portal_registry(lambda *a: checks.append(a), P)
        return checks[0]

    def test_app_info_not_found_is_actionable(self):
        name, status, detail, action = self.run_check(portal_module.AppInfoNotFound(
            portal_module.APP_INFO_HELP.format(app_id='app.mouthtype.Mouthtype')))
        self.assertEqual((name, status), ('portal', 'error'))
        self.assertIn('App info not found', detail)
        self.assertIn('Exec program is on PATH', action)

    def test_ok_and_other_failures(self):
        self.assertEqual(self.run_check(None)[1], 'ok')
        self.assertEqual(self.run_check(portal_module.PortalError('boom'))[1], 'warning')


class RegisterErrorTests(unittest.TestCase):
    def test_register_maps_app_info_error(self):
        class DBusErrorResponse(Exception):
            name = 'org.freedesktop.DBus.Error.Failed'
            data = 'App info not found for app.mouthtype.Mouthtype'

        def unwrap_msg(reply):
            raise DBusErrorResponse()

        wrappers = mock.Mock(DBusErrorResponse=DBusErrorResponse, unwrap_msg=unwrap_msg)
        portal = portal_module.Portal()
        with mock.patch.object(portal_module, '_jeepney', return_value=(mock.Mock(), None)), \
                mock.patch.object(portal, '_send', return_value=None), \
                mock.patch.dict(sys.modules, {'jeepney': mock.Mock(), 'jeepney.wrappers': wrappers}):
            with self.assertRaises(portal_module.AppInfoNotFound):
                portal.register()


class PackagingTests(unittest.TestCase):
    def test_desktop_deb_depends_on_qtwidgets(self):
        from pathlib import Path
        path = Path(__file__).resolve().parents[2] / 'packaging/debian/control-desktop.in'
        if not path.is_file():
            self.skipTest('packaging/ is not part of the installed source tree')
        control = path.read_text()
        self.assertIn('python3-pyside6.qtwidgets', control.split('Depends:')[1].split('\n')[0])


if __name__ == '__main__':
    unittest.main()
