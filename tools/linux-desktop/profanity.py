"""Formal-tone swearing softening: a port of Core's ProfanityRemover with its word lists and rules.

The one platform difference is part-of-speech tagging. Core asks Apple's NLTagger for the lexical class of the word
after an intensifier (and in two other spots); Linux has no such tagger in the standard library, so
`lexical_class` below answers from closed word classes and suffix rules and is checked against NLTagger by
check_tone.py. English only.
"""

import unicodedata

from cleanup import _is_lower, _is_upper, _newline
from lexical import lexical_class
from spellings import _collapse, _lower, _space, _word
from vendor.grapheme import graphemes

WORDS = frozenset((
    'fuck', 'fucks', 'fucked', 'fucking', 'fucker', 'fuckers', 'motherfucker', 'motherfuckers', 'motherfucking',
    'shit', 'shits', 'shitting', 'shitty', 'bullshit',
    'damn', 'damned', 'goddamn', 'goddamned', 'goddamnit', 'dammit',
    'ass', 'asses', 'asshole', 'assholes',
    'bitch', 'bitches', 'bitched', 'bitching', 'bitchin',
    'crap', 'crappy',
))
AFTER_THE = frozenset(('fuck', 'hell'))
DAMN_WORDS = frozenset(('damn', 'damned', 'goddamn', 'goddamned'))
STANDALONE = frozenset(('dammit', 'goddamnit'))
INTERJECTIONS = frozenset(('fuck', 'fucking', 'motherfucking', 'shit', 'bullshit', 'crap', 'damn', 'damned', 'goddamn',
                           'goddamned'))
INTENSIFIERS = frozenset(('fucking', 'motherfucking', 'damn', 'goddamn'))
GERUND_TRIGGERS = frozenset(('stop', 'stopped', 'stopping', 'quit', 'quitting', 'keep', 'keeps', 'kept', 'keeping',
                             'start', 'started', 'starting'))
AUXILIARIES = frozenset(('is', 'are', 'was', 'were', 'am', 'be', 'been', 'being', 'has', 'have', 'had', 'will', 'would',
                         'can', 'could', 'should', 'might', 'must', 'did', 'does', 'do', "'s", "'re", "'m"))
SWAPS = {
    'asshole': 'jerk', 'assholes': 'jerks', 'bitch': 'jerk', 'bitches': 'jerks', 'fucker': 'jerk', 'fuckers': 'jerks',
    'motherfucker': 'jerk', 'motherfuckers': 'jerks', 'bullshit': 'nonsense', 'shitty': 'bad', 'crappy': 'bad',
    'crap': 'junk', 'bitching': 'complaining', 'ass': 'butt', 'asses': 'butts',
}
MESS_FORMS = {'fuck': 'mess', 'fucks': 'messes', 'fucked': 'messed', 'fucking': 'messing'}
CHEAT_FORMS = {'fuck': 'cheat', 'fucks': 'cheats', 'fucked': 'cheated', 'fucking': 'cheating'}
SLEEP_FORMS = {'fuck': 'sleep with', 'fucks': 'sleeps with', 'fucked': 'slept with', 'fucking': 'sleeping with'}
MESS_UP_FORMS = {'fuck': 'mess up', 'fucks': 'messes up', 'fucked': 'messed up', 'fucking': 'messing up'}
PERSON_OBJECTS = frozenset(('her', 'him', 'them', 'me', 'us', 'you'))
TALK_VERBS = frozenset(('talk', 'talks', 'talked', 'talking'))
VERB_LEADERS = frozenset((
    'i', 'we', 'they', 'to', 'will', 'would', 'can', 'could', 'should', 'might', 'must', 'may', 'shall', 'not', 'never',
    "don't", "doesn't", "didn't", "won't", "can't", "couldn't", "wouldn't", "shouldn't", "i'll", "we'll", "they'll",
    "you'll", "he'll", "she'll", "it'll", "i'd", "we'd", "they'd", "you'd", "he'd", "she'd",
))
NOUN_LEADERS = frozenset((
    'a', 'an', 'the', 'this', 'that', 'these', 'those', 'my', 'your', 'his', 'her', 'its', 'our', 'their', 'some', 'any',
    'no', 'each', 'every', 'another', 'such', 'what', 'whose', 'many', 'few', 'several', 'more', 'most', 'other', 'of',
    'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'like', 'you', 'stupid',
))
IDIOM_COUNTS = frozenset(('a', 'one', 'two', 'three', 'no', 'any'))
GIVE_VERBS = frozenset(('give', 'gives', 'gave', 'giving', 'given'))
FORGET_OBJECTS = frozenset(('the', 'those', 'these', 'my', 'his', 'her', 'their', 'our', 'your', 'him', 'them', 'everything',
                            'everyone', 'everybody'))
