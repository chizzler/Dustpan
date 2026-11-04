"""The calendar, in a window of its own beside the main one. See spec/rules.md.

It reads the main window's store and writes through it, so both refresh together.
The rules are in rules.py; this file only draws them.
"""

import math
from datetime import date, datetime, time, timedelta

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GLib, GObject, Graphene, Gsk, Gtk, Pango  # noqa: E402

from . import calendar_rules as rules  # noqa: E402
from .calendar_rules import DAY_MINUTES, MIN_BLOCK_MINUTES, SLOT_MINUTES  # noqa: E402
from .dates import format_minutes, format_time, uses_12h  # noqa: E402
from .dragdrop import ToDay, ToSlot  # noqa: E402
from .widgets import Dot  # noqa: E402

MOST_ROWS = 4  # task lines a Month day shows before "+N more"
MOST_LANE = 3  # untimed tasks a Week or Day header shows before "+N more"
PX_PER_MINUTE = 0.8  # 48 px an hour, as the web app
GUTTER_PX = 52
VIEWS = ("day", "week", "month")

CSS = """
.cal-weekday { font-size: 0.85em; font-weight: bold; opacity: 0.6; padding: 4px 6px; }
.cal-cell { padding: 4px; border-top: 1px solid alpha(currentColor, 0.1); border-left: 1px solid alpha(currentColor, 0.1); }
.cal-cell.other-month { background: alpha(currentColor, 0.03); }
.cal-cell.other-month .cal-day, .cal-cell.past .cal-day { opacity: 0.45; }
.cal-cell.drop-onto, .cal-head.drop-onto .cal-lane { background: alpha(var(--accent-bg-color), 0.2); }
.cal-day { font-size: 0.9em; min-width: 22px; padding: 1px 4px; }
.today .cal-day { background: var(--accent-bg-color); color: var(--accent-fg-color); border-radius: 11px; font-weight: bold; }
.cal-load { font-size: 0.8em; opacity: 0.6; }
.cal-load.over { color: var(--dustpan-overdue); opacity: 1; }
.cal-task { font-size: 0.9em; padding: 1px 3px; border-radius: 4px; }
.cal-task:hover { background: alpha(currentColor, 0.07); }
.cal-task.dragging, .cal-block.dragging { opacity: 0.4; }
.cal-time { font-size: 0.85em; opacity: 0.65; font-feature-settings: "tnum"; }
.cal-deadline { font-size: 0.85em; color: var(--dustpan-overdue); }
.cal-more { font-size: 0.85em; padding: 0 3px; min-height: 0; }
.cal-head { padding: 4px; border-left: 1px solid alpha(currentColor, 0.1); }
.cal-head.past .cal-day { opacity: 0.45; }
.cal-lane { min-height: 22px; border: 1px dashed alpha(currentColor, 0.18); border-radius: 5px; padding: 1px; }
.cal-heads { border-bottom: 1px solid alpha(currentColor, 0.12); }
.cal-hour { font-size: 0.75em; opacity: 0.55; font-feature-settings: "tnum"; }
.cal-block { padding: 2px 4px 2px 7px; font-size: 0.85em; }
.cal-block .cal-time { font-size: 0.9em; }
"""


def hhmm(minutes):
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


