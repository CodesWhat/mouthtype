"""A small English lexical-class guesser standing in for Apple's NLTagger in the profanity port.

Core asks the tagger for the class of one word in a sentence, and only for these decisions: whether a swear word
before it is an intensifier (a noun, adjective, adverb or interjection follows; a preposition, particle or pronoun
means the swear word is the verb), whether a pronoun or determiner is followed by a verb (a new clause), and whether
the word before "shits" or "bitches" is a noun or pronoun. Closed word classes answer most of it. Open classes use a
verb list, an adjective list and suffix rules, with the word before the swear word as context. The word lists were
taken from NLTagger's majority answer over a few sentence frames, and check_tone.py compares this guesser to the real
tagger on generated sentences.
"""

PRONOUNS = frozenset((
    'i', 'you', 'he', 'she', 'it', 'we', 'they', 'me', 'him', 'her', 'us', 'them', 'myself', 'yourself', 'himself',
    'herself', 'itself', 'ourselves', 'themselves', 'who', 'whom', 'what', 'which', 'when', 'where', 'why', 'how',
    "i'm", "i've", "i'll", "i'd", "you're", "you've", "you'll", "you'd", "he's", "he'll",
    "he'd", "she's", "she'll", "she'd", "it's", "it'll", "it'd", "we're", "we've", "we'll", "we'd", "they're",
    "they've", "they'll", "they'd", "who's", "what's", "where's", "how's", "there's", "that's",
))
DETERMINERS = frozenset((
    'a', 'an', 'the', 'this', 'that', 'these', 'those', 'my', 'your', 'his', 'its', 'our', 'their', 'whose', 'some',
    'any', 'no', 'each', 'every', 'another', 'all', 'both', 'neither',
))
NUMBERS = frozenset(('two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten'))
OTHER = frozenset((
    'about', 'above', 'across', 'after', 'against', 'along', 'although', 'around', 'as', 'at', 'because', 'before',
    'below', 'beside', 'besides', 'between', 'beyond', 'by', 'during', 'for', 'from', 'if', 'in', 'into',
    'near', 'of', 'on', 'onto', 'over', 'per', 'since', 'than', 'through', 'to', 'under', 'unless', 'until', 'versus',
    'via', 'while', 'with', 'within', 'without', 'and', 'but', 'or', 'down', 'off', 'out', 'up', 'upon', 'whether',
    'nor', 'yet',
)) | NUMBERS
INTERJECTIONS = frozenset((
    'ah', 'oh', 'hello', 'hey', 'hi', 'nope', 'ok', 'okay', 'yeah', 'yep', 'yes', 'well', 'please', 'wow', 'ugh',
    'oops', 'hmm', 'uh', 'um', 'sorry', 'thanks',
))
ADVERBS = frozenset((
    'absolutely', 'actually', 'again', 'almost', 'already', 'also', 'always', 'anyway', 'anywhere', 'apart', 'away',
    'back', 'basically', 'better', 'completely', 'early', 'else', 'even', 'everywhere', 'exactly', 'fast', 'finally',
    'fully', 'here', 'honestly', 'however', 'instead', 'just', 'late', 'later', 'less', 'literally', 'long', 'maybe',
    'meanwhile', 'more', 'most', 'much', 'never', 'not', 'now', 'nowhere', 'often', 'only', 'otherwise', 'perhaps',
    'pretty', 'probably', 'quite', 'rather', 'really', 'seriously', 'sometimes', 'somewhere', 'soon', 'still', 'then',
    'therefore', 'together', 'too', 'totally', 'truly', 'very', 'worse', 'today', 'tomorrow', 'yesterday', 'tonight',
    'behind', 'either', 'so', 'such', 'there', 'though',
))
NOUNS = frozenset(('everything', 'everyone', 'everybody', 'something', 'someone', 'somebody', 'anything', 'anyone',
                   'nothing', 'nobody'))