PHRASAL_STOPS = frozenset(('and', 'or', 'but', 'to', 'of', 'in', 'on', 'at', 'for', 'with', 'up', 'around', 'off', 'out',
                           'so', 'if', 'because'))
DROPPED_ADJECTIVES = frozenset(('damned', 'goddamned'))
CONJUNCTIONS = ('and', 'but', 'so', 'or', 'because', 'that', 'if', 'then', 'when', 'while')
BLOCKERS = frozenset('/\\@_`-#$')
PUNCTUATION = ',.!?…;:'
SENTENCE_END = '.!?…'
CONTRACTED_SUBJECTS = frozenset(
    [subject + suffix for subject in ('it', 'he', 'she', 'that', 'there', 'here', 'what', 'who', 'let')
     for suffix in ("'s", '’s', "'ll", '’ll', "'d", '’d')] +
    [subject + suffix.replace("'", mark) for subject in ('i', 'you', 'we', 'they')
     for suffix in ("'m", "'re", "'ve", "'ll", "'d") for mark in ("'", '’')])


def starts_with_vowel_sound(word):
    w = word.lower()
    if any(w.startswith(prefix) for prefix in ('hour', 'honest', 'honor', 'honour', 'heir')):
        return True
    if not w or w[0] not in 'aeiou':
        return False
    if any(w.startswith(prefix) for prefix in ('eu', 'once', 'use', 'usu', 'uti', 'uto', 'ubiq', 'unanim')):
        return False
    if w.startswith('one'):
        return w.startswith('onerous')
    if w.startswith('uni'):
        return any(w.startswith(prefix) for prefix in ('unim', 'unin', 'unid'))
    return True


def _has(characters, char):
    return len(char) == 1 and char in characters


def _is_space(char):
    return char in (' ', '\t')


def _only_spaces(chars, start, end):
    return start <= end and all(_is_space(char) for char in chars[start:end])


def _upper_first(text):
    return text[:1].upper() + text[1:] if text else text


def _is_letter(char):
    return unicodedata.category(char[0]).startswith('L')


def _is_number(char):
    return char[0].isnumeric()


class _Word:
    __slots__ = ('start', 'end', 'lower')

    def __init__(self, start, end, lower):
        self.start, self.end, self.lower = start, end, lower


def _scan_words(chars):
    result, i, n = [], 0, len(chars)
    lower = [_lower(char) for char in chars]
    while i < n:
        if not _word(chars[i]):
            i += 1
            continue
        j = i + 1
        while j < n:
            if _word(chars[j]):
                j += 1
            elif chars[j] in ("'", '’') and j + 1 < n and _word(chars[j + 1]):
                j += 2
            else:
                break
        result.append(_Word(i, j, ''.join(lower[i:j])))
        i = j
    return result, lower


def _capitalized(chars, word):
    """Core's TextScan.capitalized: the word with its first letter raised, or None when that doesn't apply."""
    first = chars[word.start]
    if not _is_letter(first) or not _is_lower(first):
        return None
    if any(_is_upper(char) for char in chars[word.start + 1:word.end]):
        return None
    up = first.upper()
    return None if up == first else up + ''.join(chars[word.start + 1:word.end])


