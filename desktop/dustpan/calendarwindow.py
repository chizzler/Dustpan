"""The calendar, in a window of its own beside the main one. See spec/calendar.md.

It reads the main window's store and writes through it, so both refresh together.
The rules are in calendar.py; this file only draws them.
"""

from datetime import date

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GObject, Gtk, Pango  # noqa: E402

from . import calendar  # noqa: E402
from .dates import format_minutes  # noqa: E402
from .dragdrop import ToDay  # noqa: E402
from .widgets import Dot  # noqa: E402

MOST_ROWS = 4  # task lines a day shows before "+N more"

CSS = """
.cal-weekday { font-size: 0.85em; font-weight: bold; opacity: 0.6; padding: 4px 6px; }
.cal-cell { padding: 4px; border-top: 1px solid alpha(currentColor, 0.1); border-left: 1px solid alpha(currentColor, 0.1); }
.cal-cell.other-month { background: alpha(currentColor, 0.03); }
.cal-cell.other-month .cal-day, .cal-cell.past .cal-day { opacity: 0.45; }
.cal-cell.drop-onto { background: alpha(var(--accent-bg-color), 0.2); }
.cal-day { font-size: 0.9em; min-width: 22px; padding: 1px 4px; }
.cal-cell.today .cal-day { background: var(--accent-bg-color); color: var(--accent-fg-color); border-radius: 11px; font-weight: bold; }
.cal-load { font-size: 0.8em; opacity: 0.6; }
.cal-load.over { color: var(--dustpan-overdue); opacity: 1; }
.cal-task { font-size: 0.9em; padding: 1px 3px; border-radius: 4px; }
.cal-task:hover { background: alpha(currentColor, 0.07); }
.cal-task.dragging { opacity: 0.4; }
.cal-time { font-size: 0.85em; opacity: 0.65; font-feature-settings: "tnum"; }
.cal-deadline { font-size: 0.85em; color: var(--dustpan-overdue); }
.cal-more { font-size: 0.85em; padding: 0 3px; min-height: 0; }
"""


