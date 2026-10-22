import unittest

import smart


class GuardTests(unittest.TestCase):
    def accept(self, source, output):
        text, reason = smart.check(source, output)
        self.assertIsNone(reason, reason)
        return text

    def reject(self, source, output, contains):
        text, reason = smart.check(source, output)
        self.assertIsNone(text)
        self.assertIn(contains, reason)

    def test_ordinary_cleanup_is_accepted(self):
        self.assertEqual(self.accept('um can you send me the uh the file', 'Can you send me the file?'),
                         'Can you send me the file?')
        self.assertEqual(self.accept("Let's do coffee at two actually three", "Let's do coffee at 3."),
                         "Let's do coffee at 3.")
        self.accept('Send it to Dana, no wait, send it to Priya.', 'Send it to Priya.')
        self.accept('the deploy is basically done we just need to flip the flag',
                    'The deploy is basically done. We just need to flip the flag.')

    def test_empty_runaway_and_invented_text_are_rejected(self):
        self.reject('hello there', '', 'empty')
        self.reject('hello there', ' '.join(['word'] * 60), 'length')
        self.reject('please book the meeting room', 'Done. The large meeting room is reserved for next week with coffee and snacks.', 'new')
        self.reject('what time is the standup', 'The standup is at nine.', 'question')

    def test_negation_certainty_and_time_of_day_are_protected(self):
        self.reject("I don't want the red one", 'I want the red one.', 'negation')
        self.reject('we should maybe ship it', 'We will ship it.', 'certainty')
        self.reject('meet me at three', 'Meet me at 3 PM.', 'time of day')
        self.accept('meet me at three p m', 'Meet me at 3 PM.')

    def test_numbers_names_acronyms_and_literals_survive(self):
        self.reject('order twenty five units', 'Order units.', 'number')
        self.accept('order twenty five units', 'Order 25 units.')
        self.reject('order twenty five units', 'Order 26 units.', 'number')
        self.accept('order twenty units', 'Order 20 units.')
        self.accept('order 25 units please', 'Order 25 units, please.')
        self.reject('tell Priya about the launch', 'Tell her about the launch.', 'name')
        self.reject('plug in the USB cable', 'Plug in the cable.', 'acronym')
        self.reject('run `make test` now', 'Run make now.', 'literal')
        self.accept('open the file config dot yaml', 'Open the file config.yaml.')

    def test_terminal_mark_and_wrappers(self):
        self.assertEqual(smart.restoring_terminal('Is it ready?', 'It is ready.'), 'It is ready?')
        self.assertEqual(smart.restoring_terminal('Ship it', 'Ship it.'), 'Ship it.')
        self.assertEqual(smart.sanitize('<think>plan</think><transcript>Hello</transcript>\n'), 'Hello')

    def test_eligibility_and_budgets(self):
        self.assertFalse(smart.eligible('yes'))
        self.assertTrue(smart.eligible('yes please'))
        self.assertFalse(smart.eligible(' '.join(['w'] * 401)))
        self.assertAlmostEqual(smart.budget_seconds('fast', 20), 1.7)
        self.assertEqual(smart.budget_seconds('fast', 400), 10.0)
        self.assertAlmostEqual(smart.budget_seconds('thorough', 20), 6.0)
        self.assertEqual(smart.budget_seconds('thorough', 400), 30.0)