class _Span:
    __slots__ = ('start', 'end', 'cut_start', 'cut_end', 'replacement')

    def __init__(self, start, end, replacement, cut=None):
        self.start, self.end, self.replacement = start, end, replacement
        self.cut_start, self.cut_end = cut if cut is not None else (start, end)


def _rewrite(chars, spans):
    """Core's SpanRewriter.apply. Returns the text and how many spans changed anything."""
    output, cursor, edits = [], 0, 0
    for span in sorted(spans, key=lambda item: (item.start, item.end)):
        if (span.start < cursor or span.cut_end > len(chars) or span.cut_start > span.start or
                span.cut_end < span.end):
            continue
        output.append(''.join(chars[cursor:max(span.cut_start, cursor)]))
        output.append(span.replacement)
        cursor = span.cut_end
        if ''.join(chars[span.start:span.end]) != span.replacement.strip(' \t'):
            edits += 1
    output.append(''.join(chars[cursor:]))
    return ''.join(output), edits


def _original_offsets(spans, count):
    mapping, cursor = [], 0
    for span in sorted(spans, key=lambda item: (item.start, item.end)):
        if (span.start < cursor or span.cut_end > count or span.cut_start > span.start or span.cut_end < span.end):
            continue
        cut_start = max(span.cut_start, cursor)
        mapping.extend(range(cursor, cut_start))
        for i in range(len(list(graphemes(span.replacement)))):
            mapping.append(min(span.start + i, span.cut_end - 1))
        cursor = span.cut_end
    mapping.extend(range(cursor, count))
    return mapping


class _Matcher:
    """Core's PhraseMatcher for one phrase: whole-word, case-insensitive, whitespace runs match any whitespace."""

    def __init__(self, phrase):
        self.pattern = tuple(_lower(char) for char in _collapse(phrase))

    def matches(self, chars, lower):
        if not self.pattern:
            return []
        result, i, n = [], 0, len(chars)
        while i < n:
            if i > 0 and _word(chars[i - 1]):
                i += 1
                continue
            end = self._match(chars, lower, i)
            if end is None:
                i += 1
            else:
                result.append((i, end))
                i = end
        return result

    def _match(self, chars, lower, start):
        n, j = len(chars), start
        for pc in self.pattern:
            if pc == ' ':
                if j >= n or not _space(chars[j]):
                    return None
                while j < n and _space(chars[j]):
                    j += 1
            else:
                if j >= n or lower[j] != pc:
                    return None
                j += 1
        if j < n and _word(chars[j]):
            return None
        return j


