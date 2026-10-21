"""Style contexts for Linux: Personal, Work, Email and Other, a tone and a cleanup level per context.

Mirrors the Mac's StyleContexts and AppCleanupStyles for apps. Websites have no Linux equivalent (Wayland exposes no
URL to other clients) and are skipped. An app is identified by its window class as Hyprland reports it, which is the
Wayland app_id for native clients and the WM_CLASS for XWayland ones. Classes compare case-insensitively.

The settings live in the `styles` block of linux.json. A config without the block, or with an empty one, changes nothing:
no tone is applied anywhere and every take uses the global cleanup level, exactly as before.

Precedence for one take: your per-app rule, then the context an app was added to by you, then the context a built-in
member puts it in, then Other. Each of tone and cleanup falls through on its own. Other holds only a cleanup level and
applies to everything no list claims; its tone is the global default tone (`styles.tone`).
"""

CONTEXTS = ('personal', 'work', 'email', 'other')
TITLES = {'personal': 'Personal messages', 'work': 'Work messages', 'email': 'Email', 'other': 'Other'}
LEVELS = ('off', 'basic', 'fast', 'thorough')
MAX_APPS = 200
MAX_CLASS = 128
# The tone the Mac starts each context with. Linux leaves tones unset so existing installs stay unchanged; V6 can offer
# this as the suggested value.
SUGGESTED_TONE = {'personal': 'casual', 'work': 'casual', 'email': 'formal', 'other': None}

# Built-in members: id, display name, window classes. Wayland app_ids and X11 classes for the same app are listed
# together. Sources are in tools/linux-desktop/README.md.
BUILT_INS = {
    'personal': (
        ('signal', 'Signal', ('signal', 'Signal', 'org.signal.Signal')),
        ('telegram', 'Telegram', ('org.telegram.desktop', 'TelegramDesktop')),
        ('discord', 'Discord', ('discord', 'com.discordapp.Discord')),
    ),
    'work': (
        ('slack', 'Slack', ('Slack', 'slack', 'com.slack.Slack')),
        ('teams', 'Microsoft Teams', ('teams-for-linux', 'com.github.IsmaelMartinez.teams_for_linux',
                                      'Microsoft Teams - Preview', 'teams')),
    ),
    'email': (
        ('thunderbird', 'Thunderbird', ('thunderbird', 'Thunderbird', 'org.mozilla.Thunderbird')),
        ('evolution', 'Evolution', ('org.gnome.Evolution', 'evolution', 'Evolution')),
        ('geary', 'Geary', ('org.gnome.Geary', 'geary')),
    ),
    'other': (),
}

# Sample dictations for the tone cards, the same lines the Mac Style page uses. `engine` is what the speech engine
# hands back; the cards run it through the real tone code.
SAMPLES = {
    'personal': [('hey are we still on for dinner tonight i can be there by seven',
                  'Hey, are we still on for dinner tonight? I can be there by seven.')],
    'work': [('quick update the deploy went out and the dashboards look fine',
              'Quick update: the deploy went out, and the dashboards look fine.')],
    'email': [('hi Priya', 'Hi Priya,'),
              ('thanks for the signed build the release notes are in the PR',
               'Thanks for the signed build. The release notes are in the PR.'),
              ('can we do the review Thursday', 'Can we do the review Thursday?'),
              ('talk soon', 'Talk soon.')],
    'other': [("sure i'll send the invoice tomorrow morning and copy Dan",
               "Sure, I'll send the invoice tomorrow morning and copy Dan.")],
}


def _key(window_class):
    return window_class.casefold()


def _check_class(value, label):
    if (not isinstance(value, str) or not value or len(value) > MAX_CLASS or '*' in value or
            any(ord(char) < 32 or ord(char) == 127 for char in value) or value != value.strip()):
        raise ValueError(label + ' must be one exact window class of up to 128 characters, without wildcards')
    return value


def _check_name(value, label):
    if not isinstance(value, str) or not value.strip() or len(value) > 128 or any(ord(c) < 32 for c in value):
        raise ValueError(label + ' needs a name')
    return value.strip()


def _check_tone(value, label):
    import tone
    if value is not None and value not in tone.TONES:
        raise ValueError(label + ' must be null, formal, casual or very_casual')
    return value


