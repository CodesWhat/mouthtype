"""Library commands: `spellings` and `phrases` list, add, edit and remove entries; `spellings import` loads a CSV.

Loaded by desktop.py's cli_*.py hook. Every command prints one JSON object (see README.md) and works without the
service running. Errors print {"error": message} on stderr and exit 1.
"""

import json
import sys

import library


def register(subparsers):
    spellings = subparsers.add_parser('spellings', help='Saved spellings (the Mac Dictionary page)')
    commands = spellings.add_subparsers(dest='library_action', required=True)
    commands.add_parser('list', help='Print the library as JSON')
    command = commands.add_parser('add', help='Add a spelling')
    command.add_argument('heard')
    command.add_argument('written')
    command = commands.add_parser('edit', help='Change a spelling')
    command.add_argument('heard', help='The heard phrase being edited')
    command.add_argument('new_heard')
    command.add_argument('new_written')
    command.add_argument('--expect-written', help='Refuse if the saved spelling is no longer this')
    command = commands.add_parser('remove', help='Remove a spelling')
    command.add_argument('heard')
    command.add_argument('--expect-written', help='Refuse if the saved spelling is no longer this')
    command = commands.add_parser('import', help='Import heard,written or name CSV rows')
    command.add_argument('file')
    command.add_argument('--dry-run', action='store_true', help='Print the per-row preview and write nothing')
    command.add_argument('--expect-digest', help='Refuse if the library is not the one a preview saw')

    phrases = subparsers.add_parser('phrases', help='Saved phrases (the Mac Transforms page)')
    commands = phrases.add_subparsers(dest='library_action', required=True)
    commands.add_parser('list', help='Print the library as JSON')
    command = commands.add_parser('add', help='Add a phrase')
    command.add_argument('trigger')
    command.add_argument('expansion')
    command = commands.add_parser('edit', help='Change a phrase')
    command.add_argument('trigger', help='The trigger being edited')
    command.add_argument('new_trigger')
    command.add_argument('new_expansion')
    command.add_argument('--expect-expansion', help='Refuse if the saved text is no longer this')
    command = commands.add_parser('remove', help='Remove a phrase')
    command.add_argument('trigger')
    command.add_argument('--expect-expansion', help='Refuse if the saved text is no longer this')


def run(args, context):
    config = context.config
    action = args.library_action
    try:
        if args.action == 'spellings':
            if action == 'list':
                result = library.list_library(config, 'spellings')
            elif action == 'add':
                result = library.add_spelling(config, args.heard, args.written)
            elif action == 'edit':
                result = library.edit_spelling(config, args.heard, args.new_heard, args.new_written, args.expect_written)
            elif action == 'remove':
                result = library.remove_spelling(config, args.heard, args.expect_written)
            elif args.dry_run:
                result = library.preview_import(config, args.file)
            else:
                result = library.import_spellings(config, args.file, args.expect_digest)
        else:
            if action == 'list':
                result = library.list_library(config, 'phrases')
            elif action == 'add':
                result = library.add_phrase(config, args.trigger, args.expansion)
            elif action == 'edit':
                result = library.edit_phrase(config, args.trigger, args.new_trigger, args.new_expansion, args.expect_expansion)
            else:
                result = library.remove_phrase(config, args.trigger, args.expect_expansion)
    except ValueError as error:
        print(json.dumps({'error': str(error)}), file=sys.stderr)
        return 1
    except OSError as error:
        print(json.dumps({'error': error.strerror or type(error).__name__}), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0
