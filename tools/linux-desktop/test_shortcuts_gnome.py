import os
import shutil
import subprocess
import tempfile
import unittest

import shortcuts_gnome as gnome


class FakeGsettings:
    """An in-memory gsettings: (schema-with-path, key) to GVariant text."""
    def __init__(self, listed=None):
        self.values = {}
        if listed is not None:
            self.values[(gnome.SCHEMA, 'custom-keybindings')] = gnome._format_list(listed)
        self.calls = []

    def __call__(self, verb, schema, key, value=None):
        self.calls.append((verb, schema, key, value))
        if verb == 'get':
            if (schema, key) not in self.values:
                return '@as []' if key == 'custom-keybindings' else "''"
            return self.values[(schema, key)]
        if verb == 'set':
            self.values[(schema, key)] = value
        else:
            self.values.pop((schema, key), None)
        return ''


class GnomeShortcutTests(unittest.TestCase):
    OTHER = gnome.BASE + 'custom0/'

    def setUp(self):
        self.fake = FakeGsettings([self.OTHER])
        self.fake.values[(gnome._entry(self.OTHER), 'binding')] = "'<Super>t'"

    def listed(self):
        return gnome._parse_list(self.fake.values[(gnome.SCHEMA, 'custom-keybindings')])

    def test_install_appends_and_keeps_the_users_entries(self):
        result = gnome.install(command='/x/mouthtype-linux toggle', run=self.fake)
        self.assertEqual(self.listed(), [self.OTHER, gnome.MARKED_PATH])
        self.assertEqual(result, {'backend': 'gnome-command', 'installed': True, 'hold': False,
                                  'binding': gnome.DEFAULT_BINDING, 'command': '/x/mouthtype-linux toggle'})
        self.assertEqual(self.fake.values[(gnome._entry(self.OTHER), 'binding')], "'<Super>t'")

    def test_install_twice_does_not_duplicate(self):
        gnome.install(command='c toggle', run=self.fake)
        gnome.install('<Control><Alt>m', command='c toggle', run=self.fake)
        self.assertEqual(self.listed(), [self.OTHER, gnome.MARKED_PATH])
        self.assertEqual(gnome.status(run=self.fake)['binding'], '<Control><Alt>m')

    def test_install_into_an_empty_list(self):
        fake = FakeGsettings([])
        gnome.install(command='c toggle', run=fake)
        self.assertEqual(gnome._parse_list(fake.values[(gnome.SCHEMA, 'custom-keybindings')]), [gnome.MARKED_PATH])

    def test_install_refuses_a_binding_someone_else_uses(self):
        with self.assertRaisesRegex(gnome.GnomeShortcutError, 'already used'):
            gnome.install('<Super>t', command='c toggle', run=self.fake)
        self.assertEqual(self.listed(), [self.OTHER])

    def test_remove_takes_only_ours(self):
        gnome.install(command='c toggle', run=self.fake)
        self.assertTrue(gnome.remove(run=self.fake))
        self.assertEqual(self.listed(), [self.OTHER])
        self.assertFalse(gnome.status(run=self.fake)['installed'])
        self.assertNotIn((gnome._entry(gnome.MARKED_PATH), 'binding'), self.fake.values)

    def test_remove_when_absent_is_a_no_op(self):
        self.assertFalse(gnome.remove(run=self.fake))
        self.assertEqual(self.listed(), [self.OTHER])
        self.assertFalse(any(call[0] != 'get' for call in self.fake.calls))

    def test_empty_binding_is_rejected(self):
        with self.assertRaises(gnome.GnomeShortcutError):
            gnome.install(' ', run=self.fake)

    def test_parse_list_forms(self):
        self.assertEqual(gnome._parse_list('@as []'), [])
        self.assertEqual(gnome._parse_list("['a', 'b']"), ['a', 'b'])
        with self.assertRaises(gnome.GnomeShortcutError):
            gnome._parse_list('nonsense(')

    def test_quote_escapes(self):
        self.assertEqual(gnome._quote("it's"), "'it\\'s'")

    def test_toggle_command_uses_the_launcher_when_given(self):
        self.assertEqual(gnome.toggle_command('/opt/ml'), '/opt/ml toggle')


@unittest.skipUnless(shutil.which('gsettings') and os.environ.get('MOUTHTYPE_GSETTINGS_KEYFILE') == '1',
                     'needs gsettings with the GNOME media-keys schemas and MOUTHTYPE_GSETTINGS_KEYFILE=1')
class KeyfileBackendTests(unittest.TestCase):
    """Real gsettings against a keyfile backend, asserting on the dconf-style keyfile it writes."""
    def test_roundtrip_in_keyfile(self):
        with tempfile.TemporaryDirectory() as home:
            env = {**os.environ, 'GSETTINGS_BACKEND': 'keyfile', 'XDG_CONFIG_HOME': home}
            original = os.environ.copy()
            os.environ.update(env)
            self.addCleanup(lambda: (os.environ.clear(), os.environ.update(original)))
            gnome.install('<Control><Alt>space', command='/bin/ml toggle')
            keyfile = os.path.join(home, 'glib-2.0', 'settings', 'keyfile')
            with open(keyfile) as handle:
                text = handle.read()
            self.assertIn('custom-keybindings=', text)
            self.assertIn('mouthtype-toggle', text)
            self.assertIn("command='/bin/ml toggle'", text)
            self.assertTrue(gnome.remove())
            with open(keyfile) as handle:
                text = handle.read()
            self.assertNotIn('/bin/ml toggle', text)
            self.assertFalse(gnome.status()['installed'])


if __name__ == '__main__':
    unittest.main()