def _check_level(value, label):
    if value is not None and value not in LEVELS:
        raise ValueError(label + ' must be null, off, basic, fast or thorough')
    return value


def validate(value):
    """Return the normalised styles block. None or {} is the inert default. Raises ValueError for anything malformed."""
    if value is None:
        value = {}
    if not isinstance(value, dict):
        raise ValueError('styles must be an object')
    unknown = set(value) - {'version', 'tone', 'contexts', 'rules'}
    if unknown:
        raise ValueError('Unknown styles field: ' + sorted(unknown)[0])
    if value.get('version', 1) != 1:
        raise ValueError('styles.version must be 1')
    result = {'tone': _check_tone(value.get('tone'), 'styles.tone'), 'contexts': {}, 'rules': []}
    contexts = value.get('contexts', {})
    if not isinstance(contexts, dict) or set(contexts) - set(CONTEXTS):
        raise ValueError('styles.contexts may only hold personal, work, email and other')
    for name, config in contexts.items():
        label = 'styles.contexts.' + name
        if not isinstance(config, dict) or set(config) - {'tone', 'cleanup', 'added', 'removed'}:
            raise ValueError(label + ' has an unknown field')
        entry = {'tone': _check_tone(config.get('tone'), label + '.tone'),
                 'cleanup': _check_level(config.get('cleanup'), label + '.cleanup'), 'added': [], 'removed': []}
        if name == 'other' and (config.get('tone') is not None or config.get('added') or config.get('removed')):
            raise ValueError('Other holds only a cleanup level; set the default tone with styles.tone')
        added, removed = config.get('added', []), config.get('removed', [])
        if not isinstance(added, list) or not isinstance(removed, list):
            raise ValueError(label + ' added and removed must be lists')
        for app in added:
            if not isinstance(app, dict) or set(app) != {'app', 'name'}:
                raise ValueError(label + '.added entries need app and name')
            entry['added'].append({'app': _check_class(app['app'], label + '.added app'),
                                   'name': _check_name(app['name'], label + '.added name')})
        known = {member[0] for member in BUILT_INS[name]}
        for member in removed:
            if member not in known:
                raise ValueError(label + '.removed holds an unknown built-in: ' + str(member))
        entry['removed'] = sorted(set(removed))
        if entry != {'tone': None, 'cleanup': None, 'added': [], 'removed': []}:
            result['contexts'][name] = entry
    rules = value.get('rules', [])
    if not isinstance(rules, list):
        raise ValueError('styles.rules must be a list')
    seen = set()
    for rule in rules:
        if not isinstance(rule, dict) or set(rule) - {'app', 'name', 'tone', 'cleanup'} or 'app' not in rule:
            raise ValueError('Each rule needs app and may hold name, tone and cleanup')
        app = _check_class(rule['app'], 'styles.rules app')
        if _key(app) in seen:
            raise ValueError('Two rules for ' + app)
        seen.add(_key(app))
        entry = {'app': app, 'name': _check_name(rule.get('name', app), 'styles.rules name'),
                 'tone': _check_tone(rule.get('tone'), 'styles.rules tone'),
                 'cleanup': _check_level(rule.get('cleanup'), 'styles.rules cleanup')}
        if entry['tone'] is None and entry['cleanup'] is None:
            raise ValueError('A rule must set a tone or a cleanup level')
        result['rules'].append(entry)
    if sum(len(c['added']) for c in result['contexts'].values()) + len(result['rules']) > MAX_APPS:
        raise ValueError('styles holds more than %d apps' % MAX_APPS)
    return result


def is_default(value):
    return validate(value) == {'tone': None, 'contexts': {}, 'rules': []}


def to_config(normalised):
    """The block to store in linux.json, or None when everything is default (the key is then removed)."""
    if normalised == {'tone': None, 'contexts': {}, 'rules': []}:
        return None
    return {'version': 1, **normalised}


def _context_config(styles, name):
    return styles['contexts'].get(name, {'tone': None, 'cleanup': None, 'added': [], 'removed': []})


