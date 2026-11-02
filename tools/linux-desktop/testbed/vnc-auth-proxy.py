#!/usr/bin/env python3
"""Password gate in front of wayvnc.

macOS Screen Sharing only authenticates against classic VNC password auth (RFB security type 2), which
wayvnc does not offer. This listens on the public port, runs that handshake against the password in
TESTBED_VNC_PASSWORD_FILE, then hands the connection to wayvnc on loopback, where it speaks no auth.
RFB passwords are truncated to eight characters, so the generated password is exactly eight.
"""
import asyncio, hmac, os, sys
from Crypto.Cipher import DES

LISTEN = ("0.0.0.0", int(os.environ.get("TESTBED_VNC_LISTEN_PORT", "5900")))
UPSTREAM = ("127.0.0.1", int(os.environ.get("TESTBED_WAYVNC_PORT", "5901")))
PASSWORD = open(os.environ["TESTBED_VNC_PASSWORD_FILE"]).read().strip().encode()[:8].ljust(8, b"\0")
# RFB uses DES with each key byte bit-reversed.
KEY = bytes(int(f"{b:08b}"[::-1], 2) for b in PASSWORD)
failures = {}


def expected(challenge):
    return DES.new(KEY, DES.MODE_ECB).encrypt(challenge)


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(reader, writer):
    peer = writer.get_extra_info("peername")[0]
    upstream = None
    try:
        if failures.get(peer, 0) >= 5:
            await asyncio.sleep(2)
            return
        writer.write(b"RFB 003.008\n")
        version = await reader.readexactly(12)
        if version[:4] != b"RFB ":
            return
        minor = int(version[8:11] or 3)
        if minor >= 7:
            writer.write(bytes([1, 2]))
            if (await reader.readexactly(1))[0] != 2:
                return
        else:
            writer.write((2).to_bytes(4, "big"))
        challenge = os.urandom(16)
        writer.write(challenge)
        reply = await reader.readexactly(16)
        if not hmac.compare_digest(reply, expected(challenge)):
            failures[peer] = failures.get(peer, 0) + 1
            await asyncio.sleep(1)
            writer.write((1).to_bytes(4, "big"))
            if minor >= 8:
                reason = b"Authentication failed"
                writer.write(len(reason).to_bytes(4, "big") + reason)
            return
        failures.pop(peer, None)
        up_reader, up_writer = upstream = await asyncio.open_connection(*UPSTREAM)
        await up_reader.readexactly(12)
        up_writer.write(b"RFB 003.008\n")
        count = (await up_reader.readexactly(1))[0]
        types = await up_reader.readexactly(count)
        if 1 not in types:
            return
        up_writer.write(bytes([1]))
        if await up_reader.readexactly(4) != bytes(4):
            return
        writer.write(bytes(4))
        await writer.drain()
        await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))
    except (asyncio.IncompleteReadError, ConnectionError, OSError):
        pass
    finally:
        writer.close()
        if upstream:
            upstream[1].close()


async def main():
    server = await asyncio.start_server(handle, *LISTEN)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
