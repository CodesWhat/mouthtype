import unittest

import atspi_target


class Role:
    FRAME, TERMINAL, PASSWORD_TEXT, TEXT = 'frame', 'terminal', 'password', 'text'


class StateType:
    ACTIVE, FOCUSED, SHOWING = 'active', 'focused', 'showing'


class FakeAtspi:
    Role = Role
    StateType = StateType

    def __init__(self, apps, fail=False):
        self.apps, self.fail, self.inited = apps, fail, False

    def init(self):
        self.inited = True

    def get_desktop(self, index):
        if self.fail:
            raise RuntimeError('bus gone')
        return Node(children=self.apps)


class Node:
    def __init__(self, name=None, role=Role.FRAME, states=(StateType.SHOWING,), children=(), pid=0):
        self.name, self.role, self.states, self.children, self.pid = name, role, set(states), list(children), pid

    def get_name(self):
        return self.name

    def get_role(self):
        return self.role

    def get_process_id(self):
        return self.pid

    def get_state_set(self):
        states = self.states

        class Set:
            def contains(self, state):
                return state in states
        return Set()

    def get_child_count(self):
        return len(self.children)

    def get_child_at_index(self, index):
        return self.children[index]


def app(name, window_active, widget, pid=42):
    window = Node(states=(StateType.SHOWING, StateType.ACTIVE) if window_active else (StateType.SHOWING,),
                  children=[Node(children=[widget])])
    return Node(name=name, children=[window], pid=pid)


def focused(role):
    return Node(role=role, states=(StateType.SHOWING, StateType.FOCUSED))


class AtspiTargetTests(unittest.TestCase):
    def targets(self, apps, **kw):
        return atspi_target.AtspiTargets(FakeAtspi(apps), **kw)

    def test_reports_the_focused_app(self):
        t = self.targets([app('other', False, focused(Role.TEXT)), app('app.mouthtype.Acceptance', True, focused(Role.TEXT))])
        self.assertEqual(t.snapshot(), {'class': 'app.mouthtype.Acceptance', 'pid': 42, 'secure': False, 'terminal': False})

    def test_terminal_role_marks_a_terminal(self):
        t = self.targets([app('konsole', True, focused(Role.TERMINAL))])
        target = t.snapshot()
        self.assertTrue(t.is_terminal(target))
        self.assertFalse(t.is_terminal({'class': 'x'}))

    def test_password_field_is_secure(self):
        t = self.targets([app('gtk', True, focused(Role.PASSWORD_TEXT))])
        self.assertIs(t.snapshot()['secure'], True)

    def test_no_active_window_or_no_focus_is_unknown(self):
        self.assertEqual(self.targets([app('a', False, focused(Role.TEXT))]).snapshot(), {'class': 'unknown'})
        self.assertEqual(self.targets([app('a', True, Node(role=Role.TEXT))]).snapshot(), {'class': 'unknown'})
        self.assertEqual(self.targets([]).snapshot(), {'class': 'unknown'})

    def test_unnamed_app_is_unknown(self):
        self.assertEqual(self.targets([app('', True, focused(Role.TEXT))]).snapshot(), {'class': 'unknown'})

    def test_missing_pid_is_omitted(self):
        self.assertNotIn('pid', self.targets([app('a', True, focused(Role.TEXT), pid=0)]).snapshot())

    def test_hidden_subtrees_are_skipped(self):
        hidden = Node(states=(), children=[focused(Role.TEXT)])
        window = Node(states=(StateType.ACTIVE, StateType.SHOWING), children=[hidden])
        self.assertEqual(self.targets([Node(name='a', children=[window])]).snapshot(), {'class': 'unknown'})

    def test_search_is_bounded(self):
        t = self.targets([app('a', True, focused(Role.TEXT))], max_nodes=2)
        self.assertEqual(t.snapshot(), {'class': 'unknown'})
        t = self.targets([app('a', True, focused(Role.TEXT))], max_depth=1)
        self.assertEqual(t.snapshot(), {'class': 'unknown'})

    def test_bus_errors_are_unknown(self):
        t = atspi_target.AtspiTargets(FakeAtspi([], fail=True))
        self.assertEqual(t.snapshot(), {'class': 'unknown'})

    def test_missing_gi_is_unknown_and_lazy(self):
        calls = []
        t = atspi_target.AtspiTargets(loader=lambda: calls.append(1))
        self.assertEqual(calls, [])
        self.assertFalse(t.available())
        self.assertEqual(t.snapshot(), {'class': 'unknown'})
        self.assertEqual(calls, [1])
        self.assertFalse(t.is_terminal({'class': 'unknown'}))

    def test_loader_result_is_initialised_once(self):
        fake = FakeAtspi([])
        t = atspi_target.AtspiTargets(loader=lambda: fake)
        t.snapshot()
        t.snapshot()
        self.assertTrue(fake.inited)


if __name__ == '__main__':
    unittest.main()