class _Scan:
    def __init__(self, chars, protected_words, written_forms, protected_phrases):
        self.chars = chars
        self.n = len(chars)
        self.words, lower = _scan_words(chars)
        self.protected_words = protected_words
        self.written_forms = written_forms
        self.removed = [False] * self.n
        self.spans = []
        self.last_cut_end = 0
        self._classes = {}
        covered = [False] * self.n
        for phrase in set(protected_phrases):
            for start, end in _Matcher(phrase).matches(chars, lower):
                for i in range(start, end):
                    covered[i] = True
        self.in_protected_phrase = covered

    def lexical_class(self, k):
        if k not in self._classes:
            self._classes[k] = lexical_class([word.lower for word in self.words], k)
        return self._classes[k]

    # Finding

    def run(self):
        units = self.find_units()
        starts = {unit[0] for unit in units}
        for unit in units:
            self.remove(unit, starts)

    def is_profane(self, k):
        w = self.words[k]
        return (w.lower in WORDS and w.lower not in self.protected_words and not self.is_protected(w) and
                not self.inside_token(w))

    def is_protected(self, w):
        return any(self.in_protected_phrase[w.start:w.end])

    def inside_token(self, w):
        chars, n = self.chars, self.n
        if w.start > 0:
            c = chars[w.start - 1]
            if _has(BLOCKERS, c):
                return True
            if c == '.' and w.start > 1 and _word(chars[w.start - 2]):
                return True
        if w.end < n:
            c = chars[w.end]
            if _has(BLOCKERS, c):
                return True
            if c == '.' and w.end + 1 < n and _word(chars[w.end + 1]):
                return True
        return False

    def is_the_hell(self, k):
        words = self.words
        if not (k > 0 and words[k].lower in AFTER_THE and words[k - 1].lower == 'the' and
                words[k].lower not in self.protected_words and not self.is_protected(words[k]) and
                not self.is_protected(words[k - 1]) and not self.inside_token(words[k]) and
                not self.inside_token(words[k - 1])):
            return False
        return all(_is_space(char) for char in self.chars[words[k - 1].end:words[k].start]) and \
            words[k].start > words[k - 1].end

    def adjacent(self, k):
        words = self.words
        return (k + 1 < len(words) and words[k].end < words[k + 1].start and
                _only_spaces(self.chars, words[k].end, words[k + 1].start))

    @staticmethod
    def is_punctuation(char):
        return _has(PUNCTUATION, char)

    def find_units(self):
        units, words = [], self.words

        def add(first, last):
            if units and units[-1][1] >= first:
                return
            units.append((first, last))

        k = 0
        while k < len(words):
            if self.is_the_hell(k):
                add(k - 1, k)
                k += 1
                continue
            last = self.holy_end(k)
            if last is None:
                last = self.dismissive_end(k)
            if last is not None:
                add(k, last)
                k = last + 1
                continue
            if not self.is_profane(k):
                k += 1
                continue
            lower = words[k].lower
            if lower in STANDALONE:
                add(k, k)
                k += 1
                continue
            if lower in DAMN_WORDS and self.adjacent(k) and words[k + 1].lower == 'it':
                after = words[k + 1].end
                it_is_protected = self.is_protected(words[k + 1]) or 'it' in self.protected_words
                if not it_is_protected and (after >= self.n or self.is_punctuation(self.chars[after]) or
                                            self.is_clause_end(after)):
                    add(k, k + 1)
                k += 2
                continue
            last = self.interjection_end(k)
            if last is not None:
                add(k, last)
                k = last + 1
                continue
            last = self.intensifier_end(k)
            if last is not None:
                add(k, last)
                k = last + 1
                continue
            k += 1
        return units

    def is_free(self, k):
        word = self.words[k]
        return word.lower not in self.protected_words and not self.is_protected(word) and not self.inside_token(word)

    def holy_end(self, k):
        words = self.words
        if (words[k].lower == 'holy' and self.is_free(k) and self.adjacent(k) and k + 1 < len(words) and
                self.is_profane(k + 1) and words[k + 1].lower in ('shit', 'crap', 'fuck')):
            return k + 1
        return None

    def dismissive_end(self, k):
        words, chars, n = self.words, self.chars, self.n
        verb = words[k].lower
        if not (verb in ('fuck', 'screw') and self.is_free(k) and self.adjacent(k) and self.is_free(k + 1)):
            return None
        target = words[k + 1].lower
        if target not in ('you', 'yourself', 'off', 'that', 'this', 'it', 'me'):
            return None
        if verb == 'screw' or target == 'me':
            j = words[k].start - 1
            while j >= 0 and _is_space(chars[j]):
                j -= 1
            if not (self.sentence_start(words[k].start) or (j >= 0 and chars[j] == ',')):
                return None
        after = words[k + 1].end
        if after >= n or self.is_punctuation(chars[after]) or self.is_clause_end(after):
            return k + 1
        if (target == 'it' and self.sentence_start(words[k].start) and self.adjacent(k + 1) and k + 2 < len(words) and
                (self.starts_clause(k + 2) or words[k + 2].lower in ('i', 'we', 'they', 'he', 'she'))):
            return k + 1
        return None

    def interjection_end(self, k):
        words, chars, n = self.words, self.chars, self.n
        if words[k].lower not in INTERJECTIONS:
            return None
        last = k
        while self.adjacent(last) and self.is_profane(last + 1) and words[last + 1].lower in INTERJECTIONS:
            last += 1
        s, e = words[k].start, words[last].end
        j = s - 1
        while j >= 0 and _is_space(chars[j]):
            j -= 1
        if not ((j >= 0 and chars[j] == ',') or self.sentence_start(s)):
            return None
        if e >= n or self.is_punctuation(chars[e]) or self.is_clause_end(e):
            return last
        if not (self.sentence_start(s) and self.adjacent(last) and self.starts_clause(last + 1)):
            return None
        return last

    def starts_clause(self, k):
        words = self.words
        if k >= len(words):
            return False
        if words[k].lower in CONTRACTED_SUBJECTS:
            return True
        if not (k + 1 < len(words) and self.adjacent(k)):
            return False
        first = self.lexical_class(k)
        if first not in ('pronoun', 'determiner'):
            return False
        return self.lexical_class(k + 1) == 'verb'

    def intensifier_end(self, k):
        words = self.words

        def modifies(i):
            return (self.is_profane(i) and words[i].lower in INTENSIFIERS and self.adjacent(i) and
                    not (words[i].lower in DAMN_WORDS and words[i + 1].lower == 'it'))

        if not (modifies(k) and self.modifies_next(k)):
            return None
        last = k
        while last + 1 < len(words) and self.adjacent(last) and modifies(last + 1) and self.modifies_next(last + 1):
            last += 1
        return last

    def modifies_next(self, k):
        words = self.words
        if k + 1 >= len(words):
            return False
        following = self.lexical_class(k + 1)
        if following is None:
            return False
        previous = words[k - 1].lower if k > 0 and self.adjacent(k - 1) else None
        if previous is not None and previous in GERUND_TRIGGERS:
            return False
        if following in ('adjective', 'adverb', 'interjection', 'noun'):
            return True
        if following == 'verb':
            return previous in AUXILIARIES if previous is not None else False
        return False

    # Swapping

    def matching_case(self, replacement, w):
        if _is_upper(self.chars[w.start]) and replacement:
            return replacement[0].upper() + replacement[1:]
        return replacement

    def previous(self, k):
        if k > 0 and self.adjacent(k - 1):
            return self.words[k - 1].lower.replace('’', "'")
        return None

    def is_verb_position(self, k, third_person):
        prev = self.previous(k)
        if prev is None:
            return False
        if prev == 'you':
            return (not third_person) and self.adjacent(k)
        if prev in VERB_LEADERS:
            return True
        if prev in NOUN_LEADERS:
            return False
        if not third_person:
            return False
        return self.lexical_class(k - 1) in ('noun', 'pronoun')

    def is_give_idiom(self, k):
        prev = self.previous(k)
        if prev is None or prev not in IDIOM_COUNTS or not (k > 1 and self.adjacent(k - 2)):
            return False
        return self.words[k - 2].lower in GIVE_VERBS

    def is_forget_object(self, k):
        if not (self.adjacent(k) and self.is_free(k + 1) and
                (self.words[k + 1].lower in FORGET_OBJECTS or self.is_name(k + 1))):
            return False
        return self.previous(k) is None

    def is_name(self, k):
        words = self.words
        return (k < len(words) and words[k].lower != 'i' and _is_upper(self.chars[words[k].start]) and
                not self.is_acronym(words[k]))

    def is_acronym(self, w):
        return w.end - w.start > 1 and all(_is_upper(char) for char in self.chars[w.start:w.end])

    def has_split_up(self, k):
        return self.split_particle(k, 'up') is not None

    def split_particle(self, k, particle):
        words = self.words
        for length in range(1, 4):
            at = k + length + 1
            if not (at < len(words) and all(self.adjacent(i) for i in range(k, at))):
                return None
            if any(words[i].lower in PHRASAL_STOPS for i in range(k + 1, k + length + 1)):
                return None
            if words[at].lower == particle and self.is_free(at):
                return at
        return None

    def find_swaps(self):
        words, chars, n = self.words, self.chars, self.n
        spans, capitalise, handled = [], set(), set()

        def cased(k, text):
            text = self.matching_case(text, words[k])
            if k in capitalise and text:
                text = text[0].upper() + text[1:]
            return text

        def replace(k, with_, end=None):
            stop = words[k].end if end is None else end
            spans.append(_Span(words[k].start, stop, cased(k, with_)))
            handled.add(k)

        def drop(k):
            w = words[k]
            if self.adjacent(k):
                spans.append(_Span(w.start, w.end, '', cut=(w.start, words[k + 1].start)))
                if (k in capitalise or self.sentence_start(w.start)) and not self.keeps_case(words[k + 1]):
                    capitalise.add(k + 1)
            else:
                back = w.start
                while back > 0 and _is_space(chars[back - 1]):
                    back -= 1
                spans.append(_Span(w.start, w.end, '', cut=(back, w.end)))
            handled.add(k)

        def next_is(k, options):
            return self.adjacent(k) and words[k + 1].lower in options and self.is_free(k + 1)

        k = 0
        while k < len(words):
            lower = words[k].lower
            if lower == 'pissed' and self.is_free(k) and next_is(k, ('off',)):
                spans.append(_Span(words[k].start, words[k + 1].end, self.matching_case('annoyed', words[k])))
                handled.add(k)
                k += 2
                continue
            if lower == 'screwing' and self.is_free(k) and next_is(k, ('around',)):
                replace(k, 'messing')
                k += 1
                continue
            if lower not in WORDS or not self.is_profane(k):
                k += 1
                continue
            if lower in MESS_FORMS and (next_is(k, ('up', 'around', 'with')) or self.has_split_up(k)):
                replace(k, MESS_FORMS[lower])
            elif lower == 'fuck' and next_is(k, ('this', 'that')) and self.adjacent(k + 1):
                replace(k, 'forget')
            elif (lower == 'ass' and k >= 3 and self.adjacent(k - 1) and self.adjacent(k - 2) and self.adjacent(k - 3) and
                  words[k - 1].lower == 'the' and words[k - 2].lower == 'in' and words[k - 3].lower == 'pain'):
                replace(k, 'neck')
            elif lower in DROPPED_ADJECTIVES and self.adjacent(k) and self.modifies_next(k):
                drop(k)
            elif lower in ('shit', 'shits', 'shitting'):
                if lower == 'shitting':
                    replace(k, 'dumping')
                elif self.is_give_idiom(k):
                    replace(k, 'hoot' if lower == 'shit' else 'hoots')
                elif (lower == 'shit' and self.adjacent(k) and words[k + 1].lower == 'you' and self.adjacent(k + 1) and
                      k + 2 < len(words) and words[k + 2].lower == 'not'):
                    replace(k, 'kid')
                elif self.is_verb_position(k, lower == 'shits'):
                    replace(k, 'dump' if lower == 'shit' else 'dumps')
                elif lower == 'shits' and self.previous(k) is not None and self.previous(k) not in NOUN_LEADERS:
                    replace(k, 'dumps')
                elif lower == 'shits':
                    replace(k, 'stuff')
                elif k > 0 and self.adjacent(k - 1) and words[k - 1].lower in TALK_VERBS:
                    replace(k, 'nonsense')
                elif (k > 1 and self.adjacent(k - 1) and self.adjacent(k - 2) and words[k - 1].lower == 'of' and
                      words[k - 2].lower == 'piece'):
                    replace(k, 'junk')
                else:
                    replace(k, 'stuff')
            elif lower in ('bitch', 'bitches'):
                if self.is_verb_position(k, lower == 'bitches'):
                    replace(k, 'complain' if lower == 'bitch' else 'complains')
                else:
                    replace(k, 'jerk' if lower == 'bitch' else 'jerks')
            elif lower == 'bitched':
                replace(k, 'complained')
            elif lower == 'bitchin':
                end = words[k].end + 1 if words[k].end < n and _has("'’", chars[words[k].end]) else words[k].end
                prev = self.previous(k) or ''
                about_next = (k + 1 < len(words) and _only_spaces(chars, end, words[k + 1].start) and
                              words[k + 1].lower == 'about')
                is_verb = (about_next or prev in GERUND_TRIGGERS or prev in ('i', 'we', 'they', 'you', 'he', 'she'))
                replace(k, 'complaining' if is_verb else 'great', end)
            elif lower in ('fuck', 'fucks', 'fucked', 'fucking', 'motherfucking'):
                if lower == 'motherfucking':
                    drop(k)
                elif lower in ('fuck', 'fucks') and self.is_give_idiom(k):
                    replace(k, 'hoot' if lower == 'fuck' else 'hoots')
                elif lower == 'fuck' and self.is_forget_object(k):
                    replace(k, 'forget')
                elif lower in CHEAT_FORMS and next_is(k, ('over',)):
                    replace(k, CHEAT_FORMS[lower], words[k + 1].end)
                elif lower in CHEAT_FORMS and self.split_particle(k, 'over') is not None:
                    over = self.split_particle(k, 'over')
                    replace(k, CHEAT_FORMS[lower])
                    spans.append(_Span(words[over].start, words[over].end, '',
                                       cut=(words[over - 1].end, words[over].end)))
                elif (lower in SLEEP_FORMS and self.adjacent(k) and self.is_free(k + 1) and
                      words[k + 1].lower in PERSON_OBJECTS):
                    replace(k, SLEEP_FORMS[lower])
                elif lower in MESS_UP_FORMS:
                    replace(k, MESS_UP_FORMS[lower])
            elif lower in SWAPS:
                replace(k, SWAPS[lower])
            k += 1
        for index in sorted(capitalise):
            if index not in handled and index < len(words) and not self.keeps_case(words[index]):
                up = _capitalized(chars, words[index])
                if up is not None:
                    spans.append(_Span(words[index].start, words[index].end, up))
        return spans

    # Articles

    def article_pairs(self):
        words = self.words
        pairs = []
        for k in range(max(len(words) - 1, 0)):
            if words[k].lower in ('a', 'an') and self.adjacent(k) and not self.inside_token(words[k]):
                pairs.append((words[k].lower + ' ' + words[k + 1].lower, k, words[k].start))
        return pairs

    def article_repairs(self, skipping, origin):
        words, chars = self.words, self.chars
        spans = []
        for key, k, offset in self.article_pairs():
            original = origin[offset] if offset < len(origin) else self.n
            if '%d:%s' % (original, key) in skipping:
                continue
            following = words[k + 1]
            if not (self.is_free(k) and self.is_free(k + 1) and _is_letter(chars[following.start])):
                continue
            if self.is_acronym(following):
                wanted = 'an' if chars[following.start] in 'AEFHILMNORSX' else 'a'
            else:
                wanted = 'an' if starts_with_vowel_sound(following.lower) else 'a'
            if wanted == words[k].lower:
                continue
            spans.append(_Span(words[k].start, words[k].end, self.matching_case(wanted, words[k])))
        return spans

    def is_clause_end(self, i):
        j = i
        while j < self.n and _is_space(self.chars[j]):
            j += 1
        return j >= self.n or _newline(self.chars[j]) or _has(PUNCTUATION, self.chars[j])

    # Removing

    def sentence_start(self, pos):
        chars = self.chars
        i = pos - 1
        while i >= 0 and (_space(chars[i]) or self.removed[i]):
            if _newline(chars[i]):
                return True
            i -= 1
        if i < 0:
            return True
        return _has(SENTENCE_END, chars[i])

    def add(self, core, cut):
        cut_start = max(cut[0], self.last_cut_end)
        self.spans.append(_Span(core[0], core[1], '', cut=(cut_start, cut[1])))
        self.last_cut_end = max(self.last_cut_end, cut[1])
        for i in range(core[0], core[1]):
            self.removed[i] = True

    def skip_spaces(self, i):
        j = i
        while j < self.n and _is_space(self.chars[j]):
            j += 1
        return j

    def keeps_case(self, w):
        chars = self.chars
        if self.is_protected(w) or ''.join(chars[w.start:w.end]) in self.written_forms:
            return True
        if any(_is_number(char) or char == '_' for char in chars[w.start:w.end]):
            return True
        if w.end + 1 < self.n and _has('./\\@', chars[w.end]) and _word(chars[w.end + 1]):
            return True
        return False

    def follows_conjunction(self, comma):
        word = next((w for w in reversed(self.words) if w.end == comma), None)
        return word is not None and word.lower in CONJUNCTIONS

    def remove(self, unit, next_unit_starts):
        words, chars, n = self.words, self.chars, self.n
        s, e = words[unit[0]].start, words[unit[1]].end
        post = None
        punct_end = e
        while punct_end < n and self.is_punctuation(chars[punct_end]):
            punct_end += 1
        if punct_end > e:
            post = chars[e]
        j = s - 1
        while j >= 0 and (_is_space(chars[j]) or self.removed[j]):
            j -= 1
        has_pre = j >= 0 and chars[j] == ','
        pre_index = j
        at_start = (not has_pre) and self.sentence_start(s)
        after_word = punct_end
        after_spaces = self.skip_spaces(after_word)
        at_end = after_spaces >= n or _newline(chars[after_spaces])

        def trailing_back():
            b = s
            while b > self.last_cut_end and _is_space(chars[b - 1]):
                b -= 1
            return b

        if at_start:
            cut_start = trailing_back() if at_end else s
            self.add((s, after_word), (cut_start, after_word if at_end else after_spaces))
            if not at_end and after_spaces < n:
                next_word = next((index for index, w in enumerate(words) if w.start == after_spaces), None)
                if (next_word is not None and next_word not in next_unit_starts and
                        not self.keeps_case(words[next_word])):
                    up = _capitalized(chars, words[next_word])
                    if up is not None:
                        self.spans.append(_Span(words[next_word].start, words[next_word].end, up))
                        self.last_cut_end = max(self.last_cut_end, words[next_word].end)
        elif has_pre and pre_index >= self.last_cut_end and post == ',' and self.follows_conjunction(pre_index):
            self.add((pre_index, after_word), (pre_index, after_word))
        elif has_pre and pre_index >= self.last_cut_end and (
                post == ',' or (post is None and at_end) or (post is not None and _has(SENTENCE_END, post))):
            self.add((pre_index, e), (pre_index, e))
        elif post == ',':
            self.add((s, after_word), (s, after_spaces))
        elif post is not None and (at_end or _has('.!?…;:', post)):
            self.add((s, e), (trailing_back(), e))
        elif at_end:
            self.add((s, e), (trailing_back(), e))
        else:
            self.add((s, e), (s, self.skip_spaces(e)))