class TimeColumn(Gtk.Widget):
    """One day of the time grid: hour lines, blocks placed by minute and lane, the line for now, a drop ghost.

    Children are added with add(); each sits at a minute from midnight, in its lane.
    """

    def __init__(self, decorate=True, width=0):
        super().__init__(hexpand=not width)
        self.width = width  # a fixed width (the hour gutter), or 0 to share the row
        self.items = []  # (child, top minute, length in minutes, lane, lanes, rgba or None, dashed)
        self.decorate = decorate
        self.past_until = None  # minutes of the day shown as past; DAY_MINUTES for a past day
        self.now = None  # minutes, on today's column
        self.ghost = None  # (start, length) of a drop in progress
        self.shade = (0, DAY_MINUTES)  # the grid hours; outside them is shaded

    def add(self, child, top, length, lane=0, lanes=1, color=None, dashed=False):
        child.set_parent(self)
        rgba = None
        if color is not None:
            rgba = Gdk.RGBA()
            if not (isinstance(color, str) and rgba.parse(color)):
                rgba.parse("#94a3b8")
        self.items.append((child, top, length, lane, lanes, rgba, dashed))

    def clear(self):
        """Let go of the children before the column is thrown away."""
        for child, *_ in self.items:
            child.unparent()
        self.items = []

    def do_measure(self, orientation, for_size):
        if orientation == Gtk.Orientation.VERTICAL:
            size = math.ceil(DAY_MINUTES * PX_PER_MINUTE)
            return size, size, -1, -1
        return self.width, self.width, -1, -1

    def rect(self, width, top, length, lane, lanes):
        x = width * lane / lanes + 2
        return x, top * PX_PER_MINUTE, max(1.0, width / lanes - 4), length * PX_PER_MINUTE

    def do_size_allocate(self, width, height, baseline):
        for child, top, length, lane, lanes, *_ in self.items:
            if length is None:  # natural height, centred on top (the hour labels)
                h = child.measure(Gtk.Orientation.VERTICAL, -1)[1]
                x, y, w, _ = self.rect(width, top, 0, lane, lanes)
                y = max(0, y - h / 2)
            else:
                x, y, w, h = self.rect(width, top, length, lane, lanes)
            point = Graphene.Point()
            point.init(x, y)
            child.allocate(int(w), int(h), -1, Gsk.Transform.new().translate(point))

    def do_snapshot(self, snap):
        width, height = self.get_width(), self.get_height()
        fg = self.get_color()

        def fill(x, y, w, h, rgba, alpha):
            color = Gdk.RGBA()
            color.red, color.green, color.blue, color.alpha = rgba.red, rgba.green, rgba.blue, alpha
            snap.append_color(color, Graphene.Rect().init(x, y, w, h))

        if self.decorate:
            start, end = self.shade
            fill(0, 0, width, start * PX_PER_MINUTE, fg, 0.03)
            fill(0, end * PX_PER_MINUTE, width, height - end * PX_PER_MINUTE, fg, 0.03)
            if self.past_until:
                fill(0, 0, width, self.past_until * PX_PER_MINUTE, fg, 0.03)
            for hour in range(1, 24):
                fill(0, hour * 60 * PX_PER_MINUTE, width, 1, fg, 0.08)
            fill(0, 0, 1, height, fg, 0.1)
        for child, top, length, lane, lanes, rgba, dashed in self.items:
            if rgba is None:
                continue
            x, y, w, h = self.rect(width, top, length, lane, lanes)
            cr = snap.append_cairo(Graphene.Rect().init(x, y, w, h))
            radius = min(5, h / 2, w / 2)
            cr.new_sub_path()
            cr.arc(x + w - radius, y + radius, radius, -math.pi / 2, 0)
            cr.arc(x + w - radius, y + h - radius, radius, 0, math.pi / 2)
            cr.arc(x + radius, y + h - radius, radius, math.pi / 2, math.pi)
            cr.arc(x + radius, y + radius, radius, math.pi, 3 * math.pi / 2)
            cr.close_path()
            cr.set_source_rgba(rgba.red, rgba.green, rgba.blue, 0.12 if dashed else 0.24)
            cr.fill_preserve()
            if dashed:  # no estimate: drawn 30 minutes long, with a dashed edge
                cr.set_source_rgba(rgba.red, rgba.green, rgba.blue, 0.8)
                cr.set_line_width(1)
                cr.set_dash([4, 3])
                cr.stroke()
            else:
                cr.new_path()
                cr.rectangle(x, y + 1, 3, h - 2)
                cr.set_source_rgba(rgba.red, rgba.green, rgba.blue, 1)
                cr.fill()
        if self.ghost:
            accent = Adw.StyleManager.get_default().get_accent_color_rgba()
            start, length = self.ghost
            fill(2, start * PX_PER_MINUTE, width - 4, max(MIN_BLOCK_MINUTES, length) * PX_PER_MINUTE, accent, 0.3)
        for child, *_ in self.items:
            self.snapshot_child(child, snap)
        if self.now is not None:
            red = Gdk.RGBA()
            red.parse("#e01b24")
            fill(0, self.now * PX_PER_MINUTE - 1, width, 2, red, 1)


