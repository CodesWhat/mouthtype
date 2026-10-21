"""Dictation statistics for the Linux client, rebuilt from the recovery directories on every call.

Nothing is stored: a take's words come from its transcript.txt, its start from take.json, and its speaking time from the
length of recording.wav. The rules are the Mac StatsEngine rules (Sources/MouthtypeCore/Store/StatsEngine.swift,
Streaks.swift, StatsTimeline.swift):

- A day is the local calendar day of the take. A streak is consecutive days with at least one word, and the current one
  survives until the end of the day after the last active day.
- A take counts toward speed only with at least 5 words and 3 seconds of speech, and a rate above 400 wpm is ignored as a
  bad timing. The average is total words over total speaking time of those takes, not a mean of rates.
- Time saved is typing the same words at 40 wpm minus speaking them, over takes with a known duration, never negative.

Differences from the Mac, all forced by the data on disk:

- History is bounded. Recovery keeps at most `maximum_recovery_takes` takes, `history_keep` can prune more, and Forget
  removes a take, so every number covers only what is still on disk. The result says so with history_limited.
- Speaking time is the whole recording. Linux doesn't log voiced time, so speed reads a little lower than the Mac's.
- Retention deletes old recording.wav files and keeps the transcript. Those takes keep their words but have no duration, so
  they leave speed and time saved alone, the same as a Mac take with no logged duration.
"""

from dataclasses import dataclass
from datetime import date, datetime
import json
import os
import re
import struct
import time
import wave
from pathlib import Path

VERSION = 1
TYPING_WPM = 40.0
MIN_WPM_WORDS = 5
MIN_WPM_MS = 3000
MAX_PLAUSIBLE_WPM = 400.0
DAILY_WINDOW_DAYS = 30
HOUR_WINDOW_DAYS = 30
TRANSCRIPT_LIMIT = 1024 * 1024
# A take with audio and no transcript this fresh is still being recorded, not an audio-only take.
ACTIVE_AUDIO_SECONDS = 5
TAKE_ID = re.compile('[0-9a-f]{32}')


@dataclass(frozen=True)
class Take:
    id: str
    started: float
    words: int
    duration_ms: int | None
    audio_only: bool


def take_started(path, children=None):
    """When the take was made: take.json, else the earliest surviving file (expiring the WAV can't move it).

    `children` is an optional {name: DirEntry} listing of the take that the caller already read."""
    path = Path(path)
    try:
        created = json.loads((path / 'take.json').read_text())['created']
        if type(created) in (int, float) and created == created and abs(created) != float('inf'):
            return float(created)
    except (OSError, ValueError, KeyError, TypeError):
        pass
    stamps = []
    if children is None:
        with os.scandir(path) as scan:
            children = list(scan)
    else:
        children = list(children.values())
    for child in children:
        try:
            if child.is_file():
                stamps.append(child.stat().st_mtime)
        except OSError:
            pass
    return min(stamps) if stamps else path.stat().st_mtime


def wav_duration_ms(path):
    try:
        with wave.open(str(path), 'rb') as audio:
            rate, frames = audio.getframerate(), audio.getnframes()
    except (OSError, EOFError, wave.Error, struct.error, ValueError, OverflowError):
        return None
    if rate <= 0 or frames <= 0:
        return None
    return int(frames * 1000 / rate)


def _regular(children, name):
    """The DirEntry for a regular file called `name` in the take, or None. A symlink never counts."""
    child = children.get(name)
    try:
        return child if child is not None and child.is_file(follow_symlinks=False) else None
    except OSError:
        return None


def read_takes(root, *, now=None):
    """Every take under the recovery directory that produced words or kept audio. Text is counted, never kept.

    One scandir pass over the root and one per take: the DirEntry objects carry the file types and stats, so a take
    costs two directory reads plus the files it actually needs (take.json, the transcript, the WAV header)."""
    root = Path(root)
    now = time.time() if now is None else now
    takes = []
    try:
        with os.scandir(root) as scan:
            entries = sorted((entry for entry in scan if TAKE_ID.fullmatch(entry.name)), key=lambda entry: entry.name)
    except OSError:
        return takes
    for entry in entries:
        try:
            if entry.is_symlink() or not entry.is_dir():
                continue
            with os.scandir(entry.path) as inner:
                children = {child.name: child for child in inner}
            path = Path(entry.path)
            started = take_started(path, children)
            transcript, audio = _regular(children, 'transcript.txt'), _regular(children, 'recording.wav')
            words = 0
            if transcript is not None:
                with open(transcript.path, 'rb') as source:
                    words = len(source.read(TRANSCRIPT_LIMIT).decode('utf-8', 'ignore').split())
            if words == 0:
                if audio is None:
                    continue
                if transcript is None and now - audio.stat().st_mtime < ACTIVE_AUDIO_SECONDS:
                    continue
            duration = wav_duration_ms(audio.path) if audio is not None else None
        except OSError:
            continue
        takes.append(Take(entry.name, started, words, duration, words == 0))
    return takes


