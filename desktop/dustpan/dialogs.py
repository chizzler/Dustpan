"""The task, view, project, label and settings dialogs."""

import re
import threading
from datetime import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GLib, Gtk  # noqa: E402

from . import config  # noqa: E402
from .api import Api, ApiError, Offline  # noqa: E402
from .dates import day_start_minutes, format_time, uses_12h  # noqa: E402
from .filters import FilterError  # noqa: E402
from .labelpicker import NEW_LABEL_COLOUR, LabelPicker  # noqa: E402
from .model import CLEARED_SUBTASKS, completed_subtask_visible  # noqa: E402
from .querybar import QueryBar  # noqa: E402
from .noteview import NotesEditor  # noqa: E402
from .quickadd.attributes import match_duration  # noqa: E402
from .recurrence import RuleError, parse, preview_occurrences  # noqa: E402
from .reminders import (DEADLINE_PRESETS, DEFAULT_DATED_PRESETS, DEFAULT_TIMED_PRESETS, RELATIVE_PRESETS,
                        describe, offset_label, parse_custom_offset, read_defaults)  # noqa: E402
from .sync import UnsupportedAccount, adopt_standalone, migrate_account, reset_for_account, verify_account  # noqa: E402
from .views import run_query, view_options  # noqa: E402
from .widgets import Dot, broom_button, escape, label_chip  # noqa: E402
from .writes import (DAY_STARTS, LABEL_COLOURS, LOCAL_USER, PROJECT_COLOURS, CannotEdit, live,
                     project_descendants)  # noqa: E402

PRIORITIES = ["Priority 1", "Priority 2", "Priority 3", "No priority"]


def parse_time(text):
    """"9:30" or "09:30" to "09:30". Empty means all day. Anything else is CannotEdit."""
    text = text.strip()
    if not text:
        return None
    match = re.fullmatch(r"(\d{1,2}):(\d{2})", text)
    if not match or int(match[1]) > 23 or int(match[2]) > 59:
        raise CannotEdit("Write the time as HH:MM, like 09:30")
    return f"{int(match[1]):02d}:{match[2]}"


def parse_estimate(text):
    """ "30m", "1h30", "2h" or a number of minutes. Empty means none. Anything else is CannotEdit."""
    text = text.replace(" ", "")
    if not text:
        return None
    minutes = match_duration("+" + text.removeprefix("+"), False)
    if not minutes:
        raise CannotEdit("Write the estimate like 30m or 1h30, up to a week")
    return minutes


def estimate_text(minutes):
    if not minutes:
        return ""
    hours, rest = divmod(minutes, 60)
    return f"{rest}m" if not hours else f"{hours}h{rest:02d}" if rest else f"{hours}h"


def date_row(title, value, on_change):
    """An expander with an on/off switch and a calendar, for a YYYY-MM-DD value."""
    row = Adw.ExpanderRow(title=title, show_enable_switch=True, enable_expansion=bool(value), expanded=bool(value))
    calendar = Gtk.Calendar(margin_top=6, margin_bottom=6, margin_start=6, margin_end=6)
    if value:
        y, m, d = (int(part) for part in value.split("-"))
        calendar.select_day(GLib.DateTime.new_local(y, m, d, 0, 0, 0))
    row.add_row(Gtk.ListBoxRow(child=calendar, activatable=False, selectable=False))
    calendar.connect("day-selected", lambda _c: on_change())
    row.connect("notify::enable-expansion", lambda *_a: on_change())
    return row, calendar


def read_date(row, calendar):
    if not row.get_enable_expansion():
        return None
    day = calendar.get_date()
    return f"{day.get_year():04d}-{day.get_month():02d}-{day.get_day_of_month():02d}"


def danger_group(label, action):
    """A full red button with a bin icon, set apart at the foot of a dialog."""
    button = Gtk.Button(child=Adw.ButtonContent(icon_name="user-trash-symbolic", label=label),
                        halign=Gtk.Align.CENTER, css_classes=["destructive-action", "pill", "danger-button"])
    button.connect("clicked", lambda _b: action())
    group = Adw.PreferencesGroup()
    group.add(button)
    return group


