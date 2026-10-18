import pathlib
import plistlib
import unittest

PLIST = pathlib.Path(__file__).resolve().parents[2] / 'packaging/Info.plist'


class InfoPlistTests(unittest.TestCase):
    def test_update_checks_are_preset_so_sparkle_never_shows_its_permission_prompt(self):
        info = plistlib.loads(PLIST.read_bytes())
        self.assertIs(info.get('SUEnableAutomaticChecks'), True)
        self.assertIs(info.get('SUAllowsAutomaticUpdates'), False)
        self.assertIs(info.get('SUEnableSystemProfiling'), False)


if __name__ == '__main__':
    unittest.main()
