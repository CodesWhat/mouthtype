"""Explicit saved-spelling replacements, compatible with Mac dictionary libraries."""

from bisect import bisect_right
import json
import os
from pathlib import Path
import stat
import unicodedata

from vendor.grapheme import graphemes

# Matching adapted from Mouthtype Core / Parrot (0eb4708), MIT,
# Copyright (c) 2026 Humanitas Labs. See THIRD_PARTY_NOTICES.md.
_PROPERTIES = json.loads(Path(__file__).with_name('spelling-unicode.json').read_text())
_WORD_RANGES = sorted(_PROPERTIES['alphabetic'] + _PROPERTIES['number'])
# Numeric and alphabetic ranges overlap. Merge them before binary searching.
_MERGED = []
for _start, _end in _WORD_RANGES:
    if _MERGED and _start <= _MERGED[-1][1] + 1:
        _MERGED[-1][1] = max(_end, _MERGED[-1][1])
    else:
        _MERGED.append([_start, _end])
_STARTS = [entry[0] for entry in _MERGED]
_WHITESPACE = frozenset('\t\n\v\f\r \x85\xa0\u1680\u2028\u2029\u202f\u205f\u3000' +
                        ''.join(chr(i) for i in range(0x2000, 0x200b)))
MAX_LIBRARY_BYTES = 4 * 1024 * 1024


def _word(char):
    if char == '_':
        return True
    point = ord(char[0])
    index = bisect_right(_STARTS, point) - 1
    return index >= 0 and point <= _MERGED[index][1]


def _space(char):
    return char[0] in _WHITESPACE


def _lower(char):
    lowered = char.lower()
    value = lowered if len(list(graphemes(lowered))) == 1 else char
    return unicodedata.normalize('NFC', value)


def _collapse(text):
    parts, pending = [], False
    for char in graphemes(text):
        if _space(char):
            pending = bool(parts)
        else:
            if pending:
                parts.append(' ')
            parts.append(char)
            pending = False
    return parts


class Spellings:
    def __init__(self, rules):
        self.buckets = {}
        seen = set()
        for index, rule in enumerate(rules):
            if not rule['written']:
                continue
            chars = tuple(_lower(char) for char in _collapse(rule['heard']))
            if not chars or chars in seen:
                continue
            seen.add(chars)
            self.buckets.setdefault(chars[0], []).append((chars, index, rule['written']))
        for candidates in self.buckets.values():
            candidates.sort(key=lambda entry: (-len(entry[0]), entry[1]))

    def apply(self, text):
        if not self.buckets or not text:
            return text
        chars = list(graphemes(text))
        lower = [_lower(char) for char in chars]
        output, cursor, i = [], 0, 0
        while i < len(chars):
            if i and _word(chars[i - 1]):
                i += 1
                continue
            for pattern, _, written in self.buckets.get(lower[i], ()):
                end = i
                for char in pattern:
                    if char == ' ':
                        if end >= len(chars) or not _space(chars[end]):
                            break
                        while end < len(chars) and _space(chars[end]):
                            end += 1
                    elif end < len(chars) and lower[end] == char:
                        end += 1
                    else:
                        break
                else:
                    if end < len(chars) and _word(chars[end]):
                        continue
                    output.extend((''.join(chars[cursor:i]), written))
                    cursor, i = end, end
                    break
            else:
                i += 1
        output.append(''.join(chars[cursor:]))
        return ''.join(output)


def load_spellings(path):
    if path is None:
        return Spellings([])
    # Nonblocking open rejects a FIFO/device without waiting for a writer before admission.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError('Dictionary must be a regular JSON file')
        raw = source.read(MAX_LIBRARY_BYTES + 1)
    if len(raw) > MAX_LIBRARY_BYTES:
        raise ValueError('Dictionary exceeds the 4 MiB limit')
    def invalid_constant(_):
        raise ValueError('Dictionary must contain valid JSON')
    try:
        rules = json.loads(raw.decode('utf-8'), parse_constant=invalid_constant)
    except RecursionError:
        raise ValueError('Dictionary nesting exceeds the decoder limit') from None
    if not isinstance(rules, list):
        raise ValueError('Dictionary must contain an entry array')
    for rule in rules:
        if (not isinstance(rule, dict) or not isinstance(rule.get('heard'), str) or
                not isinstance(rule.get('written'), str) or
                (rule.get('starred') is not None and type(rule['starred']) is not bool)):
            raise ValueError('Invalid dictionary entry')
        rule['heard'].encode('utf-8')
        rule['written'].encode('utf-8')
    return Spellings(rules)
