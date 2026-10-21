"""Deterministic Core punctuation/layout formatting with literal-text preservation."""

from bisect import bisect_left, bisect_right
import json
from pathlib import Path
import re
import unicodedata

from spellings import _lower, _space, _word
from vendor.grapheme import graphemes

_TABLE = json.loads(Path(__file__).with_name('cleanup-commands.json').read_text())
_GUARDS = {name: frozenset(values) for name, values in _TABLE['guards'].items()}
_ENTRIES = {}
for _entry in sorted(_TABLE['commands'], key=lambda entry: -len(entry['words'])):
    _ENTRIES.setdefault(_entry['words'][0], []).append(_entry)
_NEWLINES = frozenset('\n\r\v\f\x85\u2028\u2029')
_ABSORB = frozenset(',. ;:!?…'.replace(' ', ''))
_LAYOUT_ABSORB = frozenset(',.;:')
_LITERAL = re.compile(
    r'```[\s\S]*?(?:```|\Z)|`[^`\r\n]*(?:`|\Z)|'
    r'"(?:\\.|[^"\\])*"|“[^”]*”|‘(?:[^’]|(?<=\w)’(?=\w))*’|'
    r"(?<!\w)'(?:\\.|[^'\\\r\n]|(?<=\w)'(?=\w))*'(?!\w)"
)
MAX_TEXT_BYTES = 2 * 1024 * 1024


def _newline(char):
    return char[0] in _NEWLINES


def _only_spaces(chars, start, end):
    return start <= end and all(char in (' ', '\t') for char in chars[start:end])


def _words(chars):
    result, i = [], 0
    lower = [_lower(char) for char in chars]
    while i < len(chars):
        if not _word(chars[i]):
            i += 1
            continue
        end = i + 1
        while end < len(chars):
            if _word(chars[end]):
                end += 1
            elif chars[end] in ("'", '’') and end + 1 < len(chars) and _word(chars[end + 1]):
                end += 2
            else:
                break
        result.append((i, end, ''.join(lower[i:end])))
        i = end
    return result


def _literal_mask(chars):
    text = ''.join(chars)
    offsets = [0]
    for char in chars:
        offsets.append(offsets[-1] + len(char))
    mask = [False] * len(chars)
    def mark(start, end):
        first = bisect_right(offsets, start) - 1
        last = bisect_left(offsets, end)
        for index in range(first, last):
            mask[index] = True
    for match in _LITERAL.finditer(text):
        mark(match.start(), match.end())
    for match in re.finditer(r'\S+', text):
        value = match.group()
        if (any(part in value for part in ('/', '\\', '@', '_', '=', '::', '->')) or
                value.startswith('--') or re.search(r'\w\.\w', value)):
            mark(match.start(), match.end())
    return mask


def _cased(char):
    return any(unit.isupper() or unit.islower() or unicodedata.category(unit) == 'Lt' for unit in char)


def _is_upper(char):
    return _cased(char) and unicodedata.normalize('NFC', char.upper()) == unicodedata.normalize('NFC', char)


def _is_lower(char):
    return _cased(char) and unicodedata.normalize('NFC', char.lower()) == unicodedata.normalize('NFC', char)


def _capitalized(chars, word, protected):
    start, end, _ = word
    if protected and any(protected[start:end]):
        return None
    first = chars[start]
    if not _word(first) or not _is_lower(first) or any(_is_upper(char) for char in chars[start + 1:end]):
        return None
    upper = first.upper()
    return upper + ''.join(chars[start + 1:end]) if upper != first else None


def _rewrite(chars, spans):
    output, cursor = [], 0
    for start, end, cut_start, cut_end, replacement in sorted(spans, key=lambda span: (span[0], span[1])):
        if start < cursor or cut_end > len(chars) or cut_start > start or cut_end < end:
            continue
        output.extend((''.join(chars[cursor:max(cut_start, cursor)]), replacement))
        cursor = cut_end
    output.append(''.join(chars[cursor:]))
    return ''.join(output)


class _Match:
    def __init__(self, entry, first, last):
        self.entry, self.first, self.last = entry, first, last


class _ListState:
    def __init__(self):
        self.close()

    def close(self):
        self.kind, self.number = None, 0

    def applies(self, match, words):
        action, following = match.entry['list'], match.last + 1
        has_text = following < len(words)
        if action == 'newBullet':
            return True
        if action == 'bullet':
            return has_text and (len(match.entry['words']) == 2 or words[following][2] not in _GUARDS['bulletFollowers'])
        if action == 'numbered':
            return has_text
        if action == 'nextItem':
            return self.kind is not None and has_text
        if action == 'next':
            return (self.kind is not None and has_text and words[following][2] not in _GUARDS['nextFollowers'] and
                    (match.first == 0 or words[match.first - 1][2] not in _GUARDS['nextPrepositions']))
        return self.kind is not None

    def apply(self, action, at_start, has_text):
        lead = '' if at_start else '\n'
        if action in ('bullet', 'newBullet'):
            self.kind, self.number = 'bullet', 0
            return lead + '- '
        if action == 'numbered':
            self.kind, self.number = 'numbered', 1
            return lead + '1. '
        if action in ('nextItem', 'next'):
            if self.kind == 'numbered':
                self.number += 1
                return lead + str(self.number) + '. '
            return lead + '- '
        self.close()
        return '' if at_start or not has_text else '\n'


