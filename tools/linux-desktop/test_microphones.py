import json
import math
import struct
import subprocess
import tempfile
import unittest
import wave
from pathlib import Path

import microphones
from desktop import PipeWireCapture

# A trimmed pw-dump: two sources (one is the default), a sink, a sink monitor class and a non-node object.
PW_DUMP = json.dumps([
    {'id': 1, 'type': 'PipeWire:Interface:Core', 'info': {}},
    {'id': 40, 'type': 'PipeWire:Interface:Node', 'info': {'props': {
        'media.class': 'Audio/Sink', 'node.name': 'alsa_output.pci', 'node.description': 'Speakers'}}},
    {'id': 55, 'type': 'PipeWire:Interface:Node', 'info': {'props': {
        'media.class': 'Audio/Source', 'node.name': 'alsa_input.pci-builtin', 'node.description': 'Built-in Audio Analog Stereo'}}},
    {'id': 61, 'type': 'PipeWire:Interface:Node', 'info': {'props': {
        'media.class': 'Audio/Source', 'node.name': 'alsa_input.usb-headset', 'node.description': 'USB Headset Mono'}}},
])
INSPECT = 'id 55, type PipeWire:Interface:Node\n    media.class = "Audio/Source"\n  * node.name = "alsa_input.pci-builtin"\n'


def fake_run(dump=PW_DUMP, muted=False, wpctl_fails=False):
    def run(argv, **kwargs):
        if argv[0] == 'pw-dump':
            if dump is None:
                raise FileNotFoundError('pw-dump')
            return subprocess.CompletedProcess(argv, 0, dump, '')
        if wpctl_fails:
            return subprocess.CompletedProcess(argv, 1, '', 'no wireplumber')
        if argv[1] == 'inspect':
            return subprocess.CompletedProcess(argv, 0, INSPECT, '')
        return subprocess.CompletedProcess(argv, 0, 'Volume: 0.40' + (' [MUTED]' if muted else '') + '\n', '')
    return run


class SourceTests(unittest.TestCase):
    def test_lists_only_sources_and_marks_the_default(self):
        self.assertEqual(microphones.list_sources(fake_run()), [
            dict(name='alsa_input.pci-builtin', description='Built-in Audio Analog Stereo', default=True),
            dict(name='alsa_input.usb-headset', description='USB Headset Mono', default=False)])

    def test_unreadable_default_marks_none(self):
        self.assertFalse(any(item['default'] for item in microphones.list_sources(fake_run(wpctl_fails=True))))

    def test_pw_dump_failures_are_oserror(self):
        with self.assertRaises(OSError):
            microphones.list_sources(fake_run(dump=None))
        with self.assertRaises(OSError):
            microphones.list_sources(fake_run(dump='not json'))

    def test_muted_default(self):
        self.assertTrue(microphones.default_muted(fake_run(muted=True)))
        self.assertFalse(microphones.default_muted(fake_run()))
        self.assertIsNone(microphones.default_muted(fake_run(wpctl_fails=True)))

    def test_target_present_is_none_when_pipewire_cannot_be_asked(self):
        self.assertTrue(microphones.target_present('alsa_input.usb-headset', fake_run()))
        self.assertFalse(microphones.target_present('gone', fake_run()))
        self.assertIsNone(microphones.target_present('gone', fake_run(dump=None)))


class CaptureFallbackTests(unittest.TestCase):
    def argv(self, present):
        return PipeWireCapture('alsa_input.usb-headset', present=present).argv(Path('/t.wav'))

    def test_connected_target_is_passed(self):
        self.assertIn('--target=alsa_input.usb-headset', self.argv(lambda target: True))

    def test_missing_target_falls_back_to_default(self):
        self.assertFalse(any(item.startswith('--target') for item in self.argv(lambda target: False)))

    def test_unknown_state_keeps_the_target(self):
        self.assertIn('--target=alsa_input.usb-headset', self.argv(lambda target: None))

    def test_no_target_never_asks_pipewire(self):
        def boom(target):
            raise AssertionError('should not be asked')
        self.assertFalse(any(item.startswith('--target') for item in PipeWireCapture(present=boom).argv(Path('/t.wav'))))


class LevelTests(unittest.TestCase):
    def write(self, path, samples):
        with wave.open(str(path), 'wb') as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(struct.pack('<%dh' % len(samples), *samples))

    def test_measure_reports_peak_and_rms(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'a.wav'
            self.write(path, [16384, -16384] * 8000)
            result = microphones.measure(path)
        self.assertEqual(result, dict(peak=0.5, rms=0.5, seconds=1.0))

    def test_silence_is_zero(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'a.wav'
            self.write(path, [0] * 100)
            self.assertEqual(microphones.measure(path)['peak'], 0)

    def test_level_test_measures_then_deletes_the_recording(self):
        seen = []

        class Fake:
            def start(self, path):
                seen.append(path)
                tone = [int(10000 * math.sin(i / 5)) for i in range(32000)]
                LevelTests.write(None, path, tone)
            def running(self):
                return True
            def stop(self):
                pass
            def cancel(self):
                raise AssertionError('not cancelled on success')
        result = microphones.level_test(Fake(), sleep=lambda seconds: None)
        self.assertEqual(result['seconds'], 2.0)
        self.assertGreater(result['peak'], 0.29)
        self.assertFalse(seen[0].exists())

    def test_level_test_cancels_when_the_microphone_dies(self):
        cancelled = []

        class Dead:
            def start(self, path):
                pass
            def running(self):
                return False
            def cancel(self):
                cancelled.append(True)
        with self.assertRaises(ValueError):
            microphones.level_test(Dead(), sleep=lambda seconds: None)
        self.assertEqual(cancelled, [True])


if __name__ == '__main__':
    unittest.main()
