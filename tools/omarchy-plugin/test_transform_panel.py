import importlib.util
import json
from pathlib import Path
import re
import sys
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "linux-desktop"))
import transform  # noqa: E402  the backend the fixtures were generated from

spec = importlib.util.spec_from_file_location("omarchy_control_transform_panel", HERE / "control_transform.py")
control_transform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control_transform)

PANEL = HERE / "transform"
FIXTURES = sorted((PANEL / "fixtures").glob("*.json"))
MODEL = (PANEL / "TransformModel.js").read_text(encoding="utf-8")
WINDOW = (HERE / "TransformWindow.qml").read_text(encoding="utf-8")
QML = {path.name: path.read_text(encoding="utf-8") for path in [*PANEL.glob("*.qml"), HERE / "TransformWindow.qml"]}


class FixtureContractTests(unittest.TestCase):
    def test_scenes_exist_for_every_render(self):
        self.assertEqual({path.stem for path in FIXTURES}, {
            "normal", "ai-ready", "ai-busy", "refused", "model-missing", "over-cap", "accepted", "capture-error"})

    def test_diffs_are_what_the_backend_produces(self):
        checked = 0
        for path in FIXTURES:
            for step in json.loads(path.read_text(encoding="utf-8"))["steps"]:
                reply = step.get("reply", {})
                if reply.get("state") == "ready":
                    self.assertEqual(reply["diff"], transform.diff_segments(reply["original"], reply["text"]), path.name)
                    self.assertEqual(reply["changed"], reply["text"] != reply["original"], path.name)
                    checked += 1
        self.assertGreaterEqual(checked, 6)

    def test_over_cap_scene_is_over_the_backend_cap(self):
        steps = json.loads((PANEL / "fixtures" / "over-cap.json").read_text(encoding="utf-8"))["steps"]
        run = next(step["reply"] for step in steps if step["op"] == "run")
        self.assertGreater(len(run["original"]), transform.DIFF_LIMIT)
        self.assertIs(run["diff"]["highlight"], False)
        self.assertEqual(run["diff"]["reason"], "over_limit")
        self.assertIn("DIFF_LIMIT = %d" % transform.DIFF_LIMIT, MODEL)

    def test_model_constants_match_the_backend(self):
        self.assertEqual([kind["id"] for kind in transform.KINDS], re.findall(r'\{ id: "([a-z-]+)", title', MODEL))
        for kind in transform.KINDS:
            self.assertIn('{ id: "%s", title: "%s", model: %s }' % (kind["id"], kind["title"], str(kind["model"]).lower()), MODEL)
        self.assertEqual(set(transform.KIND_IDS), set(control_transform.KINDS))

    def test_captures_carry_the_window_address_the_focus_verb_needs(self):
        for path in FIXTURES:
            for step in json.loads(path.read_text(encoding="utf-8"))["steps"]:
                if step["op"] == "capture" and step["reply"].get("state") == "captured":
                    app = step["reply"]["app"]
                    self.assertRegex(app["address"], control_transform.ADDRESS_PATTERN.pattern)
        self.assertEqual(transform.app_summary({"class": "Slack", "pid": 1, "address": "0xab"}),
                         {"class": "Slack", "name": "Slack", "pid": 1, "address": "0xab"})


class SourceContractTests(unittest.TestCase):
    def test_every_model_function_the_qml_calls_exists(self):
        defined = set(re.findall(r"^function (\w+)\(", MODEL, re.M))
        for name, source in QML.items():
            for called in re.findall(r"\bModel\.(\w+)\(", source):
                self.assertIn(called, defined, "%s calls Model.%s" % (name, called))

    def test_window_only_calls_verbs_control_py_loads(self):
        verbs = set(re.findall(r'"(transform-[a-z-]+)"', WINDOW))
        self.assertEqual(verbs, {"transform-status", "transform-run", "transform-accept", "transform-copy",
                                 "transform-cancel", "transform-focus"})
        self.assertLessEqual(verbs, set(control_transform.COMMANDS))
        self.assertIn("transform-open", control_transform.COMMANDS)

    def test_window_reads_the_file_transform_open_writes(self):
        self.assertIn("/mouthtype/" + control_transform.PANEL_REQUEST, WINDOW)
        self.assertEqual(control_transform.RUNTIME.name, "mouthtype")

    def test_window_meets_the_service_loader_contract(self):
        self.assertRegex(WINDOW, r"property var shell: null")
        service = (HERE / "Service.qml").read_text(encoding="utf-8")
        self.assertIn('/TransformWindow.qml', service)

    def test_window_is_a_non_focus_taking_overlay_that_refocuses_before_accept(self):
        self.assertIn("WlrKeyboardFocus.OnDemand", WINDOW)
        self.assertIn("WlrLayer.Overlay", WINDOW)
        accept = WINDOW[WINDOW.index("function accept()"):WINDOW.index("function copy(")]
        self.assertIn('runAction([helper, "transform-focus", address], function() { runAction(command, finish) })', accept)

    def test_no_ellipsis_truncation_and_no_hard_coded_colors(self):
        for name, source in QML.items():
            self.assertNotIn("elide:", source, name)
            if name != "TransformWindow.qml":
                self.assertIsNone(re.search(r'"#[0-9A-Fa-f]{3,8}"', source), name + " hard-codes a color")

    def test_the_panel_has_no_restricted_names(self):
        names = [path.name for path in [*PANEL.rglob("*"), *HERE.glob("transform-render/*")]]
        self.assertFalse([name for name in names if "token" in name.lower()])


if __name__ == "__main__":
    unittest.main()
