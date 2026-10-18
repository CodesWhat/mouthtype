"""Model cleanup guards for the Linux client, ported from the Mac SmartCleanupGuard.

Every check answers one failure seen with small models: output that is empty, runs away, drops the speaker's
words, changes a number, loses a name, flips a negation or answers the dictation instead of transcribing it.
The guard never produces text; it only decides whether model text may replace the deterministic text.
"""

import math
import re

MIN_WORDS = 2
MAX_WORDS = 400
MINIMUM_KEPT = 0.5
MAXIMUM_NOVEL = 0.5
CUE_REACH = 4

CORRECTION_CUES = (['actually'], ['no', 'wait'], ['wait'], ['i', 'mean'], ['scratch', 'that'], ['sorry'], ['rather'],
                   ['make', 'that'], ['never', 'mind'], ['correction'])

NUMBER_WORDS = {word: index for index, word in enumerate(
    ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve',
     'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty'])}
for _index, _tens in enumerate(['thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety']):
    NUMBER_WORDS[_tens] = (_index + 3) * 10
ORDINAL_WORDS = {'first': 1, 'second': 2, 'third': 3, 'fourth': 4, 'fifth': 5, 'sixth': 6, 'seventh': 7,
                 'eighth': 8, 'ninth': 9, 'tenth': 10}

STOP_WORDS = set('''the and but for nor yet are was were been being have has had does did doing will would shall should
can could may might must not its his her hers him she they them their theirs you your yours our ours that this these
those there here then than with without from into onto about over under out off just also very really kind sort like
know mean okay well yeah yes wait actually sorry rather basically maybe probably literally totally right got get one
some any all who what when where why how which whose whom let lets let's it's i'm i've i'll i'd you're you've you'll
you'd we're we've we'll we'd they're they've they'll they'd he's she's that's there's here's what's who's how's where's
isn't aren't wasn't weren't don't doesn't didn't won't wouldn't can't couldn't shouldn't haven't hasn't hadn't cannot
gonna wanna gotta going um uh umm hmm huh err ahh ugh oh ooh ok hey now too still even ever much many more most other
such only own same both each few again because while though although since until unless whether after before during
between through against above below else once thing things stuff'''.split()) | set(NUMBER_WORDS) | set(ORDINAL_WORDS)

CERTAINTY = {'probably', 'maybe', 'perhaps', 'might', 'must', 'should', 'could', 'would'}
NEGATIVES = {'no', 'not', 'never', 'neither', 'nor', 'without', 'cannot'}
QUESTIONS = {'what', "what's", 'who', "who's", 'where', "where's", 'when', 'why', 'how', 'which'}


def budget_seconds(level, words):
    """Linux budgets from the on-machine CPU benchmarks: Fast (S1-mini) grows 35 ms a word, Thorough (Qwen3 4B) 200 ms."""
    if level == 'thorough':
        return min(2.0 + 0.2 * words, 30.0)
    return min(1.0 + 0.035 * words, 10.0)


def word_count(text):
    return len(text.split())


def max_output_words(text):
    return word_count(text) * 3 + 48


def normalized_words(text):
    folded = text.lower().replace('’', "'").replace('‘', "'")
    cleaned = ''.join(char if char.isalpha() or char.isdigit() or char == "'" else ' ' for char in folded)
    return [word.strip("'") for word in cleaned.split() if word.strip("'")]


def stripped(token):
    word = token.strip(''.join(chr(c) for c in range(33, 127) if not chr(c).isalnum()) + '“”‘’…–—')
    for suffix in ("'s", '’s'):
        if word.endswith(suffix):
            word = word[:-len(suffix)]
    return word


def sanitize(output):
    text = re.sub(r'<think>.*?</think>', '', output, flags=re.S)
    for tag in ('<transcript>', '</transcript>'):
        text = text.replace(tag, '')
    return text.strip()


def restoring_terminal(source, output):
    """A dictation that ended in . ? or ! keeps that mark; the model may not turn a statement into a question."""
    wanted = next((char for char in reversed(source) if not char.isspace()), None)
    if wanted is None or wanted not in '.?!':
        return output
    body = output.rstrip()
    if not body or body[-1] == wanted or body[-1] not in '.?!':
        return output
    return body[:-1] + wanted


def later_cue(tokens, position):
    lower = [stripped(token).lower() for token in tokens]
    for start in range(position, min(len(lower) - 1, position + CUE_REACH) + 1):
        for cue in CORRECTION_CUES:
            if lower[start:start + len(cue)] == cue:
                return True
    return False