class TaskDialog(Adw.Dialog):
    """Edit one task. Saving writes only the fields that changed, as one batch."""

    def __init__(self, window, task):
        super().__init__(title="Edit task", content_width=460)
        self.window = window
        self.task = task
        self.due = task.get("due")

        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda _b: self.close())
        save = Gtk.Button(label="Save", css_classes=["suggested-action"])
        save.connect("clicked", lambda _b: self.save())
        header = Adw.HeaderBar(show_start_title_buttons=False, show_end_title_buttons=False)
        header.pack_start(cancel)
        header.pack_end(save)

        page = Adw.PreferencesPage()
        main = Adw.PreferencesGroup()
        self.title_row = Adw.EntryRow(title="Title", text=task.get("title", ""))
        self.title_row.connect("entry-activated", lambda _r: self.save())
        main.add(self.title_row)
        self.priority_row = Adw.ComboRow(title="Priority", model=Gtk.StringList.new(PRIORITIES))
        priority = task.get("priority")
        self.priority_row.set_selected(priority - 1 if priority in (1, 2, 3, 4) else 3)
        main.add(self.priority_row)
        # Ids this device can't show yet stay in the array: only what the user removes is removed.
        self.labels = list(dict.fromkeys(task.get("labels") or []))
        main.add(self.labels_row())
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_dialog_key)
        self.add_controller(keys)
        self.estimate_row = Adw.EntryRow(title="Estimate, like 30m or 1h30",
                                         text=estimate_text(task.get("estimate_minutes")))
        self.estimate_row.connect("entry-activated", lambda _r: self.save())
        main.add(self.estimate_row)
        page.add(main)
        self.notes = NotesEditor(task.get("description") or "", self.save)
        page.add(self.notes)

        when = Adw.PreferencesGroup()
        self.due_row, self.calendar = date_row("Due date", (self.due or {}).get("date"), self.show_repeat)
        if self.due and self.due.get("tz"):
            self.due_row.set_subtitle(f"Time in {self.due['tz']}")
        self.time_row = Adw.EntryRow(title="Time (HH:MM, empty for all day)",
                                     text=(self.due or {}).get("time", ""))
        self.time_row.connect("entry-activated", lambda _r: self.save())
        self.due_row.add_row(self.time_row)
        when.add(self.due_row)
        self.deadline_row, self.deadline_calendar = date_row("Deadline", task.get("deadline"), lambda: None)
        when.add(self.deadline_row)
        self.repeat_row = Adw.EntryRow(title="Repeat, like “every weekday”",
                                       text=task.get("recurrence") or "")
        self.repeat_row.connect("changed", lambda _r: self.show_repeat())
        self.repeat_row.connect("entry-activated", lambda _r: self.save())
        when.add(self.repeat_row)
        self.repeat_hint = Adw.ActionRow()
        when.add(self.repeat_hint)
        if task.get("recurrence") and not task.get("completed_at"):
            skip = Adw.ButtonRow(title="Skip to the next occurrence")
            skip.connect("activated", lambda _r: self.move_on(self.window.writer.skip, "Skipped"))
            when.add(skip)
            detach = Adw.ButtonRow(title="Split off this occurrence")
            detach.connect("activated", lambda _r: self.move_on(self.window.writer.detach, "Split off a copy"))
            when.add(detach)
        page.add(when)
        self.show_repeat()

        self.reminder_group = Adw.PreferencesGroup(title="Reminders")
        add = Gtk.MenuButton(icon_name="list-add-symbolic", tooltip_text="Add reminder",
                             valign=Gtk.Align.CENTER, css_classes=["flat"])
        menu = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for kind, presets in (("relative", RELATIVE_PRESETS), ("deadline", DEADLINE_PRESETS)):
            for minutes, label in presets:
                button = Gtk.Button(label=label, css_classes=["flat"])
                button.connect("clicked", lambda _b, k=kind, m=minutes: self.add_reminder(k, offset_minutes=m))
                menu.append(button)
            menu.append(Gtk.Separator(margin_top=4, margin_bottom=4))
        at = Gtk.Entry(placeholder_text="At a time, like “tomorrow 9am”", width_chars=26)
        at.connect("activate", self.add_reminder_at)
        menu.append(at)
        add.set_popover(Gtk.Popover(child=menu))
        self.add_reminder_button = add
        self.reminder_group.set_header_suffix(add)
        self.reminder_rows = []
        page.add(self.reminder_group)
        self.fill_reminders()

        place = Adw.PreferencesGroup()
        self.projects = [(None, "Inbox")]

        def walk(nodes, depth):
            for node in nodes:
                self.projects.append((node.id, " " * depth + node.row.get("name", "")))
                walk(node.children, depth + 1)

        walk(window.snap.projects, 0)
        ids = [pid for pid, _ in self.projects]
        if task.get("project_id") not in ids:  # never move by accident
            self.projects.append((task.get("project_id"), "(current project)"))
            ids.append(task.get("project_id"))
        self.project_row = Adw.ComboRow(title="Project",
                                        model=Gtk.StringList.new([name for _, name in self.projects]))
        self.project_row.set_selected(ids.index(task.get("project_id")))
        self.project_row.connect("notify::selected", lambda *_a: self.fill_sections(None))
        place.add(self.project_row)
        self.section_row = Adw.ComboRow(title="Section")
        place.add(self.section_row)
        self.fill_sections(task.get("section_id"))
        page.add(place)

        self.subtask_group = Adw.PreferencesGroup(title="Subtasks")
        self.subtask_broom = broom_button()
        self.subtask_broom.connect("clicked", lambda _b: self.clear_completed_subtasks())
        self.subtask_group.set_header_suffix(self.subtask_broom)
        self.subtask_rows = []
        self.subtask_entry = Adw.EntryRow(title="Add a subtask")
        self.subtask_entry.connect("entry-activated", lambda _r: self.add_subtask())
        page.add(self.subtask_group)
        self.fill_subtasks()

        page.add(danger_group("Delete task", self.delete))

        view = Adw.ToolbarView(content=page)
        view.add_top_bar(header)
        self.toasts = Adw.ToastOverlay(child=view)
        self.set_child(self.toasts)
        self.set_focus(self.title_row)

    def project_id(self):
        return self.projects[self.project_row.get_selected()][0]

    # ---- labels: ids, and names of labels to create on Save ----

    def labels_row(self):
        row = Gtk.ListBoxRow(activatable=False)
        box = Gtk.Box(spacing=12, margin_top=10, margin_bottom=10, margin_start=12, margin_end=12)
        box.append(Gtk.Label(label="Labels", xalign=0, valign=Gtk.Align.CENTER))
        self.chips = Adw.WrapBox(child_spacing=6, line_spacing=6, hexpand=True, valign=Gtk.Align.CENTER,
                                 justify=Adw.JustifyMode.NONE, align=1)
        box.append(self.chips)
        add = Gtk.MenuButton(icon_name="list-add-symbolic", tooltip_text="Add or remove labels (L)",
                             valign=Gtk.Align.CENTER, css_classes=["flat"])
        add.set_create_popup_func(self.open_label_picker)
        self.label_button = add
        box.append(add)
        row.set_child(box)
        self.fill_chips()
        return row

    def fill_chips(self):
        self.chips.remove_all()
        known = self.window.snap.labels
        shown = [(ref, known[ref].get("name", ""), known[ref].get("color")) if ref in known else (ref, ref, NEW_LABEL_COLOUR)
                 for ref in self.labels if ref in known or ref in self.created_names()]
        for ref, name, color in shown:
            self.chips.append(label_chip(name, color, on_remove=lambda r=ref: self.toggle_label(r, False)))
        if not shown:
            self.chips.append(Gtk.Label(label="None", css_classes=["dim-label"]))

    def created_names(self):
        return [ref for ref in self.labels if ref not in self.window.store.rows("label")]

    def open_label_picker(self, button):
        known = self.window.snap.labels
        button.set_popover(LabelPicker(self.window.labels_for_picker(), selected=[r for r in self.labels if r in known],
                                       created=self.created_names(), on_toggle=self.toggle_label))

    def toggle_label(self, ref, on):
        if on and ref not in self.labels:
            self.labels.append(ref)
        elif not on and ref in self.labels:
            self.labels.remove(ref)
        self.fill_chips()

    def on_dialog_key(self, _controller, keyval, _code, state):
        """L opens the picker, as on a task row, unless a text field has the focus."""
        if keyval in (Gdk.KEY_l, Gdk.KEY_L) and not state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK):
            focus = self.get_focus()
            if not isinstance(focus, (Gtk.Editable, Gtk.TextView)):
                self.label_button.popup()
                return True
        return False

    def show_repeat(self):
        """Under the rule: its next dates, or why it doesn't parse."""
        text = self.repeat_row.get_text().strip()
        self.repeat_hint.set_visible(bool(text) or bool(self.task.get("recurrence")))
        if not text:
            self.repeat_hint.set_title("Doesn't repeat")
            self.repeat_hint.set_subtitle("")
            return
        try:
            rule = parse(text)
        except RuleError as err:
            self.repeat_hint.set_title("Not a repeat rule")
            self.repeat_hint.set_subtitle(str(err))
            return
        try:
            due = self.read_due()
        except CannotEdit:
            due = self.due
        due = due["date"] if due else None
        today = self.window.writer.today()
        dates = preview_occurrences(rule, due, today) if due else []
        self.repeat_hint.set_title("Then " + ", ".join(self.window.day_text(d) for d in dates) if dates
                                   else "Due on the first matching day")
        self.repeat_hint.set_subtitle("Turning the due date off ends the repeat.")

    def move_on(self, action, verb):
        done = self.window.run(action, self.task.id)
        if done:
            self.close()
            self.window.moved_on(done, verb)

    def fill_reminders(self):
        for row in self.reminder_rows:
            self.reminder_group.remove(row)
        self.reminder_rows = []
        reminders = [r for r in self.window.store.rows("reminder").values()
                     if r.get("task_id") == self.task.id and live(r)]
        reminders.sort(key=lambda r: (r.get("fire_at") is None, r.get("fire_at") or 0, r.id))
        for reminder in reminders:
            row = Adw.ActionRow(title=describe(reminder))
            if reminder.get("fire_at") is None:
                row.set_subtitle(f"No {'deadline' if reminder.get('kind') == 'deadline' else 'due date'}, so it won't fire")
            remove = Gtk.Button(icon_name="user-trash-symbolic", tooltip_text="Delete reminder",
                                valign=Gtk.Align.CENTER, css_classes=["flat"])
            remove.connect("clicked", lambda _b, rid=reminder.id: self.reminder_action(self.window.writer.delete_reminder, rid))
            row.add_suffix(remove)
            self.reminder_group.add(row)
            self.reminder_rows.append(row)
        if not reminders:
            row = Adw.ActionRow(title="None", css_classes=["dim-label"])
            self.reminder_group.add(row)
            self.reminder_rows.append(row)

    def add_reminder(self, kind, **when):
        self.add_reminder_button.popdown()
        self.reminder_action(self.window.writer.add_reminder, self.task.id, kind, **when)

    def add_reminder_at(self, entry):
        try:
            fire_at = self.window.writer.moment(entry.get_text())
        except CannotEdit as err:
            self.toasts.add_toast(Adw.Toast(title=escape(str(err)), timeout=5))
            return
        entry.set_text("")
        self.add_reminder("absolute", fire_at=fire_at)

    def fill_subtasks(self):
        for row in self.subtask_rows:
            self.subtask_group.remove(row)
        cleared = self.window.store.get_meta(CLEARED_SUBTASKS) or {}
        children = sorted((t for t in self.window.snap.tasks if t.get("parent_id") == self.task.id
                           and (t.get("completed_at") is None or completed_subtask_visible(t, cleared))),
                          key=lambda t: (t.get("position") or 0, t.id))
        self.completed_subtasks = [t for t in children if t.get("completed_at") is not None]
        self.subtask_broom.set_visible(bool(self.completed_subtasks))
        self.subtask_rows = [Adw.ActionRow(title=f"<s>{escape(t.get('title', ''))}</s>" if t.get("completed_at") is not None
                                            else escape(t.get("title", "")), use_markup=True,
                                           css_classes=["dim-label"] if t.get("completed_at") is not None else [])
                             for t in children] + [self.subtask_entry]
        for row in self.subtask_rows:
            self.subtask_group.add(row)

    def clear_completed_subtasks(self):
        before = self.window.clear_completed_subtasks(self.completed_subtasks, notify=False)
        self.fill_subtasks()
        toast = Adw.Toast(title="Cleared completed subtasks", timeout=5)
        toast.set_button_label("Undo")

        def undo(_toast):
            self.window.restore_cleared_subtasks(before)
            self.fill_subtasks()

        toast.connect("button-clicked", undo)
        self.toasts.add_toast(toast)

    def add_subtask(self):
        """Subtasks are added at once, like reminders. The line is read with quick add."""
        try:
            self.window.writer.quick_add(self.subtask_entry.get_text(), parent_id=self.task.id)
        except CannotEdit as err:
            self.toasts.add_toast(Adw.Toast(title=escape(str(err)), timeout=5))
            return
        self.subtask_entry.set_text("")
        self.window.after_edit()
        self.fill_subtasks()

    def delete(self):
        self.close()
        self.window.delete_task(self.task.id)

    def reminder_action(self, action, *args):
        """Reminders change at once, apart from Save: they're their own entities."""
        try:
            action(*args)
        except CannotEdit as err:
            self.toasts.add_toast(Adw.Toast(title=escape(str(err)), timeout=5))
            return
        self.window.after_edit()
        self.fill_reminders()

    def fill_sections(self, selected):
        project_id = self.project_id()
        self.sections = [(None, "No section")]
        if project_id is not None:
            self.sections += [(s.id, s.get("name", "")) for s in self.window.snap.sections_by_project.get(project_id, [])]
        self.section_row.set_model(Gtk.StringList.new([name for _, name in self.sections]))
        ids = [sid for sid, _ in self.sections]
        self.section_row.set_selected(ids.index(selected) if selected in ids else 0)
        self.section_row.set_sensitive(len(self.sections) > 1)

    def read_due(self):
        day = read_date(self.due_row, self.calendar)
        if day is None:
            return None
        due = {"date": day}
        if at := parse_time(self.time_row.get_text()):
            due["time"] = at
            # Editing a zoned due keeps its zone. Clearing the time drops it.
            if self.due and self.due.get("tz"):
                due["tz"] = self.due["tz"]
        return due

    def save(self):
        task = self.task
        changes = {}
        try:
            title = self.title_row.get_text().strip()
            if title != task.get("title", ""):
                changes["title"] = title
            notes = self.notes.text()
            if notes.rstrip() != (task.get("description") or "").rstrip():
                changes["description"] = notes
            priority = self.priority_row.get_selected() + 1
            if priority != (task.get("priority") or 4):
                changes["priority"] = priority
            due = self.read_due()
            if due != self.due:
                changes["due"] = due
            if self.labels != list(dict.fromkeys(task.get("labels") or [])):
                changes["labels"] = self.labels
            estimate = parse_estimate(self.estimate_row.get_text())
            if estimate != task.get("estimate_minutes"):
                changes["estimate_minutes"] = estimate
            deadline = read_date(self.deadline_row, self.deadline_calendar)
            if deadline != task.get("deadline"):
                changes["deadline"] = deadline
            rule = self.repeat_row.get_text().strip()
            if rule != (self.task.get("recurrence") or ""):
                changes["recurrence"] = rule
            project_id = self.project_id()
            section_id = self.sections[self.section_row.get_selected()][0]
            if project_id != task.get("project_id"):
                changes["project_id"] = project_id
                changes["section_id"] = section_id
            elif section_id != task.get("section_id"):
                changes["section_id"] = section_id
            if changes:
                self.window.writer.edit(task.id, changes)
                if "labels" in changes:
                    before = task.get("labels") or []
                    now = self.window.store.rows("task")[task.id].get("labels") or []
                    self.window.remember_labels([i for i in now if i not in before])
        except CannotEdit as err:
            self.toasts.add_toast(Adw.Toast(title=escape(str(err)), timeout=5))
            return
        self.close()
        if changes:
            self.window.after_edit()


