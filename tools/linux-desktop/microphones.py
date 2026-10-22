"""PipeWire microphone lookup and a short level test. Reads pw-dump and wpctl only; opens capture only for level_test."""

import array
import json
import math
import re
import subprocess
import tempfile
import time
import wave
from pathlib import Path


def _run(argv, run):
    result = run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5, check=False)
    if result.returncode:
        raise OSError(argv[0] + ' exited with status ' + str(result.returncode))
    return result.stdout


def list_sources(run=subprocess.run):
    """Audio/Source nodes as [{name, description, default}], default first-class. Raises OSError when PipeWire can't be asked."""
    try:
        dump = json.loads(_run(['pw-dump'], run))
    except (subprocess.SubprocessError, ValueError) as error:
        raise OSError('pw-dump failed: ' + type(error).__name__) from error
    default = None
    try:
        match = re.search(r'node\.name = "([^"]*)"', _run(['wpctl', 'inspect', '@DEFAULT_AUDIO_SOURCE@'], run))
        default = match.group(1) if match else None
    except (OSError, subprocess.SubprocessError):
        pass
    sources = []
    for item in dump if isinstance(dump, list) else []:
        props = (item.get('info') or {}).get('props') or {} if isinstance(item, dict) else {}
        if props.get('media.class') == 'Audio/Source' and isinstance(props.get('node.name'), str):
            name = props['node.name']
            sources.append(dict(name=name, description=str(props.get('node.description') or name), default=name == default))
    return sources


def default_muted(run=subprocess.run):
    """True when the default source is muted, None when that can't be read."""
    try:
        return '[MUTED]' in _run(['wpctl', 'get-volume', '@DEFAULT_AUDIO_SOURCE@'], run)
    except (OSError, subprocess.SubprocessError):
        return None


def target_present(target, run=subprocess.run):
    """True or False when PipeWire answers, None when it can't be asked (the target is then left alone)."""
    try:
        return any(item['name'] == target for item in list_sources(run))
    except OSError:
        return None


def measure(path):
    """Peak and RMS of a 16-bit mono WAV as fractions of full scale."""
    with wave.open(str(path), 'rb') as audio:
        if audio.getsampwidth() != 2:
            raise ValueError('Expected 16-bit audio')
        samples = array.array('h')
        samples.frombytes(audio.readframes(audio.getnframes()))
        rate = audio.getframerate() * audio.getnchannels()
    if not samples:
        raise ValueError('The test recording was empty')
    peak = max(max(samples), -min(samples)) / 32768
    rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples)) / 32768
    return dict(peak=round(min(peak, 1.0), 4), rms=round(rms, 4), seconds=round(len(samples) / rate, 2))


def level_test(capture, seconds=2, sleep=time.sleep):
    """Record `seconds` through `capture` (a PipeWireCapture) into a private temp file, measure it, delete it."""
    with tempfile.TemporaryDirectory(prefix='mouthtype-mic-') as directory:
        path = Path(directory) / 'test.wav'
        capture.start(path)
        try:
            sleep(seconds)
            if not capture.running():
                raise ValueError('The microphone stopped before the test finished')
            capture.stop()
        except BaseException:
            capture.cancel()
            raise
        return measure(path)
