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
        # Compound spoken numbers are left to the deterministic stage; the guard is conservative.
        self.reject('order twenty five units', 'Order 25 units.', 'number')
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


if __name__ == '__main__':
    unittest.main()