class ViewDialog(Adw.Dialog):
    """Create or edit a saved view. The query is checked, and its matches counted, as you type."""

    GROUPS = [("project", "Project"), ("due", "Due date"), ("priority", "Priority"), ("label", "Label"), ("none", "None")]
    SORTS = [("due", "Due date"), ("priority", "Priority"), ("position", "Manual order"), ("created", "Date added"),
             ("deadline", "Deadline"), ("title", "Title")]
    DIRECTIONS = [("asc", "Ascending"), ("desc", "Descending")]

    def __init__(self, window, view=None, query=""):
        """query: a new view's query, from the Filter page."""
        super().__init__(title="Edit view" if view else "New view", content_width=520)
        self.window = window
        self.view = view
        group_by, sort_by, sort_dir = view_options(view or {})
        # What the dialog shows. Only fields the user changes are written, so a value
        # from a newer client that reads here as a default survives.
        self.shown = {"name": view.get("name", "") if view else "", "query": view.get("query", "") if view else query,
                      "group_by": group_by, "sort_by": sort_by, "sort_dir": sort_dir,
                      "show_completed": bool(view and view.get("show_completed") is True)}

        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda _b: self.close())
        save = Gtk.Button(label="Save", css_classes=["suggested-action"])
        save.connect("clicked", lambda _b: self.save())
        header = Adw.HeaderBar(show_start_title_buttons=False, show_end_title_buttons=False)
        header.pack_start(cancel)
        header.pack_end(save)

        page = Adw.PreferencesPage()
        main = Adw.PreferencesGroup()
        self.name_row = Adw.EntryRow(title="Name", text=self.shown["name"])
        self.name_row.connect("entry-activated", lambda _r: self.save())
        main.add(self.name_row)
        page.add(main)
        query = Adw.PreferencesGroup(title="Query")
        self.query_bar = QueryBar(window.query_names, lambda _q: self.show_matches(), on_enter=lambda _q: self.save(),
                                  text=self.shown["query"])
        query.add(self.query_bar)
        self.hint = Gtk.Label(xalign=0, wrap=True, selectable=True, margin_top=6, css_classes=["dim-label"])
        query.add(self.hint)
        page.add(query)

        options = Adw.PreferencesGroup(title="Display")
        self.choices = {}
        for name, title, items in (("group_by", "Group by", self.GROUPS), ("sort_by", "Sort by", self.SORTS),
                                   ("sort_dir", "Order", self.DIRECTIONS)):
            row = Adw.ComboRow(title=title, model=Gtk.StringList.new([label for _, label in items]))
            row.set_selected([key for key, _ in items].index(self.shown[name]))
            options.add(row)
            self.choices[name] = (row, items)
        self.completed_row = Adw.SwitchRow(title="Show completed tasks", active=self.shown["show_completed"])
        options.add(self.completed_row)
        page.add(options)

        if view:
            page.add(danger_group("Delete view", self.delete))

        toolbar = Adw.ToolbarView(content=page)
        toolbar.add_top_bar(header)
        self.toasts = Adw.ToastOverlay(child=toolbar)
        self.set_child(self.toasts)
        self.set_focus(self.query_bar.entry if view else self.name_row)
        self.show_matches()

    def show_matches(self):
        query = self.query_bar.text().strip()
        if not query:
            self.hint.set_text("Type a query, or add conditions. @ suggests labels, # projects.")
            return
        window = self.window
        try:
            _, count, warnings = run_query(query, window.filter_context, window.snap.tasks)
        except FilterError as err:
            self.hint.set_text(f"Not a query yet: {err}")
            return
        self.hint.set_text(" · ".join([f"{count} open task{'' if count == 1 else 's'} match", *warnings]))

    def read(self):
        values = {"name": self.name_row.get_text().strip(), "query": self.query_bar.text().strip(),
                  "show_completed": self.completed_row.get_active()}
        for name, (row, items) in self.choices.items():
            values[name] = items[row.get_selected()][0]
        return values

    def save(self):
        window = self.window
        values = self.read()
        try:
            if self.view:
                changes = {k: v for k, v in values.items() if v != self.shown[k]}
                if changes:
                    window.writer.edit_view(self.view.id, changes)
                view_id = self.view.id
            else:
                name, query = values.pop("name"), values.pop("query")
                view_id = window.writer.add_view(name, query, **values)
        except CannotEdit as err:
            self.toasts.add_toast(Adw.Toast(title=escape(str(err)), timeout=5))
            return
        self.close()
        window.show_view(view_id)

    def delete(self):
        """Close, then ask: the window confirms before deleting."""
        self.close()
        self.window.delete_view(self.view.id)


