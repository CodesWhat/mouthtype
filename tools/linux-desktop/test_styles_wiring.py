import json
from pathlib import Path
import tempfile
import unittest

from cleanup import BasicCleanup
from desktop import Session, validate_config
import styles
import tone
from test_desktop import Capture, Delivery, Engine
from test_model_cleanup import FakeCleanup

RAW = 'um so we should ship it comma right'
SHORT = 'See you Friday.'


def block(*changes):
    result = styles.validate(None)
    for change in changes:
        result = change(result)
    return result


def config(*changes):
    return styles.to_config(block(*changes))


def set_tone(context, value):
    return lambda b: styles.set_context(b, context, 'tone', value)


def set_cleanup(context, value):
    return lambda b: styles.set_context(b, context, 'cleanup', value)


class Loader:
    """An engine_loader that hands out one fake per level and remembers what was asked for."""

    def __init__(self, **engines):
        self.engines, self.asked = engines, []

    def __call__(self, level):
        self.asked.append(level)
        return self.engines.get(level)


class WiringCase(unittest.TestCase):
    def take(self, raw=RAW, window='editor', level='off', **options):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        delivery = Delivery()
        delivery.target = {'address': '0x1', 'class': window, 'pid': 7}
        session = Session(Capture(), Engine(raw), delivery, Path(temp.name), cleanup=level, **options)
        self.addCleanup(session.close)
        session.command('start')
        session.command('stop')
        session.wait()
        return session, delivery, (session.take / 'transcript.txt').read_text()


class NoStylesBlockTests(WiringCase):
    def test_no_block_matches_the_plain_pipeline_byte_for_byte(self):
        for level in ('off', 'basic'):
            for raw in (RAW, SHORT, 'Hello, 世界. café 👋', 'that was a damn good idea. see you friday.'):
                plain = BasicCleanup(level).apply(raw)
                _, delivery, text = self.take(raw, level=level)
                self.assertEqual(text, plain)
                self.assertEqual(delivery.calls[0][0], plain)
                for inert in (None, {}, config()):
                    _, other, text = self.take(raw, level=level, styles=inert)
                    self.assertEqual(text.encode(), plain.encode())
                    self.assertEqual(other.calls[0][0].encode(), plain.encode())

    def test_no_block_in_a_model_take_applies_no_tone_and_keeps_the_cleanup_record(self):
        model = 'That is a damn good idea.'
        fake = FakeCleanup(model)
        session, _, text = self.take('that is a damn good idea', level='fast', cleanup_engine=fake)
        self.assertEqual(text, model)
        record = json.loads((session.take / 'cleanup.json').read_text())
        self.assertEqual((record['level'], record['outcome']), ('fast', 'ok'))

    def test_a_config_without_styles_validates_as_before(self):
        value = validate_config({'engine_config': 'x.json'})
        self.assertNotIn('styles', value)
        with self.assertRaises(ValueError):
            validate_config({'engine_config': 'x.json', 'styles': {'tone': 'sparkly'}})


