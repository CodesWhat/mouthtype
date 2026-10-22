"""Static checks for the panel shell and its page files: the page contract, the verbs the pages call, and the repo's text rules.
Plain stdlib, no Qt needed. The rendered behaviour is checked by shell-render/tst_shell.qml on the NAS testbed."""
import importlib.util
import re
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("omarchy_control", HERE / "control.py")
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)

DATA_PAGES = ["StatsPage", "DictionaryPage", "TransformsPage", "StylePage"]
SETTINGS_TABS = ["General", "Linux", "Health", "Advanced"]
SIDEBAR = ["Home", "Stats", "Dictionary", "Transforms", "Style", "Appearance", "Settings"]


def sources():
    files = sorted((HERE / "pages").glob("*.qml")) + sorted((HERE / "parts").glob("*.qml")) + sorted(HERE.glob("Mouthtype*.qml"))
    return files + [HERE / "Panel.qml", HERE / "AppState.qml"]


def pages_files():
    return sorted((HERE / "pages").glob("*.qml")) + sorted(HERE.glob("Mouthtype*.qml")) + [HERE / "Panel.qml", HERE / "AppState.qml"]


class PageContractTests(unittest.TestCase):
    def test_data_pages_follow_the_contract(self):
        for name in DATA_PAGES:
            text = (HERE / "pages" / (name + ".qml")).read_text()
            self.assertRegex(text, r"property var backend\b", name)
            self.assertRegex(text, r"property bool active\b", name)
            self.assertRegex(text, r"signal request\(string command, var args\)", name)

    def test_shell_loads_every_page_file_it_names(self):
        shell = (HERE / "MouthtypeShell.qml").read_text()
        block = re.search(r"pageFiles: \(\{(.*?)\}\)", shell, re.S).group(1)
        names = re.findall(r'"([A-Za-z]+Page)"', block)
        self.assertGreaterEqual(len(names), 8)
        for name in names:
            self.assertTrue((HERE / "pages" / (name + ".qml")).is_file(), name)
        for name in DATA_PAGES:
            self.assertIn(name, names)

    def test_settings_tabs_have_files(self):
        for tab in SETTINGS_TABS:
            self.assertTrue((HERE / "pages" / ("Settings" + tab + ".qml")).is_file(), tab)

    def test_sidebar_order(self):
        sidebar = (HERE / "MouthtypeSidebar.qml").read_text()
        titles = re.findall(r'title: "([A-Za-z]+)"', sidebar)
        self.assertEqual(titles, SIDEBAR)

    def test_shell_documents_the_contract(self):
        shell = (HERE / "MouthtypeShell.qml").read_text()
        for needle in ("PAGE CONTRACT", "backend.results", "request(string command, var args)"):
            self.assertIn(needle, shell)


class VerbTests(unittest.TestCase):
    def test_every_verb_a_page_calls_exists_in_control(self):
        called = {}
        for path in pages_files():
            for verb in re.findall(r'\.run\(\["([a-z][a-z0-9-]*)"', path.read_text()):
                called.setdefault(verb, path.name)
        self.assertIn("set-config", called)
        for verb, where in called.items():
            if verb == "close":
                continue
            self.assertIn(verb, control.VALID_ACTIONS, "%s calls unknown verb %s" % (where, verb))

    def test_panel_keeps_its_ipc_surface(self):
        panel = (HERE / "Panel.qml").read_text()
        for name in ("open", "close", "toggle", "refresh", "openPage", "startCapture"):
            self.assertRegex(panel, r"function %s\(" % name)


class TextRuleTests(unittest.TestCase):
    def test_no_stale_version_strings(self):
        for path in sources():
            self.assertNotIn("alpha.8", path.read_text(), path.name)

    def test_about_reads_both_versions(self):
        health = (HERE / "pages" / "SettingsHealth.qml").read_text()
        self.assertIn("versions.app", health)
        self.assertIn("versions.plugin", health)

    def test_no_elide_and_no_small_text(self):
        for path in sources():
            text = path.read_text()
            self.assertNotRegex(text, r"elide:\s*Text\.Elide(?!None)", path.name)
            for size in re.findall(r"pixelSize:\s*(\d+(?:\.\d+)?)\s*$", text, re.M):
                self.assertGreaterEqual(float(size), 10, path.name)

    def test_no_restricted_word_in_new_names(self):
        for path in HERE.rglob("*"):
            self.assertNotIn("token", path.name.lower(), str(path))


if __name__ == "__main__":
    unittest.main()
