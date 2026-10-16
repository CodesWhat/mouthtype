"""Private JSONL worker, launched and bounded by proof.py."""

from array import array
import http.client
import importlib.metadata
import json
from pathlib import Path
import resource
import re
import signal
import socket
import subprocess
import sys
import time
import wave
import uuid


PINS = json.loads(Path(__file__).with_name("pins.json").read_text())
SYSTEM = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
CONTROLS = "[Styling: semi-formal] [Structure: lists] [Context: general]"


def read_wav(path):
    with wave.open(str(path), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getcomptype()) != (1, 2, 16000, "NONE"):
            raise ValueError("Expected 16 kHz mono uncompressed PCM16 WAV")
        if source.getnframes() > 16000 * 600:
            raise ValueError("Fixture exceeds ten minutes")
        raw = source.readframes(source.getnframes())
        if len(raw) != source.getnframes() * 2:
            raise ValueError("Truncated WAV fixture")
    samples = array("h")
    samples.frombytes(raw)
    if sys.byteorder != "little":
        samples.byteswap()
    return [sample / 32768 for sample in samples]


def speech_engine(config):
    version = importlib.metadata.version("sherpa-onnx")
    if version != PINS["sherpa"]["version"]:
        raise ValueError("Unexpected sherpa-onnx revision")
    import sherpa_onnx
    paths = {name: item["path"] for name, item in config["artifacts"].items()}
    recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=paths["encoder"], decoder=paths["decoder"], joiner=paths["joiner"],
        tokens=paths["vocabulary"], num_threads=config.get("threads", 2),
        sample_rate=16000, provider="cpu", model_type="nemo_transducer",
        decoding_method="greedy_search")

    def infer(case):
        stream = recognizer.create_stream()
        stream.accept_waveform(16000, read_wav(case["wav"]))
        recognizer.decode_stream(stream)
        return stream.result.text

    return infer, {"runtime": "sherpa-onnx " + version, "revision": PINS["sherpa"]["revision"]}


def server_command(config, port, alias="mouthtype-proof"):
    return [config["server"], "--model", config["artifacts"]["model"]["path"],
            "--host", "127.0.0.1", "--port", str(port), "--n-gpu-layers", "0",
            "--threads", str(config.get("threads", 2)), "--ctx-size", "8192",
            "--parallel", "1", "--jinja", "--chat-template-kwargs", '{"enable_thinking":false}',
            "--temp", "0", "--alias", alias, "--no-webui"]


def cleanup_payload(text):
    return {"messages": [{"role": "system", "content": SYSTEM},
                         {"role": "user", "content": CONTROLS + "\n" + text}],
            "temperature": 0, "seed": 0, "stream": False,
            "chat_template_kwargs": {"enable_thinking": False}}


def http_json(port, path, payload=None, timeout=1):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        body = json.dumps(payload).encode() if payload is not None else None
        connection.request("POST" if payload is not None else "GET", path, body,
                           {"Content-Type": "application/json"})
        response = connection.getresponse()
        raw = response.read(2 * 1024 * 1024 + 1)
        if response.status != 200 or len(raw) > 2 * 1024 * 1024:
            raise ValueError("Unexpected local engine HTTP response")
        return json.loads(raw)
    finally:
        connection.close()


def stop_server(server):
    if server.poll() is None:
        server.terminate()
    try:
        server.wait(timeout=.25)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait(timeout=.25)


def cleanup_engine(config):
    version = subprocess.run([config["server"], "--version"], capture_output=True,
                             timeout=5, check=True, text=True)
    description = version.stdout + version.stderr
    if not any(PINS["llama"]["revision"].startswith(revision)
               for revision in re.findall(r"\b[0-9a-f]{7,40}\b", description)):
        raise ValueError("Unexpected llama.cpp revision")
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    alias = "mouthtype-proof-" + uuid.uuid4().hex
    server = subprocess.Popen(server_command(config, port, alias), stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    try:
        end = time.monotonic() + 120
        while True:
            if server.poll() is not None:
                raise ValueError("Local llama-server exited during startup")
            try:
                healthy = http_json(port, "/health").get("status") == "ok"
            except (OSError, ValueError, http.client.HTTPException):
                healthy = False
            if healthy and server.poll() is None:
                models = http_json(port, "/v1/models").get("data", [])
                if not any(model.get("id") == alias for model in models):
                    raise ValueError("Local engine identity mismatch")
                break
            if time.monotonic() >= end:
                raise TimeoutError("Local llama-server startup deadline")
            time.sleep(.05)
    except BaseException:
        stop_server(server)
        raise

    def infer(case):
        if server.poll() is not None:
            raise ValueError("Local llama-server exited")
        payload = cleanup_payload(case["input"])
        payload["model"] = alias
        result = http_json(port, "/v1/chat/completions", payload, timeout=600)
        choice = result["choices"][0]
        text = choice["message"].get("content")
        if choice.get("finish_reason") != "stop" or not isinstance(text, str):
            raise ValueError("Incomplete cleanup result")
        if choice["message"].get("reasoning_content") or "<think>" in text:
            raise ValueError("Unexpected thinking output")
        return text

    metadata = {"runtime": description.strip(), "revision": PINS["llama"]["revision"], "server_pid": server.pid}
    return infer, metadata, server


def memory_record(server):
    own = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    own = own if sys.platform == "darwin" else own * 1024
    server_peak = None
    if server and sys.platform == "linux":
        try:
            for line in Path(f"/proc/{server.pid}/status").read_text().splitlines():
                if line.startswith("VmHWM:"):
                    server_peak = int(line.split()[1]) * 1024
        except (OSError, ValueError):
            pass
    combined = own if server is None else own + server_peak if server_peak is not None else None
    return {"peak_rss_bytes": combined, "worker_peak_rss_bytes": own, "server_peak_rss_bytes": server_peak}


def main():
    server = None

    def terminate(*_):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, terminate)
    try:
        config = json.loads(sys.stdin.readline())["configuration"]
        started = time.monotonic()
        if sys.argv[1] == "speech":
            infer, metadata = speech_engine(config)
        else:
            infer, metadata, server = cleanup_engine(config)
        print(json.dumps({"event": "ready", "load_ms": (time.monotonic() - started) * 1000, **metadata}), flush=True)
        for line in sys.stdin:
            case = json.loads(line)
            text = infer(case)
            print(json.dumps({"id": case["id"], "text": text, **memory_record(server)}), flush=True)
        return 0
    except Exception as error:
        print(json.dumps({"event": "error", "error_class": type(error).__name__}), flush=True)
        return 1
    finally:
        if server:
            stop_server(server)


if __name__ == "__main__":
    sys.exit(main())
