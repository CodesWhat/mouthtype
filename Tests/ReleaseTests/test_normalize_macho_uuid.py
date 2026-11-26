import hashlib
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/normalize-macho-uuid.py'
LC_UUID, LC_CODE_SIGNATURE, LC_SEGMENT_64 = 0x1B, 0x1D, 0x19


def macho(uuid, payload=b'code', signature=None):
    """A minimal thin 64-bit Mach-O: header, optional LC_UUID, LC_CODE_SIGNATURE, then payload bytes."""
    commands = []
    if uuid is not None:
        commands.append(struct.pack('<II16s', LC_UUID, 24, uuid))
    body_start = 32 + sum(len(c) for c in commands) + (16 if signature is not None else 0)
    if signature is not None:
        commands.append(struct.pack('<IIII', LC_CODE_SIGNATURE, 16, body_start + len(payload), len(signature)))
    blob = b''.join(commands)
    header = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, len(commands), len(blob), 0, 0)
    return header + blob + payload + (signature or b'')


def uuid_of(data):
    offset = 32
    while True:
        cmd, size = struct.unpack_from('<II', data, offset)
        if cmd == LC_UUID:
            return data[offset + 8:offset + 24]
        offset += size


class NormalizeMachoUuidTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mouthtype-macho-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def normalize(self, *paths):
        return subprocess.run([sys.executable, '-I', str(SCRIPT), *map(str, paths)],
                              capture_output=True, text=True)

    def write(self, name, data):
        path = self.root / name
        path.write_bytes(data)
        return path

    def test_same_code_with_different_linker_uuids_converges(self):
        first = self.write('a', macho(b'\x01' * 16))
        second = self.write('b', macho(b'\x02' * 16))
        self.assertNotEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(self.normalize(first, second).returncode, 0)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertNotEqual(uuid_of(first.read_bytes()), b'\x01' * 16)

    def test_different_code_gets_a_different_uuid(self):
        first = self.write('a', macho(b'\x01' * 16, b'code one'))
        second = self.write('b', macho(b'\x01' * 16, b'code two'))
        self.normalize(first, second)
        self.assertNotEqual(uuid_of(first.read_bytes()), uuid_of(second.read_bytes()))

    def test_uuid_is_a_version_5_variant_hash_of_the_zeroed_file(self):
        path = self.write('a', macho(b'\x07' * 16))
        zeroed = macho(bytes(16))
        expected = bytearray(hashlib.sha256(zeroed).digest()[:16])
        expected[6] = (expected[6] & 0x0F) | 0x50
        expected[8] = (expected[8] & 0x3F) | 0x80
        self.normalize(path)
        self.assertEqual(uuid_of(path.read_bytes()), bytes(expected))

    def test_the_code_signature_bytes_do_not_change_the_uuid(self):
        first = self.write('first', macho(b'\x03' * 16, signature=b'SIGNATURE-ONE'))
        second = self.write('second', macho(b'\x03' * 16, signature=b'SIGNATURE-TWO'))
        self.normalize(first, second)
        self.assertEqual(uuid_of(first.read_bytes()), uuid_of(second.read_bytes()))
        self.assertTrue(first.read_bytes().endswith(b'SIGNATURE-ONE'))

    def test_normalizing_twice_is_stable(self):
        path = self.write('a', macho(b'\x04' * 16))
        self.normalize(path)
        once = path.read_bytes()
        self.normalize(path)
        self.assertEqual(path.read_bytes(), once)

    def test_non_macho_input_is_refused_and_left_untouched(self):
        path = self.write('text', b'#!/bin/sh\n' + bytes(64))
        result = self.normalize(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not a thin little-endian 64-bit Mach-O', result.stderr)
        self.assertEqual(path.read_bytes(), b'#!/bin/sh\n' + bytes(64))

    def test_macho_without_lc_uuid_is_refused_and_left_untouched(self):
        original = macho(None)
        path = self.write('nouuid', original)
        result = self.normalize(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no LC_UUID', result.stderr)
        self.assertEqual(path.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