def _at_line_start(chars, start, accepted, match):
    index = start - 1
    while index >= 0 and chars[index] in (' ', '\t'):
        index -= 1
    if index < 0 or _newline(chars[index]):
        return True
    if accepted and accepted[-1][0].last + 1 == match.first:
        previous, _, _, replacement = accepted[-1]
        value = previous.entry['output'] if replacement is None else replacement
        return value.endswith('\n') or (previous.entry['list'] is not None and value.endswith(('- ', '. ')))
    return False


def _clause_end(chars, words, match, end, raw_starts):
    if end > words[match.last][1]:
        return True
    index = end
    while index < len(chars) and chars[index] in (' ', '\t'):
        index += 1
    if index >= len(chars) or _newline(chars[index]) or chars[index] in ')]}"”' or not _word(chars[index]):
        return True
    following = match.last + 1
    if following >= len(words) or words[following][0] != index:
        return False
    if _is_upper(chars[index]):
        return True
    other = raw_starts.get(following)
    return (other is not None and other.entry['style'] != 'clauseEnd' and
            other.entry['list'] not in ('nextItem', 'next', 'end'))


def spoken_commands(text, protected=None):
    chars = list(graphemes(text))
    words, raw, index = _words(chars), [], 0
    while index < len(words):
        for entry in _ENTRIES.get(words[index][2], ()):
            end = index + len(entry['words'])
            if end > len(words):
                continue
            if any(words[index + offset][2] != value for offset, value in enumerate(entry['words'])):
                continue
            if any(not _only_spaces(chars, words[i - 1][1], words[i][0]) or words[i - 1][1] == words[i][0]
                   for i in range(index + 1, end)):
                continue
            if protected and any(protected[words[index][0]:words[end - 1][1]]):
                continue
            raw.append(_Match(entry, index, end - 1))
            index = end
            break
        else:
            index += 1
    if not raw:
        return text
    raw_starts = {match.first: match for match in raw}
    accepted, command_starts, state = [], set(), _ListState()
    for match in raw:
        entry = match.entry
        first, last = words[match.first], words[match.last]
        if match.first > 0:
            previous = words[match.first - 1]
            signals = _GUARDS['layoutNounSignals' if entry['style'] == 'layout' else 'nounSignals']
            if previous[1] < first[0] and _only_spaces(chars, previous[1], first[0]) and previous[2] in signals:
                continue
        if entry['style'] == 'punctuation':
            if match.first > 0 and words[match.first - 1][2] in _GUARDS['punctuationVerbs'] and _only_spaces(chars, words[match.first - 1][1], first[0]):
                continue
            following = match.last + 1
            if following < len(words) and words[following][2] in _GUARDS['punctuationFollowers'] and _only_spaces(chars, last[1], words[following][0]):
                continue
        if entry['list'] is not None and not state.applies(match, words):
            continue
        start, end = first[0], last[1]
        if entry['attach'] == 'previous':
            while end < len(chars) and chars[end] in _ABSORB:
                end += 1
        elif entry['attach'] == 'newline':
            while end < len(chars) and chars[end] in _LAYOUT_ABSORB:
                end += 1
        if entry['style'] == 'layout':
            if accepted:
                previous, old_start, _, _ = accepted[-1]
                if previous.entry['style'] == 'punctuation' and previous.entry['output'] in (',', ';', ':') and previous.last + 1 == match.first:
                    start = old_start
                    command_starts.remove(previous.first)
                    accepted.pop()
            index = start - 1
            while index >= 0 and chars[index] in (' ', '\t'):
                index -= 1
            if index >= (accepted[-1][2] if accepted else 0) and chars[index] in (',', ';', ':') and (not protected or not protected[index]):
                start = index
        replacement = None
        if entry['list'] is not None:
            index = start - 1
            while index >= 0 and chars[index] in (' ', '\t'):
                index -= 1
            if index >= 0 and chars[index] == ',' and (not protected or not protected[index]):
                start = index
            replacement = state.apply(entry['list'], _at_line_start(chars, start, accepted, match), match.last + 1 < len(words))
        elif entry['attach'] == 'newline' and entry['output'] == '\n\n':
            state.close()
        if entry['style'] == 'clauseEnd' and not _clause_end(chars, words, match, end, raw_starts):
            continue
        if entry['attach'] == 'previous':
            index = start - 1
            while index >= 0 and chars[index] in (' ', '\t'):
                index -= 1
            if index >= 0 and chars[index] in (',', entry['output']) and (not protected or not protected[index]):
                start = index
        accepted.append((match, start, end, replacement))
        command_starts.add(match.first)
    spans, last_cut_end = [], 0
    for match, start, end, list_replacement in accepted:
        entry = match.entry
        cut_start, cut_end = start, end
        replacement = entry['output'] if list_replacement is None else list_replacement
        if entry['attach'] == 'previous':
            while cut_start > last_cut_end and chars[cut_start - 1] in (' ', '\t'):
                cut_start -= 1
            if cut_end < len(chars) and _word(chars[cut_end]):
                replacement += ' '
        elif entry['attach'] in ('newline', 'both', 'spaced'):
            while cut_start > last_cut_end and chars[cut_start - 1] in (' ', '\t'):
                cut_start -= 1
            while cut_end < len(chars) and chars[cut_end] in (' ', '\t'):
                cut_end += 1
        elif entry['attach'] == 'next':
            while cut_end < len(chars) and chars[cut_end] in (' ', '\t'):
                cut_end += 1
        spans.append((start, end, cut_start, cut_end, replacement))
        last_cut_end = cut_end
        following = match.last + 1
        if entry['endsSentence'] and following < len(words) and following not in command_starts:
            word = words[following]
            if all(_space(char) for char in chars[end:word[0]]):
                capital = _capitalized(chars, word, protected)
                if capital is not None:
                    spans.append((word[0], word[1], word[0], word[1], capital))
                    last_cut_end = max(last_cut_end, word[1])
    return _rewrite(chars, spans)