class OrderAndMeridiemTests(unittest.TestCase):
    def reason(self, source, output):
        return smart.check(source, output)[1]

    def test_swapped_times_and_numbers_are_rejected(self):
        for source, output in [
            ('the shop is open 9 AM to 5 PM', 'The shop is open 5 PM to 9 AM.'),
            ('call at 3:30 PM then at 9:15 AM', 'Call at 9:15 AM, then at 3:30 PM.'),
            ('meet at 9 AM then at 9 PM', 'Meet at 9 PM, then at 9 AM.'),
            ('we need two chairs and five tables', 'We need five tables and two chairs.'),
            ('the shop is open nine to five', 'The shop is open 5 to 9.'),
        ]:
            self.assertIsNotNone(self.reason(source, output), output)

    def test_normal_reformatting_keeps_order(self):
        for source, output in [
            ('the shop is open 9 AM to 5 PM', 'The shop is open 9 AM to 5 PM.'),
            ('we need three to five chairs', 'We need 3\u20135 chairs.'),
            ('the shop is open nine to five', 'The shop is open 9 to 5.'),
            ('call at 3:30 PM then at 9:15 AM', 'Call at 3:30 PM, then at 9:15 AM.'),
            ('we need two chairs and five tables', 'We need 2 chairs and 5 tables.'),
            ('pick one two three', 'Pick 1, 2, 3.'),
            ('i have 5 cats then 9 dogs and 5 birds', 'I have 5 cats, 9 dogs, and 5 birds.'),
            ('meet at five no wait nine', 'Meet at nine.'),
        ]:
            self.assertIsNone(self.reason(source, output), output)

    def test_a_spoken_meridiem_stays_with_its_own_hour(self):
        day = 'meet from nine a m to five p m tomorrow'
        self.assertIsNone(self.reason(day, 'Meet from 9 AM to 5 PM tomorrow.'))
        self.assertIsNotNone(self.reason(day, 'Meet from 9 PM to 5 AM tomorrow.'))
        self.assertIsNotNone(self.reason(day, 'Meet from 5 AM to 9 PM tomorrow.'))
        self.assertIsNotNone(self.reason(day, 'Meet from 9 AM to 6 PM tomorrow.'))
        half = 'call at three thirty p m then at nine fifteen a m'
        self.assertIsNone(self.reason(half, 'Call at 3:30 PM, then at 9:15 AM.'))
        self.assertIsNotNone(self.reason(half, 'Call at 3:30 AM, then at 9:15 PM.'))

    def test_a_spoken_oh_minute_meridiem_stays_with_its_own_time(self):
        half = 'call at three thirty p m then at nine oh five a m'
        self.assertIsNone(self.reason(half, 'Call at 3:30 PM, then at 9:05 AM.'))
        self.assertIsNotNone(self.reason(half, 'Call at 3:30 AM, then at 9:05 PM.'))

    def test_a_digit_or_colon_before_a_number_is_not_a_meridiem_time(self):
        self.assertEqual(smart.meridiem_pairs('meet at 9 pm'), {'9:00p'})
        self.assertEqual(smart.meridiem_pairs('123 pm'), set())
        self.assertEqual(smart.meridiem_pairs('a1 pm'), set())
        self.assertEqual(smart.meridiem_pairs('10:30:45 pm'), set())

    def test_spoken_meridiem_pairs_read_hours_and_minutes(self):
        self.assertEqual(smart.spoken_meridiem_pairs('three oh five p m'), {'3:05p'})
        self.assertEqual(smart.spoken_meridiem_pairs('ten forty five a m'), {'10:45a'})
        self.assertEqual(smart.spoken_meridiem_pairs('nine a m to five p m'), {'9:00a', '5:00p'})


