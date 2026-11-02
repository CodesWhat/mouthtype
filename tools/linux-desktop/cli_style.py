"""`style` command: tone, swearing softening and Style contexts, as JSON for scripts and the Omarchy panel."""

import json
import sys

import styles
import tone

LEVEL_CHOICES = list(styles.LEVELS) + ['none']
TONE_CHOICES = list(tone.TONES) + ['none']


def _none(value):
    return None if value == 'none' else value


def register(subparsers):
    command = subparsers.add_parser('style', help='Style contexts, tone and swearing softening (JSON)')
    verbs = command.add_subparsers(dest='style_action', required=True)
    verbs.add_parser('show', help='Contexts, members, tones and sample outputs for the Style page')
    preview = verbs.add_parser('preview', help='Run text through a tone')
    preview.add_argument('tone', choices=list(tone.TONES))
    preview.add_argument('text')
    resolve = verbs.add_parser('resolve', help='What applies to a take captured in a window class')
    resolve.add_argument('app', nargs='?', default=None, help='Hyprland window class; omit for an unknown target')
    default = verbs.add_parser('set-default-tone', help='The tone for Other and unlisted apps; none turns it off')
    default.add_argument('tone', choices=TONE_CHOICES)
    context_tone = verbs.add_parser('set-tone', help='A context tone; none follows the default tone')
    context_tone.add_argument('context', choices=['personal', 'work', 'email'])
    context_tone.add_argument('tone', choices=TONE_CHOICES)
    cleanup = verbs.add_parser('set-cleanup', help='A context cleanup level; none means same as everywhere')
    cleanup.add_argument('context', choices=list(styles.CONTEXTS))
    cleanup.add_argument('level', choices=LEVEL_CHOICES)
    add = verbs.add_parser('add-app', help='Put a window class in a context')
    add.add_argument('context', choices=['personal', 'work', 'email'])
    add.add_argument('app')
    add.add_argument('--name')
    remove = verbs.add_parser('remove-app', help='Take a member out of a context')
    remove.add_argument('context', choices=['personal', 'work', 'email'])
    remove.add_argument('member', help='A built-in id, or app:<window class> for one you added')
    rule = verbs.add_parser('rule', help='A per-app tone and cleanup rule; no options clears it')
    rule.add_argument('app')
    rule.add_argument('--name')
    rule.add_argument('--tone', choices=TONE_CHOICES)
    rule.add_argument('--cleanup', choices=LEVEL_CHOICES)


def run(args, context):
    action = args.style_action
    if action == 'preview':
        print(json.dumps({'text': tone.apply(args.text, args.tone)}, ensure_ascii=False))
        return 0
    try:
        if action in ('show', 'resolve'):
            block = styles.read_block(context.config)
            if action == 'show':
                output = styles.describe(block)
            else:
                output = styles.resolve(block, args.app)
        else:
            changes = {
                'set-default-tone': lambda b: styles.set_default_tone(b, _none(args.tone)),
                'set-tone': lambda b: styles.set_context(b, args.context, 'tone', _none(args.tone)),
                'set-cleanup': lambda b: styles.set_context(b, args.context, 'cleanup', _none(args.level)),
                'add-app': lambda b: styles.add_app(b, args.context, args.app, args.name),
                'remove-app': lambda b: styles.remove_app(b, args.context, args.member),
                'rule': lambda b: styles.set_rule(b, args.app, args.name, _none(args.tone), _none(args.cleanup)),
            }
            output = styles.describe(styles.update_config(context.config, changes[action]))
    except (OSError, ValueError) as error:
        print(json.dumps({'error': str(error)}), file=sys.stderr)
        return 1
    print(json.dumps(output, ensure_ascii=False))
    return 0
