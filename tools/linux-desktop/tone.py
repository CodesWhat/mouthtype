"""Tone for dictated text: Formal, Casual and Very casual, mirroring Core's StyleStage.

Formal sentence case, keeps the final full stop, and softens swearing (profanity.py). Casual drops the final full
stop of a short message. Very casual also lowercases sentence starts that are safe to lowercase. Nothing here runs
unless a tone is chosen: with no tone the text goes through untouched.
"""

from cleanup import _is_upper, _newline
from profanity import ProfanityRemover, _Span, _is_letter, _is_number, _rewrite, _scan_words
from spellings import _space, _word
from vendor.grapheme import graphemes

TONES = ('formal', 'casual', 'very_casual')
TITLES = {'formal': 'Formal', 'casual': 'Casual', 'very_casual': 'Very casual'}
# (capitalisation, ending punctuation) behind each preset, as in Core's StylePreset.options.
OPTIONS = {'formal': ('sentence', 'keep'), 'casual': ('sentence', 'drop_final_full_stop'),
           'very_casual': ('lowercase', 'drop_final_full_stop')}
SHORT_MESSAGE_WORDS = 25
SHORT_MESSAGE_SENTENCES = 2
ABBREVIATIONS = frozenset(('etc', 'vs', 'inc', 'ltd', 'co', 'mr', 'mrs', 'ms', 'dr', 'jr', 'sr', 'st', 'approx', 'dept'))
SENTENCE_ENDS = '.!?\u2026'

# Everyday words that are safe to lowercase at the start of a sentence (Core's CommonWords).
COMMON_WORDS = frozenset("""
the a an this that these those my your his her its our their me him us them i you he she it we they who whom
whose which what where when why how and but or so if because although though while since unless until before
after as than then else also too very just only even still already again always never often sometimes maybe
perhaps probably actually basically really quite rather almost both either neither each every any some many much
more most less least few several all none one two three four five six seven eight nine ten first second third
last next other another such same different new old good great bad better best worse little big small long short
high low early late right wrong sure ok okay yes no not nope yeah yep hi hello hey oh ah well now here there
today tomorrow yesterday tonight soon later anyway however therefore instead meanwhile finally otherwise besides
thanks thank please sorry welcome congrats is are was were be been being am do does did done doing have has had
having can could shall should would might must need needs needed want wants wanted like likes liked love loved
hate think thinks thought know knows knew known see sees saw seen look looks looked make makes made get gets got
go goes going went gone come comes came take takes took give gives gave say says said tell tells told ask asks
asked call calls called try tries tried use uses used work works worked find finds found feel feels felt keep
keeps kept let lets put set run runs ran move moves moved start starts started stop stops stopped turn turns
turned open opens opened close closes closed read reads write writes wrote send sends sent ship ships shipped
build builds built check checks checked fix fixes fixed add adds added remove removes removed change changes
changed update updates updated create creates created show shows showed help helps helped bring brings brought
buy buys bought pay pays paid meet meets met talk talks talked wait waits waited follow follows leave leaves
left remember forget forgot learn learns plan plans planned book books booked schedule scheduled share shares
shared save saves saved test tests tested review reviews reviewed thing things way ways time times day days week
weeks month months year years people person man woman time work life world place home house office team project
problem question questions idea ideas point part number number case issue issues list item items email message
note notes file files page word words line lines thing something anything everything nothing someone anyone
everyone nobody somebody somewhere anywhere everywhere nowhere for of to in on at by with from into onto over
under about above below between through during without within across against along around behind beside beyond
near off out up down back away together apart per via versus let's it's that's there's here's what's who's how's
where's don't doesn't didn't can't couldn't won't wouldn't shouldn't isn't aren't wasn't weren't haven't hasn't
hadn't we're you're they're he's she's we'll you'll they'll we've you've they've we'd you'd they'd clear restart
reset install uninstall deploy merge push pull commit delete copy paste click press type enter select choose
pick drop grab pack call email text print scan sign log login upload download install connect disconnect refresh
reload rename schedule cancel confirm approve submit finish complete continue resume pause skip repeat explain
describe consider remember mention suggest recommend expect hope wish wonder guess mean means meant happen
happens happened seem seems become becomes became begin begins began end ends ended walk drive visit watch
listen sit stand eat drink sleep wake cook clean wash pick cut fill hold carry throw catch lose win miss
""".split())


def options(tone):
    if tone not in OPTIONS:
        raise ValueError('tone must be one of ' + ', '.join(TONES))
    return OPTIONS[tone]


def words_of(strings):
    """Every word in the given strings, exactly as written, for use as protected words."""
    result = set()
    for text in strings:
        chars = list(graphemes(text))
        for word in _scan_words(chars)[0]:
            result.add(''.join(chars[word.start:word.end]))
    return result


def _starts_sentence(chars, index):
    j = index - 1
    while j >= 0 and chars[j] in (' ', '\t'):
        j -= 1
    if j < 0 or _newline(chars[j]):
        return True
    if chars[j] == '-' and (j == 0 or _newline(chars[j - 1])):
        return True
    if j >= index - 1:
        return False
    return len(chars[j]) == 1 and chars[j] in SENTENCE_ENDS


