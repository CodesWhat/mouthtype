"""Check the tone and swearing-softening port against actual Core sources.

Needs the Swift compiler and macOS (Core's ProfanityRemover asks Apple's NLTagger for parts of speech). The Python port
answers those questions from lexical.py, so a few sentences can differ from Core; tone-fixtures.json records every one
of them with `diverges: true` and this check fails if that list is wrong in either direction.
"""

import argparse
import json
from pathlib import Path
import re
import tempfile

from setup_speech import bounded_run

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'Sources/MouthtypeCore'
HERE = Path(__file__).resolve().parent
FIXTURES = HERE / 'tone-fixtures.json'
SOURCES = ['Text/ProfanityRemover.swift', 'Text/StyleStage.swift', 'Text/CommonWords.swift', 'Text/TextScan.swift',
           'Text/TextSpan.swift', 'Text/PhraseMatcher.swift', 'Text/PhraseKey.swift', 'TextMetrics.swift']
STUBS = ('public enum FillerRemover { public static let stageName = "filler" }\n'
         'public enum BlendStage { public static let stageName = "blend" }\n')

# Cases from StyleStageTests that call the stage directly: (tone, input, protected words).
STYLE_CASES = [
    ('casual', 'sounds good thanks', ()), ('casual', 'I will be there at five.', ()),
    ('casual', 'Sounds good. See you then.', ()), ('casual', 'One thing. Two things. Three things.', ()),
    ('casual', ' '.join('word%d' % n for n in range(1, 31)) + '.', ()), ('casual', 'Well...', ()),
    ('casual', 'Well…', ()), ('casual', 'Bring cups, plates, etc.', ()), ('casual', 'See you at 5 p.m.', ()),
    ('casual', "Hi Dana, I'm late. Sorry.", ()), ('casual', 'See you Friday.', ()),
    ('casual', 'Are you coming?', ()), ('casual', 'That is great!', ()),
    ('casual', 'Here is the list:\n- Ship it\n- Call Sam', ()), ('casual', 'Groceries\n- Milk\n- Eggs.', ()),
    ('casual', 'Here is the plan\n1. Ship it\n2. Call Sam.', ()),
    ('very_casual', 'Send the notes to Dana. Then book the room.', ()), ('very_casual', 'Thanks. See you soon.', ()),
    ('very_casual', "Let's go. Don't wait", ()), ('very_casual', "I think I'm right. I'll go.", ()),
    ('very_casual', "I'd say so", ()),
    ('very_casual', 'The NASA team met Dana at the iPhone store. McDonald agreed', ()),
    ('very_casual', 'OK sure', ()), ('very_casual', 'iPhone is out', ()),
    ('very_casual', 'Dana called. Congratulations', ()),
    ('very_casual', 'Congratulations to the team. congratulations again', ()),
    ('very_casual', 'Dana will call. I asked dana', ()),
    ('very_casual', 'Mouthtype is fast', ('Mouthtype',)), ('very_casual', 'Regards from Scott', ('Regards',)),
    ('very_casual', 'Email Dana@Example.com. Thanks', ()), ('very_casual', 'Visit Example.com now', ()),
    ('very_casual', 'Src/Main is ready', ()), ('very_casual', 'Snake_case is fine', ()),
    ('very_casual', 'See https://Example.com/Path. Then go', ()),
    ('very_casual', 'He said "Hello there". Then left', ()),
    ('very_casual', 'He said “Hello there”. Then left', ()),
    ('very_casual', 'Are you coming?', ()), ('very_casual', 'That is great!', ()),
    ('very_casual', '1. Ship it\n2. Call Sam about 20 retries', ()),
    ('very_casual', 'Here is the list:\n- Ship it\n- Call Sam', ()),
    ('very_casual', 'Here is the plan\n1. Ship it\n2. Call Sam.', ()), ('very_casual', '- Milk\n- Eggs', ()),
    ('very_casual', 'Thanks   a lot', ()),
    ('very_casual', 'Hey, are we still on for dinner tonight? I can be there by seven.', ()),
    ('casual', 'Quick update: the deploy went out, and the dashboards look fine.', ()),
    ('very_casual', 'Quick update: the deploy went out, and the dashboards look fine.', ()),
    ('very_casual', 'Hi Priya,', ()), ('very_casual', 'Thanks for the signed build. The release notes are in the PR.', ()),
    ('casual', 'Talk soon.', ()), ('very_casual', 'Talk soon.', ()),
    ('casual', 'Sure, I’ll send the invoice tomorrow morning and copy Dan.', ()),
    ('very_casual', 'Sure, I’ll send the invoice tomorrow morning and copy Dan.', ()),
]
# Direct ProfanityRemover cases from ProfanityRemoverTests that take protections.
PROTECTED_CASES = [
    ("Don't be an asshole.", ('asshole',), ()), ('It is a piece of shit.', (), ('piece of shit',)),
    ('Fuck off.', (), ('fuck off',)), ('Fuck this job.', ('fuck',), ()), ('Fuck, npm is broken.', ('npm',), ()),
    ('Holy shit, this is fucking broken.', (), ('holy shit', 'brain fuck', 'damn good coffee')),
    ('Deploy brain fuck.', (), ('holy shit', 'brain fuck', 'damn good coffee')),
    ('I want damn good coffee.', (), ('holy shit', 'brain fuck', 'damn good coffee')),
    ('Fuck, I want damn good coffee.', (), ('holy shit', 'brain fuck', 'damn good coffee')),
    ('Oh my damn project is late.', (), ('oh my', 'my damn project')), ('Damn IT.', ('IT',), ()),
    ('Damn it.', (), ()), ('Ask Damn about it.', ('Damn',), ()),
    ('The crap project is fucking late.', ('crap',), ()), ("Fuck we're late.", ('fuck',), ()),
    ('Fuck this is a test.', (), ('fuck this',)), ('I love Crappy Bird, it is fucking hard.', ('Crappy', 'Bird'), ()),
    ('WHAT THE FUCK', (), ()), ('This is FUCKING great', (), ()),
]
WORD_FRAMES = [
    ('It is fucking W.', 'adj noun'), ('It was a fucking W.', 'adj noun'), ('That goddamn W is late.', 'noun'),
    ('He is a damn W.', 'noun adj'), ('I want damn W.', 'adj noun'), ('The fucking W is here.', 'noun'),
    ('They are fucking W.', 'part adj'), ('It is fucking W again.', 'part adj'), ('I fucking W it.', 'verb'),
    ('He is a fucking W guy.', 'adj part'), ('Fuck I W it.', 'verb'), ('Shit they W the keys.', 'verb'),
    ('Damn we W it.', 'verb'), ('Okay. Fuck she W.', 'verb'), ('The W shits on it.', 'noun'),
    ('The W bitches about it.', 'noun'), ('Stop fucking W it.', 'verb'),
]
WORDS = {
    'adj': 'amazing awesome annoying awful beautiful boring brilliant broken busy cold cool crazy cute dead dumb easy '
           'expensive fast funny gorgeous hard heavy hilarious hot huge incredible insane interesting lazy loud lucky '
           'massive nice perfect pretty ridiculous rude scary slow smart stupid sweet terrible tired tough ugly '
           'unbelievable useless weird wonderful unique great good bad big small late early',
    'noun': 'car idiot job boss coffee computer phone traffic weather meeting party game movie song dog cat house door '
            'window printer router server database bug keys keyboard mouse screen laptop battery bridge road street '
            'town city country company customer client manager developer engineer driver neighbor teacher kid friend '
            'family brother sister mother father wife husband guy girl lawyer doctor government tax money price bill '
            'rent bank card password email spam video photo camera app site website browser tab link button menu form '
            'report plan budget deadline contract invoice order package delivery truck bus train plane flight hotel '
            'room bed kitchen garden shop store restaurant food lunch pizza beer wine water music band show story '
            'joke lie truth reason fact mess disaster nightmare circus zoo idea test project problem question day '
            'week hour year',
    'verb': 'love hate need want like see help try start stop move open close break fix eat drink sleep run work make '
            'take get give tell think know say show bring buy sell build call check forgot lost missed broke fixed '
            'ruined killed screwed',
    'part': 'broken stuck done finished fixed lost dead gone ruined screwed busted slow tired',
}


