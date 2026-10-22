import unittest

from cleanup import BasicCleanup, slash_commands
from styles import is_coding_class


def run(text, protected=None):
    return slash_commands(text, protected)


def pipeline(text, coding):
    return BasicCleanup('basic').apply(text, {'class': 'kitty' if coding else 'firefox'})


class SlashCommandsTests(unittest.TestCase):
    def test_converts_spoken_slash_commands(self):
        for source, expected in [
            ('slash research', '/research'),
            ('Slash Research', '/research'),
            ('SLASH RESEARCH', '/research'),
            ('forward slash research', '/research'),
            ('Do we want to do a slash research?', 'Do we want to do a /research?'),
            ('run slash review now', 'run /review now'),
            ('ok. slash compact', 'ok. /compact'),
            ('ok, slash compact, then go', 'ok, /compact, then go'),
            ('slash research.', '/research'),
            ('Slash research.', '/research'),
            ('Slash research?', '/research'),
            ('slash research!  ', '/research  '),
            ('do slash research.', 'do /research.'),
            ('slash research. then go', '/research. then go'),
            ('slash code dash review', '/code-review'),
            ('slash code hyphen review', '/code-review'),
            ('slash pr underscore comments', '/pr_comments'),
            ('slash x dash b underscore c', '/x-b_c'),
            ('slash code dash', '/code dash'),
            ('slash research and slash review', '/research and /review'),
            ('slash research then dash', '/research then dash'),
        ]:
            with self.subTest(source=source):
                self.assertEqual(run(source), expected)

    def test_leaves_everything_else_alone(self):
        for source in [
            'slash', 'go to the slash', 'slash 2', 'slash 2fa', 'and slash or', 'a slash of paint',
            'slash\nresearch', '/research', 'run /research now', 'slash /research', 'slash src/app.swift',
            'use `slash research` literally', 'slashing prices', 'Press the slash key',
            'A forward slash separates paths', 'the slash character', 'type a slash symbol',
            'a back slash fixes it', 'a forward slash separates paths', 'the forward slash key',
            'double slash comments', 'trailing slash redirects', 'slash the budget', 'press slash key',
            'this slash mark', 'slash, research',
        ]:
            with self.subTest(source=source):
                self.assertEqual(run(source), source)

    def test_protected_phrases_are_left_alone(self):
        self.assertEqual(run('say slash research', ['slash research']), 'say slash research')
        self.assertEqual(run('say slash research', ['Slash Research']), 'say slash research')
        self.assertEqual(run('say slash research and slash review', ['slash research']),
                         'say slash research and /review')

    def test_unicode_neighbours(self):
        self.assertEqual(run('😀 café slash code dash review now'), '😀 café /code-review now')

    def test_pipeline_only_runs_it_for_a_coding_target(self):
        self.assertEqual(pipeline('slash research', True), '/research')
        self.assertEqual(pipeline('Do we want to do a slash research?', True), 'Do we want to do a /research?')
        self.assertEqual(pipeline('Do we want to do a slash research?', False), 'Do we want to do a slash research?')
        self.assertEqual(pipeline('and slash or', False), 'And slash or')
        self.assertEqual(BasicCleanup('basic', slash_commands=False).apply('slash research', {'class': 'kitty'}),
                         'Slash research')
        self.assertEqual(BasicCleanup('basic').apply('slash research'), 'Slash research')

    def test_non_coding_targets_never_convert(self):
        for text in ['and slash or', 'Slash research.', 'slash code dash review', 'slash newline']:
            with self.subTest(text=text):
                self.assertNotIn('/', pipeline(text, False))
        self.assertEqual(pipeline('Slash research.', False), 'Slash research.')

    def test_generated_names_survive_later_stages(self):
        for source, expected in [
            ('slash newline', '/newline'),
            ('slash new line', '/new line'),
            ('run slash newline now', 'Run /newline now'),
            ('slash new dash line', '/new-line'),
            ('slash new underscore paragraph', '/new_paragraph'),
            ('slash code dash review', '/code-review'),
            ('slash research dash comma', '/research-comma'),
            ('slash period', '/period'),
            ('Run (slash newline) now', 'Run (/newline) now'),
            ('Run [slash newline] now', 'Run [/newline] now'),
            ('Run "slash newline" now', 'Run "/newline" now'),
            ('Run “slash newline” now', 'Run “/newline” now'),
            ("Run 'slash newline' now", "Run '/newline' now"),
            ('Run (slash new dash line) now', 'Run (/new-line) now'),
            ('Run `/newline` now', 'Run `/newline` now'),
        ]:
            with self.subTest(source=source):
                self.assertEqual(pipeline(source, True), expected)

    def test_runs_before_spoken_commands(self):
        self.assertEqual(pipeline('slash code dash review', True), '/code-review')
        self.assertEqual(pipeline('slash pr underscore comments', True), '/pr_comments')
        self.assertEqual(pipeline('code dash review', True), 'Code - review')

    def test_coding_classes(self):
        for name in ('kitty', 'Kitty', 'Alacritty', 'foot', 'ghostty', 'org.wezfurlong.wezterm', 'code', 'Code',
                     'cursor', 'zed', 'jetbrains-idea', 'jetbrains-PyCharm', 'claude', 'codex', 'orca'):
            with self.subTest(name=name):
                self.assertTrue(is_coding_class(name))
        for name in ('firefox', 'Slack', 'jetbrains', '', None, 5):
            with self.subTest(name=name):
                self.assertFalse(is_coding_class(name))


if __name__ == '__main__':
    unittest.main()