class CalendarWindow(Adw.ApplicationWindow):
    def __init__(self, main, on_closed):
        super().__init__(application=main.get_application(), title="Calendar", default_width=900,
                         default_height=700, hide_on_close=True)
        self.main = main
        self.anchor = main.today  # the shown month holds this day
        self.title = Adw.WindowTitle(title="Calendar")
        back = Gtk.Button(icon_name="go-previous-symbolic", tooltip_text="Previous month ([)")
        back.connect("clicked", lambda _b: self.go(-1))
        forward = Gtk.Button(icon_name="go-next-symbolic", tooltip_text="Next month (])")
        forward.connect("clicked", lambda _b: self.go(1))
        today = Gtk.Button(label="Today", tooltip_text="Today (t)")
        today.connect("clicked", lambda _b: self.go(0))
        header = Adw.HeaderBar(title_widget=self.title)
        for button in (back, today, forward):
            header.pack_start(button)
        self.grid = Gtk.Grid(row_homogeneous=False, column_homogeneous=True, hexpand=True, vexpand=True)
        view = Adw.ToolbarView(content=self.grid)
        view.add_top_bar(header)
        self.toasts = Adw.ToastOverlay(child=view)
        self.set_content(self.toasts)
        self.set_size_request(360, 300)
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_key)
        self.add_controller(keys)
        self.connect("close-request", lambda _w: on_closed() or False)

    def on_key(self, _controller, keyval, _code, state):
        if state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK):
            return False
        step = {Gdk.KEY_bracketleft: -1, Gdk.KEY_bracketright: 1, Gdk.KEY_t: 0}.get(keyval)
        if step is None:
            return False
        self.go(step)
        return True

    def go(self, months):
        """Move by months; 0 comes back to today."""
        self.anchor = calendar.add_months(self.anchor, months) if months else self.main.today
        self.refresh()

    # ---- drawing ----

    def refresh(self):
        main = self.main
        week_start = main.week_start
        weeks = calendar.month_grid(self.anchor, week_start)
        first, last = weeks[0][0], weeks[-1][-1]
        projects = main.store.rows("project")
        archived = {p.id for p in projects.values() if p.get("archived")}
        tasks = list(main.snap.all_tasks.values())
        days = calendar.by_day(calendar.calendar_tasks(tasks, archived, first, last))
        deadlines = calendar.deadline_markers(tasks, archived, first, last)
        day_length = (main.store.get_meta("calendar_grid", {}) or {}).get("dayLength", calendar.DAY_LENGTH)
        month = self.anchor[:7]
        shown = date.fromisoformat(self.anchor)
        self.title.set_title(shown.strftime("%B %Y"))

        while child := self.grid.get_first_child():
            self.grid.remove(child)
        for col, day in enumerate(weeks[0]):
            self.grid.attach(Gtk.Label(label=date.fromisoformat(day).strftime("%a"), xalign=0,
                                       css_classes=["cal-weekday"]), col, 0, 1, 1)
        for row, week in enumerate(weeks, start=1):
            for col, day in enumerate(week):
                cell = self.cell(day, days.get(day, []), deadlines.get(day, []), projects, day_length)
                for css, on in (("other-month", day[:7] != month), ("past", day < main.today), ("today", day == main.today)):
                    if on:
                        cell.add_css_class(css)
                self.grid.attach(cell, col, row, 1, 1)

    def cell(self, day, tasks, deadlines, projects, day_length):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1, vexpand=True, css_classes=["cal-cell"])
        top = Gtk.Box(spacing=4)
        top.append(Gtk.Label(label=str(int(day[8:])), xalign=0.5, css_classes=["cal-day"]))
        planned, _, over = calendar.day_load(tasks, day_length)
        if planned:
            top.append(Gtk.Label(label=f"{format_minutes(planned)} / {format_minutes(day_length)}", hexpand=True,
                                 xalign=1, css_classes=["cal-load", *(["over"] if over else [])],
                                 tooltip_text="Planned against your day length"))
        box.append(top)
        for task in deadlines:
            box.append(Gtk.Label(label="◆ " + (task.get("title") or ""), xalign=0, ellipsize=Pango.EllipsizeMode.END,
                                 css_classes=["cal-deadline"], tooltip_text="Deadline"))
        rows, hidden = calendar.visible_rows(tasks, max(1, MOST_ROWS - len(deadlines)))
        for task in rows:
            box.append(self.task_line(task, projects))
        if hidden:
            more = Gtk.MenuButton(label=f"+{hidden} more", halign=Gtk.Align.START, css_classes=["flat", "cal-more"])
            listing = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1, margin_top=6, margin_bottom=6,
                              margin_start=6, margin_end=6)
            for task in tasks[len(rows):]:
                listing.append(self.task_line(task, projects))
            more.set_popover(Gtk.Popover(child=listing))
            box.append(more)
        self.drop_on(box, day)
        return box

    def task_line(self, task, projects):
        line = Gtk.Box(spacing=5, css_classes=["cal-task"])
        project = projects.get(task.get("project_id"))
        line.append(Dot(project.get("color") if project else None, 7))
        if at := calendar.viewed_due(task)[1]:
            line.append(Gtk.Label(label=at, css_classes=["cal-time"]))
        title = task.get("title") or ""
        line.append(Gtk.Label(label=title, xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END,
                              tooltip_text=title))
        click = Gtk.GestureClick()
        click.connect("released", lambda *_a: self.main.edit(task.id, parent=self))
        line.add_controller(click)
        self.main.drag.source(line, task.id, title)
        return line

    def drop_on(self, cell, day):
        """A task dropped on a day gets that date and keeps its time."""
        target = Gtk.DropTarget.new(GObject.TYPE_STRING, Gdk.DragAction.MOVE)
        target.connect("enter", lambda *_a: cell.add_css_class("drop-onto") or Gdk.DragAction.MOVE)
        target.connect("leave", lambda *_a: cell.remove_css_class("drop-onto"))

        def drop(_target, task_id, _x, _y):
            cell.remove_css_class("drop-onto")
            if not task_id or task_id not in self.main.snap.all_tasks:
                return False
            self.main.drop_task(task_id, ToDay(day))
            return True

        target.connect("drop", drop)
        cell.add_controller(target)
