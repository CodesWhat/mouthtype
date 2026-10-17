import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

from build_sway import unpack_source


class SourceTests(unittest.TestCase):
    def fixture(self, name='sway-abc/meson.build'):
        memory = io.BytesIO()
        with tarfile.open(fileobj=memory, mode='w:gz') as archive:
            info = tarfile.TarInfo(name)
            info.size = 5
            archive.addfile(info, io.BytesIO(b'build'))
        data = memory.getvalue()
        return data, {'revision': 'abc', 'sha256': hashlib.sha256(data).hexdigest()}
    def test_verified_source_is_extracted_only_under_owned_destination(self):
        data, pin = self.fixture()
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'new'
            source = unpack_source(data, output, pin)
            self.assertEqual(source, output / 'sway-abc')
            self.assertEqual((source / 'meson.build').read_bytes(), b'build')
            with self.assertRaises(FileExistsError):
                unpack_source(data, output, pin)
    def test_wrong_digest_or_escaping_member_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            data, pin = self.fixture()
            with self.assertRaises(ValueError):
                unpack_source(data + b'changed', Path(temp) / 'wrong', pin)
            self.assertFalse((Path(temp) / 'wrong').exists())
            data, pin = self.fixture('../outside')
            with self.assertRaises(ValueError):
                unpack_source(data, Path(temp) / 'escape', pin)
            self.assertFalse((Path(temp) / 'outside').exists())

class PatchTests(unittest.TestCase):
    def test_exact_upstream_patch_digest_is_required(self):
        from build_sway import verify_patch
        data=b'verified upstream patch'
        pin={'sha256':hashlib.sha256(data).hexdigest()}
        self.assertEqual(verify_patch(data,pin),data)
        with self.assertRaises(ValueError):
            verify_patch(data+b'changed',pin)

if __name__ == '__main__':
    unittest.main()
