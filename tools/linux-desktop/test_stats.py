import contextlib
from datetime import datetime, timedelta, timezone
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
import wave

import desktop
import stats

TZ = timezone(timedelta(hours=-5))


def stamp(day, hour=0, minute=0):
    return datetime(2026, 10, day, hour, minute, tzinfo=TZ).timestamp()


NOW = stamp(20, 14)


def make_take(root, identity, created, words=None, seconds=None, *, age=3600, metadata=True):
    path = Path(root) / identity
    path.mkdir(mode=0o700)
    if metadata:
        (path / 'take.json').write_text(json.dumps({'created': created}))
    if words is not None:
        (path / 'transcript.txt').write_text(' '.join(['word'] * words))
    if seconds is not None:
        audio = path / 'recording.wav'
        with wave.open(str(audio), 'wb') as output:
            output.setparams((1, 2, 16000, 0, 'NONE', ''))
            output.writeframes(b'\0\0' * int(16000 * seconds))
        os.utime(audio, (NOW - age, NOW - age))
    return path


def hexid(number):
    return '%032x' % number


class StatsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        make_take(self.root, hexid(1), stamp(20, 9, 10), 10, 4)        # 150 wpm
        make_take(self.root, hexid(2), stamp(20, 9, 50), 3, 1)         # too few words for speed
        make_take(self.root, hexid(3), stamp(19, 22, 30), 60, 20)      # 180 wpm
        make_take(self.root, hexid(4), stamp(14, 8, 0), 20)            # audio retired, no duration
        make_take(self.root, hexid(5), stamp(13, 12, 0), 7, 2)         # under three seconds
        make_take(self.root, hexid(6), stamp(20, 11, 0), None, 2)      # audio only
        self.result = stats.build(stats.read_takes(self.root, now=NOW), now=NOW, tz=TZ)

    def test_words_and_takes(self):
        self.assertEqual(self.result['words'], {'today': 13, 'week': 93, 'all_time': 100})
        self.assertEqual(self.result['takes'], 5)
        self.assertEqual(self.result['today'], '2026-10-20')
        self.assertEqual(self.result['first_day'], '2026-10-13')
        self.assertTrue(self.result['has_history'])
        self.assertTrue(self.result['history_limited'])

    def test_week_is_the_trailing_seven_days(self):
        make_take(self.root, hexid(7), stamp(13, 23, 59), 1000, 1)
        result = stats.compute(self.root, now=NOW, tz=TZ)
        self.assertEqual(result['words']['week'], 93)
        self.assertEqual(result['words']['all_time'], 1100)

    def test_speed_uses_total_words_over_total_time_of_qualifying_takes(self):
        speed = self.result['speed']
        self.assertEqual(speed['average_wpm'], 175.0)
        self.assertEqual(speed['peak_wpm'], 180.0)
        self.assertEqual(speed['rated_takes'], 2)

    def test_implausible_rate_is_ignored(self):
        make_take(self.root, hexid(8), stamp(18, 10, 0), 5000, 3)      # 100000 wpm
        self.assertEqual(stats.compute(self.root, now=NOW, tz=TZ)['speed']['peak_wpm'], 180.0)

    def test_speed_is_null_without_a_qualifying_take(self):
        other = tempfile.TemporaryDirectory()
        self.addCleanup(other.cleanup)
        make_take(other.name, hexid(1), stamp(20, 9), 3, 1)
        speed = stats.compute(other.name, now=NOW, tz=TZ)['speed']
        self.assertIsNone(speed['average_wpm'])
        self.assertIsNone(speed['peak_wpm'])

    def test_streaks(self):
        self.assertEqual(self.result['streak'], {'current': 2, 'longest': 2})
        self.assertEqual(self.result['high_scores']['longest_streak'], {'value': 2, 'date': '2026-10-14'})

    def test_streak_survives_a_quiet_today_but_not_a_quiet_yesterday(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        make_take(directory.name, hexid(1), stamp(18, 9), 5, 3)
        make_take(directory.name, hexid(2), stamp(19, 9), 5, 3)
        result = stats.compute(directory.name, now=NOW, tz=TZ)
        self.assertEqual(result['streak']['current'], 2)
        self.assertEqual(result['daily'][-1]['words'], 0)
        self.assertEqual(result['streak_lit'][-3:], [True, True, False])
        later = stats.compute(directory.name, now=stamp(21, 14), tz=TZ)
        self.assertEqual(later['streak']['current'], 0)
        self.assertEqual(later['streak']['longest'], 2)

    def test_daily_window_is_thirty_zero_filled_days_ending_today(self):
        daily = self.result['daily']
        self.assertEqual(len(daily), 30)
        self.assertEqual(daily[-1], {'day': '2026-10-20', 'words': 13})
        self.assertEqual(daily[-2], {'day': '2026-10-19', 'words': 60})
        self.assertEqual(daily[-3]['words'], 0)
        self.assertEqual(self.result['streak_lit'][-2:], [True, True])
        self.assertEqual(sum(self.result['streak_lit']), 2)

    def test_hours(self):
        hourly = self.result['hourly']
        self.assertEqual(len(hourly), 24)
        self.assertEqual((hourly[9], hourly[22], hourly[8], hourly[12]), (13, 60, 20, 7))
        self.assertEqual(self.result['peak_hour'], 22)

    def test_hours_ignore_takes_older_than_the_window(self):
        make_take(self.root, hexid(9), stamp(1, 3, 0), 500, 5)
        self.assertEqual(stats.compute(self.root, now=stamp(31, 14), tz=TZ)['hourly'][3], 0)
        self.assertEqual(stats.compute(self.root, now=stamp(30, 14), tz=TZ)['hourly'][3], 500)

    def test_tape_lists_todays_takes_in_time_order_with_audio_only_flag(self):
        tape = self.result['tape']
        self.assertEqual([(t['time'], t['words'], t['audio_only']) for t in tape],
                         [('09:10', 10, False), ('09:50', 3, False), ('11:00', 0, True)])
        self.assertEqual(tape[0]['id'], hexid(1))
        self.assertEqual(tape[0]['duration_ms'], 4000)
        self.assertEqual(tape[0]['seconds_into_day'], 9 * 3600 + 600)
        self.assertEqual(self.result['tape_summary'],
                         {'takes': 3, 'words': 13, 'speaking_ms': 7000, 'minutes_avoided': 0.21})

    def test_high_scores(self):
        scores = self.result['high_scores']
        self.assertEqual(scores['fastest'], {'value': 180.0, 'date': '2026-10-19'})
        self.assertEqual(scores['biggest_day'], {'value': 60, 'date': '2026-10-19'})
        self.assertEqual(scores['longest_take'], {'value': 60, 'duration_ms': 20000, 'date': '2026-10-19'})

    def test_ties_go_to_the_earliest(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        make_take(directory.name, hexid(1), stamp(18, 9), 30, 12)
        make_take(directory.name, hexid(2), stamp(19, 9), 30, 12)
        scores = stats.compute(directory.name, now=NOW, tz=TZ)['high_scores']
        self.assertEqual(scores['fastest']['date'], '2026-10-18')
        self.assertEqual(scores['biggest_day']['date'], '2026-10-18')
        self.assertEqual(scores['longest_take']['date'], '2026-10-18')

    def test_time_saved_skips_takes_without_a_duration(self):
        saved = self.result['time_saved']
        self.assertEqual(saved['typing_wpm'], 40.0)
        self.assertEqual(saved['speaking_minutes'], 0.45)
        self.assertEqual(saved['minutes'], 1.55)

    def test_time_saved_is_never_negative(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        make_take(directory.name, hexid(1), stamp(20, 9), 2, 30)
        self.assertEqual(stats.compute(directory.name, now=NOW, tz=TZ)['time_saved']['minutes'], 0.0)

    def test_empty_history_has_the_full_shape(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        result = stats.compute(directory.name, now=NOW, tz=TZ)
        self.assertEqual(set(result), set(self.result))
        self.assertFalse(result['has_history'])
        self.assertEqual(result['words'], {'today': 0, 'week': 0, 'all_time': 0})
        self.assertEqual((result['daily'], result['tape'], result['hourly']), ([], [], [0] * 24))
        self.assertEqual(result['high_scores'], {'fastest': None, 'biggest_day': None,
                                                  'longest_streak': None, 'longest_take': None})
        self.assertIsNone(result['peak_hour'])
        self.assertIsNone(result['first_day'])

    def test_missing_directory_is_empty_history(self):
        self.assertFalse(stats.compute(self.root / 'absent', now=NOW, tz=TZ)['has_history'])

    def test_result_is_json_serialisable(self):
        self.assertEqual(json.loads(json.dumps(self.result)), self.result)

    def test_a_recording_in_progress_is_not_an_audio_only_take(self):
        make_take(self.root, hexid(10), stamp(20, 13, 59), None, 2, age=1)
        ids = [take['id'] for take in stats.compute(self.root, now=NOW, tz=TZ)['tape']]
        self.assertNotIn(hexid(10), ids)

    def test_strays_are_ignored(self):
        make_take(self.root, 'not-a-take', stamp(20, 9), 999, 1)
        (self.root / 'file.txt').write_text('x')
        target = self.root / 'elsewhere'
        target.mkdir()
        (target / 'transcript.txt').write_text('a b c')
        (self.root / hexid(11)).symlink_to(target)
        self.assertEqual(stats.compute(self.root, now=NOW, tz=TZ)['words']['all_time'], 100)

    def test_take_without_metadata_uses_its_earliest_file(self):
        path = make_take(self.root, hexid(12), 0, 40, None, metadata=False)
        os.utime(path / 'transcript.txt', (stamp(20, 10), stamp(20, 10)))
        result = stats.compute(self.root, now=NOW, tz=TZ)
        self.assertEqual(result['words']['today'], 53)

    def test_damaged_audio_has_no_duration(self):
        path = make_take(self.root, hexid(13), stamp(20, 12), 9)
        (path / 'recording.wav').write_bytes(b'not a wav')
        os.utime(path / 'recording.wav', (NOW - 3600, NOW - 3600))
        take = next(t for t in stats.read_takes(self.root, now=NOW) if t.id == hexid(13))
        self.assertIsNone(take.duration_ms)
        self.assertEqual(take.words, 9)

    def test_latest_transcript_is_the_newest_take_with_text(self):
        self.assertEqual(stats.latest_transcript(self.root), (hexid(2), 'word word word'))
        self.assertIsNone(stats.latest_transcript(self.root / 'absent'))


class StatsVerbTests(unittest.TestCase):
    def run_cli(self, recovery, *words):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = desktop.main(['--recovery', str(recovery), *words])
        return code, output.getvalue()

    def test_stats_verb_prints_the_json_through_the_cli_loader(self):
        with tempfile.TemporaryDirectory() as directory:
            make_take(directory, hexid(1), time.time(), 12, 4, age=3600)
            os.utime(Path(directory) / hexid(1) / 'recording.wav', (time.time() - 3600,) * 2)
            code, text = self.run_cli(directory, 'stats')
        self.assertEqual(code, 0)
        result = json.loads(text)
        self.assertEqual(result['words']['all_time'], 12)
        self.assertEqual(result['takes'], 1)


if __name__ == '__main__':
    unittest.main()
