"""Checks for the Dictionary and Transforms pages (slice V5) that need no Qt: the pages call the control_library verbs with
the right arguments, the fixtures have the shapes the real library code produces, the text rules hold under pages/library/,
and the pure helpers in LibraryModel.js behave (run with node when it is installed). The rendered behaviour is checked by
shell-render/tst_library.qml on the NAS testbed."""
import importlib.util
import inspect
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
LIBRARY = HERE / "pages" / "library"
FIXTURES = LIBRARY / "fixtures"

spec = importlib.util.spec_from_file_location("omarchy_control_for_library_pages", HERE / "control.py")
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)
sys.path.insert(0, str(HERE.parent / "linux-desktop"))
import library  # noqa: E402

PAGES = [HERE / "pages" / "DictionaryPage.qml", HERE / "pages" / "TransformsPage.qml"]


def library_sources():
    return sorted(LIBRARY.glob("*.qml")) + PAGES


def fixture(name):
    return json.loads((FIXTURES / (name + ".json")).read_text(encoding="utf-8"))


def top_level_arguments(text):
    """The number of items in a QML array literal body, splitting on commas outside brackets and quotes."""
    depth, count, quoted, escaped, seen = 0, 0, None, False, False
    for char in text:
        if quoted:
            escaped = (char == "\\" and not escaped)
            if char == quoted and not escaped:
                quoted = None
            continue
        if char in "\"'":
            quoted, seen = char, True
        elif char in "([{":
            depth, seen = depth + 1, True
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            count += 1
        elif not char.isspace():
            seen = True
    return count + 1 if seen else 0


class PageContractTests(unittest.TestCase):
    def test_pages_follow_the_shell_contract(self):
        for path in PAGES:
            text = path.read_text(encoding="utf-8")
            self.assertRegex(text, r"property var backend\b", path.name)
            self.assertRegex(text, r"property bool active\b", path.name)
            self.assertRegex(text, r"signal request\(string command, var args\)", path.name)
            self.assertRegex(text, r"readonly property bool editing\b", path.name)
            self.assertIn("implicitHeight", text, path.name)

    def test_every_verb_the_pages_send_exists_with_matching_arguments(self):
        commands = control.module_commands()
        sent = {}
        for path in PAGES:
            for verb, args in re.findall(r'(?:tracker|root)\.send\("([a-z-]+)", (\[[^\n]*\])\)', path.read_text(encoding="utf-8")):
                sent.setdefault(verb, set()).add(top_level_arguments(args[1:-1]))
        self.assertGreaterEqual(len(sent), 10, sorted(sent))
        for verb, counts in sent.items():
            if verb == "transform-status":
                self.assertIn(verb, commands)
                continue
            self.assertIn(verb, commands, verb)
            parameters = inspect.signature(commands[verb]).parameters.values()
            minimum = sum(1 for p in parameters if p.default is p.empty)
            maximum = len(list(inspect.signature(commands[verb]).parameters))
            for count in counts:
                self.assertTrue(minimum <= count <= maximum, f"{verb} sent with {count} arguments, takes {minimum} to {maximum}")

    def test_edit_remove_and_import_send_their_expect_values(self):
        dictionary = PAGES[0].read_text(encoding="utf-8")
        transforms = PAGES[1].read_text(encoding="utf-8")
        self.assertIn('root.send("spellings-edit", [wordSheet.pair.heard, heard, written, wordSheet.pair.written])', dictionary)
        self.assertIn('root.send("spellings-remove", [wordSheet.pair.heard, wordSheet.pair.written])', dictionary)
        self.assertIn('root.send("spellings-import", [path, digest, csvDigest])', dictionary)
        self.assertIn('root.send("phrases-edit", [sheet.pair.trigger, trigger, expansion, sheet.pair.expansion])', transforms)
        self.assertIn('root.send("phrases-remove", [sheet.pair.trigger, sheet.pair.expansion])', transforms)

    def test_import_sheet_hands_both_digests_back(self):
        sheet = (LIBRARY / "ImportCsvSheet.qml").read_text(encoding="utf-8")
        self.assertIn('importRequested(previewPath, preview.digest || "", preview.csv_digest || "")', sheet)

    def test_sheets_bind_escape_and_ctrl_return(self):
        frame = (LIBRARY / "LibrarySheet.qml").read_text(encoding="utf-8")
        self.assertIn('"Ctrl+Return"', frame)
        self.assertIn('sequence: "Escape"', frame)

    def test_restart_note_text_is_present_in_both_pages(self):
        for path in PAGES:
            text = path.read_text(encoding="utf-8")
            self.assertIn("adoptedConfig", text, path.name)
            self.assertIn("Restart Mouthtype", text, path.name)