SUBJECTS = frozenset(('i', 'you', 'he', 'she', 'it', 'we', 'they', 'who'))
AUXILIARIES = frozenset((
    'is', 'are', 'was', 'were', 'am', 'be', 'been', 'being', 'has', 'have', 'had', 'having', 'will', 'would', 'can',
    'could', 'should', 'might', 'must', 'shall', 'did', 'does', 'do', 'doing', "'s", "'re", "'m", "isn't", "aren't",
    "wasn't", "weren't", "don't", "doesn't", "didn't", "can't", "couldn't", "won't", "wouldn't", "shouldn't",
    "haven't", "hasn't", "hadn't",
))
VERBS = frozenset((
    'added', 'adds', 'annoying', 'approve', 'ask', 'asked', 'asks', 'became', 'become', 'becomes', 'began', 'begin',
    'begins', 'booked', 'bought', 'brings', 'broke', 'broken', 'brought', 'builds', 'built', 'buy', 'called', 'came',
    'changed', 'checked', 'choose', 'closed', 'come', 'comes', 'confirm', 'continue', 'created', 'creates', 'done',
    'ended', 'expect', 'explain', 'felt', 'find', 'finds', 'finished', 'fixed', 'follows', 'found', 'gave', 'get',
    'gets', 'give', 'gives', 'go', 'goes', 'going', 'gone', 'got', 'happen', 'happened', 'happens', 'hated', 'helped',
    'helps', 'keep', 'keeps', 'kept', 'knew', 'know', 'known', 'knows', 'learn', 'left', 'let', "let's", 'lets',
    'liked', 'listen', 'looked', 'looks', 'lose', 'lost', 'loved', 'loves', 'made', 'make', 'makes', 'met', 'missing',
    'moved', 'needed', 'opened', 'opens', 'paid', 'pays', 'planned', 'ran', 'reads', 'remember', 'removed', 'removes',
    'reviewed', 'said', 'saved', 'saw', 'says', 'scheduled', 'seem', 'seems', 'seen', 'sees', 'sells', 'sent',
    'shared', 'shipped', 'showed', 'sit', 'slept', 'started', 'stopped', 'stuck', 'suggest', 'take', 'takes', 'talked',
    'tell', 'tells', 'tested', 'thank', 'think', 'thinks', 'thought', 'told', 'took', 'tried', 'tries', 'turned',
    'updated', 'used', 'wait', 'waited', 'want', 'wanted', 'wants', 'went', 'worked', 'writes', 'wrote', 'love',
    'hate', 'like', 'need', 'see', 'help', 'try', 'start', 'stop', 'move', 'open', 'close', 'break', 'breaks',
    'run', 'runs', 'fix', 'fixes', 'eat', 'ate', 'drink', 'drank', 'sleep', 'say', 'bring', 'show', 'shows',
))
ADJECTIVES = frozenset((
    'afraid', 'alive', 'amazing', 'angry', 'asleep', 'awesome', 'awful', 'bad', 'beautiful', 'best', 'big',
    'brilliant', 'busy', 'clean', 'clear', 'cold', 'complete', 'crazy', 'cute', 'dead', 'different', 'dumb', 'easy',
    'expensive', 'few', 'funny', 'glad', 'good', 'gorgeous', 'great', 'happy', 'hard', 'heavy', 'high', 'hilarious',
    'hot', 'huge', 'incredible', 'insane', 'interesting', 'last', 'lazy', 'least', 'little', 'loud', 'low', 'lucky',
    'mad', 'many', 'massive', 'new', 'next', 'nice', 'old', 'other', 'ready', 'ridiculous', 'sad', 'same', 'scared',
    'scary', 'second', 'several', 'short', 'sick', 'slow', 'small', 'smart', 'stupid', 'sure', 'sweet', 'terrible',
    'third', 'tired', 'tough', 'ugly', 'unbelievable', 'unique', 'useless', 'weird', 'wonderful', 'worth', 'wrong',
    'broken', 'first', 'right', 'cool',
))
_DETERMINING = DETERMINERS | frozenset(('her', 'one', 'two', 'three'))
_SKIPPED = frozenset(('fucking', 'motherfucking', 'damn', 'damned', 'goddamn', 'goddamned', 'very', 'so', 'too'))
# NLTagger reads these as nouns or adjectives, not verbs, right after an intensifier ("I fucking love it").
_NOUN_AFTER_INTENSIFIER = frozenset(('love', 'hate', 'need', 'see', 'help', 'try', 'start', 'stop', 'move', 'open', 'close',
                                     'break', 'fix', 'eat', 'drink', 'sleep', 'run', 'take', 'show', 'forgot'))
