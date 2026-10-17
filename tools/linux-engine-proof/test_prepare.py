import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

import prepare
import proof


class PrepareTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.models = self.path / "speech"
        self.models.mkdir()
        self.archive = self.path / "models.tar.bz2"
        self.entries = {"encoder": "encoder.int8.onnx", "decoder": "decoder.int8.onnx",
                        "joiner": "joiner.int8.onnx", "vocabulary": "vocabulary.txt"}
        with tarfile.open(self.archive, "w:bz2") as out:
            for name in self.entries.values():
                data = name.encode()
                (self.models / name).write_bytes(data)
                info = tarfile.TarInfo("models/" + name)
                info.size = len(data)
                out.addfile(info, io.BytesIO(data))
        self.s1 = self.path / "s1.gguf"
        self.s1.write_bytes(b"model")
        self.server = self.path / "llama-server"
        self.server.write_bytes(b"executable")
        self.pins = {"parakeet": {"archive": "models.tar.bz2", "sha256": proof.digest(self.archive)},
                     "s1": {"sha256": proof.digest(self.s1)}, "llama": {}, "sherpa": {}}

    def test_preparation_verifies_published_assets_and_extracted_files_and_records_hashes(self):
        result = prepare.prepare_settings(self.archive, self.models, self.s1, self.server,
                                          pins=self.pins, speech_entries=self.entries)
        self.assertEqual(set(result.get("engines", {})), {"speech", "cleanup"})
        speech = result["engines"]["speech"]
        self.assertEqual(speech["artifacts"]["encoder"]["sha256"], proof.digest(self.models / "encoder.int8.onnx"))
        self.assertEqual(result["engines"]["cleanup"]["artifacts"]["model"]["sha256"], proof.digest(self.s1))
        self.assertEqual(result["engines"]["cleanup"]["artifacts"]["server"]["sha256"], proof.digest(self.server))

    def test_mutated_model_archive_and_extracted_files_are_rejected(self):
        for kind in ("archive", "extracted", "s1"):
            with self.subTest(kind=kind):
                target = {"archive": self.archive, "extracted": self.models / "encoder.int8.onnx", "s1": self.s1}[kind]
                original = target.read_bytes()
                target.write_bytes(b"different")
                try:
                    with self.assertRaisesRegex(ValueError, "SHA-256"):
                        prepare.prepare_settings(self.archive, self.models, self.s1, self.server,
                                                  pins=self.pins, speech_entries=self.entries)
                finally:
                    target.write_bytes(original)

    def test_cleanup_only_does_not_require_speech_artifacts(self):
        result = prepare.prepare_settings(None, None, self.s1, self.server, pins=self.pins)
        self.assertEqual(set(result.get("engines", {})), {"cleanup"})


if __name__ == "__main__":
    unittest.main()