def _local(stamp, tz):
    return datetime.fromtimestamp(stamp, tz)


def _day_number(day):
    return day.toordinal()


def _day_string(number):
    return date.fromordinal(number).isoformat()


def _rate(take):
    """Words per minute when the take qualifies for speed, else None. Multiplies first like the SQL path."""
    if take.words < MIN_WPM_WORDS or take.duration_ms is None or take.duration_ms < MIN_WPM_MS:
        return None
    rate = take.words * 60000 / take.duration_ms
    return rate if rate <= MAX_PLAUSIBLE_WPM else None


def _longest_run(numbers):
    """(length, day number it first reached that length) of the longest run of consecutive day numbers, or None."""
    if not numbers:
        return None
    best = (1, numbers[0])
    run = 1
    for index in range(1, len(numbers)):
        run = run + 1 if numbers[index] == numbers[index - 1] + 1 else 1
        if run > best[0]:
            best = (run, numbers[index])
    return best


def _streaks(numbers, today):
    """(current, longest) from ascending distinct day numbers."""
    if not numbers:
        return 0, 0
    longest = run = 1
    for index in range(1, len(numbers)):
        run = run + 1 if numbers[index] == numbers[index - 1] + 1 else 1
        longest = max(longest, run)
    last = numbers[-1]
    return (run if today - 1 <= last <= today else 0), longest


def _streak_lit(daily, current):
    """Which daily dots are lit. A streak not yet extended today ends yesterday and leaves today's dot dark."""
    lit = [False] * len(daily)
    if not daily or current <= 0:
        return lit
    end = len(daily) - 1 if daily[-1]['words'] > 0 else len(daily) - 2
    if end < 0:
        return lit
    start = end - current + 1
    return [start <= index <= end for index in range(len(daily))]


def _round(value, places=2):
    return None if value is None else round(value, places)


