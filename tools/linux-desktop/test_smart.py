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


if __name__ == '__main__':
    unittest.main()