class ToneAndOverrideTests(WiringCase):
    def test_tone_follows_the_window_class_captured_at_take_start(self):
        setup = config(set_tone('work', 'casual'), set_tone('email', 'formal'))
        _, _, slack = self.take(SHORT, window='Slack', level='basic', styles=setup)
        _, _, editor = self.take(SHORT, window='editor', level='basic', styles=setup)
        self.assertEqual(slack, tone.apply(BasicCleanup('basic').apply(SHORT), 'casual'))
        self.assertEqual(slack, 'See you Friday')
        self.assertEqual(editor, 'See you Friday.')

    def test_formal_context_softens_swearing_in_a_basic_take(self):
        setup = config(set_tone('email', 'formal'))
        _, _, text = self.take('that was a damn good idea', window='thunderbird', level='basic', styles=setup)
        self.assertEqual(text, tone.apply(BasicCleanup('basic').apply('that was a damn good idea'), 'formal'))
        self.assertNotIn('damn', text)
        _, _, other = self.take('that was a damn good idea', window='editor', level='basic', styles=setup)
        self.assertIn('damn', other)

    def test_off_override_leaves_the_raw_text_even_when_the_global_level_is_basic(self):
        setup = config(set_cleanup('work', 'off'), set_tone('work', 'casual'))
        _, _, slack = self.take(RAW, window='Slack', level='basic', styles=setup)
        _, _, editor = self.take(RAW, window='editor', level='basic', styles=setup)
        self.assertEqual(slack, RAW)
        self.assertEqual(editor, BasicCleanup('basic').apply(RAW))

    def test_basic_override_runs_basic_even_when_the_global_level_is_off_or_a_model(self):
        setup = config(set_cleanup('work', 'basic'))
        _, _, text = self.take(RAW, window='Slack', level='off', styles=setup)
        self.assertEqual(text, BasicCleanup('basic').apply(RAW))
        fake = FakeCleanup('Model text should not appear.')
        session, _, text = self.take(RAW, window='Slack', level='fast', cleanup_engine=fake, styles=setup)
        self.assertEqual(text, BasicCleanup('basic').apply(RAW))
        self.assertEqual(fake.calls, [])
        self.assertFalse((session.take / 'cleanup.json').exists())

    def test_per_app_rule_beats_the_context(self):
        setup = config(set_tone('work', 'casual'), lambda b: styles.set_rule(b, 'slack', None, 'formal', None))
        _, _, text = self.take(SHORT, window='Slack', level='basic', styles=setup)
        self.assertEqual(text, 'See you Friday.')

    def test_unlisted_windows_use_the_default_tone(self):
        setup = config(lambda b: styles.set_default_tone(b, 'casual'))
        _, _, text = self.take(SHORT, window='editor', level='basic', styles=setup)
        self.assertEqual(text, 'See you Friday')


class ModelRoutingTests(WiringCase):
    def test_fast_override_runs_the_fast_model_while_the_global_level_is_basic(self):
        fast = FakeCleanup('So we should ship it, right?')
        loader = Loader(fast=fast)
        setup = config(set_cleanup('work', 'fast'))
        session, _, text = self.take(RAW, window='Slack', level='basic', styles=setup, engine_loader=loader)
        self.assertEqual(text, 'So we should ship it, right?')
        self.assertEqual(len(fast.calls), 1)
        record = json.loads((session.take / 'cleanup.json').read_text())
        self.assertEqual((record['level'], record['outcome']), ('fast', 'ok'))
        _, _, other = self.take(RAW, window='editor', level='basic', styles=setup, engine_loader=loader)
        self.assertEqual(other, BasicCleanup('basic').apply(RAW))
        self.assertEqual(len(fast.calls), 1)

    def test_thorough_override_picks_the_thorough_engine_not_the_global_fast_one(self):
        fast, thorough = FakeCleanup('Fast text, right?'), FakeCleanup('So we should ship it, right?')
        setup = config(set_cleanup('work', 'thorough'))
        _, _, text = self.take(RAW, window='Slack', level='fast', cleanup_engine=fast, styles=setup,
                               engine_loader=Loader(thorough=thorough))
        self.assertEqual(text, 'So we should ship it, right?')
        self.assertEqual((len(fast.calls), len(thorough.calls)), (0, 1))

    def test_a_context_can_turn_the_model_off_for_a_global_model_level(self):
        fast = FakeCleanup('Model text, right?')
        setup = config(set_cleanup('work', 'off'))
        _, _, text = self.take(RAW, window='Slack', level='fast', cleanup_engine=fast, styles=setup)
        self.assertEqual(text, RAW)
        self.assertEqual(fast.calls, [])

    def test_an_override_with_no_engine_falls_back_to_basic(self):
        setup = config(set_cleanup('work', 'fast'))
        session, _, text = self.take(RAW, window='Slack', level='basic', styles=setup, engine_loader=Loader())
        self.assertEqual(text, BasicCleanup('basic').apply(RAW))
        self.assertFalse((session.take / 'cleanup.json').exists())
        _, _, text = self.take(RAW, window='Slack', level='basic', styles=setup)
        self.assertEqual(text, BasicCleanup('basic').apply(RAW))

    def test_an_override_whose_model_times_out_keeps_the_basic_text(self):
        fast = FakeCleanup(timeout=True)
        setup = config(set_cleanup('work', 'fast'))
        session, _, text = self.take(RAW, window='Slack', level='basic', styles=setup,
                                     engine_loader=Loader(fast=fast))
        self.assertEqual(text, BasicCleanup('basic').apply(RAW))
        self.assertEqual(json.loads((session.take / 'cleanup.json').read_text())['outcome'], 'timeout')

    def test_formal_is_reapplied_after_the_model_puts_swearing_back(self):
        back = 'So we should ship this damn thing, right?'
        setup = config(set_tone('email', 'formal'))
        fake = FakeCleanup(back)
        _, _, text = self.take('so we should ship it comma right', window='thunderbird', level='fast',
                               cleanup_engine=fake, styles=setup)
        self.assertEqual(len(fake.calls), 1)
        self.assertEqual(text, tone.apply(back, 'formal'))
        self.assertNotIn('damn', text)
        fake = FakeCleanup(back)
        _, _, text = self.take('so we should ship it comma right', window='editor', level='fast',
                               cleanup_engine=fake, styles=setup)
        self.assertEqual(text, back)

    def test_casual_is_reapplied_after_the_model(self):
        setup = config(set_tone('work', 'casual'))
        fake = FakeCleanup('See you Friday.')
        _, _, text = self.take('see you friday', window='Slack', level='fast', cleanup_engine=fake, styles=setup)
        self.assertEqual(text, 'See you Friday')