def build(takes, *, now=None, tz=None, typing_wpm=TYPING_WPM):
    """The Stats page data as one JSON-ready dict. `tz` is a tzinfo (local time when None)."""
    now = time.time() if now is None else now
    typing_wpm = typing_wpm if typing_wpm and typing_wpm > 0 else TYPING_WPM
    today = _day_number(_local(now, tz).date())

    worded = []
    for take in takes:
        if take.words > 0:
            worded.append((take, _local(take.started, tz)))
    worded.sort(key=lambda item: (item[0].started, item[0].id))

    by_day = {}
    for take, when in worded:
        number = _day_number(when.date())
        by_day[number] = by_day.get(number, 0) + take.words
    numbers = sorted(by_day)

    words_today = by_day.get(today, 0)
    words_week = sum(words for number, words in by_day.items() if today - 7 < number <= today)
    words_all = sum(take.words for take, _ in worded)

    rated = [(take, rate) for take, _ in worded if (rate := _rate(take)) is not None]
    rated_words = sum(take.words for take, _ in rated)
    rated_ms = sum(take.duration_ms for take, _ in rated)
    average = rated_words / (rated_ms / 60000) if rated_ms > 0 else None
    fastest = None
    for take, rate in rated:
        if fastest is None or rate > fastest[1]:
            fastest = (take, rate)

    current, longest = _streaks(numbers, today)
    run = _longest_run(numbers)

    timed = [take for take, _ in worded if (take.duration_ms or 0) > 0]
    speaking_minutes = sum(take.duration_ms for take in timed) / 60000
    minutes_saved = max(0.0, sum(take.words for take in timed) / typing_wpm - speaking_minutes)

    biggest = None
    for number in numbers:
        if by_day[number] > (biggest[1] if biggest else 0):
            biggest = (number, by_day[number])
    longest_take = None
    for take, when in worded:
        if longest_take is None or take.words > longest_take[0].words:
            longest_take = (take, when)

    daily = []
    if worded:
        daily = [{'day': _day_string(number), 'words': by_day.get(number, 0)}
                 for number in range(today - (DAILY_WINDOW_DAYS - 1), today + 1)]

    hourly = [0] * 24
    for take, when in worded:
        if today - HOUR_WINDOW_DAYS < _day_number(when.date()) <= today:
            hourly[when.hour] += take.words
    peak_hour = None
    for hour, words in enumerate(hourly):
        if words > (hourly[peak_hour] if peak_hour is not None else 0):
            peak_hour = hour

    tape = []
    for take in takes:
        when = _local(take.started, tz)
        if _day_number(when.date()) == today:
            tape.append((when.hour * 3600 + when.minute * 60 + when.second, take, when))
    tape.sort(key=lambda item: (item[0], item[1].started, item[1].words, item[1].duration_ms or -1, item[1].id))
    tape_timed = [take for _, take, _ in tape if (take.duration_ms or 0) > 0]
    tape_saved = max(0.0, sum(take.words for take in tape_timed) / typing_wpm
                     - sum(take.duration_ms for take in tape_timed) / 60000)

    return {
        'version': VERSION,
        'generated_at': int(now),
        'today': _day_string(today),
        'has_history': bool(worded),
        'history_limited': True,
        'first_day': _day_string(numbers[0]) if numbers else None,
        'words': {'today': words_today, 'week': words_week, 'all_time': words_all},
        'takes': len(worded),
        'speed': {'average_wpm': _round(average), 'peak_wpm': _round(fastest[1]) if fastest else None,
                  'rated_takes': len(rated), 'minimum_words': MIN_WPM_WORDS, 'minimum_milliseconds': MIN_WPM_MS,
                  'typing_wpm': typing_wpm},
        'streak': {'current': current, 'longest': longest},
        'time_saved': {'minutes': _round(minutes_saved), 'speaking_minutes': _round(speaking_minutes),
                       'typing_wpm': typing_wpm},
        'daily': daily,
        'streak_lit': _streak_lit(daily, current),
        'hourly': hourly,
        'hour_window_days': HOUR_WINDOW_DAYS,
        'peak_hour': peak_hour,
        'tape': [{'id': take.id, 'started_at': int(take.started), 'seconds_into_day': seconds,
                  'time': when.strftime('%H:%M'), 'words': take.words, 'duration_ms': take.duration_ms,
                  'audio_only': take.audio_only} for seconds, take, when in tape],
        'tape_summary': {'takes': len(tape), 'words': sum(take.words for _, take, _ in tape),
                         'speaking_ms': sum(take.duration_ms or 0 for _, take, _ in tape),
                         'minutes_avoided': _round(tape_saved)},
        'high_scores': {
            'fastest': {'value': _round(fastest[1]), 'date': _local(fastest[0].started, tz).date().isoformat()}
            if fastest else None,
            'biggest_day': {'value': biggest[1], 'date': _day_string(biggest[0])} if biggest else None,
            'longest_streak': {'value': run[0], 'date': _day_string(run[1])} if run else None,
            'longest_take': {'value': longest_take[0].words, 'duration_ms': longest_take[0].duration_ms,
                             'date': longest_take[1].date().isoformat()} if longest_take else None,
        },
    }


def compute(root, *, now=None, tz=None):
    now = time.time() if now is None else now
    return build(read_takes(root, now=now), now=now, tz=tz)


def latest_transcript(root):
    """(id, text) of the newest take with a non-empty transcript, or None.

    Newest means the take directory's mtime, which moves when its transcript is written. Takes are visited newest
    first and the walk stops at the first one with words, so the rest of the history is never opened."""
    candidates = []
    try:
        with os.scandir(root) as scan:
            for entry in scan:
                try:
                    if TAKE_ID.fullmatch(entry.name) and not entry.is_symlink() and entry.is_dir():
                        candidates.append((entry.stat().st_mtime, entry.name))
                except OSError:
                    continue
    except OSError:
        return None
    candidates.sort(reverse=True)
    for _, name in candidates:
        transcript = Path(root) / name / 'transcript.txt'
        try:
            if transcript.is_symlink() or not transcript.is_file():
                continue
            with open(transcript, 'rb') as source:
                raw = source.read(TRANSCRIPT_LIMIT)
            if not raw.decode('utf-8', 'ignore').split():
                continue
            return name, raw.decode('utf-8')
        except UnicodeDecodeError:
            return None
        except OSError:
            continue
    return None