def swift_strings(source):
    return re.findall(r'"((?:[^"\\]|\\.)*)"', source)


def swift_literal(text, name):
    match = re.search(r'\b' + name + r'\b[^=\n]*=\s*(\[.*?\n?\s*\])', text, re.S)
    assert match, 'Missing Swift list ' + name
    return match.group(1)


def swift_set(text, name):
    return {item for item in swift_strings(swift_literal(text, name))}


def swift_dict(text, name):
    items = swift_strings(swift_literal(text, name))
    return dict(zip(items[0::2], items[1::2]))


def check_tables():
    import lexical  # noqa: F401  (imported so a broken module fails here)
    import profanity
    import tone
    source = (CORE / 'Text/ProfanityRemover.swift').read_text()
    sets = {'words': profanity.WORDS, 'afterThe': profanity.AFTER_THE, 'damnWords': profanity.DAMN_WORDS,
            'standalone': profanity.STANDALONE, 'interjections': profanity.INTERJECTIONS,
            'intensifiers': profanity.INTENSIFIERS, 'gerundTriggers': profanity.GERUND_TRIGGERS,
            'auxiliaries': profanity.AUXILIARIES, 'personObjects': profanity.PERSON_OBJECTS,
            'talkVerbs': profanity.TALK_VERBS, 'verbLeaders': profanity.VERB_LEADERS,
            'nounLeaders': profanity.NOUN_LEADERS, 'idiomCounts': profanity.IDIOM_COUNTS,
            'giveVerbs': profanity.GIVE_VERBS, 'forgetObjects': profanity.FORGET_OBJECTS,
            'phrasalStops': profanity.PHRASAL_STOPS, 'droppedAdjectives': profanity.DROPPED_ADJECTIVES}
    for name, expected in sets.items():
        assert swift_set(source, name) == set(expected), 'Profanity list is stale relative to Core: ' + name
    dicts = {'swaps': profanity.SWAPS, 'messForms': profanity.MESS_FORMS, 'cheatForms': profanity.CHEAT_FORMS,
             'sleepForms': profanity.SLEEP_FORMS, 'messUpForms': profanity.MESS_UP_FORMS}
    for name, expected in dicts.items():
        assert swift_dict(source, name) == expected, 'Profanity table is stale relative to Core: ' + name
    style = (CORE / 'Text/StyleStage.swift').read_text()
    assert swift_set(style, 'abbreviations') == set(tone.ABBREVIATIONS), 'Tone abbreviations are stale'
    assert re.search(r'shortMessageWords = ' + str(tone.SHORT_MESSAGE_WORDS), style)
    assert re.search(r'shortMessageSentences = ' + str(tone.SHORT_MESSAGE_SENTENCES), style)
    common = (CORE / 'Text/CommonWords.swift').read_text()
    raw = re.search(r'raw = """(.*?)"""', common, re.S).group(1).replace('\\\n', ' ').split()
    assert set(raw) == set(tone.COMMON_WORDS), 'Common words are stale relative to Core'
    print('Profanity and tone tables match Core')