def _looks_like_code(token):
    value = ''.join(token)
    if any(part in value for part in ('://', '@', '/', '\\', '_', '`')):
        return True
    return any(token[k] == '.' and _word(token[k - 1]) and _word(token[k + 1])
               for k in range(1, max(1, len(token) - 1)))


def _shielded(chars):
    shielded = [False] * len(chars)
    opened = None
    for i, char in enumerate(chars):
        if char == '"':
            if opened is not None:
                for k in range(opened, i + 1):
                    shielded[k] = True
                opened = None
            else:
                opened = i
    curly = None
    for i, char in enumerate(chars):
        if char == '“':
            curly = i
        if char == '”' and curly is not None:
            for k in range(curly, i + 1):
                shielded[k] = True
            curly = None
    i = 0
    while i < len(chars):
        if _space(chars[i]):
            i += 1
            continue
        j = i
        while j < len(chars) and not _space(chars[j]):
            j += 1
        if _looks_like_code(chars[i:j]):
            for k in range(i, j):
                shielded[k] = True
        i = j
    return shielded


def _lowercase_spans(chars, words, shielded, protected):
    lower_forms = {''.join(chars[w.start:w.end]) for w in words if ''.join(chars[w.start:w.end]) == w.lower}
    spans = []
    for w in words:
        if not _starts_sentence(chars, w.start) or shielded[w.start]:
            continue
        first = chars[w.start]
        if not (_is_letter(first) and _is_upper(first)):
            continue
        original = ''.join(chars[w.start:w.end])
        if any(_is_upper(char) for char in chars[w.start + 1:w.end]):
            continue
        if original == 'I' or original.startswith("I'") or original.startswith('I’'):
            continue
        if original in protected:
            continue
        if w.lower not in COMMON_WORDS and w.lower not in lower_forms:
            continue
        spans.append(_Span(w.start, w.end, w.lower))
    return spans


def _has_list_line(chars):
    i = 0
    while i < len(chars):
        if i == 0 or _newline(chars[i - 1]):
            if chars[i] == '-' and i + 1 < len(chars) and chars[i + 1] == ' ':
                return True
            j = i
            while j < len(chars) and _is_number(chars[j]):
                j += 1
            if j > i and j + 1 < len(chars) and chars[j] == '.' and chars[j + 1] == ' ':
                return True
        i += 1
    return False


def _sentence_count(chars, limit):
    count, pending, i = 0, False, 0
    while i <= limit:
        char = chars[i]
        if _newline(char):
            if pending:
                count, pending = count + 1, False
        elif (len(char) == 1 and char in SENTENCE_ENDS and
              (i == limit or _space(chars[i + 1]) or (len(chars[i + 1]) == 1 and chars[i + 1] in SENTENCE_ENDS))):
            if pending:
                count, pending = count + 1, False
        elif not _space(char):
            pending = True
        i += 1
    return count + (1 if pending else 0)


def _final_stop_span(chars, words, existing):
    e = len(chars) - 1
    while e >= 0 and _space(chars[e]):
        e -= 1
    if not (e >= 1 and chars[e] == '.' and chars[e - 1] != '.' and chars[e - 1] != '…'):
        return None
    if _has_list_line(chars):
        return None
    if not (len(''.join(chars).split()) < SHORT_MESSAGE_WORDS and _sentence_count(chars, e) <= SHORT_MESSAGE_SENTENCES):
        return None
    token_start = e
    while token_start > 0 and not _space(chars[token_start - 1]):
        token_start -= 1
    token = ''.join(chars[token_start:e])
    if '.' in token or token.lower() in ABBREVIATIONS:
        return None
    word = next((w for w in reversed(words) if w.end == e), None)
    if not _word(chars[e - 1]) or word is None:
        return _Span(e, e + 1, '')
    replacement = ''.join(chars[word.start:word.end])
    lowered = next((span for span in existing if span.start == word.start and span.end == word.end), None)
    if lowered is not None:
        replacement = lowered.replacement
    return _Span(word.start, e + 1, replacement)


def apply_style(text, tone, protected_words=()):
    """Core's StyleStage for Casual and Very casual. Formal changes nothing here (see apply)."""
    capitalisation, ending = options(tone)
    if tone == 'formal':
        return text
    chars = list(graphemes(text))
    if not chars:
        return text
    words = _scan_words(chars)[0]
    shielded = _shielded(chars)
    protected = frozenset(protected_words)
    spans = []
    if capitalisation == 'lowercase':
        spans += _lowercase_spans(chars, words, shielded, protected)
    if ending == 'drop_final_full_stop':
        drop = _final_stop_span(chars, words, spans)
        if drop is not None:
            spans = [span for span in spans
                     if not (span.end == drop.end - 1 and drop.start <= span.start < drop.end)]
            spans.append(drop)
    return _rewrite(chars, spans)[0]


def apply(text, tone, protected_words=(), protected_phrases=()):
    """The tone pass as the Mac pipeline runs it: Formal softens swearing, the others restyle casing and the final stop.

    protected_words are saved spellings and snippet text. They are never removed or lowercased. protected_phrases are
    saved heard forms and triggers that swearing removal must not cut. A falsy tone returns the text unchanged."""
    if not tone:
        return text
    options(tone)
    if tone == 'formal':
        return ProfanityRemover(protected_words, protected_phrases).apply(text)
    return apply_style(text, tone, protected_words)
