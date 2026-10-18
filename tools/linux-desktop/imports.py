"""Bounded audio file transcription for the Linux client: decode, recognize, keep the raw result."""

import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
import uuid
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'linux-engine-proof'))
from proof import Stopped

MAXIMUM_SECONDS = 600
MAXIMUM_FRAMES = 16000 * MAXIMUM_SECONDS
MAXIMUM_SOURCE_BYTES = 512 * 1024 * 1024
FORMATS = ('wav', 'aiff', 'm4a')
# The chooser offers these extensions; the container is still identified by content.
EXTENSIONS = ('wav', 'aiff', 'aif', 'm4a')
ACTIVE = ('preparing', 'transcribing', 'cancelling')


class FileError(Exception):
    """A refusal with a coarse, text-free code that clients can show."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _stop(process):
    if process is None:
        return
    process.poll()
    for action, limit in ((signal.SIGTERM, 1.5), (signal.SIGKILL, .5)):
        try:
            os.killpg(process.pid, action)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            continue
        if action == signal.SIGKILL:
            break
    process.wait(timeout=.5)


def probe_command(source, command=None):
    return list(command or ['ffprobe']) + ['-v', 'error', '-print_format', 'json', '-show_format',
                                            '-show_streams', str(source)]


def decode_command(source, destination, command=None):
    return list(command or ['ffmpeg']) + ['-nostdin', '-hide_banner', '-loglevel', 'error', '-i', str(source),
                                           '-vn', '-map', '0:a:0', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le',
                                           '-t', str(MAXIMUM_SECONDS + 1), '-bitexact', '-f', 'wav', '-y', str(destination)]


def probe(source, *, command=None, seconds=20):
    """Identify the container and duration without decoding. Raises FileError."""
    try:
        result = subprocess.run(probe_command(source, command), stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=seconds,
                                check=False, start_new_session=True)
    except FileNotFoundError:
        raise FileError('decoder_unavailable') from None
    except subprocess.SubprocessError:
        raise FileError('invalid_audio') from None
    if result.returncode != 0 or len(result.stdout) > 1024 * 1024:
        raise FileError('invalid_audio')
    try:
        report = json.loads(result.stdout)
        names = str(report['format']['format_name']).split(',')
        streams = [item for item in report.get('streams', []) if item.get('codec_type') == 'audio']
    except (ValueError, KeyError, TypeError):
        raise FileError('invalid_audio') from None
    if 'wav' in names:
        kind = 'wav'
    elif 'aiff' in names:
        kind = 'aiff'
    elif 'm4a' in names or 'mp4' in names:
        kind = 'm4a'
    else:
        raise FileError('unsupported_format')
    if not streams:
        raise FileError('invalid_audio')
    try:
        duration = float(report['format'].get('duration') or streams[0].get('duration') or 0)
    except (TypeError, ValueError):
        raise FileError('invalid_audio') from None
    if not math.isfinite(duration) or duration < 0:
        raise FileError('invalid_audio')
    if duration == 0:
        raise FileError('empty')
    if duration > MAXIMUM_SECONDS + 1:
        raise FileError('too_long')
    return {'format': kind, 'duration': duration}


def decode(source, destination, cancelled, *, command=None, seconds=120):
    """Decode into a new private 16 kHz mono PCM16 WAV. Raises FileError or Stopped."""
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(fd)
    try:
        process = subprocess.Popen(decode_command(source, destination, command), stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except FileNotFoundError:
        raise FileError('decoder_unavailable') from None
    end = time.monotonic() + seconds
    try:
        while process.poll() is None:
            if cancelled.is_set():
                raise Stopped('cancelled')
            if time.monotonic() >= end:
                raise Stopped('deadline')
            try:
                process.wait(timeout=.02)
            except subprocess.TimeoutExpired:
                pass
        if process.returncode != 0:
            raise FileError('invalid_audio')
    finally:
        _stop(process)
    return inspect_wav(destination)


def inspect_wav(path):
    """Return the frame count of a decoded 16 kHz mono PCM16 WAV within limits. Raises FileError."""
    try:
        with wave.open(str(path), 'rb') as audio:
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, 16000, 'NONE'):
                raise FileError('invalid_audio')
            frames = audio.getnframes()
            if frames == 0:
                raise FileError('empty')
            if frames > MAXIMUM_FRAMES:
                raise FileError('too_long')
            if len(audio.readframes(frames)) != frames * 2:
                raise FileError('invalid_audio')
    except (wave.Error, EOFError, OSError):
        raise FileError('invalid_audio') from None
    return frames


def job_directories(root):
    root = Path(root)
    if not root.is_dir():
        return []
    return sorted((path for path in root.iterdir()
                   if re.fullmatch('[0-9a-f]{32}', path.name) and path.is_dir() and not path.is_symlink()),
                  key=lambda path: path.stat().st_mtime, reverse=True)


def remove_job(job):
    for name in ('decoded.wav', 'transcript.txt', 'source.json'):
        (job / name).unlink(missing_ok=True)
    try:
        job.rmdir()
    except OSError:
        pass


def _private_write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            output.write(data)
    except BaseException:
        path.unlink(missing_ok=True)
        raise


class FileTranscription:
    """One bounded file job at a time, separate from dictation history."""

    def __init__(self, engine, root, *, prober=None, decoder=None, request_seconds=30, decode_seconds=120):
        self.engine = engine
        self.root = Path(root)
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.root.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('Import directory must be private and owned by you')
        self.probe = prober or probe
        self.decoder = decoder or decode
        self.request_seconds, self.decode_seconds = request_seconds, decode_seconds
        self.lock = threading.RLock()
        self.state, self.error = 'idle', None
        self.job, self.thread = None, None
        # The last finished result stays on disk until its replacement is decoded and ready to transcribe.
        self.previous = None
        self.cancelled = threading.Event()
        self.duration, self.format = None, None
        self.closed = False
        for job in job_directories(self.root):
            if (job / 'transcript.txt').is_file() and self.job is None:
                self.job, self.state = job, 'finished'
                try:
                    self.duration = json.loads((job / 'source.json').read_text(encoding='utf-8')).get('duration')
                except (OSError, ValueError, AttributeError):
                    self.duration = None
            else:
                # An interrupted job never becomes a result; its decoded audio is not kept.
                remove_job(job)

    def status(self):
        retained = self.previous is not None and (self.previous / 'transcript.txt').is_file()
        return {'state': self.state, 'error': self.error, 'id': self.job.name if self.job else None,
                'retained_id': self.previous.name if retained else None,
                'duration_seconds': self.duration, 'format': self.format,
                'maximum_seconds': MAXIMUM_SECONDS, 'maximum_bytes': MAXIMUM_SOURCE_BYTES}

    def active(self):
        return self.state in ACTIVE

    def _refused(self, code):
        return {**self.status(), 'accepted': False, 'error': code}

    def start(self, source, *, session_busy=False):
        with self.lock:
            if self.closed:
                raise ValueError('Import is closed')
            if self.active():
                return self._refused('busy')
            if session_busy:
                return self._refused('session_active')
            if not isinstance(source, str) or not source or '\0' in source:
                return self._refused('invalid_audio')
            try:
                path = Path(source).expanduser().resolve(strict=True)
                info = path.stat()
            except (OSError, RuntimeError):
                return self._refused('invalid_audio')
            if not stat.S_ISREG(info.st_mode):
                return self._refused('unsupported_format')
            if info.st_size > MAXIMUM_SOURCE_BYTES:
                return self._refused('too_large')
            if info.st_size == 0:
                return self._refused('empty')
            if self.job is not None:
                if (self.job / 'transcript.txt').is_file():
                    if self.previous is not None:
                        remove_job(self.previous)
                    self.previous = self.job
                else:
                    remove_job(self.job)
            self.job = self.root / uuid.uuid4().hex
            self.job.mkdir(mode=0o700)
            _private_write(self.job / 'source.json', json.dumps({'source': str(path), 'bytes': info.st_size}))
            self.cancelled = threading.Event()
            self.state, self.error = 'preparing', None
            self.duration, self.format = None, None
            self.thread = threading.Thread(target=self._run, args=(self.job, path, self.cancelled))
            self.thread.start()
            return {**self.status(), 'accepted': True}

    def _run(self, job, source, cancelled):
        decoded = job / 'decoded.wav'
        try:
            info = self.probe(source)
            with self.lock:
                if cancelled.is_set() or self.closed:
                    return
                self.format = info['format']
            frames = self.decoder(source, decoded, cancelled, seconds=self.decode_seconds)
            duration = frames / 16000
            with self.lock:
                if cancelled.is_set() or self.closed:
                    return
                self.duration, self.state = duration, 'transcribing'
                if self.previous is not None:
                    remove_job(self.previous)
                    self.previous = None
            text = self.engine.transcribe(decoded, cancelled, seconds=max(self.request_seconds, 60 + duration))
            if not isinstance(text, str):
                raise ValueError('Invalid transcript')
            with self.lock:
                if cancelled.is_set() or self.closed:
                    return
                _private_write(job / 'transcript.txt', text)
                record = json.loads((job / 'source.json').read_text(encoding='utf-8'))
                record['duration'] = duration
                (job / 'source.json').write_text(json.dumps(record), encoding='utf-8')
                self.state = 'finished' if text.strip() else 'empty'
        except FileError as error:
            self._fail(cancelled, error.code)
        except Stopped as error:
            self._fail(cancelled, 'decoder_timeout' if str(error) == 'deadline' else 'cancelled')
        except (OSError, ValueError, RuntimeError, KeyError, TypeError, subprocess.SubprocessError):
            self._fail(cancelled, 'transcription_failed')
        finally:
            decoded.unlink(missing_ok=True)
            with self.lock:
                if cancelled.is_set() and self.cancelled is cancelled:
                    self.state, self.error = 'cancelled', None

    def _fail(self, cancelled, code):
        with self.lock:
            if not cancelled.is_set() and not self.closed:
                self.state, self.error = 'failed', code

    def cancel(self):
        with self.lock:
            if self.active():
                self.cancelled.set()
                self.state = 'cancelling' if self.thread and self.thread.is_alive() else 'cancelled'
            return self.status()

    def forget(self):
        with self.lock:
            if self.active():
                return self._refused('busy')
            for job in (self.job, self.previous):
                if job is not None:
                    remove_job(job)
            self.job, self.previous, self.state, self.error = None, None, 'idle', None
            self.duration, self.format = None, None
            return self.status()

    def wait(self, seconds=5):
        if self.thread:
            self.thread.join(seconds)
            if self.thread.is_alive():
                raise TimeoutError('File transcription did not stop')

    def close(self):
        with self.lock:
            self.closed = True
            if self.active():
                self.cancelled.set()
        self.wait(5)


def latest_result(root):
    """The newest completed job directory, or None. Never starts work."""
    for job in job_directories(root):
        if (job / 'transcript.txt').is_file():
            return job
    return None


def result_text(root):
    job = latest_result(root)
    if job is None:
        raise FileError('no_result')
    return (job / 'transcript.txt').read_bytes().decode('utf-8')


def save_text(root, destination, *, overwrite=False):
    """Write the raw result as UTF-8 to a path that is not the original audio file."""
    job = latest_result(root)
    if job is None:
        raise FileError('no_result')
    text = (job / 'transcript.txt').read_bytes().decode('utf-8')
    source = Path(json.loads((job / 'source.json').read_text(encoding='utf-8'))['source'])
    target = Path(destination).expanduser()
    if not str(target) or '\0' in str(target):
        raise FileError('invalid_destination')
    resolved = target.resolve()
    if resolved == source.resolve() or (target.exists() and source.exists() and os.path.samefile(target, source)):
        raise FileError('cannot_replace_source')
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise FileError('invalid_destination')
    if target.exists() and not overwrite:
        raise FileError('destination_exists')
    flags = os.O_WRONLY | os.O_CREAT | (os.O_TRUNC if overwrite else os.O_EXCL)
    try:
        fd = os.open(target, flags | os.O_NOFOLLOW, 0o644)
    except FileExistsError:
        raise FileError('destination_exists') from None
    with os.fdopen(fd, 'w', encoding='utf-8') as output:
        output.write(text)
    return resolved


def forget_result(root):
    job = latest_result(root)
    if job is not None:
        remove_job(job)
    return job is not None


def decoder_available(which=None):
    which = which or shutil.which
    return all(which(name) for name in ('ffprobe', 'ffmpeg'))
