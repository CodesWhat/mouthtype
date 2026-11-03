import importlib.util
import json
import struct
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
DESKTOP = HERE.parent / "linux-desktop"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


control = load("omarchy_control_for_mic", HERE / "control.py")
control_mic = load("omarchy_control_mic", HERE / "control_mic.py")

SOURCES = [dict(name="alsa_input.pci-builtin", description="Built-in", default=True),
           dict(name="alsa_input.usb-headset", description="USB Headset", default=False)]


class MicrophoneVerbTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.config = Path(directory.name) / "linux.json"
        self.write({"engine_config": "/x", "notifications": True})
        self.microphones = mock.Mock(list_sources=lambda: SOURCES, default_muted=lambda: False)
        patches = [
            mock.patch.object(control_mic, "CONFIG", self.config),
            mock.patch.object(control_mic, "DESKTOP_DIRS", (DESKTOP,)),
            mock.patch.object(control, "CONFIG", self.config),
            mock.patch.object(control, "DESKTOP", DESKTOP),
            mock.patch.object(control, "state", lambda: {"running": False, "state": "idle", "file_import": {}}),
            mock.patch.object(control, "module_commands", lambda: {"microphones": control_mic.microphones}),
            mock.patch.object(control_mic, "load_microphones", lambda: (self.microphones, DESKTOP)),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def write(self, data):
        self.config.write_text(json.dumps(data), encoding="utf-8")

    def stored(self):
        return json.loads(self.config.read_text(encoding="utf-8"))

    def test_microphones_lists_sources_and_selection(self):
        result = control_mic.microphones()
        self.assertEqual(result["sources"], SOURCES)
        self.assertEqual(result["selected"], "default")
        self.assertFalse(result["missing"])

    def test_configured_microphone_that_is_gone_is_reported(self):
        self.write({"engine_config": "/x", "capture_target": "unplugged"})
        result = control_mic.microphones()
        self.assertEqual(result["selected"], "default")
        self.assertTrue(result["missing"])

    def test_set_config_writes_a_connected_microphone(self):
        control.set_config("microphone", "alsa_input.usb-headset")
        self.assertEqual(self.stored()["capture_target"], "alsa_input.usb-headset")
        self.assertEqual(control.config_summary()["microphone"], "alsa_input.usb-headset")

    def test_set_config_default_removes_the_target(self):
        self.write({"engine_config": "/x", "notifications": True, "capture_target": "alsa_input.usb-headset"})
        control.set_config("microphone", "default")
        self.assertNotIn("capture_target", self.stored())
        self.assertEqual(control.config_summary()["microphone"], "default")

    def test_set_config_refuses_an_unknown_microphone(self):
        with self.assertRaisesRegex(RuntimeError, "not connected"):
            control.set_config("microphone", "nope")
        self.assertNotIn("capture_target", self.stored())

    def test_mic_test_uses_the_configured_target_and_returns_levels(self):
        self.write({"engine_config": "/x", "capture_target": "alsa_input.usb-headset"})
        made = []

        class Capture:
            def __init__(self, target):
                made.append(target)
        sys.path.insert(0, str(DESKTOP))
        self.microphones.level_test = lambda capture: {"peak": 0.4, "rms": 0.1, "seconds": 2.0}
        with mock.patch("desktop.PipeWireCapture", Capture):
            self.assertEqual(control_mic.mic_test(), {"peak": 0.4, "rms": 0.1, "seconds": 2.0})
        self.assertEqual(made, ["alsa_input.usb-headset"])

    def test_verbs_are_registered(self):
        self.assertEqual(set(control_mic.COMMANDS), {"microphones", "mic-test"})


if __name__ == "__main__":
    unittest.main()