class DraftWiringTests(unittest.TestCase):
    def test_pages_send_only_draft_verbs_control_library_has(self):
        commands = control.module_commands()
        for path in PAGES + [HERE / "pages" / "HomePage.qml"]:
            for verb in re.findall(r'request\("(draft-[a-z]+)"', path.read_text(encoding="utf-8")):
                self.assertIn(verb, commands, f"{path.name} sends {verb}")

    def test_home_recovery_row_and_host_handoff(self):
        home = (HERE / "pages" / "HomePage.qml").read_text(encoding="utf-8")
        self.assertIn('request("draft-list", [])', home)
        self.assertIn('buttonText: "Recover"', home)
        self.assertIn("host.pendingDraft = d", home)
        for name in ("DictionaryPage", "TransformsPage"):
            text = (HERE / "pages" / f"{name}.qml").read_text(encoding="utf-8")
            self.assertIn("host.pendingDraft", text, name)
            self.assertIn('request("draft-clear", [draftId])', text, name)
        for path in (HERE / "AppState.qml", HERE / "shell-render" / "FixtureHost.qml"):
            self.assertIn("property var pendingDraft", path.read_text(encoding="utf-8"), path.name)


class TextRuleTests(unittest.TestCase):
    def test_no_elide_no_small_text_no_restricted_word(self):
        for path in library_sources():
            text = path.read_text(encoding="utf-8")
            self.assertNotRegex(text, r"elide:\s*Text\.Elide(?!None)", path.name)
            for size in re.findall(r"pixelSize:\s*(\d+(?:\.\d+)?)\s*$", text, re.M):
                self.assertGreaterEqual(float(size), 10, path.name)
            for size in re.findall(r"Type\.(?:sans|mono|serif)\((\d+(?:\.\d+)?)", text):
                self.assertGreaterEqual(float(size), 10, path.name)
            self.assertNotIn("token", path.name.lower())
        for path in LIBRARY.rglob("*"):
            self.assertNotIn("token", path.name.lower(), str(path))

    def test_no_em_dash_in_visible_copy(self):
        for path in library_sources():
            self.assertNotIn("—", path.read_text(encoding="utf-8"), path.name)


class FixtureShapeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config = self.root / "linux.json"
        self.config.write_text(json.dumps({"engine_config": "engines.json"}), encoding="utf-8")

    def test_spellings_fixtures_match_the_real_listing(self):
        library.add_spelling(self.config, "win", "Winn")
        real = library.list_library(self.config, "spellings")
        for name in ("spellings-list", "spellings-empty"):
            self.assertEqual(set(fixture(name)), set(real), name)
        self.assertEqual(set(fixture("spellings-list")["entries"][0]), set(real["entries"][0]))
        self.assertTrue(real["entries"][0]["warning"], "the everyday-word warning comes from the library")
        self.assertTrue(any(entry["starred"] for entry in fixture("spellings-list")["entries"]))

    def test_phrase_fixtures_match_the_real_listing(self):
        library.add_phrase(self.config, "sign off", "Thanks,\nScott")
        real = library.list_library(self.config, "phrases")
        for name in ("phrases-list", "phrases-empty"):
            self.assertEqual(set(fixture(name)), set(real), name)
        self.assertEqual(set(fixture("phrases-list")["entries"][0]), set(real["entries"][0]))

    def test_import_fixtures_match_the_real_preview(self):
        csv = self.root / "names.csv"
        csv.write_text("heard,written\nshawn,Sean\n,Blank\nwin,Winn\n", encoding="utf-8")
        real = library.preview_import(self.config, str(csv))
        for name in ("import-valid", "import-invalid", "import-many", "import-many-invalid", "import-names-column", "import-problem"):
            self.assertEqual(set(fixture(name)), set(real), name)
        self.assertEqual(set(fixture("import-invalid")["rows"][0]), set(real["rows"][0]))
        self.assertEqual({row["result"] for row in real["rows"]}, {"add", "invalid"})
        invalid = fixture("import-invalid")
        self.assertFalse(invalid["can_import"])
        self.assertGreater(invalid["counts"]["invalid"], 0)
        self.assertTrue(any(row["warning"] for row in invalid["rows"]))
        self.assertTrue(fixture("import-valid")["can_import"])
        self.assertGreater(len(fixture("import-many")["rows"]), 6)


