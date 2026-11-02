import json
from pathlib import Path
import unittest

import profanity
import tone
from profanity import ProfanityRemover, starts_with_vowel_sound

# The case tables below are ported from Core's ProfanityRemoverTests and StyleStageTests.
REMOVALS = [
    ('This is fucking great.', 'This is great.'),
    ('Fucking great.', 'Great.'),
    ('what the fuck is this', 'what is this'),
    ('What the hell is this?', 'What is this?'),
    ('Shit, I forgot.', 'I forgot.'),
    ('I forgot, shit.', 'I forgot.'),
    ('Well, fuck, I forgot.', 'Well, I forgot.'),
    ('Fuck.', ''),
    ('Okay. Fuck. Next one.', 'Okay. Next one.'),
    ('Okay. Fuck.', 'Okay.'),
    ('Damn it, I lost it.', 'I lost it.'),
    ('I lost it, dammit.', 'I lost it.'),
    ('Goddamn, that is good.', 'That is good.'),
    ('It was fucking shit, honestly.', 'It was stuff, honestly.'),
    ('I drove a goddamn car.', 'I drove a car.'),
    ('That is damn good.', 'That is good.'),
    ('Fuck!!', ''),
    ('Fuck;', ''),
    ('Shit... I forgot.', 'I forgot.'),
    ('Okay. Shit!! Next one.', 'Okay. Next one.'),
    ('Fuck?! I forgot.', 'I forgot.'),
    ('This goddamn car is slow.', 'This car is slow.'),
    ('Damn good coffee.', 'Good coffee.'),
    ('It broke and, fuck, it stayed broken.', 'It broke and it stayed broken.'),
]
SWAPPED = [
    ("Don't be an asshole.", "Don't be a jerk."),
    ('He is a motherfucker.', 'He is a jerk.'),
    ('They are assholes.', 'They are jerks.'),
    ('Stop being a bitch about it.', 'Stop being a jerk about it.'),
    ('Such a bitch.', 'Such a jerk.'),
    ('Quit the bullshit and go.', 'Quit the nonsense and go.'),
    ('This is some crap.', 'This is some junk.'),
    ('Talk shit all day.', 'Talk nonsense all day.'),
    ('He talks shit about me.', 'He talks nonsense about me.'),
    ('It is a piece of shit.', 'It is a piece of junk.'),
    ('My shit is gone.', 'My stuff is gone.'),
    ('Pick up this shit.', 'Pick up this stuff.'),
    ('What a pain in the ass.', 'What a pain in the neck.'),
    ('I am pissed off.', 'I am annoyed.'),
    ('Pissed off about it.', 'Annoyed about it.'),
    ('That was a shitty day.', 'That was a bad day.'),
    ('I feel crappy today.', 'I feel bad today.'),
    ('It was a damned fool idea.', 'It was a fool idea.'),
    ('Damned fool.', 'Fool.'),
    ('Stop fucking around.', 'Stop messing around.'),
    ('Quit screwing around.', 'Quit messing around.'),
    ('Stop fucking up the build.', 'Stop messing up the build.'),
    ('I fucked up the build.', 'I messed up the build.'),
    ("Don't fuck up.", "Don't mess up."),
    ('Fuck this job.', 'Forget this job.'),
    ('I hate it, fuck that guy.', 'I hate it, forget that guy.'),
    ('Fuck, asshole.', 'Jerk.'),
    ('Holy shit, we shipped.', 'We shipped.'),
]
VERBS_AND_ARTICLES = [
    ('I shit you not.', 'I kid you not.'),
    ('She bitches about work.', 'She complains about work.'),
    ('They bitched about it all day.', 'They complained about it all day.'),
    ('Stop bitching about it.', 'Stop complaining about it.'),
    ('I hate to bitch.', 'I hate to complain.'),
    ('He shits on everything.', 'He dumps on everything.'),
    ('Stop shitting on the plan.', 'Stop dumping on the plan.'),
    ('Those bitches are loud.', 'Those jerks are loud.'),
    ("I don't give a shit.", "I don't give a hoot."),
    ('I fucked it up.', 'I messed it up.'),
    ('He fucked the whole thing up.', 'He messed the whole thing up.'),
    ('They screwed it up.', 'They screwed it up.'),
    ("Don't fuck it up.", "Don't mess it up."),
    ('Stop fucking it up.', 'Stop messing it up.'),
    ("We're fucked.", "We're messed up."),
    ("Don't fuck with it.", "Don't mess with it."),
    ('Fuck me, that hurt.', 'That hurt.'),
    ('I fucked her.', 'I slept with her.'),
    ('He fucked Sarah.', 'He messed up Sarah.'),
    ('He fucked Excel.', 'He messed up Excel.'),
    ('They fucked us over.', 'They cheated us.'),
    ('They fucked over the team.', 'They cheated the team.'),
    ('You bitch about work.', 'You complain about work.'),
    ('You shit on everything.', 'You dump on everything.'),
    ('You bitch!', 'You jerk!'),
    ("Stop bitchin' about it.", 'Stop complaining about it.'),
    ("She keeps bitchin'.", 'She keeps complaining.'),
    ("That's bitchin'.", "That's great."),
    ('That is a fucking unique idea.', 'That is a unique idea.'),
    ('He has a fucking MBA.', 'He has an MBA.'),
    ('It was a fucking UFO.', 'It was a UFO.'),
    ('It was a fucking FBI agent.', 'It was an FBI agent.'),
    ("An asshole wrote 'an jerk'.", "A jerk wrote 'an jerk'."),
    ('That is a pissed off look.', 'That is an annoyed look.'),
    ('He is a pissed off guy.', 'He is an annoyed guy.'),
    ('She was a bit pissed off.', 'She was a bit annoyed.'),
    ('I was a fucking idiot.', 'I was an idiot.'),
    ('He is an asshole.', 'He is a jerk.'),
    ('He is a fucking annoying guy.', 'He is an annoying guy.'),
    ('That is a fucking university.', 'That is a university.'),
    ('It took a fucking hour.', 'It took an hour.'),
    ('It was a shitty idea.', 'It was a bad idea.'),
    ('A pissed off customer called.', 'An annoyed customer called.'),
    ('That damned asshole.', 'That jerk.'),
    ('Damned asshole.', 'Jerk.'),
    ('Kick his ass.', 'Kick his butt.'),
    ("That bitchin' car.", 'That great car.'),
    ("Bitchin' idea.", 'Great idea.'),
]
DISMISSALS = [
    ('Fuck you.', ''),
    ('Fuck off', ''),
    ('Fuck that.', ''),
    ('Fuck it.', ''),
    ("Fuck it, let's go.", "Let's go."),
    ('Fuck it we ship.', 'We ship.'),
    ('Screw you.', ''),
    ('Okay. Fuck you. Next.', 'Okay. Next.'),
    ('I told him to fuck off.', 'I told him to.'),
    ('Fuck you, man.', 'Man.'),
]
OPENING_WITHOUT_COMMA = [
    ("Fuck this is a test and it's fucking great.", "This is a test and it's great."),
    ('Shit I forgot the keys.', 'I forgot the keys.'),
    ("Damn it's cold.", "It's cold."),
    ("Fuck we're late.", "We're late."),
    ('Okay. Crap we missed it.', 'Okay. We missed it.'),
    ('Fuck, this is a test.', 'This is a test.'),
]
UNTOUCHED = ['Please assess the class.', 'Scunthorpe won.', 'Say hello to the shell.', 'Dickens wrote it.', 'He is a badass.', 'Open shit.py now.', 'See /tmp/crap/file', "It's hell out there.", 'bull-shit', 'Cockburn and Hancock met.', 'The grass is green.', 'A passenger and a compass.']