def members(styles, name):
    """The apps in a context: built-ins you haven't removed, then the ones you added. Other has none."""
    config = _context_config(validate(styles), name)
    result = [{'id': member_id, 'name': title, 'apps': list(classes), 'built_in': True}
              for member_id, title, classes in BUILT_INS[name] if member_id not in config['removed']]
    result += [{'id': 'app:' + app['app'], 'name': app['name'], 'apps': [app['app']], 'built_in': False}
               for app in config['added']]
    return result


def context_of(styles, window_class):
    """The context an app counts as, or None when it is unlisted (and so Other). An added app beats a built-in."""
    if not window_class:
        return None
    styles = validate(styles)
    wanted = _key(window_class)
    for name in CONTEXTS:
        if any(_key(app['app']) == wanted for app in _context_config(styles, name)['added']):
            return name
    for name in CONTEXTS:
        for member in members(styles, name):
            if member['built_in'] and any(_key(app) == wanted for app in member['apps']):
                return name
    return None


def resolve(styles, window_class):
    """What applies to a take captured in `window_class` (None when the target is unknown).

    Returns {'context', 'tone', 'cleanup', 'source'}. tone None means no tone pass; cleanup None means the global
    level stands. source says which layer decided: rule, added, built_in or other."""
    styles = validate(styles)
    wanted = _key(window_class) if window_class else None
    layers, membership = [], 'other'
    rule = next((r for r in styles['rules'] if wanted and _key(r['app']) == wanted), None)
    if rule is not None:
        layers.append(('rule', rule['tone'], rule['cleanup']))
    name = context_of(styles, window_class)
    if name is not None:
        config = _context_config(styles, name)
        added = any(wanted and _key(app['app']) == wanted for app in config['added'])
        membership = 'added' if added else 'built_in'
        layers.append((membership, config['tone'], config['cleanup']))
    else:
        layers.append(('other', None, _context_config(styles, 'other')['cleanup']))
    layers.append(('default', styles['tone'], None))
    tone_layer = next((layer for layer in layers if layer[1] is not None), None)
    level_layer = next((layer for layer in layers if layer[2] is not None), None)
    decided = next((layer[0] for layer in layers if layer[1] is not None or layer[2] is not None), None)
    return {'context': name or 'other', 'tone': tone_layer[1] if tone_layer else None,
            'cleanup': level_layer[2] if level_layer else None,
            'source': decided or membership}


def effective_cleanup(resolved, global_level, models=()):
    """The cleanup level a take should run at. A Fast or Thorough override with no prepared model for it falls back
    to Basic, because the service has no model to run it with. `models` lists the prepared levels."""
    level = resolved['cleanup'] or global_level
    if level in ('fast', 'thorough') and level not in models:
        return 'basic'
    return level


def describe(styles, models=()):
    """The JSON the Style page reads."""
    import tone
    styles = validate(styles)
    contexts = []
    for name in CONTEXTS:
        config = _context_config(styles, name)
        samples = []
        for preset in tone.TONES:
            lines = [{'spoken': spoken, 'engine': engine, 'styled': tone.apply(engine, preset)}
                     for spoken, engine in SAMPLES[name]]
            samples.append({'tone': preset, 'title': tone.TITLES[preset], 'lines': lines})
        contexts.append({
            'id': name, 'title': TITLES[name], 'has_list': name != 'other',
            'tone': config['tone'] if name != 'other' else styles['tone'], 'suggested_tone': SUGGESTED_TONE[name],
            'cleanup': config['cleanup'], 'members': members(styles, name), 'samples': samples,
            'built_in_removed': [m for m in config['removed']]})
    return {'tones': [{'id': t, 'title': tone.TITLES[t]} for t in tone.TONES], 'levels': list(LEVELS),
            'default_tone': styles['tone'], 'contexts': contexts, 'rules': styles['rules'],
            'cleanup_overrides': [{'context': c['id'], 'level': c['cleanup']} for c in contexts if c['cleanup']],
            'websites': 'unsupported'}


# Editing. Each takes a styles block and returns a new normalised one.

def set_default_tone(styles, value):
    result = validate(styles)
    result['tone'] = _check_tone(value, 'tone')
    return validate(result)