class ProjectDialog(Adw.Dialog):
    """Create or edit a project: name, colour and parent. An existing one can also be archived or deleted."""

    def __init__(self, window, project=None, parent_id=None):
        super().__init__(title="Edit project" if project else "New project", content_width=460)
        self.window = window
        self.project = project
        self.color = project.get("color") if project else PROJECT_COLOURS[0][0]

        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda _b: self.close())
        save = Gtk.Button(label="Save" if project else "Add", css_classes=["suggested-action"])
        save.connect("clicked", lambda _b: self.save())
        header = Adw.HeaderBar(show_start_title_buttons=False, show_end_title_buttons=False)
        header.pack_start(cancel)
        header.pack_end(save)

        page = Adw.PreferencesPage()
        main = Adw.PreferencesGroup()
        self.name_row = Adw.EntryRow(title="Name", text=project.get("name", "") if project else "")
        self.name_row.connect("entry-activated", lambda _r: self.save())
        main.add(self.name_row)

        # A new project's colour is chosen by the writer unless the user picks one.
        self.picked = project is not None
        colours = Gtk.Box(spacing=4, valign=Gtk.Align.CENTER)
        first = None
        for hex_, name in PROJECT_COLOURS:
            button = Gtk.ToggleButton(child=Dot(hex_, 16), tooltip_text=name, css_classes=["flat", "colour-choice"],
                                      active=project is not None and hex_ == self.color)
            button.set_group(first)
            first = first or button
            button.connect("toggled", lambda b, c=hex_: b.get_active() and self.pick(c))
            colours.append(button)
        colour_row = Adw.ActionRow(title="Colour")
        colour_row.add_suffix(colours)
        main.add(colour_row)

        # Any live, unarchived project but this one and those below it.
        below = {p.id for p in project_descendants(project.id, window.store.rows("project"))} if project else set()
        self.parents = [None] + [pid for pid, _ in window.project_paths
                                 if not project or (pid != project.id and pid not in below)]
        names = dict(window.project_paths)
        self.parent_row = Adw.ComboRow(title="Parent project", model=Gtk.StringList.new(
            ["None"] + [names[pid] for pid in self.parents[1:]]))
        current = project.get("parent_id") if project else parent_id
        # A parent not offered (archived, say) shows as None, and is only written if the user picks another.
        self.shown_parent = current if current in self.parents else None
        self.parent_row.set_selected(self.parents.index(self.shown_parent))
        main.add(self.parent_row)
        page.add(main)

        if project:
            archive = Gtk.Button(child=Adw.ButtonContent(icon_name="folder-symbolic", label="Archive project"),
                                 halign=Gtk.Align.CENTER, css_classes=["pill"])
            archive.connect("clicked", lambda _b: self.then(window.archive_project))
            group = Adw.PreferencesGroup()
            group.add(archive)
            page.add(group)
            page.add(danger_group("Delete project", lambda: self.then(window.delete_project)))

        toolbar = Adw.ToolbarView(content=page)
        toolbar.add_top_bar(header)
        self.toasts = Adw.ToastOverlay(child=toolbar)
        self.set_child(self.toasts)
        self.set_focus(self.name_row)

    def then(self, action):
        """Close, then run action(project id)."""
        self.close()
        action(self.project.id)

    def pick(self, color):
        self.color, self.picked = color, True

    def save(self):
        window = self.window
        name = self.name_row.get_text()
        parent_id = self.parents[self.parent_row.get_selected()]
        try:
            if self.project:
                changes = {"name": name, "color": self.color}
                if parent_id != self.shown_parent:
                    changes["parent_id"] = parent_id
                window.writer.edit_project(self.project.id, changes)
                project_id = self.project.id
            else:
                project_id = window.writer.add_project(name, parent_id, self.color if self.picked else None)
        except CannotEdit as err:
            self.toasts.add_toast(Adw.Toast(title=escape(str(err)), timeout=5))
            return
        self.close()
        window.show_project(project_id)