def strip(text, protected=(), phrases=()):
    return ProfanityRemover(protected, phrases).apply(text)


class ProfanityTests(unittest.TestCase):
    def check(self, pairs):
        for source, expected in pairs:
            with self.subTest(source=source):
                self.assertEqual(strip(source), expected)

    def test_removals(self):
        self.check(REMOVALS)

    def test_swaps(self):
        self.check(SWAPPED)

    def test_verbs_phrasal_verbs_and_articles(self):
        self.check(VERBS_AND_ARTICLES)

    def test_dismissals(self):
        self.check(DISMISSALS)

    def test_opening_swear_before_a_new_clause(self):
        self.check(OPENING_WITHOUT_COMMA)

    def test_ordinary_words_are_left_alone(self):
        for text in UNTOUCHED + ['Shiitake soup and shitake rice.', 'Scrap the plan.', 'A crappie is a fish.',
                                 'Assess the damage.', 'Mr. Cockburn called.', 'Dickens wrote it.',
                                 'I live in Scunthorpe.', 'Class is over.', 'A passage from the book.', 'Bass and glass.',
                                 'We are damned if we do.', 'Damn it all.', 'I screw in the bolt.', 'Tighten the screw.',
                                 'He was pissed.', 'Pick up the shell.', 'A fine class.']:
            with self.subTest(text=text):
                self.assertEqual(strip(text), text)

    def test_speakers_own_articles_stay(self):
        for text in ['A apple a day.', 'He is an hour late.', 'A university, an hour, an honest man.']:
            self.assertEqual(strip(text), text)
        self.assertEqual(strip('A fucking apple a day.'), 'An apple a day.')
        self.assertEqual(strip('A fucking idiot called.'), 'An idiot called.')
        self.assertEqual(strip('An asshole called.'), 'A jerk called.')

    def test_vowel_sound(self):
        for word in ['annoyed', 'idiot', 'hour', 'honest', 'honor', 'umbrella', 'unimportant', 'unanswered', 'egg']:
            self.assertTrue(starts_with_vowel_sound(word), word)
        for word in ['jerk', 'university', 'unit', 'one', 'once', 'euro', 'user', 'usual', 'utility', 'ubiquitous',
                     'unanimous', 'bad', 'hat']:
            self.assertFalse(starts_with_vowel_sound(word), word)

    def test_no_listed_swear_survives_any_frame(self):
        kept = {'damn', 'damned', 'goddamn', 'goddamned'}
        frames = ['%s', 'Well, %s.', 'He said %s again.', 'I %s it.', 'She %s about work.', 'That is a %s idea.',
                  'The %s is here.', "Don't be %s.", '%s the whole thing.', 'They gave two %s.', 'Stop %s around.',
                  'He %s on everything.', 'We %s you not.', 'What a %s!', 'Such %s people.', 'It is %s broken.']
        survivors = []
        for word in sorted(profanity.WORDS - kept):
            for frame in frames:
                for form in (word, word.capitalize()):
                    source = frame % form
                    output = strip(source).lower()
                    tokens = [t for t in __import__('re').split(r"[^\w']+", output) if t]
                    if any(t in profanity.WORDS - kept for t in tokens):
                        survivors.append(source + ' -> ' + output)
        self.assertEqual(survivors, [])

    def test_protected_spellings_and_phrases(self):
        self.assertEqual(strip("Don't be an asshole.", ['asshole']), "Don't be an asshole.")
        self.assertEqual(strip('It is a piece of shit.', (), ['piece of shit']), 'It is a piece of shit.')
        self.assertEqual(strip('Fuck off.', (), ['fuck off']), 'Fuck off.')
        self.assertEqual(strip('Fuck this job.', ['fuck']), 'Fuck this job.')
        self.assertEqual(strip('Ask Damn about it.', ['Damn']), 'Ask Damn about it.')
        self.assertEqual(strip('The crap project is fucking late.', ['crap']), 'The crap project is late.')
        self.assertEqual(strip('Damn IT.', ['IT']), 'Damn IT.')
        self.assertEqual(strip('Damn it.'), '')
        phrases = ['holy shit', 'brain fuck', 'damn good coffee']
        self.assertEqual(strip('Holy shit, this is fucking broken.', (), phrases), 'Holy shit, this is broken.')
        self.assertEqual(strip('Deploy brain fuck.', (), phrases), 'Deploy brain fuck.')
        self.assertEqual(strip('I want damn good coffee.', (), phrases), 'I want damn good coffee.')
        self.assertEqual(strip('Fuck, I want damn good coffee.', (), phrases), 'I want damn good coffee.')
        self.assertEqual(strip('Oh my damn project is late.', (), ['oh my', 'my damn project']),
                         'Oh my damn project is late.')
        self.assertEqual(strip("Fuck we're late.", ['fuck']), "Fuck we're late.")
        self.assertEqual(strip('Fuck this is a test.', (), ['fuck this']), 'Fuck this is a test.')

    def test_capitalisation_repair_skips_spellings_and_identifiers(self):
        self.assertEqual(strip('Fuck, npm is broken.', ['npm']), 'npm is broken.')
        self.assertEqual(strip('Fuck, foo.py is missing.'), 'foo.py is missing.')
        self.assertEqual(strip('Shit, build_2 failed.'), 'build_2 failed.')
        self.assertEqual(strip('Shit, a/b failed.'), 'a/b failed.')
        self.assertEqual(strip('Fuck, iPhone is broken.'), 'iPhone is broken.')
        self.assertEqual(strip('Fuck, the build is broken.'), 'The build is broken.')

    def test_intensifiers_go_only_when_the_next_word_is_modified(self):
        self.assertEqual(strip('It is fucking great'), 'It is great')
        self.assertEqual(strip('fucking great'), 'Great')
        self.assertEqual(strip('this goddamn car'), 'this car')
        self.assertEqual(strip('I want damn good coffee'), 'I want good coffee')
        self.assertEqual(strip('damn good coffee'), 'Good coffee')

    def test_case_insensitive_and_idempotent(self):
        self.assertEqual(strip('WHAT THE FUCK'), 'WHAT')
        self.assertEqual(strip('This is FUCKING great'), 'This is great')
        for source, _ in REMOVALS:
            once = strip(source)
            self.assertEqual(strip(once), once, source)

    def test_empty_and_plain_text(self):
        self.assertEqual(strip(''), '')
        self.assertEqual(strip('Nothing to see here.'), 'Nothing to see here.')


