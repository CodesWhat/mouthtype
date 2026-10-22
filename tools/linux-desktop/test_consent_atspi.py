import types
import unittest

import consent_atspi


class Action:
    def __init__(self, node):
        self.node = node

    def get_n_actions(self):
        return 1

    def do_action(self, index):
        self.node.pressed += 1
        if self.node.role in consent_atspi.SWITCH_ROLES:
            self.node.checked = True


class Node:
    def __init__(self, role, name, children=(), checked=False):
        self.role, self.name, self.children, self.checked, self.pressed = role, name, list(children), checked, 0

    def get_role_name(self):
        return self.role

    def get_name(self):
        return self.name

    def get_child_count(self):
        return len(self.children)

    def get_child_at_index(self, index):
        return self.children[index]

    def get_action_iface(self):
        return Action(self)

    def get_state_set(self):
        return types.SimpleNamespace(contains=lambda state: self.checked)


def atspi_with(*apps):
    desktop = Node('desktop', '', apps)
    return types.SimpleNamespace(get_desktop=lambda index: desktop, StateType=types.SimpleNamespace(CHECKED='checked'))


def shortcuts_dialog(extra=()):
    window = Node('frame', 'Add Keyboard Shortcuts', [Node('button', 'Reset Shortcut'), Node('button', 'Cancel'),
                                                      Node('button', 'Add'), *extra])
    return Node('application', 'gnome-control-center-global-shortcuts-provider', [window]), window


class ConsentTests(unittest.TestCase):
    def test_answer_presses_the_affirmative_button_only(self):
        app, window = shortcuts_dialog()
        result = consent_atspi.answer(window, atspi_with(app))
        self.assertEqual(result['pressed'], 'Add')
        self.assertEqual(result['buttons'], ['Add', 'Cancel', 'Reset Shortcut'])
        self.assertEqual([node.pressed for node in window.children], [0, 0, 1])

    def test_answer_switches_on_unchecked_toggles(self):
        on, off = Node('switch', 'Allow Clipboard Access', checked=True), Node('switch', 'Allow Keyboard')
        app, window = shortcuts_dialog([on, off])
        result = consent_atspi.answer(window, atspi_with(app))
        self.assertEqual(result['switched_on'], ['Allow Keyboard'])
        self.assertEqual((on.pressed, off.pressed), (0, 1))

    def test_dialog_without_an_affirmative_button_is_an_error(self):
        window = Node('frame', 'Other', [Node('button', 'Cancel')])
        with self.assertRaises(ValueError):
            consent_atspi.answer(window, atspi_with())

    def test_find_dialog_ignores_other_applications(self):
        app, window = shortcuts_dialog()
        other = Node('application', 'gedit', [Node('frame', 'Save', [Node('button', 'Add')])])
        self.assertIs(consent_atspi.find_dialog(atspi_with(other, app)), window)
        self.assertIsNone(consent_atspi.find_dialog(atspi_with(other)))

    def test_answerer_records_what_it_saw_and_answered(self):
        app, window = shortcuts_dialog()
        answerer = consent_atspi.ConsentAnswerer(atspi_with(app), timeout=2, interval=.01)
        answerer.start()
        for _ in range(200):
            if answerer.answers:
                break
            answerer._stop_event.wait(.01)
        answerer.stop()
        self.assertEqual(answerer.evidence()['answers'][0]['pressed'], 'Add')
        self.assertIsNone(answerer.error)
        self.assertEqual(answerer.dialogs[0][0][1], 'Add Keyboard Shortcuts')


if __name__ == '__main__':
    unittest.main()
