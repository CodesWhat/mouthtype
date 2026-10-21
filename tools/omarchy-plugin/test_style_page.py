"""Static and logic checks for the Style page (slice V6): the generated fixtures match the backend, the pure helpers in
pages/style/StyleLogic.js behave (run under node when it is installed), and the page keeps the repo's text rules.
The rendered behaviour is checked by shell-render/tst_shell.qml on the NAS testbed."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parent
STYLE = HERE / "pages" / "style"
sys.path.insert(0, str(STYLE / "fixtures"))
import gen_fixtures  # noqa: E402

NODE = shutil.which("node")


def node(script):
    result = subprocess.run([NODE, "-e", script], capture_output=True, text=True, timeout=30, cwd=str(STYLE))
    if result.returncode != 0:
        raise AssertionError(result.stderr)
    return json.loads(result.stdout)


LOAD = "const fs=require('fs');const L={};new Function('exports',fs.readFileSync('StyleLogic.js','utf8').replace('.pragma library',''));"
HARNESS = ("const src=require('fs').readFileSync('StyleLogic.js','utf8').replace('.pragma library','');"
           "const L=new Function(src+';return {addedMask,segments,ranges,markup,plain,ruleFor,ownRules,ruleRequests,classProblem,"
           "toneIndex,levelIndex,toneChoices,levelChoices,sameAs,followText,followCount,levelStatus,TONE_IDS,LEVEL_IDS};')();")


class FixtureTests(unittest.TestCase):
    def test_generated_fixtures_are_current(self):
        self.assertEqual((STYLE / "fixtures" / "StyleFixtures.js").read_text(encoding="utf-8"), gen_fixtures.render())

    def test_populated_fixture_covers_the_cases(self):
        fixtures = gen_fixtures.fixtures()
        populated = {c["id"]: c for c in fixtures["populated"]["contexts"]}
        self.assertEqual(list(populated), ["personal", "work", "email", "other"])
        self.assertIsNone(populated["email"]["tone"])
        self.assertEqual(populated["email"]["suggested_tone"], "formal")
        self.assertTrue(any(not m["built_in"] for m in populated["personal"]["members"]))
        self.assertTrue(any(m["built_in"] for m in populated["personal"]["members"]))
        self.assertEqual(populated["work"]["cleanup"], "thorough")
        self.assertEqual(fixtures["fresh"]["websites"], "unsupported")
        self.assertEqual(len(populated["email"]["samples"][0]["lines"]), 4)


@unittest.skipUnless(NODE, "node is not installed")
class LogicTests(unittest.TestCase):
    def run_js(self, expression):
        return node(HARNESS + "process.stdout.write(JSON.stringify(" + expression + "));")

    def test_added_characters_are_the_ones_the_tone_made(self):
        segs = self.run_js("L.segments('hey are we on', 'Hey, are we on?')")
        self.assertEqual("".join(s["text"] for s in segs), "Hey, are we on?")
        added = "".join(s["text"] for s in segs if s["added"])
        self.assertEqual(added, "H,?")
        self.assertEqual(self.run_js("L.ranges(L.segments('hey are we on', 'Hey, are we on?'))"),
                         [{"start": 0, "end": 1}, {"start": 3, "end": 4}, {"start": 14, "end": 15}])

    def test_removed_text_adds_nothing(self):
        segs = self.run_js("L.segments('see you friday.', 'see you friday')")
        self.assertFalse(any(s["added"] for s in segs))

    def test_same_text_has_no_marks_and_empty_is_safe(self):
        self.assertEqual(self.run_js("L.ranges(L.segments('abc', 'abc'))"), [])
        self.assertEqual(self.run_js("L.segments('', '')"), [])
        self.assertEqual(self.run_js("L.ranges(L.segments('', 'ab'))"), [{"start": 0, "end": 2}])

    def test_markup_escapes_and_keeps_text(self):
        html = self.run_js("L.markup(L.segments('a<b', 'A<b&'), '#aabbcc', '#000000')")
        self.assertIn("&lt;", html)
        self.assertIn("&amp;", html)
        self.assertIn("background-color:#aabbcc", html)
        self.assertNotIn("<b", html)

    def test_real_samples_highlight_something_for_every_tone(self):
        for context in gen_fixtures.fixtures()["populated"]["contexts"]:
            added = 0
            for sample in context["samples"]:
                for line in sample["lines"]:
                    segs = self.run_js("L.segments(%s, %s)" % (json.dumps(line["spoken"]), json.dumps(line["styled"])))
                    self.assertEqual("".join(s["text"] for s in segs), line["styled"])
                    added += sum(len(s["text"]) for s in segs if s["added"])
            self.assertGreater(added, 0, context["id"])

    def test_rule_requests_cover_each_window_class_once(self):
        member = {"id": "slack", "name": "Slack", "apps": ["Slack", "slack", "com.slack.Slack"]}
        requests = self.run_js("L.ruleRequests(%s, null, 'tone', 'casual')" % json.dumps(member))
        self.assertEqual(requests, [["style-rule", ["Slack", "casual", "none", "Slack"]],
                                    ["style-rule", ["com.slack.Slack", "casual", "none", "Slack"]]])

    def test_rule_requests_keep_the_other_field(self):
        member = {"id": "a:x", "name": "X", "apps": ["x"]}
        rule = {"app": "x", "tone": "formal", "cleanup": "fast"}
        self.assertEqual(self.run_js("L.ruleRequests(%s, %s, 'cleanup', null)" % (json.dumps(member), json.dumps(rule))),
                         [["style-rule", ["x", "formal", "none", "X"]]])
        rule["tone"] = None
        self.assertEqual(self.run_js("L.ruleRequests(%s, %s, 'cleanup', null)" % (json.dumps(member), json.dumps(rule))),
                         [["style-rule", ["x", "none", "none", "X"]]])

    def test_rule_lookup_ignores_case(self):
        rules = [{"app": "SLACK", "tone": "casual", "cleanup": None}]
        self.assertEqual(self.run_js("L.ruleFor(%s, ['slack'])" % json.dumps(rules))["tone"], "casual")
        self.assertIsNone(self.run_js("L.ruleFor(%s, ['foot'])" % json.dumps(rules)))

    def test_own_rules_are_the_ones_no_list_holds(self):
        state = gen_fixtures.fixtures()["populated"]
        own = self.run_js("L.ownRules(%s)" % json.dumps(state))
        self.assertEqual([r["app"] for r in own], ["foot"])

    def test_class_problems(self):
        for text, bad in (("org.telegram.desktop", False), ("", True), ("  ", True), (" a", True), ("a*", True),
                          ("a\tb", True), ("x" * 129, True), ("x" * 128, False)):
            problem = self.run_js("L.classProblem(%s)" % json.dumps(text))
            self.assertEqual(problem != "", bad, repr(text))

    def test_class_problems_match_the_backend(self):
        sys.path.insert(0, str(gen_fixtures.DESKTOP))
        import styles
        for text in ("org.telegram.desktop", "", " a", "a*", "a\tb", "x" * 129, "x" * 128):
            try:
                styles._check_class(text, "App")
                backend_bad = False
            except ValueError:
                backend_bad = True
            self.assertEqual(self.run_js("L.classProblem(%s)" % json.dumps(text)) != "", backend_bad, repr(text))

    def test_popup_choices_line_up_with_ids(self):
        self.assertEqual(self.run_js("L.TONE_IDS"), [None, "formal", "casual", "very_casual"])
        self.assertEqual(self.run_js("L.LEVEL_IDS"), [None, "off", "basic", "fast", "thorough"])
        tones = gen_fixtures.fixtures()["fresh"]["tones"]
        self.assertEqual(self.run_js("L.toneChoices('Same as work', %s)" % json.dumps(tones)),
                         ["Same as work", "Formal", "Casual", "Very casual"])
        self.assertEqual(self.run_js("L.levelChoices('Same as everywhere · Fast')"),
                         ["Same as everywhere · Fast", "Off", "Basic", "Fast", "Thorough"])
        self.assertEqual(self.run_js("L.sameAs('personal', 'Casual')"), "Same as personal · Casual")
        self.assertEqual(self.run_js("L.sameAs('personal', '')"), "Same as personal")
        self.assertEqual(self.run_js("[L.toneIndex('casual'), L.toneIndex(null), L.levelIndex('thorough'), L.levelIndex(undefined)]"),
                         [2, 0, 4, 0])

    def test_cleanup_summary(self):
        contexts = gen_fixtures.fixtures()["populated"]["contexts"]
        self.assertEqual(self.run_js("L.followText(%s, 'fast')" % json.dumps(contexts)),
                         "Personal messages and Email use Fast, the level above.")
        self.assertEqual(self.run_js("L.followCount(%s)" % json.dumps(contexts)), 2)
        none = [{"title": "A", "cleanup": "off"}]
        self.assertEqual(self.run_js("L.followText(%s, 'fast')" % json.dumps(none)), "Every context sets its own level.")

    def test_level_status(self):
        models = {"fast": "prepared", "thorough": "absent"}
        service = {"level": "fast", "model": {"state": "ready"}}
        self.assertEqual(self.run_js("L.levelStatus('basic', {}, null, null)"), "NO MODEL · INSTANT")
        self.assertEqual(self.run_js("L.levelStatus('fast', %s, %s, null)" % (json.dumps(models), json.dumps(service))), "READY")
        self.assertEqual(self.run_js("L.levelStatus('thorough', %s, null, null)" % json.dumps(models)), "NOT PREPARED")
        setup = {"state": "downloading", "level": "thorough"}
        self.assertEqual(self.run_js("L.levelStatus('thorough', %s, null, %s)" % (json.dumps(models), json.dumps(setup))), "PREPARING")


class PageTests(unittest.TestCase):
    def sources(self):
        return [HERE / "pages" / "StylePage.qml"] + sorted(STYLE.glob("*.qml"))

    def test_page_keeps_the_contract(self):
        text = (HERE / "pages" / "StylePage.qml").read_text()
        self.assertRegex(text, r"property var backend\b")
        self.assertRegex(text, r"property bool active\b")
        self.assertRegex(text, r"signal request\(string command, var args\)")

    def test_page_only_requests_verbs_that_exist(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("omarchy_control", HERE / "control.py")
        control = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(control)
        commands = control.module_commands() if hasattr(control, "module_commands") else {}
        used = set()
        for path in self.sources() + [STYLE / "StyleLogic.js"]:
            used |= set(re.findall(r'"((?:style-[a-z-]+)|set-config|cleanup-setup)"', path.read_text()))
        self.assertIn("style-set-tone", used)
        for verb in used:
            self.assertTrue(verb in control.VALID_ACTIONS or verb in commands, verb)

    def test_edit_verbs_the_page_sends_are_watched(self):
        page = (HERE / "pages" / "StylePage.qml").read_text()
        watched = re.search(r"watched: \[(.*?)\]", page, re.S).group(1)
        for verb in ("style-set-tone", "style-set-default-tone", "style-set-cleanup", "style-add-app", "style-remove-app",
                     "style-rule", "style-state", "set-config", "cleanup-setup"):
            self.assertIn('"' + verb + '"', watched)

    def test_no_website_rows_or_globes(self):
        for path in self.sources():
            lowered = path.read_text().lower()
            self.assertNotIn("globe", lowered, path.name)
            self.assertNotIn("add a website", lowered, path.name)
            self.assertNotIn("domain", lowered, path.name)

    def test_no_elide_no_small_text_no_em_dash(self):
        for path in self.sources():
            text = path.read_text()
            self.assertNotRegex(text, r"elide:\s*Text\.Elide(?!None)", path.name)
            self.assertNotIn("—", text, path.name)
            for size in re.findall(r"pixelSize:\s*(\d+(?:\.\d+)?)\s*$", text, re.M):
                self.assertGreaterEqual(float(size), 10, path.name)

    def test_health_no_longer_chooses_the_level(self):
        health = (HERE / "pages" / "SettingsHealth.qml").read_text()
        self.assertNotIn('"set-config", "cleanup"', health)
        self.assertIn('openPage("style")', health)
        self.assertIn("cleanup-setup", health)

    def test_lime_is_confined_to_the_selection_check_and_primary_button(self):
        uses = {}
        for path in self.sources():
            count = path.read_text().count("Theme.accent")
            if count:
                uses[path.name] = count
        self.assertEqual(sorted(uses), ["LevelCard.qml", "ToneCard.qml"])

    def test_no_restricted_word_in_new_names(self):
        for path in STYLE.rglob("*"):
            self.assertNotIn("token", path.name.lower(), str(path))


if __name__ == "__main__":
    unittest.main()