class StyleStageTests(unittest.TestCase):
    def test_presets(self):
        self.assertEqual(tone.options('formal'), ('sentence', 'keep'))
        self.assertEqual(tone.options('casual'), ('sentence', 'drop_final_full_stop'))
        self.assertEqual(tone.options('very_casual'), ('lowercase', 'drop_final_full_stop'))
        with self.assertRaises(ValueError):
            tone.options('shouty')

    def test_no_tone_and_formal_style_change_nothing(self):
        self.assertEqual(tone.apply('Send it to Dana. Thanks.', None), 'Send it to Dana. Thanks.')
        self.assertEqual(tone.apply('Send it to Dana. Thanks.', 'formal'), 'Send it to Dana. Thanks.')

    def test_casual(self):
        casual = lambda text: tone.apply(text, 'casual')
        self.assertEqual(casual('I will be there at five.'), 'I will be there at five')
        self.assertEqual(casual('Sounds good. See you then.'), 'Sounds good. See you then')
        self.assertEqual(casual('Are you coming?'), 'Are you coming?')
        self.assertEqual(casual('That is great!'), 'That is great!')
        three = 'One thing. Two things. Three things.'
        self.assertEqual(casual(three), three)
        words = ' '.join('word%d' % n for n in range(1, 31)) + '.'
        self.assertEqual(casual(words), words)
        for text in ('Well...', 'Well\u2026', 'Bring cups, plates, etc.', 'See you at 5 p.m.'):
            self.assertEqual(casual(text), text)
        self.assertEqual(casual("Hi Dana, I'm late. Sorry."), "Hi Dana, I'm late. Sorry")
        self.assertEqual(casual('See you Friday.'), 'See you Friday')

    def test_very_casual(self):
        very = lambda text, protected=(): tone.apply(text, 'very_casual', protected)
        self.assertEqual(very('Send the notes to Dana. Then book the room.'), 'send the notes to Dana. then book the room')
        self.assertEqual(very('Thanks. See you soon.'), 'thanks. see you soon')
        self.assertEqual(very("Let's go. Don't wait"), "let's go. don't wait")
        self.assertEqual(very("I think I'm right. I'll go."), "I think I'm right. I'll go")
        self.assertEqual(very("I'd say so"), "I'd say so")
        self.assertEqual(very('The NASA team met Dana at the iPhone store. McDonald agreed'),
                         'the NASA team met Dana at the iPhone store. McDonald agreed')
        self.assertEqual(very('OK sure'), 'OK sure')
        self.assertEqual(very('iPhone is out'), 'iPhone is out')
        self.assertEqual(very('Dana called. Congratulations'), 'Dana called. Congratulations')
        self.assertEqual(very('Congratulations to the team. congratulations again'),
                         'congratulations to the team. congratulations again')
        self.assertEqual(very('Dana will call. I asked dana'), 'dana will call. I asked dana')

    def test_protected_words_survive(self):
        self.assertEqual(tone.apply('Mouthtype is fast', 'very_casual', {'Mouthtype'}), 'Mouthtype is fast')
        self.assertEqual(tone.words_of(['Regards from Scott', 'Mouth type']), {'Regards', 'from', 'Scott', 'Mouth', 'type'})

    def test_urls_emails_code_and_quotes_keep_capitals(self):
        very = lambda text: tone.apply(text, 'very_casual')
        self.assertEqual(very('Email Dana@Example.com. Thanks'), 'email Dana@Example.com. thanks')
        self.assertEqual(very('Visit Example.com now'), 'visit Example.com now')
        self.assertEqual(very('Src/Main is ready'), 'Src/Main is ready')
        self.assertEqual(very('Snake_case is fine'), 'Snake_case is fine')
        self.assertEqual(very('See https://Example.com/Path. Then go'), 'see https://Example.com/Path. then go')
        self.assertEqual(very('He said "Hello there". Then left'), 'he said "Hello there". then left')

    def test_lists_keep_markers_and_the_last_line(self):
        self.assertEqual(tone.apply('Groceries\n- Milk\n- Eggs.', 'casual'), 'Groceries\n- Milk\n- Eggs.')
        self.assertEqual(tone.apply('Here is the list:\n- Ship it\n- Call Sam', 'very_casual'),
                         'here is the list:\n- ship it\n- call Sam')
        self.assertEqual(tone.apply('- Milk\n- Eggs', 'very_casual'), '- Milk\n- Eggs')

    def test_formal_tone_softens_swearing_and_others_keep_it(self):
        source = 'This is fucking great.'
        self.assertEqual(tone.apply(source, 'formal'), 'This is great.')
        self.assertIn('fucking', tone.apply(source, 'casual'))
        self.assertIn('fucking', tone.apply(source, 'very_casual'))


class CoreFixtureTests(unittest.TestCase):
    """tone-fixtures.json holds Core's output for every case; check_tone.py keeps it honest on a Mac."""

    def test_python_matches_core(self):
        fixtures = json.loads(Path(__file__).with_name('tone-fixtures.json').read_text())
        self.assertGreater(len(fixtures), 500)
        diverging = []
        for case in fixtures:
            actual = tone.apply(case['input'], case['tone'], case.get('protectedWords', ()), case.get('protectedPhrases', ()))
            if case.get('diverges'):
                diverging.append(case['input'])
                self.assertNotEqual(actual, case['expected'], case['input'])
            else:
                self.assertEqual(actual, case['expected'], case['input'])
        # The part-of-speech guesser stands in for Apple's tagger; these are the sentences it gets differently.
        self.assertLessEqual(len(diverging), 5)


if __name__ == '__main__':
    unittest.main()
