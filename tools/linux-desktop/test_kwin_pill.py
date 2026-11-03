import json
import tempfile
from pathlib import Path
import unittest

import kwin_pill


def event(kind, at, **fields):
    base = {'kind': kind, 'at': at, 'layer': 9, 'skipTaskbar': True, 'x': 436, 'y': 688, 'width': 408, 'height': 100,
            'resourceClass': 'python3.14', 'caption': ''}
    return {**base, **fields}


class PillResultTests(unittest.TestCase):
    screen = (1280, 800)

    def test_accepts_a_bottom_centre_overlay_that_maps_during_the_hold_and_unmaps(self):
        events = [event('added', 5.0, layer=2, skipTaskbar=False, x=160, y=46, width=960, height=708),
                  event('added', 11.0), event('removed', 16.0)]
        result = kwin_pill.pill_result(events, 10.0, 12.5, self.screen)
        self.assertEqual(result['geometry'], [436, 688, 408, 100])
        self.assertTrue(result['unmapped_after'])

    def test_a_normal_window_is_not_the_pill(self):
        events = [event('added', 11.0, layer=2, skipTaskbar=False)]
        with self.assertRaises(ValueError):
            kwin_pill.pill_result(events, 10.0, 12.5, self.screen)

    def test_rejects_a_pill_that_mapped_outside_the_hold(self):
        with self.assertRaises(ValueError):
            kwin_pill.pill_result([event('added', 9.0)], 10.0, 12.5, self.screen)
        with self.assertRaises(ValueError):
            kwin_pill.pill_result([event('added', 13.0)], 10.0, 12.5, self.screen)

    def test_rejects_a_pill_off_centre_or_off_the_bottom_edge(self):
        with self.assertRaises(ValueError):
            kwin_pill.pill_result([event('added', 11.0, x=0)], 10.0, 12.5, self.screen)
        with self.assertRaises(ValueError):
            kwin_pill.pill_result([event('added', 11.0, y=100)], 10.0, 12.5, self.screen)

    def test_reports_a_pill_that_never_unmapped(self):
        result = kwin_pill.pill_result([event('added', 11.0)], 10.0, 12.5, self.screen)
        self.assertFalse(result['unmapped_after'])


class WatcherTests(unittest.TestCase):
    def test_receive_stamps_events_and_ignores_garbage(self):
        watcher = kwin_pill.KwinWatcher(Path('.'), lambda argv: '', clock=lambda: 42.0)
        watcher._receive(json.dumps({'kind': 'added', 'layer': 9}))
        watcher._receive('not json')
        self.assertEqual(watcher.snapshot(), [{'kind': 'added', 'layer': 9, 'at': 42.0}])

    def test_stop_unloads_only_a_loaded_script(self):
        calls = []
        watcher = kwin_pill.KwinWatcher(Path('.'), calls.append)
        watcher.stop()
        self.assertEqual(calls, [])
        watcher._loaded = True
        watcher.stop()
        self.assertIn('org.kde.kwin.Scripting.unloadScript', calls[0])
        self.assertIn(kwin_pill.SCRIPT_NAME, calls[0])

    def test_the_script_reports_to_the_owned_bus_name(self):
        self.assertIn(kwin_pill.BUS_NAME, kwin_pill.SCRIPT)
        self.assertIn('windowAdded', kwin_pill.SCRIPT)


if __name__ == '__main__':
    unittest.main()
