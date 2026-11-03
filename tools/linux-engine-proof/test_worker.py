import hashlib
import json
import os
import sys
import signal
import subprocess
import time
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch, Mock
import wave

import worker
import proof


SERVER = r'''#!/usr/bin/env python3
import http.server,json,os,pathlib,sys,time
if "--version" in sys.argv:
 print("fake llama 27c7a76");sys.exit(0)
port=int(sys.argv[sys.argv.index("--port")+1])
alias=sys.argv[sys.argv.index("--alias")+1] if "--alias" in sys.argv else "unidentified"
pathlib.Path(__file__).with_suffix(".pid.json").write_text(json.dumps({"server":os.getpid(),"worker":os.getppid()}))
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  self.send_response(200);self.end_headers();self.wfile.write(json.dumps({"data":[{"id":alias}]} if self.path=="/v1/models" else {"status":"ok"}).encode())
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers["Content-Length"])))
  pathlib.Path(__file__).with_suffix(".request.json").write_text(json.dumps(body))
  text=body["messages"][1]["content"].split("\n",1)[1]
  if text=="hold": time.sleep(30)
  result={"choices":[{"message":{"content":"" if text=="um" else text},"finish_reason":"stop"}]}
  self.send_response(200);self.end_headers();self.wfile.write(json.dumps(result).encode())
http.server.HTTPServer(("127.0.0.1",port),Handler).serve_forever()
'''


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def wav(self, *, rate=16000, channels=1, width=2):
        path = self.root / "speech.wav"
        with wave.open(str(path), "wb") as out:
            out.setnchannels(channels)
            out.setsampwidth(width)
            out.setframerate(rate)
            out.writeframes(b"\0\0\0\x40\0\xc0" if channels == 1 and width == 2 else b"\0" * channels * width * 3)
        return path

    def test_wav_is_normalized_and_invalid_audio_is_rejected_without_resampling(self):
        audio = worker.read_wav(self.wav())
        self.assertEqual(audio, [0.0, .5, -.5])
        for kwargs in ({"rate": 44100}, {"channels": 2}, {"width": 1}):
            with self.subTest(kwargs=kwargs):
                with self.assertRaises(ValueError):
                    worker.read_wav(self.wav(**kwargs))

    def test_sherpa_loads_once_with_cpu_nemo_settings_and_no_fabricated_confidence(self):
        calls = []
        stream = types.SimpleNamespace(result=types.SimpleNamespace(text="Hello, Sean."),
                                       accept_waveform=lambda rate, samples: calls.append((rate, samples)))
        recognizer = types.SimpleNamespace(create_stream=lambda: stream,
                                          decode_stream=lambda value: None)
        fake = types.SimpleNamespace(OfflineRecognizer=types.SimpleNamespace(
            from_transducer=lambda **kw: calls.append(kw) or recognizer))
        config = {"threads": 2, "artifacts": {name: {"path": name} for name in ("encoder", "decoder", "joiner", "vocabulary")}}
        with patch.dict("sys.modules", {"sherpa_onnx": fake}), patch("importlib.metadata.version", return_value="1.13.8"):
            infer, metadata = worker.speech_engine(config)
            self.assertTrue(callable(infer))
            self.assertEqual(infer({"wav": str(self.wav())}), "Hello, Sean.")
            self.assertEqual(infer({"wav": str(self.wav())}), "Hello, Sean.")
        self.assertEqual(sum(isinstance(c, dict) for c in calls), 1)
        self.assertEqual(calls[0]["provider"], "cpu")
        self.assertEqual(calls[0]["model_type"], "nemo_transducer")
        self.assertEqual(metadata["runtime"], "sherpa-onnx 1.13.8")
        self.assertNotIn("confidence", metadata)

    def test_sherpa_wrong_runtime_revision_is_rejected(self):
        with patch("importlib.metadata.version", return_value="0.0.1"):
            with self.assertRaises(ValueError):
                worker.speech_engine({})

    def test_s1_server_is_loopback_cpu_greedy_with_publisher_template_settings(self):
        command = worker.server_command({"server": "/local/llama-server", "threads": 2,
                                         "artifacts": {"model": {"path": "/local/s1.gguf"}}}, 12345)
        self.assertIn("--jinja", command)
        self.assertIn("--alias", command)
        self.assertEqual(command[command.index("--host") + 1], "127.0.0.1")
        self.assertEqual(command[command.index("--port") + 1], "12345")
        self.assertEqual(command[command.index("--n-gpu-layers") + 1], "0")
        self.assertEqual(command[command.index("--temp") + 1], "0")
        self.assertEqual(json.loads(command[command.index("--chat-template-kwargs") + 1]), {"enable_thinking": False})

    def test_managed_cleanup_worker_uses_real_http_and_reaps_its_loopback_server(self):
        server = self.root / "fake-server.py"
        server.write_text(SERVER)
        server.chmod(0o700)
        model = self.root / "model.gguf"
        model.write_bytes(b"test fixture")
        config = {"engines": {"cleanup": {"server": str(server), "threads": 1,
                  "artifacts": {name: {"path": str(path), "sha256": proof.digest(path)}
                                for name, path in (("model", model), ("server", server))}}}}
        result = proof.run_suite(config, {"cleanup": [
            {"id": "one", "input": "Send Sean’s mock-ups.", "expected": "Send Sean’s mock-ups."},
            {"id": "filler", "input": "um", "expected": ""}]}, startup_seconds=2, request_seconds=1)
        self.assertEqual([r["status"] for r in result["results"]], ["passed", "passed"])
        payload = json.loads(server.with_suffix(".request.json").read_text())
        self.assertEqual(payload["temperature"], 0)
        pid = result["engines"]["cleanup"]["server_pid"]
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_sigterm_of_cli_cancels_and_cleans_managed_server(self):
        server = self.root / "fake-server.py"
        server.write_text(SERVER)
        server.chmod(0o700)
        model = self.root / "model.gguf"
        model.write_bytes(b"fixture")
        config = {"engines": {"cleanup": {"server": str(server),
                  "artifacts": {name: {"path": str(path), "sha256": proof.digest(path)}
                                for name, path in (("model", model), ("server", server))}}}}
        config_path, cases_path, output = (self.root / name for name in ("config.json", "cases.json", "result.json"))
        config_path.write_text(json.dumps(config))
        cases_path.write_text(json.dumps([{"id": "cancel", "input": "hold", "expected": "hold"}]))
        process = subprocess.Popen([sys.executable, str(Path(proof.__file__)), "--config", str(config_path),
                                    "--cleanup", str(cases_path), "--output", str(output)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        receipt = server.with_suffix(".pid.json")
        try:
            end = time.monotonic() + 3
            while not receipt.exists() and time.monotonic() < end:
                time.sleep(.01)
            self.assertTrue(receipt.exists(), "managed fake server did not start")
            time.sleep(.1)
            process.terminate()
            self.assertEqual(process.wait(timeout=3), 1)
            self.assertEqual(json.loads(output.read_text())["results"][0]["status"], "cancelled")
            with self.assertRaises(ProcessLookupError):
                os.kill(json.loads(receipt.read_text())["server"], 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1)
            if receipt.exists():
                try:
                    os.killpg(json.loads(receipt.read_text())["worker"], signal.SIGTERM)
                except ProcessLookupError:
                    pass

    def test_unrelated_healthy_loopback_server_is_never_used_for_cleanup(self):
        process = Mock(pid=1)
        process.poll.return_value = None
        version = types.SimpleNamespace(stdout="fake llama 27c7a76", stderr="")
        config = {"server": "server", "artifacts": {"model": {"path": "model"}}}
        def foreign(port, path, payload=None, timeout=1):
            return {"status": "ok"} if path == "/health" else {"data": [{"id": "foreign-server"}]}
        with patch("worker.subprocess.run", return_value=version), patch("worker.subprocess.Popen", return_value=process), patch("worker.http_json", side_effect=foreign):
            try:
                with self.assertRaisesRegex(ValueError, "identity"):
                    worker.cleanup_engine(config)
            finally:
                process.terminate()

    def test_cleanup_can_become_ready_after_120_seconds_with_larger_configured_budget(self):
        process = Mock(pid=1)
        process.poll.return_value = None
        version = types.SimpleNamespace(stdout="fake llama 27c7a76", stderr="")
        config = {"server": "server", "startup_seconds": 180, "artifacts": {"model": {"path": "model"}}}
        attempts = []
        def health(port, path, payload=None, timeout=1):
            if path == "/health":
                attempts.append(path)
                return {"status": "loading" if len(attempts) == 1 else "ok"}
            command = launched.call_args.args[0]
            return {"data": [{"id": command[command.index("--alias") + 1]}]}
        with patch("worker.subprocess.run", return_value=version), patch("worker.subprocess.Popen", return_value=process) as launched, patch("worker.http_json", side_effect=health), patch("worker.time.monotonic", side_effect=[0, 121]), patch("worker.time.sleep"):
            try:
                try:
                    infer, metadata, server = worker.cleanup_engine(config)
                except TimeoutError:
                    self.fail("Configured 180-second startup was rejected by the old 120-second cap")
                self.assertIs(server, process)
                self.assertTrue(callable(infer))
                self.assertEqual(len(attempts), 2)
                process.terminate.assert_not_called()
            finally:
                worker.stop_server(process)

    def test_cleanup_uses_smaller_configured_startup_budget_and_reaps_server(self):
        process = Mock(pid=1)
        process.poll.return_value = None
        version = types.SimpleNamespace(stdout="fake llama 27c7a76", stderr="")
        config = {"server": "server", "startup_seconds": .5, "artifacts": {"model": {"path": "model"}}}
        outcome = None
        with patch("worker.subprocess.run", return_value=version), patch("worker.subprocess.Popen", return_value=process), patch("worker.http_json", side_effect=[{"status": "loading"}, RuntimeError("continued past configured deadline")]), patch("worker.time.monotonic", side_effect=[0, .6]), patch("worker.time.sleep"):
            try:
                worker.cleanup_engine(config)
            except TimeoutError:
                outcome = "deadline"
            except RuntimeError:
                outcome = "past-deadline"
        self.assertEqual(outcome, "deadline")
        process.terminate.assert_called_once()
        process.wait.assert_called_once()

    def test_s1_payload_preserves_exact_prompt_control_settings_and_empty_text(self):
        payload = worker.cleanup_payload("um send Sean the mock-ups")
        self.assertEqual(payload.get("temperature"), 0)
        self.assertEqual(payload["messages"][0]["content"],
            "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.")
        self.assertEqual(payload["messages"][1]["content"],
            "[Styling: semi-formal] [Structure: lists] [Context: general]\num send Sean the mock-ups")
        self.assertTrue(worker.cleanup_payload("")["messages"][1]["content"].endswith("\n"))
        self.assertEqual(payload["chat_template_kwargs"], {"enable_thinking": False})


if __name__ == "__main__":
    unittest.main()
