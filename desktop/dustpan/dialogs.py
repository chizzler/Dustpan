"""The task, view and project editors."""

import re

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GLib, Gtk  # noqa: E402

from .filters import FilterError  # noqa: E402
from .labelpicker import NEW_LABEL_COLOUR, LabelPicker  # noqa: E402
from .model import CLEARED_SUBTASKS, completed_subtask_visible  # noqa: E402
from .querybar import QueryBar  # noqa: E402
from .noteview import NotesEditor  # noqa: E402
from .quickadd.attributes import match_duration  # noqa: E402
from .recurrence import RuleError, parse, preview_occurrences  # noqa: E402
from .reminders import DEADLINE_PRESETS, RELATIVE_PRESETS, describe  # noqa: E402
from .views import run_query, view_options  # noqa: E402
from .widgets import Dot, broom_button, escape, label_chip  # noqa: E402
from .writes import LABEL_COLOURS, PROJECT_COLOURS, CannotEdit, live, project_descendants  # noqa: E402

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