def _suppress_space(chars, index, previous):
    if previous == '(':
        return True
    char = chars[index]
    following = chars[index + 1] if index + 1 < len(chars) else None
    if char in (',', '?', '!', ')', '…'):
        return True
    if char in (';', ':'):
        if following in (')', '('):
            return False
        return not (char == ':' and following is not None and _word(following))
    if char == '.':
        if following is not None and _word(following):
            return False
        return not (following == '/' or (following == '.' and index + 2 < len(chars) and chars[index + 2] == '/'))
    return False


def whitespace(text, protected=None):
    chars = list(graphemes(text))
    output, pending, index = [], False, 0
    while index < len(chars):
        char = chars[index]
        if protected and protected[index]:
            if pending and output and not _newline(output[-1]) and not _suppress_space(chars, index, output[-1]):
                output.append(' ')
            pending = False
            while index < len(chars) and protected[index]:
                output.append(chars[index])
                index += 1
            continue
        if _newline(char):
            pending = False
            output.append(char)
        elif _space(char):
            pending = True
        else:
            if pending:
                if output and not _newline(output[-1]) and not _suppress_space(chars, index, output[-1]):
                    output.append(' ')
                pending = False
            output.append(char)
        index += 1
    return ''.join(output)


class BasicCleanup:
    def __init__(self, mode='off', styles=None):
        if not isinstance(mode, str) or mode not in ('off', 'basic'):
            raise ValueError('cleanup must be off or basic')
        self.mode = mode
        if styles is not None:
            import styles as style_contexts
            styles = style_contexts.validate(styles)
            if style_contexts.to_config(styles) is None:
                styles = None
        self.styles = styles

    def apply(self, text, target=None):
        """Basic cleanup. `target` is the window snapshot captured at record start; with a `styles` block it picks the
        context whose cleanup level and tone apply (see styles.py). Without one, behavior is unchanged."""
        mode, tone_name = self.mode, None
        if self.styles is not None:
            import styles as style_contexts
            choice = style_contexts.resolve(self.styles, target.get('class') if isinstance(target, dict) else None)
            tone_name = choice['tone']
            if choice['cleanup'] is not None:
                mode = 'off' if choice['cleanup'] == 'off' else 'basic'
        if mode == 'off':
            return text
        if len(text.encode('utf-8')) > MAX_TEXT_BYTES:
            raise ValueError('Cleanup text exceeds its input limit')
        chars = list(graphemes(text))
        text = spoken_commands(text, _literal_mask(chars))
        chars = list(graphemes(text))
        protected = _literal_mask(chars)
        first = next((i for i, char in enumerate(chars) if not _space(char)), None)
        if first is not None:
            word = next((word for word in _words(chars) if word[0] == first), None)
            if word is not None:
                capital = _capitalized(chars, word, protected)
                if capital is not None:
                    text = _rewrite(chars, [(word[0], word[1], word[0], word[1], capital)])
        chars = list(graphemes(text))
        result = whitespace(text, _literal_mask(chars))
        if tone_name:
            import tone
            result = tone.apply(result, tone_name)
        if len(result.encode('utf-8')) > MAX_TEXT_BYTES:
            raise ValueError('Cleanup text exceeds its output limit')
        return result
