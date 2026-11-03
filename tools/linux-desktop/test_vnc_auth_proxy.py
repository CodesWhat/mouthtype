import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

PROXY = Path(__file__).resolve().parent / "testbed" / "vnc-auth-proxy.py"
COMPOSE = PROXY.with_name("compose.yaml")


def load_proxy(env):
    """Import the proxy fresh under env. It reads its settings at import time."""
    with tempfile.NamedTemporaryFile("w", suffix=".pw") as pw:
        pw.write("secret12")
        pw.flush()
        modules = {}
        try:
            import Crypto.Cipher  # noqa: F401
        except ImportError:
            crypto = types.ModuleType("Crypto")
            cipher = types.ModuleType("Crypto.Cipher")
            cipher.DES = types.SimpleNamespace(MODE_ECB=1, new=lambda *a, **k: None)
            crypto.Cipher = cipher
            modules = {"Crypto": crypto, "Crypto.Cipher": cipher}
        with mock.patch.dict(os.environ, {}, clear=False), mock.patch.dict(sys.modules, modules):
            for name in ("TESTBED_VNC_BIND", "TESTBED_VNC_LISTEN_PORT"):
                os.environ.pop(name, None)
            os.environ.update({"TESTBED_VNC_PASSWORD_FILE": pw.name, **env})
            spec = importlib.util.spec_from_file_location("vnc_auth_proxy_under_test", PROXY)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module


class BindTests(unittest.TestCase):
    def test_defaults_to_loopback(self):
        self.assertEqual(load_proxy({}).LISTEN, ("127.0.0.1", 5900))

    def test_env_overrides_bind_and_port(self):
        proxy = load_proxy({"TESTBED_VNC_BIND": "100.64.0.9", "TESTBED_VNC_LISTEN_PORT": "5999"})
        self.assertEqual(proxy.LISTEN, ("100.64.0.9", 5999))

    def test_compose_publishes_on_host_loopback_only(self):
        text = COMPOSE.read_text()
        self.assertIn('"127.0.0.1:${TESTBED_PORT:-20010}:5900"', text)
        self.assertIn("TESTBED_VNC_BIND: 0.0.0.0", text)


if __name__ == "__main__":
    unittest.main()
