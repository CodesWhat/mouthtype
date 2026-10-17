"""Saved phrase snapshots with the Core matcher's literal, one-pass semantics."""

import datetime
import json
import os
import re
import stat
import subprocess
import unicodedata

from spellings import Spellings, _collapse
from vendor.grapheme import graphemes

MAX_LIBRARY_BYTES = 1024 * 1024
MAX_RESULT_BYTES = 2 * 1024 * 1024
_VARIABLE = re.compile(r'\{([^{}]{1,10})\}')
_MONTHS = ('January', 'February', 'March', 'April', 'May', 'June',
           'July', 'August', 'September', 'October', 'November', 'December')


class PhraseContextUnavailable(ValueError):
    pass


class Phrases:
    def __init__(self, rules, *, date_text='', clipboard=None):
        def expand(match):
            name = match.group(1).lower()
            if name == 'date':
                return date_text
            if name == 'clipboard':
                return clipboard or ''
            return match.group(0)
        expanded = [{'heard': rule['trigger'], 'written': _VARIABLE.sub(expand, rule['expansion'])}
                    for rule in rules]
        self.matcher = Spellings(expanded, allow_empty=True, maximum_output_bytes=MAX_RESULT_BYTES)

    def apply(self, text):
        return self.matcher.apply(text)


def load_phrases(path, *, now=datetime.datetime.now, clipboard=None):
    if path is None:
        return Phrases([])
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError('Phrases must be a regular JSON file')
        raw = source.read(MAX_LIBRARY_BYTES + 1)
    if len(raw) > MAX_LIBRARY_BYTES:
        raise ValueError('Phrases exceed the 1 MiB limit')
    def invalid_constant(_):
        raise ValueError('Phrases must contain valid JSON')
    try:
        rules = json.loads(raw.decode('utf-8'), parse_constant=invalid_constant)
    except RecursionError:
        raise ValueError('Phrase nesting exceeds the decoder limit') from None
    if not isinstance(rules, list):
        raise ValueError('Phrases must contain an entry array')
    seen, variables = set(), set()
    for rule in rules:
        if (not isinstance(rule, dict) or not isinstance(rule.get('trigger'), str) or
                not isinstance(rule.get('expansion'), str)):
            raise ValueError('Invalid phrase entry')
        trigger = ''.join(_collapse(rule['trigger']))
        expansion = rule['expansion']
        trigger.encode('utf-8'); expansion.encode('utf-8')
        if (not trigger or len(list(graphemes(trigger))) > 128 or
                not _collapse(expansion) or len(list(graphemes(expansion))) > 16000):
            raise ValueError('Invalid phrase length')
        key = unicodedata.normalize('NFC', trigger.lower())
        if key in seen:
            raise ValueError('Duplicate phrase trigger')
        seen.add(key)
        variables.update(match.group(1).lower() for match in _VARIABLE.finditer(expansion))
        rule['trigger'] = trigger
    clip = None
    if 'clipboard' in variables:
        if clipboard is None:
            raise PhraseContextUnavailable('Clipboard phrase context requires explicit permission')
        try:
            clip = clipboard()
        except (OSError, ValueError, subprocess.SubprocessError):
            raise PhraseContextUnavailable('Clipboard phrase context is unavailable') from None
        if not isinstance(clip, str):
            raise PhraseContextUnavailable('Clipboard phrase context is unavailable')
    date_text = ''
    if 'date' in variables:
        date = now()
        date_text = f'{_MONTHS[date.month - 1]} {date.day}, {date.year}'
    return Phrases(rules, date_text=date_text, clipboard=clip)
