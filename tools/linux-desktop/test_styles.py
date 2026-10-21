import io
import json
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace

import cli_style
import styles
from cleanup import BasicCleanup


class ResolutionTests(unittest.TestCase):
    def test_default_is_inert(self):
        self.assertTrue(styles.is_default(None))
        self.assertTrue(styles.is_default({}))
        self.assertIsNone(styles.to_config(styles.validate(None)))
        self.assertEqual(styles.resolve(None, 'foot'), {'context': 'other', 'tone': None, 'cleanup': None, 'source': 'other'})

    def test_built_in_members_map_to_contexts(self):
        for window_class, context in [('signal', 'personal'), ('Signal', 'personal'), ('org.telegram.desktop', 'personal'),
                                      ('TelegramDesktop', 'personal'), ('discord', 'personal'), ('Slack', 'work'),
                                      ('teams-for-linux', 'work'), ('thunderbird', 'email'),
                                      ('org.gnome.Evolution', 'email'), ('org.gnome.Geary', 'email')]:
            with self.subTest(window_class=window_class):
                self.assertEqual(styles.context_of(None, window_class), context)
        self.assertIsNone(styles.context_of(None, 'foot'))
        self.assertIsNone(styles.context_of(None, None))

    def test_unlisted_apps_are_other_and_follow_the_default_tone(self):
        block = {'tone': 'very_casual'}
        self.assertEqual(styles.resolve(block, 'foot')['tone'], 'very_casual')
        self.assertEqual(styles.resolve(block, None)['tone'], 'very_casual')
        self.assertEqual(styles.resolve({'contexts': {'other': {'cleanup': 'basic'}}}, 'foot')['cleanup'], 'basic')
        self.assertEqual(styles.resolve({'contexts': {'other': {'cleanup': 'basic'}}}, None)['cleanup'], 'basic')
        self.assertIsNone(styles.resolve({'contexts': {'other': {'cleanup': 'basic'}}}, 'Slack')['cleanup'])

    def test_context_tone_beats_default_and_falls_through_when_unset(self):
        block = {'tone': 'formal', 'contexts': {'work': {'tone': 'casual'}}}
        self.assertEqual(styles.resolve(block, 'Slack')['tone'], 'casual')
        self.assertEqual(styles.resolve(block, 'thunderbird')['tone'], 'formal')

    def test_user_rule_beats_user_added_beats_built_in(self):
        block = styles.add_app(None, 'email', 'Slack')
        block = styles.set_context(block, 'email', 'tone', 'formal')
        block = styles.set_context(block, 'work', 'tone', 'casual')
        self.assertEqual(styles.resolve(block, 'slack')['context'], 'email')
        self.assertEqual(styles.resolve(block, 'slack')['source'], 'added')
        block = styles.set_rule(block, 'slack', 'Slack', 'very_casual', None)
        decided = styles.resolve(block, 'Slack')
        self.assertEqual((decided['tone'], decided['source']), ('very_casual', 'rule'))

    def test_tone_and_cleanup_fall_through_on_their_own(self):
        block = styles.set_context(None, 'work', 'tone', 'casual')
        block = styles.set_context(block, 'work', 'cleanup', 'basic')
        block = styles.set_rule(block, 'Slack', 'Slack', None, 'off')
        decided = styles.resolve(block, 'Slack')
        self.assertEqual((decided['tone'], decided['cleanup']), ('casual', 'off'))
        self.assertEqual(styles.resolve(block, 'org.signal.Signal')['cleanup'], None)

    def test_adding_moves_an_app_between_contexts_and_restores_defaults(self):
        block = styles.add_app(None, 'email', 'Slack')
        self.assertEqual(styles.context_of(block, 'Slack'), 'email')
        self.assertFalse(any('Slack' in m['apps'] for m in styles.members(block, 'work')))
        block = styles.add_app(block, 'work', 'Slack')
        self.assertEqual(styles.context_of(block, 'Slack'), 'work')
        self.assertTrue(styles.is_default(block))

    def test_moving_one_alias_leaves_its_siblings(self):
        block = styles.add_app(None, 'email', 'Slack')
        block = styles.set_context(block, 'work', 'tone', 'casual')
        self.assertEqual(styles.context_of(block, 'Slack'), 'email')
        self.assertEqual(styles.context_of(block, 'com.slack.Slack'), 'work')
        block = styles.add_app(block, 'work', 'Slack')
        self.assertEqual(styles.context_of(block, 'Slack'), 'work')
        self.assertEqual(styles.validate(block)['contexts']['work']['removed'], [])

    def test_removing_a_built_in_falls_back_to_other(self):
        block = styles.remove_app(None, 'personal', 'discord')
        self.assertIsNone(styles.context_of(block, 'discord'))
        with self.assertRaises(ValueError):
            styles.remove_app(block, 'personal', 'nope')
        block = styles.add_app(block, 'personal', 'Foo.App', 'Foo')
        self.assertEqual(styles.context_of(block, 'foo.app'), 'personal')
        block = styles.remove_app(block, 'personal', 'app:Foo.App')
        self.assertIsNone(styles.context_of(block, 'foo.app'))

    def test_effective_cleanup_needs_a_prepared_model(self):
        decided = {'cleanup': 'thorough'}
        self.assertEqual(styles.effective_cleanup(decided, 'off'), 'basic')
        self.assertEqual(styles.effective_cleanup(decided, 'off', models=('thorough',)), 'thorough')
        self.assertEqual(styles.effective_cleanup({'cleanup': None}, 'fast', models=('fast',)), 'fast')
        self.assertEqual(styles.effective_cleanup({'cleanup': 'off'}, 'fast', models=('fast',)), 'off')

    def test_validation_rejects_bad_blocks(self):
        for bad in ([], {'tone': 'loud'}, {'contexts': {'home': {}}}, {'contexts': {'other': {'tone': 'casual'}}},
                    {'contexts': {'work': {'cleanup': 'max'}}}, {'contexts': {'work': {'removed': ['nope']}}},
                    {'contexts': {'work': {'added': [{'app': 'a*', 'name': 'A'}]}}},
                    {'contexts': {'work': {'added': [{'app': '', 'name': 'A'}]}}},
                    {'rules': [{'app': 'foot'}]}, {'rules': [{'app': 'a', 'tone': 'casual'}, {'app': 'A', 'cleanup': 'off'}]},
                    {'extra': 1}, {'version': 2}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                styles.validate(bad)

    def test_describe_shape_and_samples_come_from_the_real_tones(self):
        page = styles.describe(None)
        self.assertEqual([c['id'] for c in page['contexts']], ['personal', 'work', 'email', 'other'])
        self.assertEqual(page['websites'], 'unsupported')
        personal = page['contexts'][0]
        self.assertEqual([m['name'] for m in personal['members']], ['Signal', 'Telegram', 'Discord'])
        self.assertTrue(all(m['built_in'] for m in personal['members']))
        styled = {s['tone']: s['lines'][0]['styled'] for s in personal['samples']}
        self.assertEqual(styled['formal'], 'Hey, are we still on for dinner tonight? I can be there by seven.')
        self.assertEqual(styled['casual'], 'Hey, are we still on for dinner tonight? I can be there by seven')
        self.assertEqual(styled['very_casual'], 'hey, are we still on for dinner tonight? I can be there by seven')
        self.assertEqual(len(page['contexts'][2]['samples'][0]['lines']), 4)
        self.assertEqual(page['contexts'][3]['members'], [])


class CleanupHookTests(unittest.TestCase):
    TEXT = 'send the notes to Dana new line then book the room.'

    def test_without_styles_nothing_changes(self):
        plain = BasicCleanup('basic').apply(self.TEXT)
        for block in (None, {}, {'tone': None}, {'version': 1, 'contexts': {}}):
            self.assertEqual(BasicCleanup('basic', block).apply(self.TEXT, {'class': 'Slack'}), plain)
        self.assertEqual(BasicCleanup('off', {'tone': 'casual'}).apply(self.TEXT), self.TEXT)

    def test_tone_follows_the_captured_window(self):
        block = {'contexts': {'work': {'tone': 'casual'}}, 'tone': 'formal'}
        cleaner = BasicCleanup('basic', block)
        self.assertTrue(cleaner.apply('see you Friday.', {'class': 'Slack'}).endswith('Friday'))
        self.assertTrue(cleaner.apply('see you Friday.', {'class': 'foot'}).endswith('Friday.'))
        self.assertTrue(cleaner.apply('see you Friday.', None).endswith('Friday.'))

    def test_cleanup_override_off_bypasses_and_overrides_a_global_off(self):
        block = {'contexts': {'other': {'cleanup': 'off'}, 'work': {'cleanup': 'basic'}}}
        self.assertEqual(BasicCleanup('basic', block).apply(self.TEXT, {'class': 'foot'}), self.TEXT)
        self.assertNotEqual(BasicCleanup('off', block).apply(self.TEXT, {'class': 'Slack'}), self.TEXT)

    def test_invalid_styles_are_rejected_like_an_invalid_mode(self):
        with self.assertRaises(ValueError):
            BasicCleanup('basic', {'tone': 'loud'})


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'linux.json'
        self.original = {'engine_config': 'x.json', 'cleanup': 'basic', 'delivery': {'mode': 'recover'}}
        self.path.write_text(json.dumps(self.original))

    def test_edits_store_the_block_and_defaults_remove_it_again(self):
        styles.update_config(self.path, lambda block: styles.set_context(block, 'work', 'tone', 'casual'))
        stored = json.loads(self.path.read_text())
        self.assertEqual(stored['styles']['contexts']['work']['tone'], 'casual')
        self.assertEqual({k: v for k, v in stored.items() if k != 'styles'}, self.original)
        self.assertEqual(oct(self.path.stat().st_mode & 0o777), '0o600')
        self.assertEqual(len(list(self.path.parent.glob('linux.json.bak.*'))), 1)
        styles.update_config(self.path, lambda block: styles.set_context(block, 'work', 'tone', None))
        self.assertEqual(json.loads(self.path.read_text()), self.original)

    def test_rapid_edits_keep_every_backup(self):
        styles.update_config(self.path, lambda block: styles.set_default_tone(block, 'casual'))
        styles.update_config(self.path, lambda block: styles.set_context(block, 'work', 'tone', 'formal'))
        backups = sorted(self.path.parent.glob('linux.json.bak.*'))
        self.assertEqual(len(backups), 2)
        self.assertIn(self.original, [json.loads(b.read_text()) for b in backups])

    def test_no_write_when_nothing_changes(self):
        styles.update_config(self.path, lambda block: block)
        self.assertEqual(list(self.path.parent.glob('linux.json.bak.*')), [])
        self.assertEqual(json.loads(self.path.read_text()), self.original)

    def test_invalid_edit_leaves_the_file_alone(self):
        with self.assertRaises(ValueError):
            styles.update_config(self.path, lambda block: styles.set_context(block, 'other', 'tone', 'casual'))
        self.assertEqual(json.loads(self.path.read_text()), self.original)

    def test_a_config_with_a_styles_block_still_passes_the_daemon_validator(self):
        import desktop
        styles.update_config(self.path, lambda block: styles.set_default_tone(block, 'casual'))
        config = json.loads(self.path.read_text())
        self.assertEqual(desktop.validate_config(config)['styles']['tone'], 'casual')


class CliTests(unittest.TestCase):
    def run_cli(self, path, *argv):
        import argparse
        parser = argparse.ArgumentParser()
        cli_style.register(parser.add_subparsers(dest='action', required=True))
        args = parser.parse_args(['style', *argv])
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = cli_style.run(args, SimpleNamespace(config=path))
        return code, out.getvalue(), err.getvalue()

    def test_show_set_resolve_preview(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'linux.json'
            path.write_text(json.dumps({'engine_config': 'x.json'}))
            code, out, _ = self.run_cli(path, 'show')
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(out)['default_tone'], None)
            code, out, _ = self.run_cli(path, 'set-tone', 'email', 'formal')
            self.assertEqual(json.loads(out)['contexts'][2]['tone'], 'formal')
            self.assertNotIn('restart_required', json.loads(out))
            code, out, _ = self.run_cli(path, 'add-app', 'work', 'foot', '--name', 'Terminal')
            self.assertEqual(code, 0)
            code, out, _ = self.run_cli(path, 'resolve', 'foot')
            self.assertEqual(json.loads(out)['context'], 'work')
            code, out, _ = self.run_cli(path, 'rule', 'foot', '--cleanup', 'off')
            code, out, _ = self.run_cli(path, 'resolve', 'foot')
            self.assertEqual(json.loads(out)['cleanup'], 'off')
            code, out, _ = self.run_cli(path, 'preview', 'casual', 'See you Friday.')
            self.assertEqual(json.loads(out), {'text': 'See you Friday'})
            code, _, err = self.run_cli(path, 'add-app', 'work', 'bad*')
            self.assertEqual(code, 1)
            self.assertIn('error', json.loads(err))


if __name__ == '__main__':
    unittest.main()
