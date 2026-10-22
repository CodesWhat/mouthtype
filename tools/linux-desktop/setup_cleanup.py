"""Prepare pinned AI cleanup models for the Linux client: verified weights and a pinned llama-server build.

Explicit opt-in only. Nothing here starts the dictation service, loads a model into memory, or edits linux.json;
it prints the configuration lines to add. Every child process has a finite deadline.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import time

PROOF = Path(__file__).resolve().parents[1] / 'linux-engine-proof'
sys.path.insert(0, str(PROOF))
from proof import digest
from setup_progress import DownloadProgress, write_atomic

PINS = json.loads((PROOF / 'pins.json').read_text())
LEVELS = {
    'fast': {'pin': 's1', 'file': 's1-mini-q4_k_m.gguf', 'prompt': 's1'},
    'thorough': {'pin': 'qwen3_4b', 'file': 'qwen3-4b-instruct-2507-q4_k_m.gguf', 'prompt': 'shared'},
}
LLAMA_SOURCE = 'https://github.com/ggml-org/llama.cpp.git'


def bounded_run(command, seconds, *, poll=None, **kwargs):
    """Run a child with a finite deadline. `poll`, when given, is called about every half second while it runs."""
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True, **kwargs)
    deadline = time.monotonic() + seconds
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, seconds)
            try:
                return process.wait(timeout=min(0.5, remaining) if poll else remaining)
            except subprocess.TimeoutExpired:
                if poll and time.monotonic() < deadline:
                    poll()
                    continue
                raise
    except subprocess.TimeoutExpired:
        for action in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, action)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
                break
            except subprocess.TimeoutExpired:
                continue
        raise TimeoutError('Deadline reached: ' + command[0])


def download(url, destination, *, seconds=3600, run=None, progress=None):
    """Fetch with curl into destination.part. `progress(bytes_so_far)` is called while the transfer runs."""
    run = run or bounded_run
    partial = destination.with_suffix(destination.suffix + '.part')
    if partial.exists():
        partial.unlink()
    command = ['curl', '-sSL', '--fail', '--connect-timeout', '20', '--speed-limit', '1024', '--speed-time', '60',
               '--max-time', str(seconds), '-o', str(partial), url]
    if progress:
        def poll():
            try:
                progress(partial.stat().st_size)
            except OSError:
                pass
        status = run(command, seconds + 30, poll=poll)
    else:
        status = run(command, seconds + 30)
    if status != 0 or not partial.is_file():
        raise ValueError('Download failed')
    return partial


def verify_and_place(partial, destination, sha256):
    actual = digest(partial)
    if actual != sha256:
        partial.unlink(missing_ok=True)
        raise ValueError('SHA-256 mismatch for downloaded model')
    os.rename(partial, destination)
    destination.chmod(0o644)
    return actual


def build_server(root, *, revision=None, seconds=1800, run=None, jobs=None):
    """Clone the pinned llama.cpp revision and build llama-server for the CPU, as the proof README documents."""
    run = run or bounded_run
    revision = revision or PINS['llama']['revision']
    source = root / 'llama.cpp'
    if not (source / '.git').exists():
        if run(['git', 'clone', '--quiet', '--filter=blob:none', LLAMA_SOURCE, str(source)], 600) != 0:
            raise ValueError('Could not clone llama.cpp')
    if run(['git', '-C', str(source), 'checkout', '--quiet', revision], 120) != 0:
        raise ValueError('Could not check out the pinned llama.cpp revision')
    head = subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'], capture_output=True, text=True, timeout=30, check=True).stdout.strip()
    if head != revision:
        raise ValueError('llama.cpp revision mismatch')
    build = source / 'build-cpu'
    log = root / 'build.log'
    with log.open('a') as output:
        if run(['cmake', '-S', str(source), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release', '-DGGML_CUDA=OFF',
                '-DGGML_VULKAN=OFF', '-DGGML_NATIVE=OFF', '-DLLAMA_CURL=OFF', '-DLLAMA_BUILD_TESTS=OFF',
                '-DLLAMA_BUILD_EXAMPLES=OFF', '-DLLAMA_BUILD_TOOLS=ON'], 300, stdout=output, stderr=output) != 0:
            raise ValueError('CMake configuration failed; see build.log')
        if run(['cmake', '--build', str(build), '--target', 'llama-server', '-j', str(jobs or max(1, (os.cpu_count() or 2) - 2))],
               seconds, stdout=output, stderr=output) != 0:
            raise ValueError('llama-server build failed; see build.log')
    server = build / 'bin' / 'llama-server'
    if not server.is_file():
        raise ValueError('llama-server missing after build')
    return server


def check_server(server, revision=None):
    revision = revision or PINS['llama']['revision']
    result = subprocess.run([str(server), '--version'], capture_output=True, text=True, timeout=10, check=False)
    description = result.stdout + result.stderr
    if not any(revision.startswith(found) for found in __import__('re').findall(r'\b[0-9a-f]{7,40}\b', description)):
        raise ValueError('llama-server is not the pinned revision')
    return description.strip()


def write_progress(destination, **fields):
    write_atomic(destination / 'cleanup-setup.json', **fields)


def setup(destination, levels, *, server=None, pins=None, download_fn=None, build_fn=None, check_fn=None, threads=None):
    pins = pins or PINS
    destination = Path(destination)
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    engines_path = destination / 'cleanup.json'
    existing = json.loads(engines_path.read_text()) if engines_path.exists() else {'schema': 1, 'engines': {}}
    download_fn = download_fn or download
    build_fn = build_fn or build_server
    check_fn = check_fn or check_server
    write_progress(destination, state='preparing', levels=list(levels))
    try:
        if server is None:
            write_progress(destination, state='building', levels=list(levels))
            server = build_fn(destination / 'build')
        server = Path(server).resolve()
        runtime = check_fn(server)
        for level in levels:
            spec = LEVELS[level]
            pin = pins[spec['pin']]
            model = destination / spec['file']
            if model.exists():
                if digest(model) != pin['sha256']:
                    raise ValueError('Existing model file does not match its pin')
            else:
                total = pin.get('bytes')
                if total:
                    def report(done, total, level=level):
                        write_progress(destination, state='downloading', level=level, bytes_done=done, bytes_total=total,
                                       levels=list(levels))
                    tracker = DownloadProgress(total, report)
                    tracker(0)
                    partial = download_fn(pin['source'], model, progress=tracker)
                    tracker.finish()
                else:
                    write_progress(destination, state='downloading', level=level, levels=list(levels))
                    partial = download_fn(pin['source'], model)
                verify_and_place(partial, model, pin['sha256'])
            existing['engines'][level] = {
                'threads': threads or max(2, min(8, (os.cpu_count() or 4) // 2)),
                'server': str(server), 'prompt': spec['prompt'],
                'artifacts': {'model': {'path': str(model), 'sha256': pin['sha256']},
                              'server': {'path': str(server), 'sha256': digest(server)}},
                'provenance': {'model': pin, 'runtime': {**pins['llama'], 'description': runtime}},
            }
        tmp = engines_path.with_suffix('.tmp')
        tmp.write_text(json.dumps(existing, indent=2) + '\n')
        os.replace(tmp, engines_path)
        engines_path.chmod(0o600)
        receipt = destination / 'setup-receipt.json'
        receipt.write_text(json.dumps({'prepared': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'levels': list(levels),
                                       'platform': platform.platform(), 'inference_tested': False}, indent=2) + '\n')
        write_progress(destination, state='ready', levels=list(levels))
        return engines_path
    except BaseException as error:
        write_progress(destination, state='failed', error=type(error).__name__, levels=list(levels))
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True, help='Directory for models, build and cleanup.json')
    parser.add_argument('--level', action='append', choices=sorted(LEVELS), help='fast and/or thorough; default fast')
    parser.add_argument('--server', type=Path, help='Existing pinned llama-server instead of building one')
    parser.add_argument('--threads', type=int)
    args = parser.parse_args(argv)
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        print('Cleanup preparation targets Linux x86_64. Nothing was downloaded.', file=sys.stderr)
        return 2
    for tool in ('curl',) + (() if args.server else ('git', 'cmake', 'c++')):
        if shutil.which(tool) is None:
            print('Missing required helper: ' + tool, file=sys.stderr)
            return 2
    levels = args.level or ['fast']
    try:
        path = setup(args.destination, levels, server=args.server, threads=args.threads)
    except (OSError, ValueError, TimeoutError, subprocess.SubprocessError, KeyError) as error:
        print('Cleanup preparation failed: ' + type(error).__name__ + ': ' + str(error), file=sys.stderr)
        return 2
    print('Prepared ' + ', '.join(levels) + ' cleanup: ' + str(path))
    print('Add to linux.json: "cleanup_engine": "' + str(path) + '", "cleanup": "' + levels[0] + '"')
    return 0


if __name__ == '__main__':
    sys.exit(main())