class ProfanityRemover:
    def __init__(self, protected_words=(), protected_phrases=()):
        self.protected_words = frozenset(word.lower() for word in protected_words)
        self.written_forms = frozenset(protected_words)
        self.protected_phrases = tuple(protected_phrases)

    def _scan(self, chars):
        return _Scan(chars, self.protected_words, self.written_forms, self.protected_phrases)

    def apply(self, text):
        chars = list(graphemes(text))
        if not chars:
            return text
        scan = self._scan(chars)
        scan.run()
        removed_text, removed_edits = _rewrite(chars, scan.spans)
        tidied = list(graphemes(removed_text))
        swaps = self._scan(tidied).find_swaps()
        swapped_text = _rewrite(tidied, swaps)[0] if swaps else removed_text
        if not removed_edits and not swaps:
            return removed_text
        origin = _original_offsets(scan.spans, len(chars))
        if swaps:
            swap_map = [origin[o] if o < len(origin) else len(chars)
                        for o in _original_offsets(swaps, len(tidied))]
        else:
            swap_map = origin
        final = list(graphemes(swapped_text))
        known = {'%d:%s' % (offset, key) for key, _, offset in scan.article_pairs()}
        articles = self._scan(final).article_repairs(known, swap_map)
        if not articles:
            return swapped_text
        return _rewrite(final, articles)[0]