_CLOSED = PRONOUNS | DETERMINERS | OTHER
_NOUNS_IN_LY = frozenset(('family', 'assembly', 'reply', 'supply', 'anomaly', 'monopoly', 'butterfly', 'jelly', 'belly',
                          'rally', 'bully', 'italy', 'july', 'lily', 'holly', 'molly', 'sally', 'emily'))
_PAST_PARTICIPLES = frozenset(('broke', 'broken', 'stuck', 'built', 'lost', 'done', 'gone', 'seen', 'known', 'left',
                               'made', 'found', 'sent', 'paid', 'kept', 'got', 'gave', 'took', 'ran', 'wrote'))


def _suffix_class(word):
    if word.endswith('ly') and len(word) > 4 and word not in _NOUNS_IN_LY:
        return 'adverb'
    if word.endswith(('ing', 'ed')) and len(word) > 4:
        return 'verb'
    if word.endswith(('ous', 'ful', 'able', 'ible', 'less', 'ish')) and len(word) > 4:
        return 'adjective'
    return 'noun'


def _participle(word):
    return word.endswith(('ed', 'en')) or word in _PAST_PARTICIPLES


def lexical_class(words, k):
    """The class of words[k] given the lower-cased words around it: noun, verb, adjective, adverb, interjection,
    pronoun, determiner or other (preposition, particle, conjunction, number)."""
    word = words[k]
    if word in PRONOUNS:
        return 'pronoun'
    if word in DETERMINERS:
        return 'determiner'
    if word in OTHER:
        return 'other'
    if word in INTERJECTIONS:
        return 'interjection'
    if word in ADVERBS:
        return 'adverb'
    if word in AUXILIARIES:
        return 'verb'
    if word in NOUNS:
        return 'noun'
    # A word right after a subject pronoun is its verb ("I forgot", "they missed").
    if k > 0 and words[k - 1] in SUBJECTS:
        return 'verb'
    if word in ADJECTIVES:
        return 'adjective'
    guess = 'verb' if word in VERBS else _suffix_class(word)
    if guess != 'verb':
        return guess
    if word in _NOUN_AFTER_INTENSIFIER and k > 0 and words[k - 1] in _SKIPPED:
        return 'noun'
    # After a determiner ("the show", "a damn meeting", "a fucking annoying guy") a verb form is a noun or adjective;
    # past participles stay verbs when an intensifier sits in between ("a fucking broken printer").
    j = k - 1
    while j >= 0 and words[j] in _SKIPPED:
        j -= 1
    if j >= 0 and words[j] in _DETERMINING and (j == k - 1 or not _participle(word)):
        adjective = word.endswith(('ed', 'en')) if j == k - 1 else word.endswith(('ing', 'ed', 'en'))
        return 'adjective' if adjective else 'noun'
    # An -ing word in front of another word is an adjective ("a fucking annoying guy"); at the end of the clause, or
    # before a preposition or pronoun, it is a verb ("is fucking leaving").
    if word.endswith('ing'):
        following = words[k + 1] if k + 1 < len(words) else None
        if following is not None and following not in _CLOSED and following not in ADVERBS:
            return 'adjective'
    return 'verb'
