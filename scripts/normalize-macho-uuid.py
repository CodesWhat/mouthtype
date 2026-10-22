#!/usr/bin/env python3
"""Rewrite LC_UUID in thin 64-bit Mach-O files to a hash of the file's own contents.

ld's UUID depends on input paths, so the same code linked from two checkout paths differs only by
UUID. The new UUID is the SHA-256 of the file with the UUID zeroed and any code signature dropped,
so it is stable for identical content. The caller re-signs afterwards.

    normalize-macho-uuid.py FILE...
"""
import hashlib
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_UUID = 0x1B
LC_CODE_SIGNATURE = 0x1D


def normalize(path: str) -> None:
    with open(path, "rb") as fh:
        data = bytearray(fh.read())
    magic, _cpu, _sub, _ftype, ncmds, _size, _flags, _res = struct.unpack_from("<8I", data, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit(f"{path}: not a thin little-endian 64-bit Mach-O")
    offset, uuid_at, sig_at = 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == LC_UUID:
            uuid_at = offset + 8
        elif cmd == LC_CODE_SIGNATURE:
            sig_at = struct.unpack_from("<I", data, offset + 8)[0]
        offset += size
    if uuid_at is None:
        raise SystemExit(f"{path}: no LC_UUID")
    data[uuid_at : uuid_at + 16] = bytes(16)
    body = bytes(data[:sig_at]) if sig_at is not None else bytes(data)
    digest = bytearray(hashlib.sha256(body).digest()[:16])
    digest[6] = (digest[6] & 0x0F) | 0x50  # RFC 4122 version 5 style bits
    digest[8] = (digest[8] & 0x3F) | 0x80
    data[uuid_at : uuid_at + 16] = digest
    with open(path, "wb") as fh:
        fh.write(data)


for target in sys.argv[1:]:
    normalize(target)