class LabelDialog(Adw.Dialog):
    """Create or edit a label: name and colour. An existing one can also be merged or deleted."""

    def __init__(self, window, label=None):
        super().__init__(title="Edit label" if label else "New label", content_width=420)
        self.window = window
        self.label = label
        self.color = label.get("color") if label else None  # None: the writer picks an unused colour

        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda _b: self.close())
        save = Gtk.Button(label="Save" if label else "Add", css_classes=["suggested-action"])
        save.connect("clicked", lambda _b: self.save())
        header = Adw.HeaderBar(show_start_title_buttons=False, show_end_title_buttons=False)
        header.pack_start(cancel)
        header.pack_end(save)

        page = Adw.PreferencesPage()
        main = Adw.PreferencesGroup()
        self.name_row = Adw.EntryRow(title="Name", text=label.get("name", "") if label else "")
        self.name_row.connect("entry-activated", lambda _r: self.save())
        main.add(self.name_row)
        page.add(main)

        colours = Adw.PreferencesGroup(title="Colour")
        swatches = Adw.WrapBox(child_spacing=4, line_spacing=4)
        first = None
        for hex_, name in LABEL_COLOURS:
            button = Gtk.ToggleButton(child=Dot(hex_, 16), tooltip_text=name, css_classes=["flat", "colour-choice"],
                                      active=hex_ == self.color)
            button.update_property([Gtk.AccessibleProperty.LABEL], [name])
            button.set_group(first)
            first = first or button
            button.connect("toggled", lambda b, c=hex_: b.get_active() and self.pick(c))
            swatches.append(button)
        colours.add(swatches)
        page.add(colours)

        if label:
            merge = Gtk.Button(label="Merge into another label…", halign=Gtk.Align.CENTER, css_classes=["pill"],
                               sensitive=len(window.snap.labels) > 1)
            merge.connect("clicked", lambda _b: self.then(window.merge_label))
            group = Adw.PreferencesGroup()
            group.add(merge)
            page.add(group)
            page.add(danger_group("Delete label", lambda: self.then(window.delete_label)))

        toolbar = Adw.ToolbarView(content=page)
        toolbar.add_top_bar(header)
        self.toasts = Adw.ToastOverlay(child=toolbar)
        self.set_child(self.toasts)
        self.set_focus(self.name_row)

    def then(self, action):
        """Close, then run action(label id)."""
        self.close()
        action(self.label.id)

    def pick(self, color):
        self.color = color

    def save(self):
        writer = self.window.writer
        try:
            if self.label:
                writer.edit_label(self.label.id, {"name": self.name_row.get_text(), "color": self.color})
                label_id = self.label.id
            else:
                label_id = writer.add_label(self.name_row.get_text(), self.color)
        except CannotEdit as err:
            self.toasts.add_toast(Adw.Toast(title=escape(str(err)), timeout=5))
            return
        self.close()
        self.window.show_label(label_id)


