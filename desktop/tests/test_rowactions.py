"""Exercise key dispatch, including the calendar's smaller action interface."""

import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import gi

gi.require_version("Gdk", "4.0")
from dustpan.rowactions import ALT, CALENDAR_KEYS, CALENDAR_MOVES, NONE, SHIFT, Gdk, RowActions


class CalendarKeysTest(unittest.TestCase):
    def setUp(self):
        # As on CalendarWindow, there is deliberately no pick_labels method.
        self.window = SimpleNamespace(**{name: Mock() for name in (
            "edit", "complete", "reopen", "delete_task", "leaving", "step", "move", "moves")})
        self.actions = RowActions(self.window, CALENDAR_KEYS, CALENDAR_MOVES, labels=False)
        self.row = Mock()
        self.row.get_height.return_value = 24
        self.pending = []
        idle = patch("dustpan.rowactions.GLib.idle_add", side_effect=self.pending.append)
        idle.start()
        self.addCleanup(idle.stop)

    def test_edit_complete_reopen_and_delete_without_a_label_picker(self):
        for key, done, method in ((Gdk.KEY_Return, False, "edit"), (Gdk.KEY_KP_Enter, False, "edit"),
                                  (Gdk.KEY_c, False, "complete"), (Gdk.KEY_c, True, "reopen"),
                                  (Gdk.KEY_Delete, False, "delete_task"),
                                  (Gdk.KEY_BackSpace, True, "delete_task")):
            with self.subTest(key=key, done=done):
                handler = getattr(self.window, method)
                handler.reset_mock()
                self.window.leaving.reset_mock()
                self.assertTrue(self.actions.key(self.row, "task", done, key, NONE))
                handler.assert_not_called()  # wait until the key signal has finished
                self.assertEqual(len(self.pending), 1)
                self.pending.pop()()
                handler.assert_called_once_with("task")
                if method in ("complete", "delete_task"):
                    self.window.leaving.assert_called_once_with("task")
                else:
                    self.window.leaving.assert_not_called()

    def test_grid_shortcuts_dispatch_and_completed_tasks_cannot_move(self):
        for key, mods, move in ((Gdk.KEY_Up, NONE, "earlier"), (Gdk.KEY_Down, NONE, "later"),
                                (Gdk.KEY_Left, NONE, "day-before"), (Gdk.KEY_Right, NONE, "day-after"),
                                (Gdk.KEY_Up, SHIFT, "shorter"), (Gdk.KEY_Down, SHIFT, "longer"),
                                (Gdk.KEY_Up, ALT | SHIFT, "start-earlier"),
                                (Gdk.KEY_Down, ALT | SHIFT, "start-later"),
                                (Gdk.KEY_u, NONE, "unschedule")):
            with self.subTest(move=move):
                self.window.move.reset_mock()
                self.assertTrue(self.actions.key(self.row, "task", False, key, mods))
                self.assertEqual(len(self.pending), 1)
                self.pending.pop()()
                self.window.move.assert_called_once_with("task", move)
                self.assertFalse(self.actions.key(self.row, "task", True, key, mods))
                self.assertEqual(self.pending, [])

    def test_selection_menu_and_escape_shortcuts(self):
        for key, step in ((Gdk.KEY_j, 1), (Gdk.KEY_k, -1)):
            self.window.step.reset_mock()
            self.assertTrue(self.actions.key(self.row, "task", False, key, NONE))
            self.window.step.assert_called_once_with("task", step)
        with patch.object(self.actions, "menu") as menu:
            for key, mods in ((Gdk.KEY_period, NONE), (Gdk.KEY_Menu, NONE), (Gdk.KEY_F10, SHIFT)):
                menu.reset_mock()
                self.assertTrue(self.actions.key(self.row, "task", False, key, mods))
                menu.assert_called_once_with(self.row, "task", False, 12, self.row.get_height() / 2)
        self.assertTrue(self.actions.key(self.row, "task", False, Gdk.KEY_Escape, NONE))
        self.row.get_root().set_focus.assert_called_once_with(None)

    def test_main_list_label_action_still_dispatches(self):
        self.window.pick_labels = Mock()
        actions = RowActions(self.window)
        self.assertTrue(actions.key(self.row, "task", False, Gdk.KEY_l, NONE))
        self.pending.pop()()
        self.window.pick_labels.assert_called_once_with("task")