def corpus():
    tests = (CORE.parents[1] / 'Tests/MouthtypeCoreTests/ProfanityRemoverTests.swift').read_text()
    pair = re.compile(r'^\s*\("((?:[^"\\]|\\.)*)", "((?:[^"\\]|\\.)*)"\),', re.M)
    cases = [{'tone': 'formal', 'input': json.loads('"%s"' % match.group(1).replace('\\u{2019}', '\\u2019'))}
             for match in pair.finditer(tests)]
    for text in ('Shiitake soup and shitake rice.', 'Scrap the plan.', 'A crappie is a fish.', 'Assess the damage.',
                 'We are damned if we do.', 'Damn it all.', 'I screw in the bolt.', 'He was pissed.', 'A apple a day.',
                 'A university, an hour, an honest man.', 'A fucking apple a day.', 'A fucking idiot called.',
                 'An asshole called.', 'Fuck you, man.', 'Fuck, asshole.', 'Holy shit, we shipped.'):
        cases.append({'tone': 'formal', 'input': text})
    for tone_name, text, protected in STYLE_CASES:
        cases.append({'tone': tone_name, 'input': text, 'protectedWords': list(protected)})
    for text, protected, phrases in PROTECTED_CASES:
        cases.append({'tone': 'formal', 'input': text, 'protectedWords': list(protected), 'protectedPhrases': list(phrases)})
    for frame, categories in WORD_FRAMES:
        words = []
        for category in categories.split():
            words += WORDS[category].split()
        words = list(dict.fromkeys(words))
        for word in words[::3]:
            cases.append({'tone': 'formal', 'input': frame.replace('W', word)})
    seen, result = set(), []
    for case in cases:
        key = json.dumps(case, sort_keys=True)
        if key not in seen:
            seen.add(key)
            result.append(case)
    for index, case in enumerate(result):
        case['name'] = 'tone-%d' % index
    return result


