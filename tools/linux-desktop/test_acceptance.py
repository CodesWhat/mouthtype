import math
from pathlib import Path
import struct
import tempfile
import unittest
import wave

from acceptance import tone_metrics


class ToneTests(unittest.TestCase):
    def test_real_capture_comparison_requires_signal_not_just_a_wav_header(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'tone.wav'
            frames = [round(math.sin(2 * math.pi * 440 * n / 16000) * 3276) for n in range(8000)]
            with wave.open(str(path), 'wb') as output:
                output.setparams((1, 2, 16000, 0, 'NONE', ''))
                output.writeframes(struct.pack('<' + 'h' * len(frames), *frames))
            self.assertEqual(tone_metrics(path).get('frames'), 8000)
            self.assertAlmostEqual(tone_metrics(path)['frequency_hz'], 440, delta=3)
            self.assertGreater(tone_metrics(path)['rms'], .05)
            with wave.open(str(path), 'wb') as output:
                output.setparams((1, 2, 16000, 0, 'NONE', ''))
                output.writeframes(b'\0\0' * 8000)
            with self.assertRaises(ValueError):
                tone_metrics(path)

class DiagnosticTests(unittest.TestCase):
    def test_synthetic_failed_command_keeps_bounded_stderr_for_investigation(self):
        import contextlib
        import io
        import os
        import subprocess
        import sys
        from acceptance import run
        output = io.StringIO()
        with contextlib.redirect_stderr(output), self.assertRaises(subprocess.CalledProcessError):
            run([sys.executable, '-c', 'import sys;sys.stderr.write("synthetic helper failure");sys.exit(3)'], dict(os.environ))
        self.assertIn('synthetic helper failure', output.getvalue())

if __name__ == '__main__':
    unittest.main()
