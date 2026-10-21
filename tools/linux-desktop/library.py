"""Edit the saved-spelling and phrase libraries the way the Mac Dictionary and Transforms pages do.

Spellings live in the file named by `dictionary` in linux.json and phrases in the one named by `phrases`; the
formats are exactly what `spellings.py` and `phrases.py` read. Every change is a locked read-modify-write that ends
in an atomic rename, so the service never sees a half-written file. Validation mirrors the Mac editors
(`SpellingEditor`, `FileVocabulary`, `FilePhrases`, `SpellingCSV`, `OrdinaryWords`). Errors are ValueError with a
message the UI can show.
"""

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import time
import unicodedata

from phrases import MAX_LIBRARY_BYTES as PHRASES_LIMIT
from spellings import MAX_LIBRARY_BYTES as SPELLINGS_LIMIT, _WHITESPACE, _collapse
from vendor.grapheme import graphemes

MAX_CSV_BYTES = 1_048_576
MAX_CSV_ROWS = 5_000
MAX_SPELLING_GRAPHEMES = 128
MAX_TRIGGER_GRAPHEMES = 128
MAX_EXPANSION_GRAPHEMES = 16_000
_TRIM = ''.join(_WHITESPACE)
_ORDINARY_WORDS = frozenset("""
the be to of and a in that have i it for not on with he as you do at this but his by from they we say her she or an will my one all would there their what so up out if about who get which go me when make can like time no just him know take people into year your good some could them see other than then now look only come its over think also back after use two how our work first well way even new want because any these give day most us is are was were been being has had did does done am
said says made makes got gets went goes gone came comes took takes taken saw seen knew known thought thinks told tells found finds gave given put puts set sets let lets kept keeps began begun begins left leaves felt feels brought brings held holds wrote written writes ran runs stood stands heard hears met meets paid pays sat sits spoke spoken speaks lost loses fell falls fall sent sends built builds spent spends cut cuts won wins win winning lose losing
here where why while those much many more very still such each both few every own same another too off down through under again never always often sometimes already yet ever once between during before until since against without within along around among across behind beyond near far away upon toward towards inside outside above below
yes yeah okay ok hello hi hey please thanks thank sorry maybe sure right left really actually probably definitely basically anyway though although however whether either neither nor rather quite almost enough less least next last later soon today tomorrow yesterday tonight morning afternoon evening night week month years days weeks months hour hours minute minutes second seconds moment
man woman men women child children boy girl kid kids baby mother father mom dad brother sister son daughter wife husband friend friends family person place home house room door window floor wall table chair bed car cars road street city town country world state area part parts point number numbers group company business money job jobs school class student teacher book books paper word words name names thing things life lives hand hands head eye eyes face body heart mind water food fire air light dark sun moon star sky tree river sea land ground earth rain snow wind weather
big small little large long short high low old young early late great best better worse worst bad nice happy sad angry hard easy simple clear free full empty open closed ready sure true false real different important possible able available whole certain special main major public private local national human strong weak fast slow quick hot cold warm cool red blue green black white yellow brown pink orange gold silver
ask asks asked call calls called try tries tried need needs needed feel become becomes became leave seem seems seemed turn turns turned start starts started show shows showed shown hear play plays played move moves moved live lives lived believe bring happen happens happened write provide sit stand lose pay meet include includes continue continues learn learns change changes changed lead leads led understand watch follow follows stop stops stopped create creates created speak read reads allow allows add adds added spend grow grows grew open walk walks walked offer remember remembers love loves loved consider appear buy buys bought wait waits waited serve die dies died send expect build stay stays fall reach reaches remain suggest raise pass passes sell sells sold require report decide decides pull pulls
run running going coming doing making taking getting having being looking working thinking saying seeing wanting using trying asking needing feeling leaving calling talking talk talks talked telling meeting playing eating eat eats ate drink drinks driving drive drives drove sleep sleeps sleeping slept cook cooks cooking clean cleans cleaned wash washes washed sing sings sang song songs dance dances danced jump jumps jumped catch catches caught throw throws threw hit hits kick kicks push pushes fix fixes fixed break breaks broke broken check checks checked test tests tested save saves saved share shares shared send sent
can't won't don't doesn't didn't isn't aren't wasn't weren't haven't hasn't hadn't wouldn't couldn't shouldn't i'm i've i'll i'd you're you've you'll you'd he's she's it's we're we've we'll they're they've they'll that's there's what's who's let's
should must might may shall cannot can't
something anything nothing everything someone anyone everyone nobody somebody anybody everybody somewhere anywhere nowhere everywhere
idea ideas question questions answer answers problem problems reason reasons result results story stories fact facts case cases issue issues program system systems government law power matter side kind kinds sort type types form forms level order rule rules lot lots bit piece pieces space story research information data game games team music movie film picture photo video voice sound sounds news email message messages phone phones computer computers screen page pages site website app apps file files folder text line lines list lists code
one two three four five six seven eight nine ten eleven twelve twenty thirty forty fifty hundred thousand million first second third zero half double
monday tuesday wednesday thursday friday saturday sunday january february march april may june july august september october november december
will bill mark jack ray rob pat joy grace hope faith art rose lily violet daisy ivy amber summer autumn winter spring dawn eve gene frank chase drew grant miles hunter
hover hovers cat cats dog dogs bird birds fish horse horses cow pig animal animals
casino bank card cards price cost costs pay tax buy shop store market sale deal trade
ahead along apart aside away downtown upstairs downstairs
able accept account across act action activity add address agree air alone amount animal apply area arm arrive art attack attention available avoid bar base beautiful beat beyond bill bit blood board boat bottom box brain bring camera care carry catch cause center century chance character charge choice choose church color common community compare complete condition contain control copy correct couple court cover cross crowd culture current customer danger date deep degree develop difference difficult direction discuss doctor dollar draw dream dress drop dry due during edge effect effort end energy enjoy enter entire environment event exactly example exist experience explain express extra fact fair fear field fight figure fill final finally finger finish flow fly focus force forget forward front future garden general girl glass goal ground guess guy hair half hang hate health heavy help history hole hospital hotel idea image imagine interest involve island join kill kitchen knowledge language laugh lay lie lift limit listen literally machine mean measure member mention middle mile mouth movement nature nearly neck notice object office officer onto opportunity option outside paint pair park particular party past pattern perfect perhaps period pick plan plant plate pool popular position pressure pretty prevent process produce product project proper protect prove quality quiet race raise range rate reach record reduce refer region relate remove repeat represent respond rest return rich ride ring rise risk rock role roll round safe scene science season seat section seem sense serious service several shape sheet shoot shot shoulder sign similar single sir size skin slightly smile soft soldier somewhat sort source speed spirit sport spot spread square staff stage standard step stick stock stone store strange stuff subject success suddenly suffer summer supply support surface surprise sweet swim system tell term thin thus tie tired title tone tool top total touch track train travel trip trouble truck trust truth twice unit usually value various view visit wait wake war wear wide wish wonder worry wrong yard
""".split())