class CalendarWindow(Adw.ApplicationWindow):
    def __init__(self, main, on_closed):
        super().__init__(application=main.get_application(), title="Calendar", default_width=900,
                         default_height=700, hide_on_close=True)
        self.main = main
        self.anchor = main.today  # the shown day, week or month holds this day
        view = main.store.get_meta("calendar_view", "month")
        self.view = view if view in VIEWS else "month"
        self.scroll = None  # the time grid's position, kept across rebuilds
        self.columns = {}  # day -> TimeColumn on the shown grid
        self.grid_parts = []  # every TimeColumn shown, the gutter too
        # Week and Day share one heads area and one scrolled grid. Only their contents are replaced,
        # so the scroll position holds through every refresh, with no frame at midnight.
        self.time_heads = Adw.Bin()
        self.time_viewport = Gtk.Viewport(scroll_to_focus=False)
        self.time_scroller = Gtk.ScrolledWindow(child=self.time_viewport, vexpand=True,
                                                hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.time_view = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.time_view.append(self.time_heads)
        self.time_view.append(self.time_scroller)

        self.title = Adw.WindowTitle(title="Calendar")
        self.back = Gtk.Button(icon_name="go-previous-symbolic")
        self.back.connect("clicked", lambda _b: self.go(-1))
        self.forward = Gtk.Button(icon_name="go-next-symbolic")
        self.forward.connect("clicked", lambda _b: self.go(1))
        today = Gtk.Button(label="Today", tooltip_text="Today (t)")
        today.connect("clicked", lambda _b: self.go(0))
        self.switcher = Adw.ToggleGroup(css_classes=["round"])
        for name, key in zip(VIEWS, "dwm"):
            self.switcher.add(Adw.Toggle(name=name, label=name.title(), tooltip=f"{name.title()} ({key})"))
        self.switcher.set_active_name(self.view)
        self.switcher.connect("notify::active-name", lambda g, _p: self.show_view(g.get_active_name()))
        header = Adw.HeaderBar(title_widget=self.title)
        for button in (self.back, today, self.forward):
            header.pack_start(button)
        header.pack_end(self.switcher)
        self.body = Adw.Bin(hexpand=True, vexpand=True)
        view = Adw.ToolbarView(content=self.body)
        view.add_top_bar(header)
        self.toasts = Adw.ToastOverlay(child=view)
        self.set_content(self.toasts)
        self.set_size_request(360, 300)
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_key)
        self.add_controller(keys)
        self.connect("close-request", lambda _w: on_closed() or False)
        GLib.timeout_add_seconds(60, self.tick)

    # ---- moving about ----

    def on_key(self, _controller, keyval, _code, state):
        if state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK):
            return False
        views = {Gdk.KEY_d: "day", Gdk.KEY_w: "week", Gdk.KEY_m: "month"}
        if keyval in views:
            self.switcher.set_active_name(views[keyval])
            return True
        step = {Gdk.KEY_bracketleft: -1, Gdk.KEY_bracketright: 1, Gdk.KEY_t: 0}.get(keyval)
        if step is None:
            return False
        self.go(step)
        return True

    def show_view(self, view):
        if view in VIEWS and view != self.view:
            self.view = view
            self.main.store.set_meta("calendar_view", view)
            self.refresh()

    def go(self, step):
        """Back or forward one day, week or month; 0 comes back to today."""
        if not step:
            self.anchor = self.main.today
        elif self.view == "month":
            self.anchor = rules.add_months(self.anchor, step)
        else:
            days = step * (7 if self.view == "week" else 1)
            self.anchor = (date.fromisoformat(self.anchor) + timedelta(days=days)).isoformat()
        self.refresh()

    def tick(self):
        """Once a minute: move the line for now."""
        if self.get_visible() and (column := self.columns.get(self.main.today)):
            column.now = column.past_until = self.now_minutes()
            column.queue_draw()
        return GLib.SOURCE_CONTINUE

    def now_minutes(self):
        now = datetime.now()
        return now.hour * 60 + now.minute

    # ---- drawing ----

    def refresh(self):
        if self.body.get_child() is self.time_view:  # read before the grid may go: going, it scrolls to the top
            self.scroll = self.time_scroller.get_vadjustment().get_value()
        for column in self.grid_parts:
            column.clear()
        self.grid_parts = []
        unit = {"day": "day", "week": "week", "month": "month"}[self.view]
        self.back.set_tooltip_text(f"Previous {unit} ([)")
        self.forward.set_tooltip_text(f"Next {unit} (])")
        main = self.main
        self.projects = main.store.rows("project")
        self.archived = {p.id for p in self.projects.values() if p.get("archived")}
        self.day_length = (main.store.get_meta("calendar_grid", {}) or {}).get("dayLength", rules.DAY_LENGTH)
        if self.view == "month":
            self.columns = {}
            self.body.set_child(self.month())
        else:
            days = [self.anchor] if self.view == "day" else rules.week_dates(self.anchor, main.week_start)
            self.time_grid(days)

    def tasks_in(self, first, last):
        tasks = list(self.main.snap.all_tasks.values())
        days = rules.by_day(rules.calendar_tasks(tasks, self.archived, first, last))
        return days, rules.deadline_markers(tasks, self.archived, first, last)

    def load_label(self, tasks):
        planned, _, over = rules.day_load(tasks, self.day_length)
        if not planned:
            return None
        return Gtk.Label(label=f"{format_minutes(planned)} / {format_minutes(self.day_length)}", hexpand=True, xalign=1,
                         ellipsize=Pango.EllipsizeMode.END,
                         css_classes=["cal-load", *(["over"] if over else [])], tooltip_text="Planned against your day length")

    def deadline_label(self, task):
        return Gtk.Label(label="◆ " + (task.get("title") or ""), xalign=0, ellipsize=Pango.EllipsizeMode.END,
                         css_classes=["cal-deadline"], tooltip_text="Deadline")

    def more_button(self, tasks):
        more = Gtk.MenuButton(label=f"+{len(tasks)} more", halign=Gtk.Align.START, css_classes=["flat", "cal-more"])
        listing = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1, margin_top=6, margin_bottom=6,
                          margin_start=6, margin_end=6)
        for task in tasks:
            listing.append(self.task_line(task))
        more.set_popover(Gtk.Popover(child=listing))
        return more

    # Month

    def month(self):
        weeks = rules.month_grid(self.anchor, self.main.week_start)
        days, deadlines = self.tasks_in(weeks[0][0], weeks[-1][-1])
        self.title.set_title(date.fromisoformat(self.anchor).strftime("%B %Y"))
        self.title.set_subtitle("")
        grid = Gtk.Grid(column_homogeneous=True, hexpand=True, vexpand=True)
        for col, day in enumerate(weeks[0]):
            grid.attach(Gtk.Label(label=date.fromisoformat(day).strftime("%a"), xalign=0, css_classes=["cal-weekday"]),
                        col, 0, 1, 1)
        month, today = self.anchor[:7], self.main.today
        for row, week in enumerate(weeks, start=1):
            for col, day in enumerate(week):
                cell = self.month_cell(day, days.get(day, []), deadlines.get(day, []))
                for css, on in (("other-month", day[:7] != month), ("past", day < today), ("today", day == today)):
                    if on:
                        cell.add_css_class(css)
                grid.attach(cell, col, row, 1, 1)
        return grid

    def month_cell(self, day, tasks, deadlines):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1, vexpand=True, css_classes=["cal-cell"])
        top = Gtk.Box(spacing=4)
        top.append(Gtk.Label(label=str(int(day[8:])), xalign=0.5, css_classes=["cal-day"]))
        if load := self.load_label(tasks):
            top.append(load)
        box.append(top)
        for task in deadlines:
            box.append(self.deadline_label(task))
        rows, hidden = rules.visible_rows(tasks, max(1, MOST_ROWS - len(deadlines)))
        for task in rows:
            box.append(self.task_line(task))
        if hidden:
            box.append(self.more_button(tasks[len(rows):]))
        self.drop_on(box, box, lambda: ToDay(day))  # keeps its time, as in the web app's Month
        return box

    # Week and Day

    def time_grid(self, days):
        main = self.main
        first, last = days[0], days[-1]
        tasks, deadlines = self.tasks_in(first, last)
        start = date.fromisoformat(first)
        if len(days) == 1:
            self.title.set_title(start.strftime("%A %-d %B"))
            self.title.set_subtitle(str(start.year))
        else:
            end = date.fromisoformat(last)
            span = f"{start.day}–{end.day} {end:%b}" if start.month == end.month else f"{start:%-d %b} – {end:%-d %b}"
            self.title.set_title(span)
            self.title.set_subtitle(f"Week {start.isocalendar()[1]}, {end.year}")
        grid = (main.store.get_meta("calendar_grid", {}) or {})
        shade = (grid.get("startHour", rules.GRID["startHour"]) * 60, grid.get("endHour", rules.GRID["endHour"]) * 60)

        heads = Gtk.Box(css_classes=["cal-heads"])
        heads.append(Gtk.Box(width_request=GUTTER_PX))
        head_row = Gtk.Box(homogeneous=True, hexpand=True)
        heads.append(head_row)
        body = Gtk.Box()
        gutter = TimeColumn(decorate=False, width=GUTTER_PX)
        twelve = uses_12h(main.time_format)
        for hour in range(1, 24):
            gutter.add(Gtk.Label(label=format_time(time(hour), twelve), xalign=1, css_classes=["cal-hour"]),
                       hour * 60, None)
        body.append(gutter)
        self.grid_parts.append(gutter)
        columns = Gtk.Box(homogeneous=True, hexpand=True)
        body.append(columns)
        self.columns = {}
        for day in days:
            day_tasks = tasks.get(day, [])
            timed = [t for t in day_tasks if rules.block_for(t)]
            untimed = [t for t in day_tasks if not rules.block_for(t)]
            head_row.append(self.day_head(day, day_tasks, untimed, deadlines.get(day, []), len(days) == 1))
            column = self.time_column(day, timed, shade)
            columns.append(column)
            self.columns[day] = column
            self.grid_parts.append(column)

        self.time_heads.set_child(heads)
        self.time_viewport.set_child(body)
        if self.body.get_child() is self.time_view:
            return  # already showing: the scroll position holds
        self.body.set_child(self.time_view)
        wanted = self.scroll if self.scroll is not None else shade[0] * PX_PER_MINUTE
        scroller = self.time_scroller
        tries = iter(range(100))  # about three seconds, then give up (a hidden window never lays out)

        def restore():
            # Only once the grid is laid out: before that the value doesn't stick.
            if self.body.get_child() is not self.time_view or next(tries, None) is None:
                return GLib.SOURCE_REMOVE
            adjustment = scroller.get_vadjustment()
            if scroller.get_height() <= 0 or adjustment.get_upper() < DAY_MINUTES * PX_PER_MINUTE:
                return GLib.SOURCE_CONTINUE
            adjustment.set_value(wanted)
            return GLib.SOURCE_REMOVE

        GLib.timeout_add(30, restore)

    def day_head(self, day, tasks, untimed, deadlines, single):
        today = self.main.today
        head = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, css_classes=["cal-head"])
        for css, on in (("past", day < today), ("today", day == today)):
            if on:
                head.add_css_class(css)
        top = Gtk.Box(spacing=4)
        shown = date.fromisoformat(day)
        top.append(Gtk.Label(label=shown.strftime("%a"), css_classes=["cal-weekday"]))
        top.append(Gtk.Label(label=str(shown.day), css_classes=["cal-day"]))
        if load := self.load_label(tasks):
            top.append(load)
        head.append(top)
        for task in deadlines:
            head.append(self.deadline_label(task))
        lane = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1, css_classes=["cal-lane"],
                       tooltip_text="Unscheduled: due this day, no time")
        rows, hidden = rules.visible_rows(untimed, MOST_LANE * (3 if single else 1))
        for task in rows:
            lane.append(self.task_line(task))
        if hidden:
            lane.append(self.more_button(untimed[len(rows):]))
        head.append(lane)
        self.drop_on(head, head, lambda: ToSlot(day))  # the lane: this day, no time
        return head

    def time_column(self, day, timed, shade):
        column = TimeColumn()
        column.shade = shade
        today = self.main.today
        if day < today:
            column.past_until = DAY_MINUTES
        elif day == today:
            column.now = column.past_until = self.now_minutes()
        blocks = {t.id: t for t in timed}
        placed, overflow = rules.layout_day(
            [(t.id, *rules.block_for(t)[:2]) for t in timed], min_length=MIN_BLOCK_MINUTES)
        twelve = uses_12h(self.main.time_format)
        for b in placed:
            if b["hidden"]:
                continue
            task = blocks[b["id"]]
            estimated = rules.block_for(task)[2]
            project = self.projects.get(task.get("project_id"))
            column.add(self.block(task, b["start"], b["end"], estimated, twelve),
                       b["start"], max(MIN_BLOCK_MINUTES, b["end"] - b["start"]), b["lane"], b["lanes"],
                       color=(project.get("color") if project else None) or "", dashed=not estimated)
        for o in overflow:
            column.add(self.more_button([blocks[i] for i in o["ids"]]), o["start"], MIN_BLOCK_MINUTES,
                       o["lane"], o["lanes"])
        self.slot_drop(column, day)
        return column

    def block(self, task, start, end, estimated, twelve):
        title = task.get("title") or ""
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, css_classes=["cal-block"], overflow=Gtk.Overflow.HIDDEN)
        when = format_time(time(start // 60, start % 60), twelve)
        if estimated:
            when += "–" + format_time(time(end // 60 % 24, end % 60), twelve)
        tall = (end - start) >= 45
        label = Gtk.Label(label=title, xalign=0, ellipsize=Pango.EllipsizeMode.END, wrap=tall,
                          wrap_mode=Pango.WrapMode.WORD_CHAR, lines=3 if tall else 1)
        if tall:
            box.append(label)
            box.append(Gtk.Label(label=when, xalign=0, css_classes=["cal-time"]))
        else:
            line = Gtk.Box(spacing=4)
            line.append(Gtk.Label(label=when.split("–")[0], css_classes=["cal-time"]))
            line.append(label)
            box.append(line)
        box.set_tooltip_text(f"{title}\n{when}")
        self.open_on_click(box, task)
        self.main.drag.source(box, task.id, title)
        return box

    # ---- tasks, clicks and drops ----

    def task_line(self, task):
        line = Gtk.Box(spacing=5, css_classes=["cal-task"])
        project = self.projects.get(task.get("project_id"))
        line.append(Dot(project.get("color") if project else None, 7))
        if (start := rules.parse_time(rules.viewed_due(task)[1])) is not None:
            at = format_time(time(start // 60, start % 60), uses_12h(self.main.time_format))
            line.append(Gtk.Label(label=at, css_classes=["cal-time"]))
        title = task.get("title") or ""
        line.append(Gtk.Label(label=title, xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END,
                              tooltip_text=title))
        self.open_on_click(line, task)
        self.main.drag.source(line, task.id, title)
        return line

    def open_on_click(self, widget, task):
        click = Gtk.GestureClick()
        click.connect("released", lambda *_a: self.main.edit(task.id, parent=self))
        widget.add_controller(click)

    def accepts(self, task_id):
        return bool(task_id) and task_id in self.main.snap.all_tasks

    def drop_on(self, widget, marked, target_of):
        """A task dropped anywhere on widget goes to target_of()."""
        target = Gtk.DropTarget.new(GObject.TYPE_STRING, Gdk.DragAction.MOVE)
        target.connect("enter", lambda *_a: marked.add_css_class("drop-onto") or Gdk.DragAction.MOVE)
        target.connect("leave", lambda *_a: marked.remove_css_class("drop-onto"))

        def drop(_target, task_id, _x, _y):
            marked.remove_css_class("drop-onto")
            if not self.accepts(task_id):
                return False
            self.main.drop_task(task_id, target_of())
            return True

        target.connect("drop", drop)
        widget.add_controller(target)

    def slot_drop(self, column, day):
        """A task dropped on the grid starts at the 15-minute slot under the pointer, shown by a ghost first."""
        target = Gtk.DropTarget.new(GObject.TYPE_STRING, Gdk.DragAction.MOVE)

        def slot(y):
            minutes = int(y / PX_PER_MINUTE // SLOT_MINUTES * SLOT_MINUTES)
            return max(0, min(DAY_MINUTES - SLOT_MINUTES, minutes))

        def length():
            task = self.main.snap.all_tasks.get(self.main.drag.task_id or "")
            minutes = task.get("estimate_minutes") if task else None
            return minutes if isinstance(minutes, int) and minutes > 0 else rules.DEFAULT_BLOCK_MINUTES

        def motion(_target, _x, y):
            column.ghost = (slot(y), length())
            column.queue_draw()
            return Gdk.DragAction.MOVE

        def leave(_target):
            column.ghost = None
            column.queue_draw()

        def drop(_target, task_id, _x, y):
            leave(None)
            if not self.accepts(task_id):
                return False
            self.main.drop_task(task_id, ToSlot(day, hhmm(slot(y))))
            return True

        target.connect("motion", motion)
        target.connect("leave", leave)
        target.connect("drop", drop)
        column.add_controller(target)
