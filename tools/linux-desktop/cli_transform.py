"""`transform` command: Transform Selection verbs for the panel. Every outcome is one JSON object on stdout.

transform status                      model availability and the five transforms
transform capture                     capture the primary selection (clipboard fallback) once
transform run ID KIND                 preview clean-up, fix-grammar, make-shorter, more-formal or more-casual
transform accept ID [--stdin]         replace the selection, only if the same window is still focused
transform copy ID [--original] [--stdin]
transform cancel [ID]                 discard the capture (all captures without an ID)

--stdin reads the user's edited result as UTF-8 from standard input. Exit status is 0 for every state except
error, which exits 2. SIGINT and SIGTERM cancel the running transform and exit with state cancelled.
"""

import json
import signal
import sys
import threading

import transform
import transform_host
from transform import MAX_UNITS, TransformService, failure, units


def register(subparsers):
    parser = subparsers.add_parser('transform', help='Transform the selected text: preview, copy, or replace it')
    actions = parser.add_subparsers(dest='transform_action', required=True)
    actions.add_parser('status', help='Model availability and the available transforms')
    actions.add_parser('capture', help='Capture the primary selection (or the clipboard) once')
    run = actions.add_parser('run', help='Preview one transform of the captured text')
    run.add_argument('id')
    run.add_argument('kind', choices=transform.KIND_IDS)
    accept = actions.add_parser('accept', help='Replace the selection with the result if the window is unchanged')
    accept.add_argument('id')
    accept.add_argument('--stdin', action='store_true', help='Use the edited result read from standard input')
    copy = actions.add_parser('copy', help='Copy the result (or the original) to the clipboard')
    copy.add_argument('id')
    copy.add_argument('--original', action='store_true')
    copy.add_argument('--stdin', action='store_true', help='Use the edited result read from standard input')
    cancel = actions.add_parser('cancel', help='Discard the capture')
    cancel.add_argument('id', nargs='?')


def read_edited(stream):
    data = stream.buffer.read(transform.SOURCE_BYTES + 1) if hasattr(stream, 'buffer') else stream.read().encode()
    if len(data) > transform.SOURCE_BYTES:
        raise ValueError('The edited result is over 16,000 characters.')
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        raise ValueError('The edited result is not valid UTF-8.')
    if units(text) > MAX_UNITS:
        raise ValueError('The edited result is over 16,000 characters.')
    return text


def service_busy(context):
    """True while dictation or a file job is running. An absent service is not busy."""
    try:
        status = context.request('status')
    except OSError:
        return False
    return isinstance(status, dict) and status.get('state') not in (None, 'idle')


def execute(args, service, stdin):
    action = args.transform_action
    if action == 'status':
        return service.status()
    if action == 'capture':
        return service.capture()
    if action == 'run':
        return service.transform(args.id, args.kind)
    if action == 'cancel':
        return service.cancel(args.id)
    edited = None
    if args.stdin:
        try:
            edited = read_edited(stdin)
        except ValueError as error:
            return failure('invalid_result', str(error))
    if action == 'accept':
        return service.accept(args.id, edited)
    return service.copy(args.id, original=args.original, edited=edited)


def run(args, context, *, stdin=None, output=None, service=None):
    cancelled = threading.Event()
    service = service or TransformService(context.config, context.runtime, cancelled=cancelled,
                                          busy=lambda: service_busy(context),
                                          idle_seconds=transform_host.idle_seconds(),
                                          hash_cache=transform._desktop().hash_cache())
    previous = {}
    if threading.current_thread() is threading.main_thread():
        for event in (signal.SIGINT, signal.SIGTERM):
            previous[event] = signal.signal(event, lambda *_: cancelled.set())
    try:
        try:
            result = execute(args, service, stdin or sys.stdin)
        except (OSError, ValueError) as error:
            result = failure('unavailable', 'Transform Selection is unavailable.', error_class=type(error).__name__)
    finally:
        for event, handler in previous.items():
            signal.signal(event, handler)
    print(json.dumps(result, ensure_ascii=False), file=output or sys.stdout, flush=True)
    return 2 if result.get('state') == 'error' else 0
