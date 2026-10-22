"""Prepare pinned AI cleanup models for the Linux client: verified weights and a pinned llama-server.

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
import tarfile
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
CANCEL_FLAG = 'cleanup-cancel'


class SetupCancelled(Exception):
    """The user asked to stop preparing; raised from a progress poll so the transfer is torn down."""


def stop_group(process):
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
    except SetupCancelled:
        stop_group(process)
        raise
    except subprocess.TimeoutExpired:
        stop_group(process)
        raise TimeoutError('Deadline reached: ' + command[0])


def download(url, destination, *, seconds=3600, run=None, progress=None, proto='=https'):
    """Fetch with curl into destination.part. `progress(bytes_so_far)` is called while the transfer runs."""
    run = run or bounded_run
    partial = destination.with_suffix(destination.suffix + '.part')
    if partial.exists():
        partial.unlink()
    command = ['curl', '-sSL', '--fail', '--proto', proto, '--proto-redir', proto, '--connect-timeout', '20', '--speed-limit', '1024', '--speed-time', '60',
               '--max-time', str(seconds), '-o', str(partial), url]
    if progress:
        def poll():
            try:
                progress(partial.stat().st_size)
            except OSError:
                pass
        try:
            status = run(command, seconds + 30, poll=poll)
        except SetupCancelled:
            partial.unlink(missing_ok=True)
            raise
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


def extract_server(archive, destination):
    """Extract only llama-server and the shared libraries beside it from the release tarball into destination.

    The tarball has one top directory. Every member is checked before anything is written, and any entry outside
    that shape (absolute path, `..`, nesting, a link that leaves the directory, a device node) rejects the archive.
    """
    wanted = []
    with tarfile.open(archive, 'r:gz') as tar:
        for member in tar.getmembers():
            parts = member.name.split('/')
            if member.name.startswith('/') or '..' in parts or '\\' in member.name:
                raise ValueError('Unsafe path in llama.cpp archive')
            if member.isdir():
                continue
            if not (member.isfile() or member.issym()):
                raise ValueError('Unsupported entry in llama.cpp archive')
            if len(parts) != 2:
                if len(parts) > 2:
                    raise ValueError('Unexpected nesting in llama.cpp archive')
                continue
            name = parts[1]
            if member.issym() and (os.path.basename(member.linkname) != member.linkname or member.linkname in ('', '.')):
                raise ValueError('Unsafe link in llama.cpp archive')
            if name == 'llama-server' or (name.startswith('lib') and '.so' in name):
                wanted.append(member)
        if not any(member.name.endswith('/llama-server') and member.isfile() for member in wanted):
            raise ValueError('llama-server missing from the llama.cpp archive')
        staging = destination.with_name(destination.name + '.new')
        shutil.rmtree(staging, ignore_errors=True)
        staging.mkdir(mode=0o700, parents=True)
        try:
            for member in wanted:
                target = staging / member.name.split('/')[1]
                if member.issym():
                    os.symlink(member.linkname, target)
                    continue
                source = tar.extractfile(member)
                with source, target.open('wb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
            shutil.rmtree(destination, ignore_errors=True)
            os.rename(staging, destination)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
    return destination / 'llama-server'


def fetch_server(root, *, pins=None, download_fn=None):
    """Download the pinned upstream llama-server release, verify its SHA-256 and unpack the server and its libraries."""
    block = (pins or PINS)['llama_binary']
    root = Path(root)
    destination = root / 'server'
    stamp = destination / '.asset-sha256'
    if stamp.is_file() and stamp.read_text().strip() == block['sha256'] and (destination / 'llama-server').is_file():
        return destination / 'llama-server'
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    archive = root / block['asset']
    partial = (download_fn or download)(block['source'], archive)
    if digest(partial) != block['sha256']:
        partial.unlink(missing_ok=True)
        raise ValueError('SHA-256 mismatch for downloaded llama-server')
    try:
        server = extract_server(partial, destination)
    finally:
        partial.unlink(missing_ok=True)
    stamp.write_text(block['sha256'] + '\n')
    return server


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


def setup(destination, levels, *, server=None, pins=None, download_fn=None, build_fn=None, fetch_fn=None, check_fn=None,
          threads=None, build=False):
    pins = pins or PINS
    destination = Path(destination)
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    engines_path = destination / 'cleanup.json'
    existing = json.loads(engines_path.read_text()) if engines_path.exists() else {'schema': 1, 'engines': {}}
    download_fn = download_fn or download
    build_fn = build_fn or build_server
    fetch_fn = fetch_fn or (lambda root: fetch_server(root, pins=pins, download_fn=download_fn))
    check_fn = check_fn or check_server
    cancel_flag = destination / CANCEL_FLAG
    cancel_flag.unlink(missing_ok=True)

    def check_cancel(done=None):
        if cancel_flag.exists():
            raise SetupCancelled()

    write_progress(destination, state='preparing', levels=list(levels))
    try:
        if server is None:
            if build:
                write_progress(destination, state='building', levels=list(levels))
                server = build_fn(destination / 'build')
            else:
                server = fetch_fn(destination)
        server = Path(server).resolve()
        runtime = check_fn(server)
        for level in levels:
            check_cancel()
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
                        check_cancel()
                        write_progress(destination, state='downloading', level=level, bytes_done=done, bytes_total=total,
                                       levels=list(levels))
                    tracker = DownloadProgress(total, report)
                    tracker(0)

                    def watch(done, tracker=tracker):
                        check_cancel()
                        tracker(done)
                    partial = download_fn(pin['source'], model, progress=watch)
                    tracker.finish()
                else:
                    write_progress(destination, state='downloading', level=level, levels=list(levels))
                    partial = download_fn(pin['source'], model, progress=check_cancel)
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
    except SetupCancelled:
        for level in levels:
            (destination / (LEVELS[level]['file'] + '.part')).unlink(missing_ok=True)
        cancel_flag.unlink(missing_ok=True)
        write_progress(destination, state='cancelled', levels=list(levels))
        return None
    except BaseException as error:
        write_progress(destination, state='failed', error=type(error).__name__, levels=list(levels))
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True, help='Directory for models, build and cleanup.json')
    parser.add_argument('--level', action='append', choices=sorted(LEVELS), help='fast and/or thorough; default fast')
    parser.add_argument('--server', type=Path, help='Existing pinned llama-server instead of downloading one')
    parser.add_argument('--build-server', action='store_true',
                        help='Compile the pinned llama.cpp locally instead of downloading the upstream release (needs git, cmake, a C++ toolchain)')
    parser.add_argument('--threads', type=int)
    args = parser.parse_args(argv)
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        print('Cleanup preparation targets Linux x86_64. Nothing was downloaded.', file=sys.stderr)
        return 2
    for tool in ('curl',) + (('git', 'cmake', 'c++') if args.build_server and not args.server else ()):
        if shutil.which(tool) is None:
            print('Missing required helper: ' + tool, file=sys.stderr)
            return 2
    levels = args.level or ['fast']
    try:
        path = setup(args.destination, levels, server=args.server, threads=args.threads, build=args.build_server)
    except (OSError, ValueError, TimeoutError, subprocess.SubprocessError, KeyError) as error:
        print('Cleanup preparation failed: ' + type(error).__name__ + ': ' + str(error), file=sys.stderr)
        return 2
    if path is None:
        print('Cleanup preparation cancelled.')
        return 0
    print('Prepared ' + ', '.join(levels) + ' cleanup: ' + str(path))
    print('Add to linux.json: "cleanup_engine": "' + str(path) + '", "cleanup": "' + levels[0] + '"')
    return 0


if __name__ == '__main__':
    sys.exit(main())