def set_context(styles, name, field, value):
    if name not in CONTEXTS:
        raise ValueError('Unknown context: ' + str(name))
    if field not in ('tone', 'cleanup'):
        raise ValueError('Unknown context field: ' + str(field))
    if name == 'other' and field == 'tone':
        raise ValueError('Other has no tone of its own; set the default tone')
    result = validate(styles)
    config = dict(_context_config(result, name))
    config[field] = _check_tone(value, 'tone') if field == 'tone' else _check_level(value, 'cleanup')
    result['contexts'][name] = config
    return validate(result)


def add_app(styles, name, window_class, display_name=None):
    """Put an app in a context. An app counts as one context at a time, so it leaves any other first."""
    if name not in CONTEXTS or name == 'other':
        raise ValueError('Choose personal, work or email')
    window_class = _check_class(window_class, 'App')
    result = validate(styles)
    wanted = _key(window_class)
    for other in CONTEXTS:
        config = dict(_context_config(result, other))
        config['added'] = [app for app in config['added'] if _key(app['app']) != wanted]
        config['removed'] = list(config['removed'])
        for member_id, _, classes in BUILT_INS[other]:
            if any(_key(c) == wanted for c in classes) and member_id not in config['removed'] and other != name:
                config['removed'].append(member_id)
        result['contexts'][other] = config
    config = result['contexts'][name]
    built_in = next((m for m in BUILT_INS[name] if any(_key(c) == wanted for c in m[2])), None)
    if built_in is not None:
        config['removed'] = [m for m in config['removed'] if m != built_in[0]]
    else:
        config['added'].append({'app': window_class, 'name': _check_name(display_name or window_class, 'Name')})
    return validate(result)


def remove_app(styles, name, member_id):
    """Take a member out of a context: a built-in by id, or an added app by its 'app:<class>' id."""
    if name not in CONTEXTS or name == 'other':
        raise ValueError('Choose personal, work or email')
    result = validate(styles)
    config = dict(_context_config(result, name))
    if member_id.startswith('app:'):
        wanted = _key(member_id[4:])
        before = len(config['added'])
        config['added'] = [app for app in config['added'] if _key(app['app']) != wanted]
        if len(config['added']) == before:
            raise ValueError('That app is not in this context')
    elif any(m[0] == member_id for m in BUILT_INS[name]):
        config['removed'] = sorted(set(config['removed']) | {member_id})
    else:
        raise ValueError('That app is not in this context')
    result['contexts'][name] = config
    return validate(result)


def set_rule(styles, window_class, display_name, tone_value, cleanup_value):
    """Set or clear (both None) the per-app rule for a window class."""
    window_class = _check_class(window_class, 'App')
    result = validate(styles)
    wanted = _key(window_class)
    result['rules'] = [r for r in result['rules'] if _key(r['app']) != wanted]
    if tone_value is not None or cleanup_value is not None:
        result['rules'].append({'app': window_class, 'name': display_name or window_class,
                                'tone': tone_value, 'cleanup': cleanup_value})
    return validate(result)


# Storage

def read_block(config_path):
    """The validated styles block in a linux.json (the inert default when it has none)."""
    import json
    from pathlib import Path
    config = json.loads(Path(config_path).read_text(encoding='utf-8'))
    if not isinstance(config, dict):
        raise ValueError('linux.json must hold an object')
    return validate(config.get('styles'))


def update_config(config_path, change):
    """Apply change(block) -> block to the styles in a linux.json and write it back atomically with a backup.

    Nothing is written when the result equals what is stored. A block that goes back to all defaults removes the
    `styles` key, so the file returns to exactly what it was before the user touched anything."""
    import json
    import os
    from pathlib import Path
    import shutil
    import tempfile
    import time
    path = Path(config_path)
    config = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(config, dict):
        raise ValueError('linux.json must hold an object')
    block = change(validate(config.get('styles')))
    stored = to_config(validate(block))
    updated = {key: value for key, value in config.items() if key != 'styles'}
    if stored is not None:
        updated['styles'] = stored
    if updated == config:
        return validate(block)
    shutil.copy2(path, path.with_name('linux.json.bak.%d' % int(time.time())))
    fd, temporary = tempfile.mkstemp(prefix='.mouthtype-', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            json.dump(updated, output, indent=2)
            output.write('\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return validate(block)