def ask_name(window, heading, text, on_name):
    """A small dialog with one entry. on_name(text) runs on Enter or the action button."""
    dialog = Adw.AlertDialog(heading=heading)
    entry = Gtk.Entry(text=text)

    def enter(_entry):
        # Closing answers "cancel", which does nothing, so Enter runs on_name once.
        dialog.close()
        on_name(entry.get_text())

    entry.connect("activate", enter)
    dialog.set_extra_child(entry)
    dialog.add_response("cancel", "Cancel")
    dialog.add_response("ok", "Save" if text else "Add")
    dialog.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
    dialog.set_default_response("ok")
    dialog.set_close_response("cancel")
    dialog.connect("response", lambda _d, response: response == "ok" and on_name(entry.get_text()))
    dialog.present(window)
    entry.grab_focus()


class SettingsDialog(Adw.PreferencesDialog):
    """Preferences (stored in user_prefs 'me' so they work locally and sync when connected) and optional OpenTodo sync."""

    TIME_CHOICES = [("system", "System"), ("24h", "24-hour"), ("12h", "12-hour")]
    DATE_CHOICES = [("system", "System"), ("day-month", "Day–month"), ("month-day", "Month–day"), ("iso", "ISO (YYYY-MM-DD)")]
    WEEK_CHOICES = [("system", "System"), ("mon", "Monday"), ("sun", "Sunday"), ("sat", "Saturday")]
    LANGUAGE_CHOICES = [("system", "System"), ("en", "English"), ("de", "Deutsch"), ("fr", "Français"),
                        ("es", "Español"), ("it", "Italiano"), ("pt", "Português")]

    def __init__(self, window):
        super().__init__(title="Settings", content_width=480, content_height=580)
        self.window = window
        self._updating = False
        self._connecting = False
        self.sync_group = None
        self.sync_rows = []

        prefs_row = window.store.rows("user_prefs").get("me")
        prefs = prefs_row.values if prefs_row else {}
        timed_default, dated_default = read_defaults(prefs)

        self.page = page = Adw.PreferencesPage()

        reminders = Adw.PreferencesGroup(
            title="Default reminders",
            description="Added automatically when a task first gets a due date.",
        )
        self.timed_row = Adw.ComboRow(title="Tasks with a time")
        self.dated_row = Adw.ComboRow(title="Tasks with no time", subtitle="Counted from 09:00 on the due date")
        self._fill_reminder_combo(self.timed_row, "timed", DEFAULT_TIMED_PRESETS, timed_default)
        self._fill_reminder_combo(self.dated_row, "dated", DEFAULT_DATED_PRESETS, dated_default)
        self.timed_row.connect("notify::selected", lambda *_a: self._on_reminder_selected("timed"))
        self.dated_row.connect("notify::selected", lambda *_a: self._on_reminder_selected("dated"))
        reminders.add(self.timed_row)
        reminders.add(self.dated_row)
        page.add(reminders)

        dt = Adw.PreferencesGroup(title="Date and time")
        dt.add(self._enum_row("time_format", "Time format", None, self.TIME_CHOICES, prefs.get("time_format")))
        dt.add(self._enum_row("date_format", "Date order", "For dates like 06/11 in quick add",
                              self.DATE_CHOICES, prefs.get("date_format")))
        dt.add(self._enum_row("week_start", "Week starts on", None, self.WEEK_CHOICES, prefs.get("week_start")))
        dt.add(self._day_start_row(prefs.get("day_start"), prefs.get("time_format", "system")))
        page.add(dt)

        qa = Adw.PreferencesGroup(title="Quick add")
        qa.add(self._enum_row("language", "Language", None, self.LANGUAGE_CHOICES, prefs.get("language")))
        qa.add(self._switch_row("time_sectors", "Time sectors",
                                "Understand phrases like “this week” or “next month”", prefs.get("time_sectors") == "on"))
        qa.add(self._switch_row("day_parts", "Parts of the day",
                                "Understand “morning” and “afternoon”", prefs.get("day_parts") == "on"))
        qa.add(self._switch_row("energy", "Energy levels",
                                "Understand “deep”, “medium” and “low energy”", prefs.get("energy") == "on"))
        page.add(qa)

        self.sync_group = Adw.PreferencesGroup(title="OpenTodo sync")
        page.add(self.sync_group)
        self._rebuild_sync_group()
        self.add(page)

    def _notice(self, text):
        self.add_toast(Adw.Toast(title=escape(text), timeout=5))

    def _set_pref(self, field, value):
        if self._updating:
            return
        try:
            self.window.writer.set_prefs({field: value})
        except CannotEdit as err:
            self._notice(str(err))
            return
        self.window.after_edit()

    def _enum_row(self, field, title, subtitle, choices, current):
        keys = [k for k, _ in choices]
        row = Adw.ComboRow(title=title, subtitle=subtitle or "", model=Gtk.StringList.new([label for _, label in choices]))
        row.set_selected(keys.index(current) if current in keys else 0)
        row.connect("notify::selected", lambda r, _p: self._set_pref(field, keys[r.get_selected()]))
        return row

    def _day_start_row(self, current, time_format):
        minutes = day_start_minutes(current)
        hhmm = f"{minutes // 60:02d}:{minutes % 60:02d}"
        twelve = uses_12h(time_format)
        values = list(DAY_STARTS)
        if hhmm not in values:
            values = sorted([*values, hhmm])
        labels = ["Midnight" if v == "00:00" else format_time(time.fromisoformat(v), twelve) for v in values]
        row = Adw.ComboRow(
            title="Day starts at",
            subtitle="Work before this hour still counts as the day before",
            model=Gtk.StringList.new(labels),
            selected=values.index(hhmm),
        )
        row.connect("notify::selected", lambda r, _p: self._set_pref("day_start", values[r.get_selected()]))
        return row

    def _switch_row(self, field, title, subtitle, active):
        row = Adw.SwitchRow(title=title, subtitle=subtitle, active=active)
        row.connect("notify::active", lambda r, _p: self._set_pref(field, "on" if r.get_active() else "off"))
        return row

    def _fill_reminder_combo(self, row, kind, presets, current):
        self._updating = True
        try:
            items = [(None, "None"), *presets]
            known = {m for m, _ in items}
            if current not in known:
                label = "On the day at 09:00" if kind == "dated" and current == 0 else offset_label(current)
                items.append((current, label))
            items.append(("custom", "Custom…"))
            setattr(self, f"_{kind}_items", items)
            setattr(self, f"_{kind}_current", current)
            row.set_model(Gtk.StringList.new([label for _, label in items]))
            row.set_selected([m for m, _ in items].index(current))
        finally:
            self._updating = False

    def _on_reminder_selected(self, kind):
        if self._updating:
            return
        row = self.timed_row if kind == "timed" else self.dated_row
        presets = DEFAULT_TIMED_PRESETS if kind == "timed" else DEFAULT_DATED_PRESETS
        items = getattr(self, f"_{kind}_items")
        current = getattr(self, f"_{kind}_current")
        choice = items[row.get_selected()][0]
        field = f"reminder_default_{kind}"
        if choice != "custom":
            setattr(self, f"_{kind}_current", choice)
            self._set_pref(field, choice)
            return
        self._ask_custom_reminder(kind, presets, current)

    def _ask_custom_reminder(self, kind, presets, previous):
        row = self.timed_row if kind == "timed" else self.dated_row
        field = f"reminder_default_{kind}"
        dialog = Adw.AlertDialog(
            heading="Custom default reminder",
            body="Enter an offset like 15m, 2h, 3d, or 30m after.",
        )
        entry = Gtk.Entry(placeholder_text="15m")
        applied = False

        def apply_text():
            nonlocal applied
            minutes = parse_custom_offset(entry.get_text())
            if minutes is None:
                self._notice("Write an offset up to 1 year, like 15m, 2h or 3d")
                self._fill_reminder_combo(row, kind, presets, previous)
                return
            applied = True
            self._fill_reminder_combo(row, kind, presets, minutes)
            self._set_pref(field, minutes)

        def on_activate(_entry):
            dialog.close()
            apply_text()

        def on_response(_dialog, response):
            if response == "ok":
                apply_text()
            elif not applied:
                self._fill_reminder_combo(row, kind, presets, previous)

        entry.connect("activate", on_activate)
        dialog.set_extra_child(entry)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("ok", "Set")
        dialog.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("ok")
        dialog.set_close_response("cancel")
        dialog.connect("response", on_response)
        dialog.present(self)
        entry.grab_focus()

    # ---- OpenTodo sync ----

    def _rebuild_sync_group(self):
        for r in self.sync_rows:
            self.sync_group.remove(r)
        self.sync_rows = []
        cfg = self.window.cfg
        if cfg is None:
            self.sync_group.set_description(
                "Optional. Tasks live locally on this device. Connect an OpenTodo server whenever you want "
                "to sync across devices — your existing local tasks will be uploaded."
            )
        else:
            self.sync_group.set_description(
                f"Connected to {cfg.url}. Edits work offline and sync when reachable."
            )
        self.url_row = Adw.EntryRow(title="Server URL (https://…)" if cfg is None else "Server URL",
                                    text=cfg.url if cfg else "")
        self.token_row = Adw.PasswordEntryRow(title="API token", text=cfg.token if cfg else "")
        self.url_row.connect("entry-activated", lambda _r: self.token_row.grab_focus())
        self.token_row.connect("entry-activated", lambda _r: self._on_connect_clicked())
        buttons = Gtk.Box(spacing=12, margin_top=8, margin_bottom=4)
        self.connect_button = Gtk.Button(
            label="Connect to OpenTodo" if cfg is None else "Save & reconnect",
            css_classes=["pill", "suggested-action"],
        )
        self.connect_button.connect("clicked", lambda _b: self._on_connect_clicked())
        buttons.append(self.connect_button)
        self.disconnect_button = None
        if cfg is not None:
            disconnect = Gtk.Button(label="Disconnect…", css_classes=["pill", "destructive-action"])
            disconnect.connect("clicked", lambda _b: self._on_disconnect_clicked())
            buttons.append(disconnect)
            self.disconnect_button = disconnect
        button_row = Gtk.ListBoxRow(child=buttons, activatable=False, selectable=False)
        for r in (self.url_row, self.token_row, button_row):
            self.sync_group.add(r)
            self.sync_rows.append(r)

    def _set_busy(self, busy):
        self._connecting = busy
        self.url_row.set_sensitive(not busy)
        self.token_row.set_sensitive(not busy)
        self.connect_button.set_sensitive(not busy)
        self.connect_button.set_label(
            "Connecting…" if busy else ("Connect to OpenTodo" if self.window.cfg is None else "Save & reconnect")
        )
        if self.disconnect_button is not None:
            self.disconnect_button.set_sensitive(not busy)

    def _on_connect_clicked(self):
        if self._connecting:
            return
        try:
            cfg = config.validate(self.url_row.get_text(), self.token_row.get_text())
        except config.ConfigMissing as err:
            self._notice(str(err))
            return
        self._set_busy(True)

        def check():
            try:
                info = verify_account(Api(cfg.url, cfg.token))
                err = None
            except Offline:
                info, err = None, "Could not reach server. Check the URL and your connection."
            except ApiError as api_err:
                if api_err.status in (401, 403):
                    info, err = None, "Authentication failed. Check your API token."
                else:
                    info, err = None, f"Server error: {api_err}"
            except UnsupportedAccount as unsup:
                info, err = None, f"Can't connect: {unsup}"
            except Exception as exc:
                info, err = None, f"Connection failed: {exc}"
            GLib.idle_add(self._on_verified, cfg, info, err)

        threading.Thread(target=check, daemon=True).start()

    def _on_verified(self, cfg, info, err):
        self._set_busy(False)
        if not self.get_mapped():
            return GLib.SOURCE_REMOVE
        if err is not None:
            self._notice(err)
            return GLib.SOURCE_REMOVE
        remote_user_id, account_key = info
        store = self.window.store
        stored_user = store.get_meta("user_id")
        has_data = any(True for _ in store.all_fields())
        if stored_user in (None, LOCAL_USER) or stored_user == remote_user_id or not has_data:
            if not has_data and stored_user not in (None, LOCAL_USER, remote_user_id):
                reset_for_account(store, remote_user_id, account_key)
            elif stored_user in (None, LOCAL_USER):
                adopt_standalone(store, remote_user_id, account_key)
            else:
                with store.transaction():
                    store.set_meta("account_key", account_key)
            self._finish_connect(cfg)
            return GLib.SOURCE_REMOVE

        dialog = Adw.AlertDialog(
            heading="Switch OpenTodo account?",
            body="This device holds tasks synced with another OpenTodo account. "
                 "Upload these tasks into the new account, or replace local data with the new account?",
        )
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("upload", "Upload local tasks")
        dialog.add_response("replace", "Replace local data")
        dialog.set_response_appearance("upload", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_response_appearance("replace", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")

        def decide(_d, response):
            if response == "upload":
                migrate_account(store, remote_user_id, account_key)
                self._finish_connect(cfg)
            elif response == "replace":
                reset_for_account(store, remote_user_id, account_key)
                self._finish_connect(cfg)

        dialog.connect("response", decide)
        dialog.present(self)
        return GLib.SOURCE_REMOVE

    def _finish_connect(self, cfg):
        config.save(cfg)
        self.window.connect_sync(cfg)
        self._rebuild_sync_group()
        self._notice("Connected to OpenTodo — syncing…")

    def _on_disconnect_clicked(self):
        dialog = Adw.AlertDialog(
            heading="Disconnect from OpenTodo?",
            body="Sync will stop. Your tasks, projects and settings stay on this device.",
        )
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("disconnect", "Disconnect")
        dialog.set_response_appearance("disconnect", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")

        def disconnect(_d, response):
            if response != "disconnect":
                return
            config.clear()
            self.window.disconnect_sync()
            self._rebuild_sync_group()
            self._notice("Disconnected — working locally")

        dialog.connect("response", disconnect)
        dialog.present(self)