def changed_intent(source, output):
    def negatives(text):
        words = normalized_words(text)
        count = 0
        for index, word in enumerate(words):
            following = words[index + 1] if index + 1 < len(words) else ''
            if word == 'no' and following in ('wait', 'sorry'):
                continue
            if word == 'never' and following == 'mind':
                continue
            if word in NEGATIVES or word.endswith("n't"):
                count += 1
        return count
    if negatives(source) != negatives(output):
        return 'negation changed'

    def words(text):
        return [word[:-3] if word.endswith("n't") else word for word in normalized_words(text)]
    source_words = words(source)
    output_words = set(words(output))
    if not (output_words & CERTAINTY) <= set(source_words):
        return 'certainty changed'
    for index, word in enumerate(source_words):
        if word in CERTAINTY and word not in output_words and not later_cue(source_words, index):
            return 'certainty changed'

    def time_of_day(text):
        values = set()
        for match in re.finditer(r'(?i)(?<![^\W\d_])([ap])[. \t]*m\.?(?![^\W\d_])', text):
            previous = text[:match.start()].split()[-1] if text[:match.start()].split() else ''
            if any(char.isdigit() for char in previous) or previous.lower() in NUMBER_WORDS:
                values.add(match.group(1).lower())
        tokens = set(normalized_words(text))
        if tokens & {'morning', 'midnight'}:
            values.add('a')
        if tokens & {'afternoon', 'evening', 'tonight', 'noon'}:
            values.add('p')
        return values
    if not time_of_day(output) <= time_of_day(source):
        return 'time of day added or changed'
    first_source = normalized_words(source)[:1]
    first_output = normalized_words(output)[:1]
    if first_source and first_source[0] in QUESTIONS and first_output and first_output[0] not in QUESTIONS:
        return 'question changed into a statement'
    return None


def written_form(text):
    digits = {'zero': '0', 'oh': '0', 'one': '1', 'two': '2', 'three': '3', 'four': '4', 'five': '5', 'six': '6',
              'seven': '7', 'eight': '8', 'nine': '9'}
    digit_pattern = '(?:zero|oh|one|two|three|four|five|six|seven|eight|nine)'
    result = re.sub(r'(?<![^\W\d_])(?:[A-Z][ \t.-]+){1,}[A-Z](?![^\W\d_])', lambda m: ''.join(c for c in m.group(0) if c.isalpha()), text)
    result = re.sub(r'\b([A-Z]{2,})-([A-Z])\b', r'\1\2', result)
    result = re.sub(r'\bUSB[ \t]+([ABC])\b', r'USB\1', result)

    def spoken_digits(match):
        words = match.group(0).lower().split()
        if 'oh' not in words and 'zero' not in words:
            return match.group(0)
        return ''.join(digits[w] for w in words)
    result = re.sub(r'(?i)\b%s(?:\s+%s)+\b' % (digit_pattern, digit_pattern), spoken_digits, result)
    for _ in range(4):
        result = re.sub(r'(?i)\b(\d+(?:\.\d+)*)\s+point\s+(%s|\d+)\b' % digit_pattern,
                        lambda m: m.group(1) + '.' + digits.get(m.group(2).lower(), m.group(2)), result)
    result = re.sub(r'\b([A-Z]{2,})\s+(%s)\b' % digit_pattern, lambda m: m.group(1) + digits.get(m.group(2), ''), result)
    return re.sub(r'\b(%s)\s+([A-Z]{1,3})\b' % digit_pattern, lambda m: digits.get(m.group(1), '') + m.group(2), result)


def content_words(text):
    seen = set()
    result = []
    for word in normalized_words(text):
        if len(word) > 2 and not any(char.isdigit() for char in word) and word not in STOP_WORDS and word not in seen:
            seen.add(word)
            result.append(word)
    return result


def present(word, words):
    return any(other == word or (len(word) >= 5 and len(other) >= 5 and word[:4] == other[:4]) for other in words)


def quantities(text):
    found = []
    for position, token in enumerate(text.split()):
        word = stripped(token).lower()
        value = NUMBER_WORDS.get(word, ORDINAL_WORDS.get(word))
        if value is not None:
            found.append(({word, str(value)}, position, word))
            continue
        digits = ''
        previous = None
        for char in token + ' ':
            joins = char in ',.' and previous is not None and previous.isdigit()
            if char.isdigit():
                digits += char
            elif joins and char == '.':
                digits += char
            elif not joins:
                value = digits.strip('.')
                if value:
                    found.append(({value}, position, value))
                digits = ''
            previous = char
    return found