KINDS = {
    'spellings': {'key': 'dictionary', 'default': 'dictionary.json', 'limit': SPELLINGS_LIMIT,
                  'label': 'spelling library'},
    'phrases': {'key': 'phrases', 'default': 'phrases.json', 'limit': PHRASES_LIMIT, 'label': 'phrase library'},
}
CHANGED_SPELLING = 'This spelling changed outside the editor. Reload the library before saving or deleting it.'
CHANGED_PHRASE = 'This phrase changed outside the editor. Reload the library before saving or deleting it.'
CHANGED_IMPORT = 'The spelling library changed after this preview. Cancel and choose the CSV again.'


def _key(text):
    return unicodedata.normalize('NFC', ''.join(_collapse(text)).lower())


def _trim(text):
    return text.strip(_TRIM)


def _count(text):
    return len(list(graphemes(text)))


def _utf8(*values):
    for value in values:
        try:
            value.encode('utf-8')
        except UnicodeEncodeError:
            raise ValueError('Text must be valid UTF-8') from None


def _digest(raw):
    return 'missing' if raw is None else hashlib.sha256(raw).hexdigest()


# Paths and the config file.

def library_path(config, kind):
    """(path, configured): the file linux.json names for this library, else the default file beside linux.json."""
    config = Path(config)
    spec = KINDS[kind]
    value = _read_config(config).get(spec['key'])
    base = config.resolve().parent
    if value is None:
        return base / spec['default'], False
    if not isinstance(value, str) or not value:
        raise ValueError(f"{spec['key']} in linux.json must be a path")
    path = Path(value).expanduser()
    return (path if path.is_absolute() else base / path), True


