"""Explicitly prepare pinned Linux speech artifacts in a new private directory."""

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import shlex
import subprocess
import sys
import tarfile

from desktop import private_write, stop_process
from prepare import PINS, SPEECH_ENTRIES, prepare_settings
from proof import digest


def bounded_run(command, seconds):
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=seconds)
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, command)
        return output.decode('utf-8', errors='replace')
    finally:
        stop_process(process)
        if process.stdout:
            process.stdout.close()


def download_archive(source, destination):
    bounded_run(['curl', '--fail', '--location', '--silent', '--show-error',
                 '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', '20',
                 '--max-time', '600', '--output', str(destination), source], 610)


def setup(destination, *, pins=None, download=None, run=None):
    pins, download, run = pins or PINS, download or download_archive, run or bounded_run
    destination = Path(destination).expanduser().resolve()
    destination.mkdir(mode=0o700, parents=True)
    archive = destination / 'parakeet.tar.bz2'
    download(pins['parakeet']['source'], archive)
    if digest(archive) != pins['parakeet']['sha256']:
        raise ValueError('Parakeet archive SHA-256 mismatch')
    model = destination / 'model'
    model.mkdir(mode=0o700)
    prefix = pins['parakeet']['archive'].removesuffix('.tar.bz2')
    with tarfile.open(archive, 'r:bz2') as source:
        for filename in SPEECH_ENTRIES.values():
            member = source.getmember(prefix + '/' + filename)
            if not member.isfile():
                raise ValueError('Expected a regular Parakeet model artifact')
            fd = os.open(model / filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as output, source.extractfile(member) as content:
                shutil.copyfileobj(content, output, length=1024 * 1024)
    settings = prepare_settings(archive, model, None, None, pins=pins)
    venv = destination / 'venv'
    run([sys.executable, '-m', 'venv', str(venv)], 60)
    python = str(venv / 'bin/python')
    requirements = Path(__file__).resolve().parents[1] / 'linux-engine-proof/requirements.txt'
    run([python, '-m', 'pip', 'install', '--disable-pip-version-check', '--no-input',
         '--only-binary=:all:', '--index-url', 'https://pypi.org/simple',
         '--timeout', '30', '--retries', '1', '-r', str(requirements)], 240)
    run([python, '-c', 'import importlib.metadata; import sherpa_onnx; assert importlib.metadata.version("sherpa-onnx") == ' +
         repr(pins['sherpa']['version'])], 20)
    installed = run([python, '-m', 'pip', 'freeze', '--disable-pip-version-check'], 20)
    engines = destination / 'engines.json'
    private_write(engines, json.dumps(settings, indent=2) + '\n')
    receipt = {'model_sha256': digest(archive), 'runtime': pins['sherpa'],
               'python': sys.version, 'system': platform.system(), 'architecture': platform.machine(),
               'installed_packages': installed.splitlines(), 'model_inference_tested': False,
               'desktop_tested': False}
    private_write(destination / 'setup-receipt.json', json.dumps(receipt, indent=2) + '\n')
    config = destination / 'linux.json'
    private_write(config, json.dumps({'engine_config': str(engines), 'python': python,
                                    'maximum_recording_seconds': 60, 'request_seconds': 30,
                                    'delivery': {'mode': 'recover'}, 'notifications': True}, indent=2) + '\n')
    return config


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True, type=Path, help='New directory; existing content is preserved')
    args = parser.parse_args(argv)
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        print('Speech preparation requires Linux x86_64. Nothing was downloaded.', file=sys.stderr)
        return 2
    missing = [command for command in ('curl', 'pw-record') if shutil.which(command) is None]
    if missing:
        print('Missing prerequisites: ' + ', '.join(missing) +
              '. Arch packages: python, python-pip, curl, pipewire-audio; optional libnotify and wtype.', file=sys.stderr)
        return 2
    try:
        print('Preparing pinned speech model and dedicated Python environment. No recording or service starts.')
        config = setup(args.destination)
        print('Prepared recover-only configuration: ' + str(config))
        print('Start explicitly with ' + shlex.join(['mouthtype-linux', '--config', str(config), 'serve']))
        return 0
    except (OSError, ValueError, KeyError, tarfile.TarError, subprocess.SubprocessError) as error:
        print('Speech preparation failed: ' + type(error).__name__ +
              '. Existing directories were preserved; incomplete new setup files remain for inspection.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