@unittest.skipUnless(shutil.which("node"), "node not installed")
class ModelTests(unittest.TestCase):
    def js(self, expression):
        script = ("const fs=require('fs');const src=fs.readFileSync(process.argv[1],'utf8').split('\\n').filter(l=>!l.startsWith('.pragma')).join('\\n');"
                  "console.log(JSON.stringify(new Function(src+'\\nreturn ('+process.argv[2]+')')()))")
        result = subprocess.run(["node", "-e", script, str(LIBRARY / "LibraryModel.js"), expression], capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_kind_tags(self):
        self.assertEqual(self.js('kindTag("scott@mouthtype.app")'), "TEXT")
        self.assertEqual(self.js('kindTag("Thanks,\\nScott")'), "2 LINES")
        self.assertEqual(self.js('kindTag("a\\r\\nb\\r\\nc")'), "3 LINES")
        self.assertEqual(self.js('kindTag("{date}")'), "DATE")
        self.assertEqual(self.js('kindTag("Report for {Date}")'), "DATE")
        self.assertEqual(self.js('kindTag("{clipboard}")'), "CLIPBOARD")
        self.assertEqual(self.js('kindTag("{date} {clipboard}")'), "CLIPBOARD")
        self.assertEqual(self.js('kindTag("{unknown}")'), "TEXT")

    def test_preview_text_is_one_line(self):
        self.assertEqual(self.js('previewText("Thanks,\\nScott")'), "Thanks, ⏎ Scott")
        self.assertEqual(self.js('previewText("{clipboard}")'), "Whatever you copied before you started talking")
        self.assertEqual(self.js('previewText("{date}", new Date(2026, 9, 21))'), "Today’s date, like October 21, 2026")
        self.assertNotIn("\n", self.js('previewText("a\\n\\nb")'))

    def test_import_rows_are_the_first_six_plus_every_invalid_row(self):
        rows = "Array.from({length:21},(_, i)=>({row:i+2,result:(i===14||i===20)?'invalid':'add'}))"
        shown = self.js("visibleImportRows(%s)" % rows)
        self.assertEqual([row["row"] for row in shown["shown"]], [2, 3, 4, 5, 6, 7, 16, 22])
        self.assertEqual(shown["hidden"], 13)
        self.assertEqual(self.js("visibleImportRows(%s).hidden" % rows.replace("21", "6")), 0)
        self.assertEqual(self.js("visibleImportRows([]).hidden"), 0)
        self.assertEqual(self.js("visibleImportRows(null).shown"), [])

    def test_summary_button_and_footnote(self):
        counts = "{add:12,existing:3,duplicate:0,invalid:1}"
        self.assertEqual(self.js("importSummary(%s).map(p=>p.count+' '+p.label)" % counts), ["12 new", "3 already saved", "1 error"])
        self.assertEqual(self.js("importSummary({add:1,existing:0,duplicate:2,invalid:2}).map(p=>p.count+' '+p.label)"),
                         ["1 new", "0 already saved", "2 duplicate", "2 errors"])
        self.assertTrue(self.js("importSummary(%s)[2].bad" % counts))
        self.assertEqual(self.js("importButtonText({add:12})"), "Import 12 spellings")
        self.assertEqual(self.js("importButtonText({add:1})"), "Import 1 spelling")
        self.assertEqual(self.js("importFootnote({problem:null,counts:%s})" % counts),
                         "Nothing changes until you import. Fix the error in the file, then choose it again.")
        self.assertEqual(self.js("importFootnote({problem:null,counts:{add:2,existing:0,duplicate:0,invalid:3}})"),
                         "Nothing changes until you import. Fix the errors in the file, then choose it again.")
        self.assertEqual(self.js("importFootnote({problem:null,counts:{add:2,existing:0,duplicate:0,invalid:0}})"), "Nothing changes until you import.")
        self.assertEqual(self.js("importBlockedReason({problem:'Bad headers',counts:{}})"), "Bad headers")
        self.assertIn("nothing to import", self.js("importBlockedReason({problem:null,counts:{add:0,existing:2,duplicate:0,invalid:0}})"))

    def test_grouping_keeps_pairs_and_marks_stars_and_warnings(self):
        entries = ('[{heard:"priya",written:"Priya",starred:true,warning:null},{heard:"win",written:"Winn",starred:false,warning:"w"},'
                   '{heard:"pre ya",written:"Priya",starred:false,warning:null}]')
        groups = self.js("groupSpellings(%s)" % entries)
        self.assertEqual([g["written"] for g in groups], ["Priya", "Winn"])
        self.assertEqual([p["heard"] for p in groups[0]["pairs"]], ["priya", "pre ya"])
        self.assertTrue(groups[0]["starred"])
        self.assertFalse(groups[1]["starred"])
        self.assertEqual(groups[1]["warnings"], ["w"])
        self.assertEqual(self.js("groupSpellings(null)"), [])

    def test_grouping_survives_object_property_names_as_written_forms(self):
        entries = ('[{heard:"a",written:"constructor"},{heard:"b",written:"__proto__"},{heard:"c",written:"toString"},'
                   '{heard:"d",written:"constructor"}]')
        groups = self.js("groupSpellings(%s).map(g=>[g.written,g.pairs.length])" % entries)
        self.assertEqual(groups, [["constructor", 2], ["__proto__", 1], ["toString", 1]])
        self.assertEqual(self.js('kindTag("{constructor} {__proto__}")'), "TEXT")

    def test_insert_at_the_cursor_or_over_a_selection(self):
        self.assertEqual(self.js('insertAt("Hi ", 3, 3, "{date}")'), {"text": "Hi {date}", "cursor": 9})
        self.assertEqual(self.js('insertAt("Hi there", 3, 8, "{clipboard}")'), {"text": "Hi {clipboard}", "cursor": 14})
        self.assertEqual(self.js('insertAt("ab", 99, 99, "X")'), {"text": "abX", "cursor": 3})

    def test_adopted_config_is_read_from_any_write_reply(self):
        self.assertTrue(self.js('adoptedConfig({"spellings-add":{adopted_config:false},"spellings-edit":{adopted_config:true}},["spellings-add","spellings-edit"])'))
        self.assertFalse(self.js('adoptedConfig({"spellings-list":{adopted_config:true}},["spellings-add"])'))
        self.assertFalse(self.js('adoptedConfig(null,["spellings-add"])'))

    def test_fresh_reply_detection(self):
        self.assertTrue(self.js("isFresh({a:1}, undefined)"))
        self.assertFalse(self.js("(function(){var r={a:1};return isFresh(r, r)})()"))
        self.assertFalse(self.js("isFresh(undefined, undefined)"))

    def test_model_status_labels(self):
        self.assertEqual(self.js("modelStatus({needs_model:false}, null).text"), "NO MODEL · INSTANT")
        self.assertEqual(self.js("modelStatus({needs_model:true}, {model:{state:'ready'}})"), {"text": "THOROUGH · READY", "ready": True})
        self.assertEqual(self.js("modelStatus({needs_model:true}, {model:{state:'absent'}}).text"), "THOROUGH · NOT PREPARED")
        self.assertEqual(self.js("modelStatus({needs_model:true}, null).text"), "THOROUGH · CHECKING")
        self.assertEqual(len(self.js("transformKinds(null)")), 5)
        self.assertEqual(self.js("transformKinds({kinds:[{id:'x'}]})"), [{"id": "x"}])
        self.assertEqual(self.js("modelReason({kinds:[{reason:null},{reason:'Missing.'}]})"), "Missing.")
        self.assertEqual(self.js("modelReason({error:'down',kinds:[]})"), "down")
        self.assertEqual(self.js("modelReason(null)"), "")

    def test_fallback_kinds_match_the_service_list(self):
        sys.path.insert(0, str(HERE.parent / "linux-desktop"))
        service = importlib.import_module("transform")
        mine = self.js("FALLBACK_KINDS.map(k=>[k.id,k.title,k.needs_model])")
        self.assertEqual(mine, [[k["id"], k["title"], k["model"]] for k in service.KINDS])


if __name__ == "__main__":
    unittest.main()