def _read_config(config):
    try:
        source = _open_regular(config, 'linux.json must be a regular file')
    except FileNotFoundError:
        return {}
    with source:
        raw = source.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise ValueError('linux.json is too large')
    try:
        data = json.loads(raw.decode('utf-8'))
    except (UnicodeDecodeError, RecursionError, json.JSONDecodeError):
        raise ValueError('linux.json is not valid JSON') from None
    if not isinstance(data, dict):
        raise ValueError('linux.json must contain an object')
    return data


def _adopt(config, kind):
    """First write to an unconfigured library: point linux.json at the new file so the service reads it. True if it did."""
    config = Path(config)
    spec = KINDS[kind]
    if not config.is_file():
        return False
    data = _read_config(config)
    if spec['key'] in data:
        return False
    data[spec['key']] = spec['default']
    shutil.copy2(config, config.with_name(f'{config.name}.bak.{int(time.time())}'))
    _replace(config, (json.dumps(data, indent=2, ensure_ascii=False) + '\n').encode('utf-8'), 1024 * 1024)
    return True


# Reading and writing the library files.

def _open_regular(path, message):
    """Open without blocking on a FIFO or device and refuse anything that isn't a regular file."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError(message)
        return os.fdopen(fd, 'rb')
    except BaseException:
        os.close(fd)
        raise


def _read_raw(path, limit, label):
    try:
        source = _open_regular(path, f'The {label} must be a regular JSON file')
    except FileNotFoundError:
        return None
    with source:
        raw = source.read(limit + 1)
    if len(raw) > limit:
        raise ValueError(f'The {label} exceeds the {limit // (1024 * 1024)} MiB limit')
    return raw


def _parse(raw, label):
    if raw is None:
        return []

    def invalid_constant(_):
        raise ValueError(f'The {label} must contain valid JSON')
    try:
        entries = json.loads(raw.decode('utf-8'), parse_constant=invalid_constant)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ValueError(f'The {label} must contain valid JSON') from None
    except RecursionError:
        raise ValueError(f'The {label} nesting exceeds the decoder limit') from None
    if not isinstance(entries, list):
        raise ValueError(f'The {label} must contain an entry array')
    return entries


@contextlib.contextmanager
def _locked(path):
    """Serialize writers on the library's directory; the service only reads and never takes this lock."""
    directory = Path(os.path.realpath(path)).parent
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _replace(path, data, limit):
    if len(data) > limit:
        raise ValueError(f'The result would exceed the {limit // (1024 * 1024)} MiB limit')
    target = Path(os.path.realpath(path))
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        mode = stat.S_IMODE(target.stat().st_mode)
    except FileNotFoundError:
        mode = 0o600
    fd, temporary = tempfile.mkstemp(prefix=f'.{target.name}.', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


# Spellings.

def spelling_message(heard, written):
    """The Mac editor's validation message for a draft, or None."""
    if not _key(heard):
        return 'Enter the word or phrase Mouthtype gets wrong.'
    if not _trim(written):
        return 'Enter the spelling to use.'
    if _count(''.join(_collapse(heard))) > MAX_SPELLING_GRAPHEMES or _count(_trim(written)) > MAX_SPELLING_GRAPHEMES:
        return 'Keep each phrase and spelling under 129 characters.'
    return None


def _is_letter(char):
    return unicodedata.category(char[0])[0] == 'L'


def _joined_spelling(heard, written):
    parts = heard.split()
    return (len(parts) > 1 and any(_count(part) > 1 for part in parts) and
            all(_is_letter(char) for part in parts for char in graphemes(part)) and
            all(_is_letter(char) for char in graphemes(written)) and
            ''.join(parts).casefold() == written.casefold())


def everyday_warning(heard, written):
    """The Mac's OrdinaryWords.warning: a spelling whose heard form is everyday English rewrites that word everywhere."""
    heard = ''.join(_collapse(heard))
    written = _trim(written)
    if not heard or not written or not _ordinary(heard):
        return None
    if heard.casefold() == written.casefold() or _joined_spelling(heard, written):
        return None
    noun = 'an everyday phrase' if ' ' in heard else 'an everyday word'
    return f'‘{heard}’ is {noun}, so every ‘{heard}’ you say becomes {written}.'


def _ordinary(heard):
    parts = heard.split()
    for part in parts:
        if not all(unicodedata.category(char)[0] in 'LM' or char in "'’" for char in part):
            return False
    return all(''.join(char for char in part.lower().replace('’', "'")
                       if unicodedata.category(char)[0] in 'LM' or char == "'") in _ORDINARY_WORDS
               for part in parts)


def _spelling_entries(raw):
    """The file's entries as the service reads them, kept as dicts so extra keys survive an edit."""
    entries = _parse(raw, 'spelling library')
    for entry in entries:
        if (not isinstance(entry, dict) or not isinstance(entry.get('heard'), str) or
                not isinstance(entry.get('written'), str) or
                (entry.get('starred') is not None and type(entry['starred']) is not bool)):
            raise ValueError('Invalid dictionary entry')
        _utf8(entry['heard'], entry['written'])
    return entries


def _spelling_problem(entries):
    """What stops the Mac editor from writing this library (blank fields, repeated heard phrase), or None."""
    seen = set()
    for entry in entries:
        if not _key(entry['heard']) or not _trim(entry['written']):
            return 'a spelling has a blank heard or written field'
        if _key(entry['heard']) in seen:
            return 'more than one spelling has the same heard phrase'
        seen.add(_key(entry['heard']))
    return None


def _spelling_line(entry):
    parts = [f'"heard": {_dump(entry["heard"])}', f'"written": {_dump(entry["written"])}',
             f'"starred": {"true" if entry.get("starred") is True else "false"}']
    for name in sorted(set(entry) - {'heard', 'written', 'starred'}):
        parts.append(f'{_dump(name)}: {json.dumps(entry[name], ensure_ascii=False, separators=(",", ":"), sort_keys=True)}')
    return '{ ' + ', '.join(parts) + ' }'


def _dump(text):
    return json.dumps(text, ensure_ascii=False)


def _render_spellings(entries):
    if not entries:
        return '[]\n'
    return '[\n' + ',\n'.join('  ' + _spelling_line(entry) for entry in entries) + '\n]\n'


def _spelling_view(entry):
    return {'heard': entry['heard'], 'written': entry['written'], 'starred': entry.get('starred') is True,
            'warning': everyday_warning(entry['heard'], entry['written'])}


def _library_state(config, kind):
    """(path, configured, raw bytes or None, parsed entries, problem or None). A library the service can't read is a problem, not an error."""
    path, configured = library_path(config, kind)
    spec = KINDS[kind]
    raw = None
    try:
        raw = _read_raw(path, spec['limit'], spec['label'])
        entries = _spelling_entries(raw) if kind == 'spellings' else _phrase_entries(raw)
        problem = _spelling_problem(entries) if kind == 'spellings' else None
        if problem:
            problem = f'The {spec["label"]} could not be read: {problem}. Fix {path.name} and reload it.'
    except ValueError as error:
        return path, configured, raw, [], f'{error}. Fix {path.name} and reload it.'
    return path, configured, raw, entries, problem


def _payload(kind, path, configured, raw, entries, problem=None, **extra):
    view = _spelling_view if kind == 'spellings' else _phrase_view
    result = {'kind': kind, 'path': str(path), 'configured': configured, 'exists': raw is not None,
              'digest': _digest(raw), 'count': len(entries), 'entries': [view(entry) for entry in entries],
              'problem': problem, 'writable': problem is None}
    result.update(extra)
    return result


def list_library(config, kind):
    path, configured, raw, entries, problem = _library_state(config, kind)
    return _payload(kind, path, configured, raw, entries, problem)


def _for_write(config, kind):
    path, configured, raw, entries, problem = _library_state(config, kind)
    if problem:
        raise ValueError(problem)
    return path, configured, raw, entries


def _commit(config, kind, path, configured, entries, text, **extra):
    data = text.encode('utf-8')
    _replace(path, data, KINDS[kind]['limit'])
    adopted = False if configured else _adopt(config, kind)
    return _payload(kind, path, configured or adopted, data, entries, adopted_config=adopted, **extra)


def _find_spelling(entries, heard, expect_written):
    for index, entry in enumerate(entries):
        if _key(entry['heard']) == _key(heard) and (expect_written is None or entry['written'] == expect_written):
            return index
    raise ValueError(CHANGED_SPELLING)


def add_spelling(config, heard, written):
    _utf8(heard, written)
    heard, written = ''.join(_collapse(heard)), _trim(written)
    message = spelling_message(heard, written)
    if message:
        raise ValueError(message)
    path, configured = library_path(config, 'spellings')
    with _locked(path):
        path, configured, _raw, entries = _for_write(config, 'spellings')
        if any(_key(entry['heard']) == _key(heard) for entry in entries):
            raise ValueError('A spelling for this heard phrase already exists.')
        entry = {'heard': heard, 'written': written, 'starred': False}
        entries.append(entry)
        return _commit(config, 'spellings', path, configured, entries, _render_spellings(entries),
                       result='added', entry=_spelling_view(entry))


def edit_spelling(config, original_heard, heard, written, expect_written=None):
    _utf8(original_heard, heard, written)
    heard, written = ''.join(_collapse(heard)), _trim(written)
    message = spelling_message(heard, written)
    if message:
        raise ValueError(message)
    path, configured = library_path(config, 'spellings')
    with _locked(path):
        path, configured, raw, entries = _for_write(config, 'spellings')
        index = _find_spelling(entries, original_heard, expect_written)
        if any(i != index and _key(entry['heard']) == _key(heard) for i, entry in enumerate(entries)):
            raise ValueError('A spelling for this heard phrase already exists.')
        entry = entries[index]
        if entry['heard'] == heard and entry['written'] == written and entry.get('starred') is not None:
            return _payload('spellings', path, configured, raw, entries, result='unchanged', entry=_spelling_view(entry))
        entry['heard'], entry['written'], entry['starred'] = heard, written, entry.get('starred') is True
        return _commit(config, 'spellings', path, configured, entries, _render_spellings(entries),
                       result='updated', entry=_spelling_view(entry))


def remove_spelling(config, heard, expect_written=None):
    _utf8(heard)
    path, configured = library_path(config, 'spellings')
    with _locked(path):
        path, configured, _raw, entries = _for_write(config, 'spellings')
        removed = entries.pop(_find_spelling(entries, heard, expect_written))
        return _commit(config, 'spellings', path, configured, entries, _render_spellings(entries),
                       result='removed', entry=_spelling_view(removed))


# Phrases (the Mac's Transforms page).

def phrase_message(trigger, expansion):
    if not _collapse(trigger):
        return 'Enter a phrase to say.'
    if not _collapse(expansion):
        return 'Enter the text to insert.'
    if _count(''.join(_collapse(trigger))) > MAX_TRIGGER_GRAPHEMES:
        return 'Keep the spoken phrase under 129 characters.'
    if _count(expansion) > MAX_EXPANSION_GRAPHEMES:
        return 'Keep the replacement under 16,001 characters.'
    return None


def _phrase_entries(raw):
    entries = _parse(raw, 'phrase library')
    seen = set()
    for entry in entries:
        if (not isinstance(entry, dict) or not isinstance(entry.get('trigger'), str) or
                not isinstance(entry.get('expansion'), str)):
            raise ValueError('Invalid phrase entry')
        _utf8(entry['trigger'], entry['expansion'])
        trigger = ''.join(_collapse(entry['trigger']))
        if (not trigger or _count(trigger) > MAX_TRIGGER_GRAPHEMES or not _collapse(entry['expansion']) or
                _count(entry['expansion']) > MAX_EXPANSION_GRAPHEMES):
            raise ValueError('Invalid phrase length')
        if _key(trigger) in seen:
            raise ValueError('Duplicate phrase trigger')
        seen.add(_key(trigger))
    return entries


def _phrase_view(entry):
    return {'trigger': entry['trigger'], 'expansion': entry['expansion']}


def _render_phrases(entries):
    if not entries:
        return '[]\n'
    return json.dumps(entries, indent=2, sort_keys=True, ensure_ascii=False) + '\n'


def _find_phrase(entries, trigger, expect_expansion):
    for index, entry in enumerate(entries):
        if _key(entry['trigger']) == _key(trigger) and (expect_expansion is None or entry['expansion'] == expect_expansion):
            return index
    raise ValueError(CHANGED_PHRASE)


def add_phrase(config, trigger, expansion):
    _utf8(trigger, expansion)
    message = phrase_message(trigger, expansion)
    if message:
        raise ValueError(message)
    trigger = ''.join(_collapse(trigger))
    path, configured = library_path(config, 'phrases')
    with _locked(path):
        path, configured, _raw, entries = _for_write(config, 'phrases')
        if any(_key(entry['trigger']) == _key(trigger) for entry in entries):
            raise ValueError('A phrase with this trigger already exists.')
        entry = {'trigger': trigger, 'expansion': expansion}
        entries.append(entry)
        return _commit(config, 'phrases', path, configured, entries, _render_phrases(entries),
                       result='added', entry=_phrase_view(entry))


def edit_phrase(config, original_trigger, trigger, expansion, expect_expansion=None):
    _utf8(original_trigger, trigger, expansion)
    message = phrase_message(trigger, expansion)
    if message:
        raise ValueError(message)
    trigger = ''.join(_collapse(trigger))
    path, configured = library_path(config, 'phrases')
    with _locked(path):
        path, configured, raw, entries = _for_write(config, 'phrases')
        index = _find_phrase(entries, original_trigger, expect_expansion)
        if any(i != index and _key(entry['trigger']) == _key(trigger) for i, entry in enumerate(entries)):
            raise ValueError('A phrase with this trigger already exists.')
        entry = entries[index]
        if entry['trigger'] == trigger and entry['expansion'] == expansion:
            return _payload('phrases', path, configured, raw, entries, result='unchanged', entry=_phrase_view(entry))
        entry['trigger'], entry['expansion'] = trigger, expansion
        return _commit(config, 'phrases', path, configured, entries, _render_phrases(entries),
                       result='updated', entry=_phrase_view(entry))


def remove_phrase(config, trigger, expect_expansion=None):
    _utf8(trigger)
    path, configured = library_path(config, 'phrases')
    with _locked(path):
        path, configured, _raw, entries = _for_write(config, 'phrases')
        removed = entries.pop(_find_phrase(entries, trigger, expect_expansion))
        return _commit(config, 'phrases', path, configured, entries, _render_phrases(entries),
                       result='removed', entry=_phrase_view(removed))


# CSV import (SpellingCSV.swift and FileVocabulary.previewImport).

def csv_records(data):
    """[(line, fields)] for a CSV with the Mac's strict quoting rules. Raises ValueError with the Mac's wording."""
    if len(data) > MAX_CSV_BYTES:
        raise ValueError('Choose a CSV of 1 MiB or smaller.')
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        raise ValueError('Save the CSV as UTF-8 text.') from None
    if text.startswith('﻿'):
        text = text[1:]
    if '\0' in text:
        raise ValueError('The CSV contains an unsupported null character.')
    state, records, fields, field = 'start', [], [], ''
    touched, line, record_line = False, 1, 1

    def finish():
        nonlocal fields, field, touched, state
        if touched:
            fields.append(field)
            records.append((record_line, fields))
            if len(records) > MAX_CSV_ROWS + 1:
                raise ValueError('Import up to 5,000 spellings at a time.')
        fields, field, touched, state = [], '', False, 'start'

    for character in graphemes(text):
        newline = character in ('\n', '\r', '\r\n')
        if state == 'quoted':
            if character == '"':
                state = 'closed'
            else:
                field += character
            if newline:
                line += 1
            continue
        if character == '"':
            if state == 'start':
                state, touched = 'quoted', True
            elif state == 'closed':
                field += character
                state = 'quoted'
            else:
                raise ValueError(f'Row {line}: a quote must start a quoted field.')
        elif character == ',':
            fields.append(field)
            field, touched, state = '', True, 'start'
        elif newline:
            finish()
            line += 1
            record_line = line
        else:
            if state == 'closed':
                raise ValueError(f'Row {line}: unexpected text after a closing quote.')
            field += character
            touched, state = True, 'unquoted'
    if state == 'quoted':
        raise ValueError(f'Row {record_line}: a quoted field was not closed.')
    finish()
    return records


def _read_csv(path):
    with _open_regular(Path(path).expanduser(), 'Choose a regular CSV file.') as source:
        return source.read(MAX_CSV_BYTES + 1)


_LABELS = {'add': 'Add', 'existing': 'Already saved', 'duplicate': 'Duplicate row'}


def _preview(entries, data):
    """Rows and verdicts for a CSV against the saved entries. No file access, so the confirm step reuses it."""
    empty = {'problem': None, 'rows': [], 'counts': {'add': 0, 'existing': 0, 'duplicate': 0, 'invalid': 0},
             'can_import': False}
    try:
        records = csv_records(data)
    except ValueError as error:
        return dict(empty, problem=str(error)), []
    header = [_trim(name).lower() for name in records[0][1]] if records else []
    names_only = header == ['name']
    if not (names_only or (len(header) == 2 and set(header) == {'heard', 'written'})):
        return dict(empty, problem='Use a name column, or heard,written columns with a header row.'), []
    heard_column = 0 if names_only else header.index('heard')
    written_column = 0 if names_only else header.index('written')
    existing = {_key(entry['heard']): entry['written'] for entry in entries}
    seen, rows, additions = {}, [], []
    for line, fields in records[1:]:
        if len(fields) != len(header):
            plural = '' if len(header) == 1 else 's'
            rows.append(_row(line, fields[0] if fields else '', '', 'invalid', f'Expected {len(header)} column{plural}.'))
            continue
        heard = ''.join(_collapse(fields[heard_column]))
        written = _trim(fields[written_column])
        key = _key(heard)
        message = spelling_message(heard, written)
        if message:
            rows.append(_row(line, heard, written, 'invalid', message))
        elif key in existing:
            saved = existing[key]
            if saved == written:
                rows.append(_row(line, heard, written, 'existing'))
            else:
                rows.append(_row(line, heard, written, 'invalid', f'Conflicts with the saved spelling “{saved}”.'))
        elif key in seen:
            if seen[key] == written:
                rows.append(_row(line, heard, written, 'duplicate'))
            else:
                rows.append(_row(line, heard, written, 'invalid', 'Conflicts with another CSV row.'))
        else:
            rows.append(_row(line, heard, written, 'add'))
            additions.append({'heard': heard, 'written': written, 'starred': False})
        seen[key] = written
    counts = {name: sum(1 for row in rows if row['result'] == name) for name in ('add', 'existing', 'duplicate', 'invalid')}
    problem = None if rows else 'The CSV has no spellings to import.'
    return {'problem': problem, 'rows': rows, 'counts': counts,
            'can_import': problem is None and counts['add'] > 0 and counts['invalid'] == 0}, additions


def _row(line, heard, written, result, message=None):
    warning = everyday_warning(heard, written) if result == 'add' else None
    return {'row': line, 'heard': heard, 'written': written, 'result': result,
            'label': message or _LABELS[result], 'warning': warning}


def preview_import(config, csv_path):
    """What importing this CSV would do, without writing. `digest` is the library's state to hand back to import_spellings."""
    path, configured, raw, entries = _for_write(config, 'spellings')
    data = _read_csv(csv_path)
    result, _additions = _preview(entries, data)
    return dict(result, file=Path(csv_path).name, digest=_digest(raw), csv_digest=_digest(data), kind='spellings',
                configured=configured)


def import_spellings(config, csv_path, expect_digest=None, expect_csv_digest=None):
    """Append the CSV's new rows in one write. With expect_digest or expect_csv_digest from a preview, refuses if the
    library or the CSV moved since, so the rows written are the rows shown."""
    data = _read_csv(csv_path)
    if expect_csv_digest is not None and expect_csv_digest != _digest(data):
        raise ValueError('The CSV changed after this preview. Cancel and choose the CSV again.')
    path, configured = library_path(config, 'spellings')
    with _locked(path):
        path, configured, raw, entries = _for_write(config, 'spellings')
        if expect_digest is not None and expect_digest != _digest(raw):
            raise ValueError(CHANGED_IMPORT)
        result, additions = _preview(entries, data)
        if not result['can_import']:
            raise ValueError(result['problem'] or 'Fix the CSV errors before importing.')
        entries.extend(additions)
        return _commit(config, 'spellings', path, configured, entries, _render_spellings(entries),
                       result='imported', imported=len(additions), skipped=result['counts']['existing'] + result['counts']['duplicate'])