def build(directory):
    directory = Path(directory)
    (directory / 'Stubs.swift').write_text(STUBS)
    record = (CORE / 'Store/DictationTypes.swift').read_text()
    start = record.index('public struct EditOp:')
    end = record.index('\npublic enum CorrectionKind:', start)
    (directory / 'EditOp.swift').write_text(record[start:end])
    binary = directory / 'verify-tone'
    bounded_run(['swiftc', '-O', '-o', str(binary), *(str(CORE / name) for name in SOURCES), str(directory / 'Stubs.swift'),
                 str(directory / 'EditOp.swift'), str(HERE / 'verify_tone.swift')], 300)
    return binary


def core_outputs(binary, cases, directory):
    path = Path(directory) / 'cases.json'
    path.write_text(json.dumps(cases, ensure_ascii=False))
    observed = json.loads(bounded_run([str(binary), str(path)], 60))
    assert [item['name'] for item in observed] == [case['name'] for case in cases]
    return [item['output'] for item in observed]


def python_output(case):
    import tone
    return tone.apply(case['input'], case['tone'], case.get('protectedWords', ()), case.get('protectedPhrases', ()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write-fixtures', action='store_true', help='Regenerate tone-fixtures.json from Core')
    args = parser.parse_args()
    check_tables()
    with tempfile.TemporaryDirectory(prefix='mouthtype-tone-check-') as directory:
        binary = build(directory)
        if args.write_fixtures:
            cases = corpus()
            for case, output in zip(cases, core_outputs(binary, cases, directory), strict=True):
                case['expected'] = output
                if python_output(case) != output:
                    case['diverges'] = True
            FIXTURES.write_text(json.dumps(cases, ensure_ascii=False, indent=1) + '\n')
            print('Wrote %d fixtures, %d diverge from Core' % (len(cases), sum(1 for case in cases if case.get('diverges'))))
            return
        cases = json.loads(FIXTURES.read_text())
        outputs = core_outputs(binary, cases, directory)
        for case, output in zip(cases, outputs, strict=True):
            assert output == case['expected'], ('Core changed', case['input'], output, case['expected'])
            matches = python_output(case) == output
            assert matches != bool(case.get('diverges')), ('Divergence record is wrong', case['input'])
        print('Core tone fixtures: %d checked, %d known divergences' % (
            len(cases), sum(1 for case in cases if case.get('diverges'))))


if __name__ == '__main__':
    main()
