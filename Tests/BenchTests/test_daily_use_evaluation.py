import importlib.util
import math
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("daily_use_evaluation", ROOT / "scripts/evaluate-mac-daily-use.py")
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class NoiseFixtureTests(unittest.TestCase):
    def test_seeded_noise_has_requested_measured_snr(self):
        samples = [round(4000 * math.sin(2 * math.pi * 440 * index / 16000)) for index in range(16000)]
        noisy, measured = evaluation.add_noise(samples, 20, 42)
        self.assertIsNotNone(measured["actual_snr_db"])
        self.assertAlmostEqual(measured["actual_snr_db"], 20, delta=0.02)
        self.assertEqual(measured["clipped_samples"], 0)
        self.assertEqual(len(noisy), len(samples))

    def test_seed_is_repeatable_and_reference_is_unchanged(self):
        samples = [1000, -2000, 1500, -3000] * 1000
        reference = samples.copy()
        first, _ = evaluation.add_noise(samples, 10, 41)
        again, _ = evaluation.add_noise(samples, 10, 41)
        other, _ = evaluation.add_noise(samples, 10, 42)
        self.assertEqual(first, again)
        self.assertNotEqual(first, other)
        self.assertEqual(samples, reference)

    def test_clipping_is_measured_instead_of_claiming_requested_snr(self):
        noisy, measured = evaluation.add_noise([32767] * 1600, 0, 42)
        self.assertGreater(measured["clipped_samples"], 0)
        self.assertTrue(all(-32768 <= sample <= 32767 for sample in noisy))
        self.assertNotEqual(measured["actual_snr_db"], measured["requested_snr_db"])

    def test_silence_empty_audio_and_nonfinite_snr_are_rejected(self):
        for samples, snr in [([], 10), ([0] * 10, 10), ([1] * 10, math.nan), ([1] * 10, math.inf)]:
            with self.subTest(snr=snr, samples=samples):
                with self.assertRaises(ValueError):
                    evaluation.add_noise(samples, snr, 42)