class UnwrapTests(unittest.TestCase):
    FRAMED = ('can you send the quarterly report to Dana by Friday afternoon so we can review it before the meeting')
    CLEAN = 'Can you send the quarterly report to Dana by Friday afternoon so we can review it before the meeting.'

    def test_markup_inside_text_is_untouched(self):
        for text in ('<svg><path d="M0 0"/></svg>', '<transcript>Hi</transcript> is a tag.', 'Run <b>bold</b> text.'):
            self.assertEqual(smart.unwrap(text, ''), text)
        self.assertEqual(smart.unwrap('<text>Hello</text> there', '<text>Hello'), '<text>Hello</text> there')

    def test_wrapper_tags_are_removed_unless_the_source_had_them(self):
        self.assertEqual(smart.unwrap('<text>\nHello.\n</text>\n', 'hello'), 'Hello.')
        self.assertEqual(smart.unwrap('<transcript>Hello.</transcript>', 'hello'), 'Hello.')
        wrapped = '<text>Hello.</text>'
        self.assertEqual(smart.unwrap(wrapped, wrapped), wrapped)

    def test_model_preambles_are_removed_but_the_sources_own_are_kept(self):
        self.assertEqual(smart.unwrap('Here is the corrected text:\n\nHe and I go.', 'me and him goes'), 'He and I go.')
        self.assertEqual(smart.unwrap("Sure! Here's the shorter version:\nHe goes.", 'he goes now'), 'He goes.')
        self.assertEqual(smart.unwrap('Here is the corrected text: He goes.', 'he goes'), 'He goes.')
        own = 'Here is the corrected text: He goes.'
        self.assertEqual(smart.unwrap(own, own), own)
        self.assertEqual(smart.unwrap('Here is the list', 'x'), 'Here is the list')
        self.assertEqual(smart.unwrap('Here is the cleaned transcript: We meet at noon.', 'we meet at noon'),
                         'We meet at noon.')

    def test_a_preamble_dictated_after_a_self_correction_is_kept(self):
        said = 'here is the transcript no wait here is the cleaned transcript we leave at nine'
        out = 'Here is the transcript, no wait, here is the cleaned transcript: We leave at nine.'
        framed = 'Here is the cleaned transcript: We leave at nine.'
        self.assertEqual(smart.unwrap(framed, said), framed)
        self.assertEqual(smart.unwrap(out, said), out)
        self.assertEqual(smart.unwrap(framed, 'we leave at nine'), 'We leave at nine.')
        self.assertEqual(smart.unwrap('Here is the cleaned text:\nWe leave at nine.', said), 'We leave at nine.')
        lead_in = 'here is the cleaned transcript we meet'
        self.assertEqual(smart.unwrap('Here is the cleaned transcript: We meet', lead_in),
                         'Here is the cleaned transcript: We meet')

    def test_only_preambles_that_name_the_output_are_removed(self):
        self.assertEqual(smart.unwrap("Here's the rewritten text:\nShip Friday.", 'ship friday'), 'Ship Friday.')
        self.assertEqual(smart.unwrap('Here is the more formal version:\nShip Friday.', 'ship friday'), 'Ship Friday.')
        self.assertEqual(smart.unwrap('Here is a version of the selected text:\nShip Friday.', 'ship friday'),
                         'Ship Friday.')
        plan = "Here's the plan for Alice:\nShip Friday."
        self.assertEqual(smart.unwrap(plan, "Here's the plan for Alice:\nShip Friday."), plan)
        self.assertEqual(smart.unwrap(plan, 'ship friday'), plan)
        lst = 'Here are the items:\n- a'
        self.assertEqual(smart.unwrap(lst, 'items a'), lst)

    def test_quotes_and_fences(self):
        self.assertEqual(smart.unwrap('"He goes."', 'he goes'), 'He goes.')
        self.assertEqual(smart.unwrap('\u201cHe goes.\u201d', 'he goes'), 'He goes.')
        self.assertEqual(smart.unwrap('"He goes."', '"he goes."'), '"He goes."')
        self.assertEqual(smart.unwrap('"a" and "b"', 'a and b'), '"a" and "b"')
        self.assertEqual(smart.unwrap('```\nHe goes.\n```', 'he goes'), 'He goes.')
        self.assertEqual(smart.unwrap('```swift\nlet x = 1\n```', 'let x=1'), 'let x = 1')
        self.assertEqual(smart.unwrap('```\ncode\n```', '```\ncode\n```'), '```\ncode\n```')
        self.assertEqual(smart.unwrap('Here is the edited text:\n"He goes."', 'he goes'), 'He goes.')

    def test_check_unwraps_model_framing_before_the_guard(self):
        for output in ('Here is the cleaned transcript:\n' + self.CLEAN, "Here's the cleaned text: " + self.CLEAN,
                       'Sure, here is the corrected version:\n' + self.CLEAN, '"' + self.CLEAN + '"',
                       '\u201c' + self.CLEAN + '\u201d', '```\n' + self.CLEAN + '\n```'):
            text, reason = smart.check(self.FRAMED, output)
            self.assertIsNone(reason, reason)
            self.assertEqual(text, self.CLEAN)

    def test_check_keeps_framing_that_was_dictated(self):
        for text in ('"we should leave earlier to beat the traffic"',
                     'here is the cleaned text: we should leave earlier to beat the traffic',
                     "Here's the cleaned text we should leave earlier to beat the traffic",
                     'here is the plan for Alice: we should leave earlier to beat the traffic'):
            result, reason = smart.check(text, text)
            self.assertIsNone(reason, reason)
            self.assertEqual(result, text)
        said = 'here is the cleaned transcript we should leave earlier to beat the traffic'
        result, _ = smart.check(said, 'Here is the cleaned transcript: We should leave earlier to beat the traffic.')
        self.assertTrue(result.startswith('Here is the cleaned transcript'), result)

    def test_check_survives_a_quote_style_swap(self):
        for source, output in (('"we should leave earlier\nto beat the traffic"', '\u201cwe should leave earlier\nto beat the traffic\u201d'),
                               ('\u201cwe should leave earlier\nto beat the traffic\u201d', '"we should leave earlier\nto beat the traffic"')):
            result, reason = smart.check(source, output)
            self.assertIsNone(reason, reason)
            self.assertEqual(result, output)

    def rej(self, source, output):
        return smart.rejection(source, output)

    def test_compound_spoken_numbers_may_become_one_value_but_only_the_right_one(self):
        offer = 'we offer twenty four seven phone support'
        self.assertIsNone(self.rej(offer, 'We offer 24/7 phone support.'))
        self.assertIsNotNone(self.rej(offer, 'We offer 25/7 phone support.'))
        self.assertIsNotNone(self.rej(offer, 'We offer 24/8 phone support.'))
        hours = "it's about fifteen hundred hours away"
        self.assertIsNone(self.rej(hours, "It's about 1,500 hours away."))
        self.assertIsNotNone(self.rej(hours, "It's about 1,600 hours away."))
        self.assertIsNotNone(self.rej(hours, "It's about 15 hours away."))

    def test_a_tens_word_before_an_ordinal_combines_only_into_the_ordinal_form(self):
        move = 'launch is moving from the fifteenth to the twenty second because legal is open'
        self.assertIsNone(self.rej(move, 'Launch is moving from the 15th to the 22nd because legal is open.'))
        self.assertIsNone(self.rej(move, 'Launch is moving from the 15th to the twenty second because legal is open.'))
        self.assertIsNotNone(self.rej(move, 'Launch is moving from the 15th to the 21st because legal is open.'))
        self.assertIsNotNone(self.rej('a twenty second timeout applies', 'A 22-second timeout applies.'))
        self.assertIsNotNone(self.rej('a twenty second timeout applies', 'A 22 timeout applies.'))
        self.assertIsNotNone(self.rej('a thirty second ad plays first', 'A 32-second ad plays first.'))
        self.assertIsNotNone(self.rej('a thirty second ad plays first', 'A 30-second ad plays first.'))
        self.assertIsNotNone(self.rej('twenty first time buyers get a discount', '21 time buyers get a discount.'))
        self.assertIsNone(self.rej('twenty first time buyers get a discount', '21st time buyers get a discount.'))
        self.assertIsNone(self.rej('a twenty second timeout applies', 'A twenty second timeout applies.'))

    def test_a_dropped_scale_word_is_rejected_unless_its_value_is_written(self):
        money = 'the marketing budget for this project is five hundred thousand dollars'
        self.assertIsNone(self.rej(money, 'The marketing budget for this project is $500,000.'))
        self.assertIsNone(self.rej(money, 'The marketing budget for this project is five hundred thousand dollars.'))
        self.assertIsNotNone(self.rej(money, 'The marketing budget for this project is $500.'))
        self.assertIsNotNone(self.rej(money, 'The marketing budget for this project is $500 thousand.'))
        self.assertIsNone(self.rej('it costs two million dollars', 'It costs $2 million.'))
        self.assertIsNotNone(self.rej('it costs two million dollars', 'It costs $2.'))
        self.assertIsNotNone(self.rej('it costs two million dollars', 'It costs $2,000.'))
        self.assertIsNone(self.rej('it takes four hundred and twelve days', 'It takes 412 days.'))
        self.assertIsNotNone(self.rej('it takes four hundred and twelve days', 'It takes 4 and 12 days.'))

    def test_a_spoken_year_needs_a_date_cue(self):
        due = "it's due on March third twenty twenty six"
        self.assertIsNone(self.rej(due, "It's due on March 3rd, 2026."))
        self.assertIsNotNone(self.rej(due, "It's due on March 3rd, 2025."))
        self.assertIsNone(self.rej('we shipped in twenty twenty six.', 'We shipped in 2026.'))
        self.assertIsNotNone(self.rej('we shipped in twenty twenty six.', 'We shipped in 2025.'))
        self.assertIsNotNone(self.rej('it takes twenty thirty minutes', 'It takes 2030 minutes.'))
        self.assertIsNone(self.rej('it takes twenty thirty minutes', 'It takes twenty thirty minutes.'))
        self.assertIsNotNone(self.rej('take twenty twenty six and forty', 'Take 2026 and 40.'))
        self.assertIsNotNone(self.rej('we had nineteen twenty people there', 'We had 1920 people there.'))
        self.assertIsNotNone(self.rej('we shipped in twenty thirty minutes late', 'We shipped in 2030 minutes late.'))

    def test_spoken_digit_strings_may_become_written_ones_without_changing_a_digit(self):
        phone = "my number is five five five, oh one two three and I'm home"
        self.assertIsNone(self.rej(phone, "My number is 555-0123 and I'm home."))
        self.assertIsNone(self.rej(phone, "My number is 5550123 and I'm home."))
        self.assertIsNotNone(self.rej(phone, "My number is 555-0124 and I'm home."))
        self.assertIsNotNone(self.rej(phone, "My number is 555-123 and I'm home."))

    def test_a_colon_time_needs_a_time_cue_and_never_becomes_the_form_without_one(self):
        deploy = 'a deploy went out at nine oh five and broke the pool'
        self.assertIsNone(self.rej(deploy, 'A deploy went out at 9:05 and broke the pool.'))
        self.assertIsNotNone(self.rej(deploy, 'A deploy went out at 9:06 and broke the pool.'))
        self.assertIsNotNone(self.rej(deploy, 'A deploy went out at 905 and broke the pool.'))
        self.assertIsNotNone(self.rej('book room nine oh five for the team', 'Book room 9:05 for the team.'))
        self.assertIsNone(self.rej('book room nine oh five for the team', 'Book room 905 for the team.'))
        self.assertIsNotNone(self.rej('the deploy went out at 9:05 and broke it', 'The deploy went out at 905 and broke it.'))
        self.assertIsNone(self.rej('the deploy went out at 9:05 and broke it', 'The deploy went out at 9:05 and broke it.'))
        self.assertIsNone(self.rej('the API returns a four oh four error', 'The API returns a 404 error.'))
        self.assertIsNotNone(self.rej('the API returns a four oh four error', 'The API returns a 405 error.'))
        self.assertIsNotNone(self.rej('the API returns a four oh four error', 'The API returns a 4:04 error.'))

    def test_only_the_ab_test_pair_may_become_a_slash(self):
        test = 'we decided to run an AB test for two weeks'
        self.assertIsNone(self.rej(test, 'We decided to run an A/B test for two weeks.'))
        self.assertIsNotNone(self.rej(test, 'We decided to run an A/C test for two weeks.'))
        self.assertIsNotNone(self.rej('please ask AB about the plan', 'Please ask A/B about the plan.'))
        self.assertIsNone(self.rej('please ask AB about the plan', 'Please ask AB about the plan.'))

    def test_each_meridiem_stays_with_its_own_time(self):
        day = 'meet from 9 AM to 5 PM tomorrow'
        self.assertIsNone(self.rej(day, 'Meet from 9 AM to 5 PM tomorrow.'))
        for output in ('Meet from 9 PM to 5 AM tomorrow.', 'Meet from 5 AM to 9 PM tomorrow.',
                       'Meet from 9pm to 5am tomorrow.', 'Meet from 5pm to 9am tomorrow.',
                       'Meet from 9 AM to 5 AM tomorrow.'):
            self.assertIsNotNone(self.rej(day, output), output)
        self.assertIsNotNone(self.rej('meet from 9 AM to 5 tomorrow', 'Meet from 9 AM to 5 PM tomorrow.'))
        self.assertIsNotNone(self.rej('meet at 3 tomorrow', 'Meet at 3 PM tomorrow.'))
        self.assertIsNotNone(self.rej('call at 3:30 PM then at 9:15 AM', 'Call at 3:30 PM then at 9:15 PM.'))
        self.assertIsNone(self.rej('call at 3:30 PM then at 9:15 AM', 'Call at 3:30 PM, then at 9:15 AM.'))

    def test_the_guard_alone_rejects_a_lowercase_meridiem(self):
        self.assertIsNotNone(self.rej('meet at 3:15 PM tomorrow', 'Meet at 3:15pm tomorrow.'))
        self.assertIsNotNone(self.rej('meet at 3:15 PM tomorrow', 'Meet at 3:15 AM tomorrow.'))

    def test_a_lowercased_meridiem_is_written_back_but_a_changed_one_stays_changed(self):
        restored = smart.restoring_meridiem
        self.assertEqual(restored('meet at 3:15 PM tomorrow', 'Meet at 3:15pm tomorrow.'), 'Meet at 3:15 PM tomorrow.')
        self.assertEqual(restored('the meeting is at 9:30 AM and lunch at 12 PM', 'The meeting is at 9:30am and lunch at 12pm.'),
                         'The meeting is at 9:30 AM and lunch at 12 PM.')
        self.assertEqual(restored('meet at 3 PM', 'Meet at 3 PM.'), 'Meet at 3 PM.')
        # The source never spelled a time that way, so the output is left alone.
        self.assertEqual(restored('meet at 3:15 tomorrow', 'Meet at 3:15pm tomorrow.'), 'Meet at 3:15pm tomorrow.')
        # The model's own change of AM to PM is kept, so the time-of-day check still rejects it.
        changed = restored('meet at 3:15 AM tomorrow', 'Meet at 3:15pm tomorrow.')
        self.assertEqual(changed, 'Meet at 3:15 PM tomorrow.')
        self.assertIsNotNone(self.rej('meet at 3:15 AM tomorrow', changed))
        # Words that merely end in "am" or "pm" are not times.
        self.assertEqual(restored('meet at 3 PM', 'Meet at 3 PM, then the team'), 'Meet at 3 PM, then the team')

    def test_check_accepts_a_model_that_lowercases_a_meridiem_and_rejects_one_that_changes_it(self):
        text, reason = smart.check('Meet at 3:15 PM tomorrow', 'Meet at 3:15pm tomorrow.')
        self.assertIsNone(reason, reason)
        self.assertEqual(text, 'Meet at 3:15 PM tomorrow.')
        text, reason = smart.check('Meet at 3:15 PM tomorrow', 'Meet at 3:15am tomorrow.')
        self.assertIsNone(text)
        self.assertIn('time of day', reason)


if __name__ == '__main__':
    unittest.main()