class ReloadTests(WiringCase):
    def session(self, path, **options):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        delivery = Delivery()
        delivery.target = {'address': '0x1', 'class': 'Slack', 'pid': 7}
        session = Session(Capture(), Engine(options.pop('raw', SHORT)), delivery, Path(temp.name),
                          cleanup='basic', styles_path=path, **options)
        self.addCleanup(session.close)
        return session

    @staticmethod
    def dictate(session):
        session.command('start')
        session.command('stop')
        session.wait()
        return (session.take / 'transcript.txt').read_text()

    def test_edits_apply_at_the_next_take_without_a_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'linux.json'
            path.write_text(json.dumps({'engine_config': 'x.json'}))
            session = self.session(path)
            self.assertEqual(self.dictate(session), 'See you Friday.')
            styles.update_config(path, set_tone('work', 'casual'))
            self.assertEqual(self.dictate(session), 'See you Friday')
            styles.update_config(path, set_tone('work', None))
            self.assertEqual(self.dictate(session), 'See you Friday.')

    def test_an_unreadable_or_invalid_edit_keeps_the_loaded_styles(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'linux.json'
            path.write_text(json.dumps({'engine_config': 'x.json', 'styles': config(set_tone('work', 'casual'))}))
            session = self.session(path)
            self.assertEqual(self.dictate(session), 'See you Friday')
            path.write_text('{ not json')
            self.assertEqual(self.dictate(session), 'See you Friday')
            path.write_text(json.dumps({'engine_config': 'x.json', 'styles': {'tone': 'sparkly'}}))
            self.assertEqual(self.dictate(session), 'See you Friday')

    def test_a_new_override_level_gets_an_engine_after_a_reload(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'linux.json'
            path.write_text(json.dumps({'engine_config': 'x.json'}))
            fast = FakeCleanup('So we should ship it, right?')
            loader = Loader(fast=fast)
            session = self.session(path, raw=RAW, engine_loader=loader)
            self.dictate(session)
            self.assertEqual(loader.asked, [])
            styles.update_config(path, set_cleanup('work', 'fast'))
            self.assertEqual(self.dictate(session), 'So we should ship it, right?')
            self.assertEqual(loader.asked, ['fast'])


if __name__ == '__main__':
    unittest.main()
