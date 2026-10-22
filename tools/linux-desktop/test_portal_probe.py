import json
import types
import unittest

import portal
import portal_probe


class FakePortal:
    """Just enough Portal for run_probe: versions, register, one shortcut session and canned signals."""
    app_id = 'app.mouthtype.Mouthtype'

    def __init__(self, versions, bind_error=None, deactivate=True):
        self.versions = versions
        self.bind_error = bind_error
        self.deactivate = deactivate
        self.keys = []

    def register(self):
        return True

    def interface_version(self, interface, timeout=None):
        return self.versions.get(interface.rsplit('.', 1)[1], 0)

    def get_property(self, interface, name, *, path=None, timeout=None):
        if interface == portal.REGISTRY_IFACE:
            return self.versions.get('Registry', 0)
        raise portal.PortalError('no property')

    def create_session(self, interface, options=None, timeout=None):
        return '/session/1'

    def request(self, interface, method, signature='', args=(), *, options=None, path=None, timeout=None):
        if self.bind_error:
            raise self.bind_error
        return {'shortcuts': [(portal_probe.SHORTCUT_ID, {'trigger_description': ('s', 'Press Ctrl+Alt+M')})]}

    def subscribe(self, interface, member, path=None, **kwargs):
        class Sub:
            def __enter__(self):
                return member

            def __exit__(self, *exc):
                return False
        return Sub()

    def get_signal(self, signals, timeout=None):
        if signals == 'Deactivated' and not self.deactivate:
            raise portal.PortalTimeout('none')
        return types.SimpleNamespace(body=('/session/1', portal_probe.SHORTCUT_ID, 1234, {}))

    def call(self, *args, **kwargs):
        return ('/mutter/session',)

    def close_session(self, session, timeout=None):
        pass


def args(**extra):
    base = dict(driver='none', rounds=2, hold=0.0, bind_timeout=1.0, wait=0.2, consent='none')
    base.update(extra)
    return types.SimpleNamespace(**base)


class ChooseDriverTests(unittest.TestCase):
    def test_follows_the_desktop(self):
        self.assertEqual(portal_probe.choose_driver('auto', {'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME'}), 'mutter')
        self.assertEqual(portal_probe.choose_driver('auto', {'XDG_CURRENT_DESKTOP': 'KDE'}), 'portal')
        self.assertEqual(portal_probe.choose_driver('auto', {'XDG_CURRENT_DESKTOP': 'sway'}), 'none')
        self.assertEqual(portal_probe.choose_driver('portal', {'XDG_CURRENT_DESKTOP': 'GNOME'}), 'portal')


class RunProbeTests(unittest.TestCase):
    VERSIONS = {'GlobalShortcuts': 2, 'RemoteDesktop': 2, 'Clipboard': 1, 'Registry': 1}

    def test_records_versions_and_grant(self):
        result = portal_probe.run_probe(FakePortal(self.VERSIONS), args(), {'XDG_CURRENT_DESKTOP': 'GNOME'})
        self.assertEqual(result['interfaces']['versions'], self.VERSIONS)
        self.assertTrue(result['registry']['registered'])
        self.assertEqual(result['shortcuts']['granted']['shortcuts'], [{'id': 'probe-chord', 'trigger': 'Press Ctrl+Alt+M'}])
        json.dumps(result)

    def test_missing_global_shortcuts_is_reported_not_raised(self):
        result = portal_probe.run_probe(FakePortal({'RemoteDesktop': 1}), args(), {})
        self.assertFalse(result['shortcuts']['ok'])
        self.assertEqual(result['interfaces']['versions']['GlobalShortcuts'], 0)

    def test_refused_bind_becomes_evidence(self):
        fake = FakePortal(self.VERSIONS, bind_error=portal.PortalTimeout('no dialog answer'))
        result = portal_probe.run_probe(fake, args(), {})
        self.assertFalse(result['shortcuts']['granted']['ok'])
        self.assertIn('no dialog answer', result['shortcuts']['granted']['error'])

    def test_rounds_measure_deactivated_latency(self):
        fake = FakePortal(self.VERSIONS)
        result = portal_probe.run_probe(fake, args(driver='mutter'), {})
        shortcuts = result['shortcuts']
        self.assertEqual(shortcuts['deactivated_received'], 2)
        self.assertEqual(len(shortcuts['rounds']), 2)
        self.assertIn('mean', shortcuts['deactivated_latency_ms'])
        self.assertEqual(shortcuts['rounds'][0]['deactivated_stamp'], 1234)

    def test_missing_deactivated_is_recorded_as_none(self):
        fake = FakePortal(self.VERSIONS, deactivate=False)
        result = portal_probe.run_probe(fake, args(driver='mutter'), {})
        shortcuts = result['shortcuts']
        self.assertEqual(shortcuts['deactivated_received'], 0)
        self.assertIsNone(shortcuts['rounds'][0]['deactivated_ms'])


if __name__ == '__main__':
    unittest.main()
