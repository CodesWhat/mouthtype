"""Read-only Linux setup checks. Never opens capture, loads weights or changes setup."""

import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys


def runtime_available(python):
    from prepare import PINS
    script = ('import importlib.metadata; '
              'raise SystemExit(importlib.metadata.version("sherpa-onnx") != ' +
              repr(PINS['sherpa']['version']) + ')')
    try:
        return subprocess.run([python, '-I', '-c', script], stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=3, check=False).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def diagnose(config_path, runtime, *, system=None, machine=None, which=None,
             runtime_check=None, service_check=None):
    from desktop import validate_config, request
    from proof import verify_artifacts
    from spellings import load_spellings
    from phrases import load_phrases
    which = which or shutil.which
    runtime_check = runtime_check or runtime_available
    service_check = service_check or (lambda path: request(path, 'status'))
    checks = []

    def add(name, status, detail, action=''):
        checks.append(dict(name=name, status=status, detail=detail, action=action))

    def relative(value):
        path = Path(value).expanduser()
        return path if path.is_absolute() else Path(config_path).resolve().parent / path

    supported = (system or platform.system()) == 'Linux' and (machine or platform.machine()) == 'x86_64'
    add('platform', 'ok' if supported else 'error',
        'Initial target: Linux x86_64.', '' if supported else 'Use the Linux x86_64 development client on its target machine.')
    try:
        config = validate_config(json.loads(Path(config_path).read_text()))
        if not config['engine_config'] or '\0' in config['engine_config']:
            raise ValueError('Invalid engine path')
        add('configuration', 'ok', 'Configuration is readable and valid.')
    except (OSError, ValueError, TypeError):
        add('configuration', 'error', 'Configuration is missing or invalid.',
            'Prepare a new directory with tools/linux-desktop/setup_speech.py --destination PATH, or repair the existing linux.json.')
        config = None
    capture = which('pw-record') is not None
    add('capture', 'ok' if capture else 'error', 'PipeWire capture helper is available.' if capture else 'pw-record is missing.',
        '' if capture else 'Install PipeWire audio tools using the normal distro package manager.')
    if config is not None:
        valid_python = runtime_check(config.get('python', sys.executable))
        add('runtime', 'ok' if valid_python else 'error',
            'Pinned speech distribution is installed.' if valid_python else 'Configured Python or pinned speech distribution is unavailable.',
            '' if valid_python else 'Repair the configured dedicated Python environment or prepare a new setup directory.')
        try:
            speech = json.loads(relative(config['engine_config']).read_text())['engines']['speech']
            artifacts = speech['artifacts']
            if set(artifacts) != {'encoder', 'decoder', 'joiner', 'vocabulary'}:
                raise ValueError('Incomplete speech artifacts')
            if any(not Path(item['path']).is_file() for item in artifacts.values()):
                raise ValueError('Models must be regular files')
            verify_artifacts(speech)
            add('models', 'ok', 'All four configured speech artifact hashes match. Inference was not run.')
        except (OSError, ValueError, TypeError, KeyError):
            add('models', 'error', 'Speech configuration, files or hashes are invalid.',
                'Restore the verified model files or prepare a new setup directory. This command downloads nothing.')
        for field, loader in (('dictionary', load_spellings), ('phrases', load_phrases)):
            if field in config:
                try:
                    loader(relative(config[field]))
                    add(field, 'ok', 'Configured library is valid. Clipboard was not read.')
                except (OSError, ValueError):
                    add(field, 'error', 'Configured library is missing or invalid.', 'Repair the configured ' + field + ' JSON file.')
        if 'phrases' in config and config.get('phrase_clipboard', False):
            clipboard = which('wl-paste') is not None
            add('phrase_clipboard', 'ok' if clipboard else 'error', 'Clipboard helper availability checked; clipboard was not read.',
                '' if clipboard else 'Install wl-clipboard using normal package policy, or disable phrase_clipboard.')
        delivery = config['delivery']['mode']
        available = delivery == 'recover' or (config['delivery'].get('allow_unknown_secure_field') is True
                                              and all(which(name) for name in ('hyprctl', 'wtype')))
        add('delivery', 'ok' if available else 'error',
            'Recovery-only delivery is configured.' if delivery == 'recover' else 'Automatic typing helpers checked; editable-field and paste verification remain unsupported.',
            '' if available else 'Type mode requires hyprctl/wtype and explicit allow_unknown_secure_field opt-in. Choose recovery-only delivery unless a suitable field is known.')
        if config['notifications']:
            notifications = which('notify-send') is not None
            add('notifications', 'ok' if notifications else 'warning', 'Notification helper checked; display is unverified.',
                '' if notifications else 'Optional: install libnotify or disable notifications in linux.json.')
    try:
        status = service_check(Path(runtime) / 'session.sock')
        if not isinstance(status, dict) or 'state' not in status:
            raise ValueError('Invalid service status')
        add('service', 'ok', 'Existing session service answered status. No recording was started.')
    except (OSError, ValueError):
        add('service', 'warning', 'Session service is not answering.',
            'Start mouthtype-linux with the same --config PATH and serve command when ready.')
    add('physical_acceptance', 'warning', 'Microphone, model inference and actual compositor delivery were not tested.',
        'Run the coordinated Arch/Omarchy acceptance checks separately.')
    return dict(ready=not any(item['status'] == 'error' for item in checks), physical_tested=False, checks=checks)


def render(report):
    lines = ['Mouthtype Linux setup: ' + ('checks passed' if report['ready'] else 'needs attention')]
    for check in report['checks']:
        lines.append(check['status'].upper() + ' ' + check['name'] + ': ' + check['detail'])
        if check['action']:
            lines.append('  ' + check['action'])
    return '\n'.join(lines)