def missing_number(source, output):
    spellings = set()
    for accepted, _, _ in quantities(output):
        spellings |= accepted
    spellings |= {stripped(token).lower() for token in output.split()}
    tokens = source.split()
    for accepted, position, label in quantities(source):
        if accepted.isdisjoint(spellings) and not later_cue(tokens, position):
            return label
    return None


LITERAL = re.compile(r'`[^`\r\n]+`|(?<![^\W\d_])"[^"\r\n]+"(?![^\W\d_])|(?<![^\W\d_])“[^”\r\n]+”(?![^\W\d_])|[^\s`]*[@/\\][^\s`]*|(?<![^\W\d_.])\.[^\W\d_][\w.-]*')
WRAPPERS = set('.,;:!?()[]{}"\'“”‘’')


def literals(text):
    found = []
    for match in LITERAL.finditer(text):
        raw = match.group(0)
        if raw[:1] in ('"', '“'):
            found.append(('"' + raw[1:-1] + '"', match.span()))
            continue
        leading = raw.lstrip(''.join(WRAPPERS - {'.'}))
        value = leading.rstrip(''.join(WRAPPERS))
        if '`' in value or any(char.isalpha() for char in value):
            found.append((value, match.span()))
    return found


def missing_literal(source, output):
    kept = {value for value, _ in literals(output)}
    found = literals(source)
    for index, (value, span) in enumerate(found):
        if value in kept:
            continue
        if index + 1 < len(found) and found[index + 1][0] in kept:
            gap = [stripped(t).lower() for t in source[span[1]:found[index + 1][1][0]].split() if stripped(t)]
            if gap in [list(cue) for cue in CORRECTION_CUES]:
                continue
        return value
    return None


def missing_name(source, output):
    tokens = source.split()
    output_tokens = {stripped(token) for token in output.split()}
    for index, token in enumerate(tokens):
        if index == 0:
            continue
        word = stripped(token)
        if not word or not word[0].isupper() or len(word) < 2 or word == 'I' or word.startswith("I'") or word.startswith('I’'):
            continue
        previous = tokens[index - 1]
        if previous and (previous[-1] in '.!?:\n' or previous.startswith('-')):
            continue
        acronym_kept = word == word.upper() and any(other.lower() == word.lower() for other in output_tokens)
        if word in output_tokens or acronym_kept or later_cue(tokens, index):
            continue
        return word
    return None


def rejection(source, output):
    """A reason to reject the model output, or None when it may replace the deterministic text."""
    trimmed = output.strip()
    if not trimmed:
        return 'empty output'
    if word_count(trimmed) > max_output_words(source):
        return 'output over the length limit'
    reason = changed_intent(source, trimmed)
    if reason:
        return reason
    literal = missing_literal(source, trimmed)
    if literal is not None:
        return 'literal "%s" changed' % literal
    comparable_source = written_form(source)
    comparable_output = written_form(trimmed)
    output_spellings = {stripped(token).lower() for token in comparable_output.split()}
    for word in (stripped(token) for token in comparable_source.split()):
        if len(word) > 1 and any(c.isalpha() for c in word) and all(c.isupper() or c.isdigit() for c in word):
            if word.lower() not in output_spellings:
                return 'acronym %s missing or changed' % word
    number = missing_number(comparable_source, comparable_output)
    if number is not None:
        return 'number %s missing or changed' % number
    name = missing_name(comparable_source, comparable_output)
    if name is not None:
        return 'name "%s" missing' % name
    source_words = content_words(comparable_source)
    output_content = content_words(comparable_output)
    if source_words:
        kept = sum(1 for word in source_words if present(word, output_content)) / len(source_words)
        if kept < MINIMUM_KEPT:
            return 'kept %d%% of the content words' % int(kept * 100)
    if output_content:
        novel = sum(1 for word in output_content if not present(word, source_words)) / len(output_content)
        if novel > MAXIMUM_NOVEL:
            return '%d%% of the output content words are new' % int(novel * 100)
    return None


def eligible(text):
    words = word_count(text)
    return MIN_WORDS <= words <= MAX_WORDS


def check(source, output):
    """The accepted text or None, with the rejection reason."""
    cleaned = restoring_terminal(source, sanitize(output))
    reason = rejection(source, cleaned)
    return (None, reason) if reason else (cleaned, None)
