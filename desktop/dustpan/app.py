"""The desktop app: GTK 4 and libadwaita."""

import os
import sys
import threading
import time
from datetime import date, datetime

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango  # noqa: E402

from . import config  # noqa: E402
from .api import Api, ApiError, Offline  # noqa: E402
from .clock import wall_ms  # noqa: E402
from .dates import day_heading, day_start_minutes, format_due, format_minutes  # noqa: E402
from .dialogs import LabelDialog, ProjectDialog, TaskDialog, ViewDialog, ask_name  # noqa: E402
from .dragdrop import (AFTER, BEFORE, INSIDE, MOVES, Place, Slot, ToDay, ToLabel, ToProject,  # noqa: E402
                       describe as describe_drop, nudge, place_item, zone)
from .dragging import Autoscroll, Drag, ItemDrag, PageDrop, SidebarDrop  # noqa: E402
from .events import EventStream  # noqa: E402
from .filters import Context, FilterError, shift  # noqa: E402
from .labelpicker import LabelPicker  # noqa: E402
from .labels import ROW_CHIPS, carrying, duplicates, in_order, picker_order, remember, shown  # noqa: E402
from .markdown import first_line  # noqa: E402
from .model import count_open, order_key, project_path, project_sections, snapshot  # noqa: E402
from .reminders import describe, is_due, snooze_until  # noqa: E402
from .rowactions import RowActions, TaskRow  # noqa: E402
from .store import Store  # noqa: E402
from .sync import ClockSkew, Syncer, UnsupportedAccount  # noqa: E402
from .views import (WEEK_START, compare_tasks, group_tasks, in_today, manual_order, open_count, run_query,  # noqa: E402
                    run_view, sorted_tasks, today_groups, upcoming_groups, view_options)
from .widgets import (CSS, INDENT_PX, Dot, ThemeFollower, escape, flash, label_chip, on_right_click, popup_menu,  # noqa: E402
                      save_screenshot, scroll_into_view)
from .writes import CannotEdit, Writer, descendants, live, project_descendants  # noqa: E402

SYNC_INTERVAL_S = 30
LIVE_SYNC_INTERVAL_S = 5 * 60  # polling relaxes while the live stream is connected
EDIT_SYNC_DELAY_MS = 250
# Sidebar keys. A project's key is its id; a saved view's is VIEW + its id; an archived project's ARCHIVED + its id;
# a label's LABEL + its id.
INBOX, TODAY, UPCOMING, VIEW, ARCHIVED, LABEL = "inbox", "today", "upcoming", "view:", "archived:", "label:"
RECENT_LABELS = "recent_labels"  # store meta: labels assigned lately on this device, newest first
# On first start, reminders that fired longer ago than this are not shown.
STALE_REMINDER_MS = 24 * 60 * 60_000


class Window(Adw.ApplicationWindow):
    def __init__(self, app, cfg):
        # Closing only hides the window, so sync and reminders carry on. Ctrl+Q quits.
        super().__init__(application=app, title="Dustpan", default_width=1000, default_height=700, hide_on_close=True)
        self.cfg = cfg
        self.store = Store(config.database_path())
        self.writer = Writer(self.store)
        self.selected = TODAY
        self.shown = None
        self.syncing = False
        self.sync_again = False
        self.sync_timer = 0
        self.last_sync = 0.0
        self.live = False
        self.rebuilding = False
        self.time_format = "system"
        self.adding = None  # (page key, section id) of the open add-task entry
        self.add_entry = None
        self.add_text = ""
        # Dragging: a refresh would rebuild the page under the pointer, so it waits for the drop.
        self.drag = Drag(on_end=self.after_drag)
        self.item_drag = ItemDrag(on_end=self.after_drag)  # a sidebar row being reordered
        self.refresh_waiting = False
        self.page_stale = False  # changes came in while hidden; rebuild when shown
        self.page_drop = None
        self.task_widgets = {}  # task id -> row on the shown page
        self.flash_task = None  # the task to highlight once the page is rebuilt
        self.focus_task = None  # the task row to focus once the page is rebuilt
        self.row_actions = RowActions(self)
        self.last_toast = None
        self.toast_undo = None

        self.sidebar = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.sidebar.add_css_class("navigation-sidebar")
        self.sidebar.connect("row-selected", self.on_row_selected)
        self.sidebar_drop = SidebarDrop(self.sidebar, self.drag, self.sidebar_target, self.drop_task, self.sidebar.select_row,
                                        springs=lambda row: not getattr(row, "key", "").startswith(LABEL),
                                        items=self.item_drag, place_of=self.sidebar_place, on_place=self.drop_item)
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_sidebar_key)
        self.sidebar.add_controller(keys)
        sidebar_scroll = Gtk.ScrolledWindow(child=self.sidebar, vexpand=True)
        sidebar_view = Adw.ToolbarView(content=sidebar_scroll)
        sidebar_view.add_top_bar(Adw.HeaderBar(title_widget=Adw.WindowTitle(title="Dustpan")))

        self.title = Adw.WindowTitle(title="Today")
        refresh = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Sync now")
        refresh.connect("clicked", lambda _b: self.sync())
        self.add_button = Gtk.Button(icon_name="list-add-symbolic", tooltip_text="Add task (Ctrl+N)")
        self.add_button.connect("clicked", lambda _b: self.start_adding(None))
        self.edit_button = Gtk.Button(icon_name="document-edit-symbolic")
        self.edit_button.connect("clicked", lambda _b: self.edit_page())
        header = Adw.HeaderBar(title_widget=self.title)
        header.pack_start(self.add_button)
        header.pack_start(self.edit_button)
        header.pack_end(refresh)
        # Never sideways: a long row would let focus scroll the page off to one side.
        self.content = Gtk.ScrolledWindow(vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.autoscrolls = [Autoscroll(sidebar_scroll),
                            Autoscroll(self.content, lambda dy: self.page_drop and self.page_drop.scrolled(dy))]
        content_view = Adw.ToolbarView(content=self.content)
        content_view.add_top_bar(header)

        split = Adw.NavigationSplitView(
            sidebar=Adw.NavigationPage(child=sidebar_view, title="Dustpan"),
            content=Adw.NavigationPage(child=content_view, title="Tasks"),
            min_sidebar_width=220,
        )
        self.toasts = Adw.ToastOverlay(child=split)
        self.set_content(self.toasts)
        self.set_size_request(360, 300)
        # Tiled windows are often narrow: show the sidebar and the tasks as separate pages.
        narrow = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 560sp"))
        narrow.add_setter(split, "collapsed", True)
        self.add_breakpoint(narrow)
        self.split = split

        shortcuts = Gtk.ShortcutController(scope=Gtk.ShortcutScope.GLOBAL)
        shortcuts.add_shortcut(Gtk.Shortcut(
            trigger=Gtk.ShortcutTrigger.parse_string("<Control>n"),
            action=Gtk.CallbackAction.new(lambda *_a: self.start_adding(None) or True)))
        shortcuts.add_shortcut(Gtk.Shortcut(
            trigger=Gtk.ShortcutTrigger.parse_string("<Control>z"),
            action=Gtk.CallbackAction.new(lambda *_a: self.undo_last())))
        for key, end in (("j", 0), ("k", -1)):
            shortcuts.add_shortcut(Gtk.Shortcut(
                trigger=Gtk.ShortcutTrigger.parse_string(key),
                action=Gtk.CallbackAction.new(lambda *_a, end=end: self.enter_list(end))))
        self.add_controller(shortcuts)

        self.refresh_view()
        self.sync()
        GLib.timeout_add_seconds(SYNC_INTERVAL_S, self.on_timer)
        with self.store.transaction():
            device = self.store.device()
        self.events = EventStream(
            Api(cfg.url, cfg.token), device,
            on_wake=lambda cursor: GLib.idle_add(self.on_wake, cursor),
            on_live=lambda live: GLib.idle_add(self.on_live, live))
        self.events.start()
        self.connect("destroy", lambda _w: self.events.stop())
        self.connect("map", lambda _w: self.page_stale and self.refresh_view())

    def toast(self, text, undo=None):
        """A new toast replaces the shown one, so Undo always means the latest action."""
        if self.last_toast is not None:
            self.last_toast.dismiss()
        toast = self.last_toast = Adw.Toast(title=escape(text), timeout=5)
        self.toast_undo = undo
        if undo:
            toast.set_button_label("Undo")
            toast.connect("button-clicked", lambda _t: undo())
        toast.connect("dismissed", self.on_toast_dismissed)
        self.toasts.add_toast(toast)

    def on_toast_dismissed(self, toast):
        if toast is self.last_toast:
            self.last_toast = self.toast_undo = None

    def undo_last(self):
        """Ctrl+Z: the Undo of the toast on screen. False lets the key through, to a text field say."""
        undo = self.toast_undo
        if undo is None:
            return False
        self.last_toast.dismiss()
        undo()
        return True

    # ---- sync ----

    def on_timer(self):
        self.check_reminders()
        interval = LIVE_SYNC_INTERVAL_S if self.live else SYNC_INTERVAL_S
        if time.monotonic() - self.last_sync >= interval - 1:
            self.sync()
        # Today and Upcoming move at midnight (or the user's day start).
        if self.writer.today() != self.today:
            self.refresh_view()
        return GLib.SOURCE_CONTINUE

    def on_wake(self, cursor):
        if cursor is None or cursor > self.store.get_meta("cursor", 0):
            self.sync()
        return GLib.SOURCE_REMOVE

    def on_live(self, live):
        self.live = live
        return GLib.SOURCE_REMOVE

    def schedule_sync(self):
        """Sync shortly after a local edit. Several quick edits share one exchange."""
        if not self.sync_timer:
            self.sync_timer = GLib.timeout_add(EDIT_SYNC_DELAY_MS, self.on_edit_timer)

    def on_edit_timer(self):
        self.sync_timer = 0
        self.sync()
        return GLib.SOURCE_REMOVE

    def sync(self):
        if self.syncing:
            self.sync_again = True
            return
        self.syncing = True
        self.title.set_subtitle("Syncing…")
        threading.Thread(target=self.sync_worker, daemon=True).start()

    def sync_worker(self):
        # SQLite connections stay on their own thread, so the worker opens its own.
        store = Store(config.database_path())
        result = None
        try:
            result = Syncer(store, Api(self.cfg.url, self.cfg.token)).run()
            message = f"Synced {datetime.now():%H:%M}"
        except Offline:
            message = "Offline"
        except UnsupportedAccount as err:
            message = f"Can't sync: {err}"
        except (ApiError, ClockSkew) as err:
            message = f"Sync error: {err}"
        except Exception as err:  # a bug in this client; keep the app alive and say so
            print(f"sync failed: {err!r}", file=sys.stderr)
            message = "Sync error (see terminal)"
        finally:
            store.close()
        GLib.idle_add(self.on_sync_done, result, message)

    def on_sync_done(self, result, message):
        self.syncing = False
        self.last_sync = time.monotonic()
        waiting = self.store.outbox_count()
        if result and result.held:
            message += f" · {result.held} held by a server limit"
        elif waiting and not self.sync_again:
            message += f" · {waiting} waiting"
        self.title.set_subtitle(message)
        if result and result.refused:
            self.toast(f"{result.refused} change{'s' if result.refused > 1 else ''} not accepted by the server")
        if result and (result.received or result.refused):
            self.refresh_view()
        if self.sync_again:
            self.sync_again = False
            self.sync()
        return GLib.SOURCE_REMOVE

    # ---- sidebar ----

    def refresh_view(self):
        if self.drag.active or self.item_drag.active:
            self.refresh_waiting = True
            return
        if not self.get_mapped() and hasattr(self, "snap"):
            # Hidden: reminders still matter, the page doesn't. Skip the rebuild until it's shown.
            self.page_stale = True
            self.check_reminders()
            return
        self.page_stale = False
        self.snap = snapshot(self.store)
        self.reminders_by_task = {}
        for reminder in self.store.rows("reminder").values():
            if live(reminder):
                self.reminders_by_task.setdefault(reminder.get("task_id"), []).append(reminder)
        self.check_reminders()
        prefs = self.store.rows("user_prefs").get("me")
        prefs = prefs.values if prefs else {}
        self.time_format = prefs.get("time_format", "system")
        self.today = self.writer.today()
        self.filter_context = Context(self.today, list(self.snap.all_tasks.values()), list(self.snap.labels.values()),
                                      self.snap.live_projects, WEEK_START.get(prefs.get("week_start"), 1),
                                      day_start_minutes(prefs.get("day_start")))
        self.rebuild_sidebar()
        self.show_page(self.selected)

    def rebuild_sidebar(self):
        self.sidebar.unselect_all()
        self.sidebar.remove_all()
        self.rows_by_key = {}
        self.project_paths = []  # (id, "Parent › Child") in sidebar order, for headings
        self.add_sidebar_row(TODAY, "Today", 0, icon="starred-symbolic",
                             count=sum(in_today(t, self.today) for t in self.snap.tasks))
        self.add_sidebar_row(UPCOMING, "Upcoming", 0, icon="x-office-calendar-symbolic")
        self.add_sidebar_row(INBOX, "Inbox", 0, icon="mail-inbox-symbolic", count=count_open(self.snap, None, self.today))

        new_project = Gtk.Button(icon_name="list-add-symbolic", tooltip_text="New project", css_classes=["flat"])
        new_project.connect("clicked", lambda _b: self.open_project_dialog(None))
        self.add_sidebar_heading("Projects", new_project)

        def walk(nodes, depth, path, parent_id):
            for node in nodes:
                name = node.row.get("name", "")
                self.project_paths.append((node.id, " › ".join(path + [name])))
                self.add_sidebar_row(node.id, name, depth, color=node.row.get("color"),
                                     count=count_open(self.snap, node.id, self.today),
                                     menu=lambda pid=node.id: self.project_menu(pid),
                                     item=("project", node.id, parent_id, [c.id for c in node.children]))
                walk(node.children, depth + 1, path + [name], node.id)

        walk(self.snap.projects, 0, [], None)

        new_label = Gtk.Button(icon_name="list-add-symbolic", tooltip_text="New label", css_classes=["flat"])
        new_label.connect("clicked", lambda _b: self.open_label_dialog(None))
        self.add_sidebar_heading("Labels", new_label)
        counts = {}
        for task in self.snap.tasks:
            if open_count(task, self.today):
                for label_id in set(task.get("labels") or []):
                    counts[label_id] = counts.get(label_id, 0) + 1
        twins = duplicates(self.snap.labels.values())
        for label in in_order(self.snap.labels.values()):
            self.add_sidebar_row(LABEL + label.id, label.get("name", ""), 0, color=label.get("color"),
                                 count=counts.get(label.id, 0), menu=lambda lid=label.id: self.label_menu(lid),
                                 item=("label", label.id, None, []),
                                 warning="Another label has this name. Merge them from this label's menu."
                                 if label.id in twins else None)

        new_view = Gtk.Button(icon_name="list-add-symbolic", tooltip_text="New view", css_classes=["flat"])
        new_view.connect("clicked", lambda _b: self.open_view_dialog(None))
        self.add_sidebar_heading("Views", new_view)
        for view in self.snap.views:
            try:
                count = run_query(view.get("query") or "", self.filter_context, self.snap.tasks)[1]
            except FilterError:
                count = 0
            self.add_sidebar_row(VIEW + view.id, view.get("name", ""), 0, icon="view-list-symbolic", count=count,
                                 menu=lambda vid=view.id: self.view_menu(vid), item=("view", view.id, None, []))

        projects = {p.id: p for p in self.snap.live_projects}
        archived = sorted(((project_path(p.id, projects), p) for p in self.snap.live_projects if p.get("archived")),
                          key=lambda item: (item[0].casefold(), item[1].id))
        if archived:
            self.add_sidebar_heading("Archived")
        for path, project in archived:
            self.add_sidebar_row(ARCHIVED + project.id, path, 0, color=project.get("color"),
                                 menu=lambda pid=project.id: self.archived_menu(pid))

        target = self.rows_by_key.get(self.selected) or self.rows_by_key[TODAY]
        self.rebuilding = True
        self.sidebar.select_row(target)
        self.rebuilding = False

    def add_sidebar_heading(self, text, button=None):
        box = Gtk.Box(margin_top=12, margin_start=6)
        heading = Gtk.Label(label=text, xalign=0, hexpand=True, css_classes=["heading", "dim-label"])
        box.append(heading)
        if button:
            box.append(button)
        self.sidebar.append(Gtk.ListBoxRow(child=box, selectable=False, activatable=False))

    def add_sidebar_row(self, key, name, depth, icon=None, color=None, count=0, menu=None, warning=None, item=None):
        """menu() gives the sections of the row's right-click menu, for popup_menu. warning: a marker's tooltip.

        item: (kind, id, parent id, child ids) for a row that can be dragged to reorder it among its kind.
        """
        box = Gtk.Box(spacing=10, margin_start=6 + depth * INDENT_PX // 2)
        box.append(Gtk.Image(icon_name=icon) if icon else Dot(color))
        box.append(Gtk.Label(label=name, xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END))
        if warning:
            box.append(Gtk.Image(icon_name="dialog-warning-symbolic", tooltip_text=warning, css_classes=["warning"]))
        if count:
            number = Gtk.Label(label=str(count))
            number.add_css_class("dim-label")
            box.append(number)
        row = Gtk.ListBoxRow(child=box)
        row.key = key
        row.name = name
        if menu:
            on_right_click(row, lambda x, y: popup_menu(row, menu(), x, y))
        row.item = item
        if item:
            self.item_drag.source(row, item[0], item[1], name)
        self.rows_by_key[key] = row
        self.sidebar.append(row)

    def on_row_selected(self, _box, row):
        if row is None or not getattr(row, "key", None):
            return
        if row.key != self.selected:
            self.selected = row.key
            self.adding = None
            self.show_page(row.key)
        if not self.rebuilding:
            self.split.set_show_content(True)

    # ---- pages ----

    def show_page(self, key):
        row = self.rows_by_key.get(key)
        if row is None:  # the project or view went away
            key, row = TODAY, self.rows_by_key[TODAY]
            self.selected = TODAY
            self.adding = None
        self.title.set_title(row.name)
        is_view, is_archived, is_label = key.startswith(VIEW), key.startswith(ARCHIVED), key.startswith(LABEL)
        self.add_button.set_visible(not is_view and not is_archived)
        self.edit_button.set_visible(is_view or is_label or self.page_project() is not None)
        self.edit_button.set_tooltip_text("Edit view" if is_view else "Edit label" if is_label else "Edit project")
        if self.add_entry is not None:
            self.add_text = self.add_entry.get_text()
            self.add_entry = None
        # Redrawing the same list keeps its scroll position, and the focused task.
        scroll = self.content.get_vadjustment().get_value() if key == self.shown else 0
        if key == self.shown and self.focus_task is None:
            self.focus_task = self.focused_task()
        self.shown = key

        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, margin_top=12, margin_bottom=24,
                         margin_start=16, margin_end=16)
        self.page_drop = PageDrop(column, self.drag, self.drop_task)
        self.task_widgets = {}
        if key == TODAY:
            self.fill_groups(column, today_groups(self.snap.tasks, self.today),
                             lambda group: ToDay(self.today) if group.key == "today" else None)
            column.append(self.add_task_row(None))
        elif key == UPCOMING:
            self.fill_groups(column, upcoming_groups(self.snap.tasks, self.today, self.day_heading),
                             lambda group: ToDay(group.key))
            column.append(self.add_task_row(None))
        elif is_view:
            self.fill_view(column, next(v for v in self.snap.views if v.id == key[len(VIEW):]))
        elif is_archived:
            self.fill_archived(column, key[len(ARCHIVED):])
        elif is_label:
            self.fill_label(column, self.snap.labels[key[len(LABEL):]])
        else:
            self.fill_project(column, None if key == INBOX else key)
        self.content.set_child(Adw.Clamp(child=self.page_drop.widget, maximum_size=760))
        GLib.idle_add(self.after_page, scroll, self.task_widgets.get(self.flash_task),
                      self.task_widgets.get(self.focus_task))
        self.flash_task = self.focus_task = None
        if self.add_entry is not None:
            GLib.idle_add(self.focus_add_entry)

    def after_page(self, scroll, moved, focus):
        """Once the new page is laid out: its old scroll position, the moved row in view and flashing, the focus."""
        if scroll:
            self.content.get_vadjustment().set_value(scroll)
        if moved is not None:
            scroll_into_view(self.content, moved)
            flash(moved)
        if focus is not None:
            focus.grab_focus()
        return GLib.SOURCE_REMOVE

    def focused_task(self):
        """The id of the task whose row has the keyboard focus, if any."""
        rows = {widget: task_id for task_id, widget in self.task_widgets.items()}
        widget = self.get_focus()
        while widget is not None and widget not in rows:
            widget = widget.get_parent()
        return rows.get(widget)

    def note(self, column, text, css="dim-label"):
        column.append(Gtk.Label(label=text, xalign=0, wrap=True, margin_top=12, margin_bottom=8, css_classes=[css]))

    def heading(self, column, text, menu=None):
        """A heading. menu() gives the sections of its menu, opened by its button or a right-click."""
        label = Gtk.Label(label=text, xalign=0, hexpand=True, wrap=True, css_classes=["heading"])
        if menu is None:
            label.add_css_class("section-heading")
            column.append(label)
            return label
        box = Gtk.Box(spacing=6, css_classes=["section-heading"])
        box.append(label)
        button = Gtk.Button(icon_name="view-more-symbolic", tooltip_text="Section menu", valign=Gtk.Align.CENTER,
                            css_classes=["flat", "circular"])
        button.connect("clicked", lambda _b: popup_menu(button, menu()))
        box.append(button)
        on_right_click(box, lambda x, y: popup_menu(box, menu(), x, y))
        column.append(box)
        return box

    def fill_project(self, column, project_id):
        """A project's or the Inbox's sections. Each real list takes drops: between rows, inside one, at its ends."""
        sections = project_sections(self.snap, project_id)
        if not any(s.tasks for s in sections) and len(sections) == 1 and self.adding is None:
            self.note(column, "Nothing to do here.")
        for sec in sections:
            menu = (lambda sid=sec.id: self.section_menu(sid)) if sec.id else None
            heading = self.heading(column, sec.name, menu) if sec.name else None
            rows = []
            self.add_tasks(column, sec.tasks, 0, None, rows)
            if sec.is_list:
                end = self.add_task_row(sec.id)
                column.append(end)
                self.page_drop.add_list(project_id, sec.id, heading, rows, end)
        if project_id is not None:
            box = Gtk.Box(spacing=8)
            box.append(Gtk.Image(icon_name="list-add-symbolic"))
            box.append(Gtk.Label(label="Add section"))
            button = Gtk.Button(child=box, halign=Gtk.Align.START, margin_top=24, css_classes=["flat", "dim-label"])
            button.connect("clicked", lambda _b: self.add_section(project_id))
            column.append(button)

    def fill_archived(self, column, project_id):
        self.note(column, "This project is archived. Its tasks are hidden until it's unarchived.")
        buttons = Gtk.Box(spacing=12, halign=Gtk.Align.START)
        unarchive = Gtk.Button(label="Unarchive", css_classes=["pill", "suggested-action"])
        unarchive.connect("clicked", lambda _b: self.unarchive_project(project_id))
        buttons.append(unarchive)
        delete = Gtk.Button(label="Delete", css_classes=["pill", "destructive-action"])
        delete.connect("clicked", lambda _b: self.delete_project(project_id))
        buttons.append(delete)
        column.append(buttons)

    def fill_groups(self, column, groups, target_of=lambda group: None):
        """Flat lists: Today, Upcoming and saved views. Each row says where its task lives.

        target_of(group) gives the drop target for a whole group, such as its day, or None.
        """
        if not groups and self.adding is None:
            self.note(column, "Nothing to do here.")
        for group in groups:
            heading = self.heading(column, group.heading) if group.heading else None
            rows = [self.task_row(task, 0, placed=True) for task in group.tasks]
            for row in rows:
                column.append(row)
            target = target_of(group)
            if target is not None and heading is not None:
                self.page_drop.add_group(target, heading, [heading, *rows])

    def fill_view(self, column, view):
        column.append(Gtk.Label(label=view.get("query") or "", xalign=0, wrap=True, selectable=True, margin_bottom=8,
                                css_classes=["dim-label", "monospace"]))
        result = run_view(view, self.filter_context, self.snap.tasks, self.labels_in_order(), self.project_paths,
                          self.day_heading)
        if result.error:
            self.note(column, f"This query can't run here: {result.error}", "error")
            return
        for warning in result.warnings:
            self.note(column, warning, "warning")
        self.fill_groups(column, result.groups)

    def fill_label(self, column, label):
        """A label's open tasks across projects, grouped by project unless the label says otherwise.
        Quick add here gives the label."""
        tasks = [t for t in self.snap.tasks if open_count(t, self.today) and label.id in (t.get("labels") or [])]
        group_by, sort_by, sort_dir = view_options(label)
        comparator = manual_order(label.get("manual_order"), sort_dir) if sort_by == "position" else \
            compare_tasks(sort_by, sort_dir)
        groups = group_tasks(sorted_tasks(tasks, comparator), group_by, self.today, self.labels_in_order(),
                             self.project_paths, self.day_heading)
        if not tasks:
            self.note(column, "No open tasks have this label. Add one below, or press L on any task.")
        else:
            self.fill_groups(column, groups)
        column.append(self.add_task_row(None))

    def labels_in_order(self):
        return sorted(self.snap.labels.values(), key=order_key)

    def day_heading(self, day):
        return day_heading(day, self.today)

    def add_tasks(self, column, nodes, depth, parent_id, rows):
        """A project's task trees. Each row is added to rows as (Slot, widget), in display order."""
        for node in nodes:
            row = self.task_row(node.row, depth)
            rows.append((Slot(node.id, depth, parent_id), row))
            column.append(row)
            self.add_tasks(column, node.children, depth + 1, node.id, rows)

    # ---- dragging ----

    def sidebar_target(self, row):
        """What a task dropped on a sidebar row gets: a date for Today, a new home for the Inbox or a project,
        or a label."""
        key = getattr(row, "key", None)
        if key and key.startswith(LABEL):
            return ToLabel(key[len(LABEL):])
        if key == TODAY:
            return ToDay(self.today)
        if key == INBOX:
            return ToProject(None)
        if key and key != UPCOMING and not key.startswith((VIEW, ARCHIVED, LABEL)):
            return ToProject(key)
        return None

    # ---- reordering the sidebar (spec/dragdrop.md, "In the sidebar") ----

    def sidebar_place(self, row, offset, height):
        """(ItemPlace, css class) for the dragged sidebar row over row, offset pixels down it. Only its own kind."""
        info, kind, item_id = getattr(row, "item", None), self.item_drag.kind, self.item_drag.item_id
        if not info or info[0] != kind:
            return None
        where = zone(offset, height, inside=kind == "project")
        below = {p.id for p in project_descendants(item_id, self.store.rows("project"))} if kind == "project" else ()
        place = place_item(info[1], info[2], info[3], where, item_id, below)
        if place is None:
            return None
        return place, {BEFORE: "drop-before", AFTER: "drop-after", INSIDE: "drop-inside"}[where]

    def drop_item(self, kind, item_id, place):
        # Not inside the drop signal: the write rebuilds the sidebar that sent it.
        GLib.idle_add(lambda: self.place_sidebar_item(kind, item_id, place) and False)

    def place_sidebar_item(self, kind, item_id, place):
        if kind == "project":
            before = self.store.rows("project").get(item_id)
            old_parent = before.get("parent_id") if before else None
            done = self.run(self.writer.place_project, item_id, place.parent_id, place.before, place.after)
            if place.parent_id == old_parent:
                text = "Order changed"
            elif place.parent_id is None:
                text = f"Moved “{self.own_name(item_id)}” to the top level"
            else:
                text = f"Moved “{self.own_name(item_id)}” under “{self.own_name(place.parent_id)}”"
        else:
            write = self.writer.place_label if kind == "label" else self.writer.place_view
            done, text = self.run(write, item_id, place.before, place.after), "Order changed"
        if done and done.undo:
            self.toast(text, undo=lambda: self.run(self.writer.revert, done.undo))

    def own_name(self, project_id):
        """A project's name without its path, for toasts."""
        project = self.store.rows("project").get(project_id)
        return project.get("name", "") if project else ""

    def on_sidebar_key(self, _controller, keyval, _code, state):
        """Alt+↑ and Alt+↓ move the focused project, label or view among its own kind, as the menus do."""
        mods = state & (Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK)
        if keyval not in (Gdk.KEY_Up, Gdk.KEY_Down) or mods != Gdk.ModifierType.ALT_MASK:
            return False
        row = self.get_focus()
        while row is not None and not isinstance(row, Gtk.ListBoxRow):
            row = row.get_parent()
        info = getattr(row, "item", None)
        if not info:
            return False
        self.move_sidebar_item(info[0], info[1], -1 if keyval == Gdk.KEY_Up else 1)
        return True

    def move_sidebar_item(self, kind, item_id, step):
        """One place up or down among its siblings. The row keeps the keyboard focus."""
        write = {"project": self.writer.move_project, "label": self.writer.move_label, "view": self.writer.move_view}[kind]
        key = {"project": "", "label": LABEL, "view": VIEW}[kind] + item_id
        if self.run(write, item_id, step):
            GLib.idle_add(lambda: (row := self.rows_by_key.get(key)) is not None and row.grab_focus() and False)

    def sibling_moves(self, kind, item_id):
        """Move up and Move down for a sidebar menu, greyed out at the ends of its siblings."""
        info = self.rows_by_key[{"project": "", "label": LABEL, "view": VIEW}[kind] + item_id].item
        siblings = [r.item[1] for r in self.rows_by_key.values() if r.item and r.item[0] == kind and r.item[2] == info[2]]
        index = siblings.index(item_id)
        return [("Move up", lambda: self.move_sidebar_item(kind, item_id, -1), index > 0),
                ("Move down", lambda: self.move_sidebar_item(kind, item_id, 1), index < len(siblings) - 1)]

    def drop_task(self, task_id, target):
        # Not inside the drop signal: the drop rebuilds the page that sent it.
        GLib.idle_add(self.apply_drop, task_id, target)

    def apply_drop(self, task_id, target):
        task = self.store.rows("task").get(task_id)
        self.flash_task = self.focus_task = task_id
        done = self.run(self.writer.drop, task_id, target)
        if done and done.undo:
            self.toast(describe_drop(target, task, self.names(), self.day_text),
                       undo=lambda: self.run(self.writer.revert, done.undo))
        else:
            self.flash_task = self.focus_task = None
            if done and isinstance(target, ToLabel):
                self.toast(f"It already has {self.label_name(target.label_id)}")
        return GLib.SOURCE_REMOVE

    # ---- keys and the row menu (rowactions.py) ----

    def moves(self, task_id):
        """Where each keyboard move would take a task, or None on a page that isn't a list."""
        owner = self.page_drop.list_of(task_id) if self.page_drop else None
        if owner is None:
            return None
        return {move: nudge(owner.slots, owner.project_id, owner.section_id, task_id, move) for move in MOVES}

    def move(self, task_id, move):
        target = (self.moves(task_id) or {}).get(move)
        if target is not None:
            self.apply_drop(task_id, target)

    def enter_list(self, end):
        """j or k from outside the list, as in the web app: focus its first or last task. Typing is left alone."""
        focus = self.get_focus()
        if (not self.task_widgets or self.get_visible_dialog() is not None
                or isinstance(focus, (Gtk.Editable, Gtk.TextView))):
            return False
        list(self.task_widgets.values())[end].grab_focus()
        return True

    def step(self, task_id, n):
        order = list(self.task_widgets)
        i = order.index(task_id) + n
        if 0 <= i < len(order):
            self.task_widgets[order[i]].grab_focus()

    def leaving(self, task_id):
        """The task's row is about to go: focus the next one when the page is rebuilt."""
        order = list(self.task_widgets)
        i = order.index(task_id)
        rest = order[i + 1:] + order[:i][::-1]
        gone = {task_id, *(d.id for d in descendants(task_id, self.snap.all_tasks))}
        self.focus_task = next((other for other in rest if other not in gone), None)

    def days(self):
        return [("Due today", ToDay(self.today)), ("Due tomorrow", ToDay(shift(self.today, 1)))]

    def places(self):
        """Move to: the Inbox and each project; a project with sections lists them."""
        out = [("Inbox", Place(None, None), [])]
        for project_id, path in self.project_paths:
            sections = self.snap.sections_by_project.get(project_id, [])
            if sections:
                out.append((path, None, [("No section", Place(project_id, None))] +
                            [(s.get("name", ""), Place(project_id, s.id)) for s in sections]))
            else:
                out.append((path, Place(project_id, None), []))
        return out

    def after_drag(self):
        for autoscroll in self.autoscrolls:
            autoscroll.aim(None)
        if self.refresh_waiting:
            self.refresh_waiting = False
            self.refresh_view()

    def names(self):
        """Ids of tasks, sections, projects and labels to what the user calls them."""
        names = {t.id: t.get("title", "") for t in self.snap.all_tasks.values()}
        names.update((s.id, s.get("name", "")) for s in self.store.rows("section").values())
        names.update(self.project_paths)
        names.update((label.id, label.get("name", "")) for label in self.snap.labels.values())
        return names

    # ---- rows ----

    def task_row(self, task, depth, placed=False):
        """placed: also show the task's project, and its parent for a subtask. An open task's row can be dragged."""
        row = TaskRow(spacing=12, margin_start=depth * INDENT_PX)
        row.add_css_class("task-row")
        self.task_widgets[task.id] = row
        done = task.get("completed_at") is not None
        if not done:
            self.drag.source(row, task.id, task.get("title", ""), lambda: sum(
                d.get("completed_at") is None for d in descendants(task.id, self.snap.all_tasks)))
        self.row_actions.attach(row, task.id, done)

        check = Gtk.Button(child=Gtk.Image(icon_name="object-select-symbolic"), valign=Gtk.Align.START,
                           tooltip_text="Reopen" if done else "Complete (c)", focusable=False)
        check.add_css_class("task-check")
        priority = task.get("priority")
        if done:
            check.add_css_class("done")
        elif priority in (1, 2, 3):
            check.add_css_class(f"p{priority}")
        check.connect("clicked", lambda _b: self.reopen(task.id) if done else self.complete(task.id))
        row.append(check)

        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, hexpand=True)
        text.add_css_class("task-text")
        title = Gtk.Label(label=task.get("title", ""), xalign=0, wrap=True,
                          wrap_mode=Pango.WrapMode.WORD_CHAR)
        if done:
            title.add_css_class("dim-label")
        text.append(title)
        if note := first_line(task.get("description") or ""):
            text.append(Gtk.Label(label=note, xalign=0, ellipsize=Pango.EllipsizeMode.END,
                                  css_classes=["dim-label", "task-note"]))

        # The details wrap onto more lines when the window is narrow.
        meta = Adw.WrapBox(child_spacing=10, line_spacing=2, hexpand=True)
        due = format_due(task.get("due"), time_format=self.time_format)
        if due:
            label = Gtk.Label(label=due.text)
            label.add_css_class(f"due-{due.state}" if due.state != "later" and not done else "dim-label")
            meta.append(label)
        if deadline := task.get("deadline"):
            late = deadline < self.today and not done
            meta.append(Gtk.Label(label="Deadline " + self.day_text(deadline),
                                  css_classes=["due-overdue" if late else "dim-label"]))
        if task.get("recurrence"):
            meta.append(Gtk.Label(label="↻", tooltip_text=task.get("recurrence"), css_classes=["dim-label"]))
        if reminders := self.reminders_by_task.get(task.id):
            meta.append(Gtk.Image(icon_name="alarm-symbolic", css_classes=["dim-label"],
                                  tooltip_text="\n".join(describe(r) for r in reminders)))
        if minutes := task.get("estimate_minutes"):
            meta.append(Gtk.Label(label=format_minutes(minutes), css_classes=["dim-label"]))
        if labels := shown(task.get("labels"), self.snap.labels, skip=self.page_label()):
            for label in labels[:ROW_CHIPS]:
                meta.append(label_chip(label.get("name", ""), label.get("color")))
            if more := labels[ROW_CHIPS:]:
                meta.append(Gtk.Label(label=f"+{len(more)}", css_classes=["label-chip", "more"],
                                      tooltip_text=", ".join(label.get("name", "") for label in labels)))
        line = Gtk.Box(spacing=10, css_classes=["task-meta"])
        if meta.get_first_child():
            line.append(meta)
        if placed:
            line.append(Gtk.Label(label=self.place_of(task), hexpand=True, xalign=1, valign=Gtk.Align.END,
                                  ellipsize=Pango.EllipsizeMode.END, css_classes=["dim-label"]))
        if line.get_first_child():
            text.append(line)
        row.append(text)
        return row

    def place_of(self, task):
        """ "Project" or "Project › Parent task"."""
        names = dict(self.project_paths)
        place = names.get(task.get("project_id"), "Inbox")
        parent = self.snap.all_tasks.get(task.get("parent_id"))
        return f"{place} › {parent.get('title', '')}" if parent else place

    # ---- adding ----

    def add_task_row(self, section_id):
        if self.adding != (self.selected, section_id):
            box = Gtk.Box(spacing=8)
            box.append(Gtk.Image(icon_name="list-add-symbolic"))
            box.append(Gtk.Label(label="Add task"))
            button = Gtk.Button(child=box, halign=Gtk.Align.START, css_classes=["flat", "dim-label", "add-task"])
            button.connect("clicked", lambda _b: self.start_adding(section_id))
            return button
        entry = Gtk.Entry(placeholder_text="Like “Call Sam tomorrow 3pm #Work @phone p1”. Esc to stop.",
                          text=self.add_text, css_classes=["add-task"])
        preview = Gtk.Label(xalign=0, wrap=True, css_classes=["dim-label", "task-meta"], margin_start=6, margin_top=4)
        entry.connect("changed", lambda _e: self.show_quick_add(entry, preview))
        entry.connect("activate", self.on_add_activate)
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_add_key)
        entry.add_controller(keys)
        self.add_entry = entry
        self.show_quick_add(entry, preview)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(entry)
        box.append(preview)
        return box

    def show_quick_add(self, entry, preview):
        """Under the entry: what the line will set, besides the title."""
        parsed = self.writer.parse_line(entry.get_text())
        due = format_due(parsed.due, time_format=self.time_format)
        names = dict(self.project_paths)
        parts = [
            due and due.text, parsed.someday and "Someday", parsed.evening and "This evening", parsed.day_part,
            parsed.deadline and "Deadline " + self.day_text(parsed.deadline),
            parsed.project_id and names.get(parsed.project_id, "Project"), *("@" + name for name in parsed.labels),
            parsed.priority and f"p{parsed.priority}", parsed.estimate_minutes and format_minutes(parsed.estimate_minutes),
            parsed.recurrence, parsed.reminders and f"{len(parsed.reminders)} reminder{'s' * (len(parsed.reminders) > 1)}",
        ]
        text = " · ".join(str(part) for part in parts if part)
        preview.set_label(text)
        preview.set_visible(bool(text))

    def start_adding(self, section_id):
        if self.selected.startswith((VIEW, ARCHIVED)):
            return
        self.adding = (self.selected, section_id)
        self.add_text = ""
        self.split.set_show_content(True)
        self.show_page(self.selected)

    def stop_adding(self):
        self.adding = None
        self.add_text = ""
        self.show_page(self.selected)

    def focus_add_entry(self):
        if self.add_entry is not None:
            self.add_entry.grab_focus_without_selecting()
            self.add_entry.set_position(-1)
        return GLib.SOURCE_REMOVE

    def on_add_key(self, _controller, keyval, _code, _state):
        if keyval == Gdk.KEY_Escape:
            self.stop_adding()
            return True
        return False

    def on_add_activate(self, entry):
        """Quick add. Today adds tasks due today, Upcoming due tomorrow, unless the line says otherwise."""
        page, section_id = self.adding
        where = {TODAY: {"due": {"date": self.today}}, UPCOMING: {"due": {"date": shift(self.today, 1)}},
                 INBOX: {}}.get(page, {"project_id": page, "section_id": section_id})
        if page.startswith(LABEL):
            where = {"labels": [page[len(LABEL):]]}
        try:
            self.writer.quick_add(entry.get_text(), **where)
        except CannotEdit as err:
            self.toast(str(err))
            return
        entry.set_text("")
        self.after_edit()

    # ---- editing ----

    def after_edit(self):
        self.refresh_view()
        self.schedule_sync()

    def run(self, action, *args):
        """Run a writer action. Shows the error and returns None when it can't be done."""
        try:
            result = action(*args)
        except CannotEdit as err:
            self.toast(str(err))
            return None
        self.after_edit()
        return result

    def complete(self, task_id):
        task = self.store.rows("task").get(task_id)
        done = self.run(self.writer.complete, task_id)
        if done and done.undo:
            title = task.get("title", "")
            text = f"“{title}” next due {self.day_text(done.next_due)}" if done.next_due else f"Completed “{title}”"
            self.toast(text, undo=lambda: self.run(self.writer.revert, done.undo))

    def delete_task(self, task_id):
        task = self.store.rows("task").get(task_id)
        done = self.run(self.writer.delete_task, task_id)
        if done:
            self.toast(f"Deleted “{task.get('title', '')}”", undo=lambda: self.run(self.writer.revert, done.undo))

    def reopen(self, task_id):
        done = self.run(self.writer.reopen, task_id)
        if done and done.undo:
            self.toast("Reopened", undo=lambda: self.run(self.writer.revert, done.undo))

    def moved_on(self, done, verb):
        """Toast for a skip or detach."""
        if done:
            self.toast(f"{verb}. Next due {self.day_text(done.next_due)}",
                       undo=lambda: self.run(self.writer.revert, done.undo))

    def day_text(self, day):
        return date.fromisoformat(day).strftime("%a %-d %b")

    def open_view_dialog(self, view_id):
        """A new view (None), or edit a saved one."""
        view = next((v for v in self.snap.views if v.id == view_id), None)
        ViewDialog(self, view).present(self)

    def view_menu(self, view_id):
        return [[("Edit view…", lambda: self.open_view_dialog(view_id), True)],
                self.sibling_moves("view", view_id),
                [("Delete", lambda: self.delete_view(view_id), True)]]

    def delete_view(self, view_id):
        try:
            self.writer.delete_view(view_id)
        except CannotEdit as err:
            self.toast(str(err))
            return
        self.view_deleted(view_id)

    def show_view(self, view_id):
        self.selected = VIEW + view_id
        self.after_edit()

    def view_deleted(self, view_id):
        self.after_edit()

        def undo():
            self.writer.revert([("view", view_id, {"deleted_at": None})])
            self.show_view(view_id)

        self.toast("View deleted", undo=undo)

    # ---- projects and sections ----

    def page_project(self):
        """The id of the live project whose page is shown, or None."""
        key = self.selected
        return key if key not in (TODAY, UPCOMING, INBOX) and not key.startswith((VIEW, ARCHIVED, LABEL)) else None

    def edit_page(self):
        if self.selected.startswith(VIEW):
            self.open_view_dialog(self.selected[len(VIEW):])
        elif self.selected.startswith(LABEL):
            self.open_label_dialog(self.selected[len(LABEL):])
        elif (project_id := self.page_project()) is not None:
            self.open_project_dialog(project_id)

    def open_project_dialog(self, project_id, parent_id=None):
        """A new project (None), under parent_id if given, or edit one."""
        project = self.store.rows("project").get(project_id) if project_id else None
        ProjectDialog(self, project, parent_id).present(self)

    def show_project(self, project_id):
        self.selected = project_id
        self.after_edit()

    def project_name(self, project_id):
        return project_path(project_id, self.store.rows("project"))

    def project_menu(self, project_id):
        return [
            [("Edit project…", lambda: self.open_project_dialog(project_id), True),
             ("New sub-project…", lambda: self.open_project_dialog(None, project_id), True),
             ("Add section…", lambda: self.add_section(project_id), True)],
            self.sibling_moves("project", project_id),
            [("Archive", lambda: self.archive_project(project_id), True)],
            [("Delete", lambda: self.delete_project(project_id), True)],
        ]

    def archived_menu(self, project_id):
        return [[("Unarchive", lambda: self.unarchive_project(project_id), True)],
                [("Delete", lambda: self.delete_project(project_id), True)]]

    # ---- labels (spec/labels.md) ----

    def page_label(self):
        """The id of the label whose page is shown, or None."""
        return self.selected[len(LABEL):] if self.selected.startswith(LABEL) else None

    def labels_for_picker(self):
        return picker_order(self.snap.labels.values(), self.store.get_meta(RECENT_LABELS) or [])

    def remember_labels(self, label_ids):
        if label_ids:
            self.store.set_meta(RECENT_LABELS, remember(self.store.get_meta(RECENT_LABELS) or [], label_ids))

    def pick_labels(self, task_id):
        """The picker for one task, below its row. Changes are written as one batch when it closes."""
        task, row = self.store.rows("task").get(task_id), self.task_widgets.get(task_id)
        if task is None or row is None:
            return
        before = list(task.get("labels") or [])
        wanted = list(before)

        def toggle(ref, on):
            if on:
                wanted.append(ref)
            else:
                wanted.remove(ref)

        picker = LabelPicker(self.labels_for_picker(), selected=[i for i in before if i in self.snap.labels],
                             on_toggle=toggle)
        # On the page's scroller, not the row: a sync while it's open rebuilds the rows.
        picker.set_parent(self.content)
        ok, bounds = row.compute_bounds(self.content)
        if ok:
            spot = Gdk.Rectangle()
            spot.x, spot.y = int(bounds.get_x() + 40), int(bounds.get_y())
            spot.width, spot.height = 1, int(bounds.get_height())
            picker.set_pointing_to(spot)
        picker.set_position(Gtk.PositionType.BOTTOM)

        def closed(_picker):
            GLib.idle_add(lambda: picker.unparent() or False)
            add = [r for r in wanted if r not in before]
            remove = [i for i in before if i not in wanted]
            if not add and not remove:
                # Back to the row, once the popover has given up the focus.
                GLib.idle_add(self.after_page, 0, None, self.task_widgets.get(task_id))
                return
            self.focus_task = task_id  # kept through the rebuild
            done = self.run(self.writer.change_task_labels, task_id, add, remove)
            if done is None or not done.undo:
                return
            now = self.store.rows("task")[task_id].get("labels") or []
            self.remember_labels([i for i in now if i not in before])
            names = ", ".join(label.get("name", "") for label in shown(now, self.snap.labels))
            # Short: the task is the focused row, and a narrow window cuts a long toast.
            self.toast(f"Labels: {names}" if names else "Labels removed",
                       undo=lambda: self.run(self.writer.revert, done.undo))

        picker.connect("closed", closed)
        picker.popup()

    def open_label_dialog(self, label_id):
        """A new label (None), or edit one."""
        LabelDialog(self, self.snap.labels.get(label_id) if label_id else None).present(self)

    def show_label(self, label_id):
        self.selected = LABEL + label_id
        self.after_edit()

    def label_name(self, label_id):
        label = self.store.rows("label").get(label_id)
        return label.get("name", "") if label else ""

    def label_menu(self, label_id):
        return [
            [("Edit label…", lambda: self.open_label_dialog(label_id), True)],
            self.sibling_moves("label", label_id),
            [("Merge into…", lambda: self.merge_label(label_id), len(self.snap.labels) > 1)],
            [("Delete…", lambda: self.delete_label(label_id), True)],
        ]

    def attach_popover(self, popover, label_id):
        """A popover about a label opens at its sidebar row, or at the top of the page when the sidebar is hidden."""
        row = self.rows_by_key.get(LABEL + label_id)
        if row is not None and row.get_mapped():
            popover.set_parent(row)
            return
        popover.set_parent(self.content)
        spot = Gdk.Rectangle()
        spot.x, spot.y, spot.width, spot.height = self.content.get_width() // 2, 0, 1, 1
        popover.set_pointing_to(spot)

    def delete_label(self, label_id):
        """Asks first when tasks carry the label, saying how many. Undo puts it back on them."""
        name, page = self.label_name(label_id), LABEL + label_id
        uses = len(carrying(self.store.rows("task").values(), label_id))

        def delete():
            done = self.run(self.writer.delete_label, label_id)
            if done:
                self.toast(f"Deleted label “{name}”", undo=lambda: self.revert_to(done.undo, page))

        if not uses:
            delete()
            return
        tasks = f"{uses} task{'s' * (uses != 1)}"
        confirm(self, f"Delete “{name}”?", f"It will be removed from {tasks}. The tasks stay.",
                "Delete label", delete, destructive=True)

    def merge_label(self, label_id):
        """Choose the label to keep, by typing, then confirm with the number of tasks that change."""
        name = self.label_name(label_id)

        def chosen(target_id):
            target = self.label_name(target_id)
            uses = len(carrying(self.store.rows("task").values(), label_id))

            def merge():
                done = self.run(self.writer.merge_labels, label_id, target_id)
                if done:
                    self.show_label(target_id)
                    self.toast(f"Merged “{name}” into “{target}”",
                               undo=lambda: self.revert_to(done.undo, LABEL + label_id))

            body = (f"{uses} task{'s' * (uses != 1)} will have “{target}” instead. “{name}” will be deleted." if uses
                    else f"No task has “{name}”. It will be deleted.")
            confirm(self, f"Merge “{name}” into “{target}”?", body, "Merge", merge)

        picker = LabelPicker(in_order(self.snap.labels.values()), choose=lambda target_id: GLib.idle_add(
            lambda: chosen(target_id) and False), exclude=label_id, placeholder=f"Merge “{name}” into…")
        self.attach_popover(picker, label_id)
        picker.connect("closed", lambda p: GLib.idle_add(lambda: p.unparent() or False))
        picker.popup()

    def archive_project(self, project_id):
        name = self.project_name(project_id)
        done = self.run(self.writer.archive_project, project_id)
        if done and done.undo:
            self.toast(f"Archived “{name}”", undo=lambda: self.revert_to(done.undo, project_id))

    def unarchive_project(self, project_id):
        done = self.run(self.writer.unarchive_project, project_id)
        if done and done.undo:
            self.show_project(project_id)
            self.toast(f"Unarchived “{self.project_name(project_id)}”",
                       undo=lambda: self.revert_to(done.undo, ARCHIVED + project_id))

    def delete_project(self, project_id):
        project = self.store.rows("project").get(project_id)
        page = ARCHIVED + project_id if project is not None and project.get("archived") else project_id
        name = self.project_name(project_id)
        done = self.run(self.writer.delete_project, project_id)
        if done:
            self.toast(f"Deleted “{name}”", undo=lambda: self.revert_to(done.undo, page))

    def revert_to(self, undo, key):
        """Undo, then show the page the action left."""
        self.selected = key
        self.run(self.writer.revert, undo)

    def add_section(self, project_id):
        def add(name):
            if self.run(self.writer.add_section, project_id, name) is not None:
                self.show_project(project_id)

        ask_name(self, "New section", "", add)

    def section_menu(self, section_id):
        section = self.store.rows("section").get(section_id)
        order = [s.id for s in self.snap.sections_by_project.get(section.get("project_id"), [])]
        index = order.index(section_id) if section_id in order else -1
        return [
            [("Rename…", lambda: self.rename_section(section_id), True)],
            [("Move up", lambda: self.run(self.writer.move_section, section_id, -1), index > 0),
             ("Move down", lambda: self.run(self.writer.move_section, section_id, 1), 0 <= index < len(order) - 1)],
            [("Delete section", lambda: self.delete_section(section_id), True)],
        ]

    def rename_section(self, section_id):
        section = self.store.rows("section").get(section_id)
        ask_name(self, "Rename section", section.get("name", ""),
                 lambda name: self.run(self.writer.rename_section, section_id, name))

    def delete_section(self, section_id):
        name = self.store.rows("section").get(section_id).get("name", "")
        done = self.run(self.writer.delete_section, section_id)
        if done:
            moved = len(done.undo) - 1
            tasks = f". {moved} task{'s' * (moved != 1)} moved to No section" if moved else ""
            self.toast(f"Deleted section “{name}”{tasks}", undo=lambda: self.run(self.writer.revert, done.undo))

    # ---- reminders ----

    def check_reminders(self):
        """Show a desktop notification once per reminder firing. Withdraw ones no longer due."""
        app = self.get_application()
        now = wall_ms()
        tasks = self.store.rows("task")
        projects = self.store.rows("project")
        notified = self.store.get_meta("notified")
        first_run = notified is None
        notified = notified or {}
        current = {}
        for reminder in self.store.rows("reminder").values():
            task = tasks.get(reminder.get("task_id"))
            if not is_due(reminder, task, now) or in_trash(task, projects):
                continue
            fire_at = reminder.get("fire_at")
            current[reminder.id] = fire_at
            if notified.get(reminder.id) == fire_at or (first_run and now - fire_at > STALE_REMINDER_MS):
                continue
            try:
                self.send_reminder(app, reminder, task)
            except Exception as err:  # a bug in this client; don't take the window down with it
                print(f"reminder notification failed: {err!r}", file=sys.stderr)
        for reminder_id in notified.keys() - current.keys():
            app.withdraw_notification(f"reminder-{reminder_id}")
        if current != notified or first_run:
            self.store.set_meta("notified", current)

    def send_reminder(self, app, reminder, task):
        note = Gio.Notification.new(task.get("title") or "Reminder")
        due = format_due(task.get("due"), time_format=self.time_format)
        note.set_body(f"Due {due.text}" if due else describe(reminder))
        note.set_priority(Gio.NotificationPriority.HIGH)
        note.set_default_action_and_target("app.open-task", GLib.Variant.new_string(task.id))
        note.add_button_with_target("Snooze 10 min", "app.snooze", GLib.Variant.new_string(reminder.id))
        note.add_button_with_target("Dismiss", "app.dismiss", GLib.Variant.new_string(reminder.id))
        app.send_notification(f"reminder-{reminder.id}", note)

    def snooze_reminder(self, reminder_id):
        self.run(self.writer.snooze, reminder_id, snooze_until("10m", wall_ms()))

    def dismiss_reminder(self, reminder_id):
        self.run(self.writer.dismiss, reminder_id)

    def edit(self, task_id):
        task = self.store.rows("task").get(task_id)
        if task is not None:
            TaskDialog(self, task).present(self)


def confirm(window, heading, body, action, then, destructive=False):
    """Ask before an action that changes many things. then() runs on the action button only."""
    dialog = Adw.AlertDialog(heading=heading, body=body)
    dialog.add_response("cancel", "Cancel")
    dialog.add_response("ok", action)
    dialog.set_response_appearance(
        "ok", Adw.ResponseAppearance.DESTRUCTIVE if destructive else Adw.ResponseAppearance.SUGGESTED)
    dialog.set_default_response("cancel" if destructive else "ok")
    dialog.set_close_response("cancel")
    dialog.connect("response", lambda _d, response: response == "ok" and then())
    dialog.present(window)


def in_trash(task, projects):
    """A task whose project, or any project above it, is deleted. Its reminders don't fire."""
    seen = set()
    project_id = task.get("project_id")
    while project_id and project_id not in seen:
        seen.add(project_id)
        project = projects.get(project_id)
        if project is None:
            return False
        if project.get("deleted_at") is not None:
            return True
        project_id = project.get("parent_id")
    return False


class App(Adw.Application):
    def __init__(self, background=False):
        super().__init__(application_id=config.APP_ID)
        # Started at login: build the window but don't show it until the app is opened.
        self.background = background

    def do_startup(self):
        Adw.Application.do_startup(self)
        # Buttons on reminder notifications.
        for name, method in (("snooze", "snooze_reminder"), ("dismiss", "dismiss_reminder"), ("open-task", "edit")):
            action = Gio.SimpleAction.new(name, GLib.VariantType.new("s"))
            action.connect("activate", self.on_notification_action, method)
            self.add_action(action)
        quit_action = Gio.SimpleAction.new("quit", None)
        quit_action.connect("activate", lambda *_a: self.quit())
        self.add_action(quit_action)
        self.set_accels_for_action("app.quit", ["<Control>q"])
        provider = Gtk.CssProvider()
        provider.load_from_string(CSS)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.theme = ThemeFollower(Gdk.Display.get_default())

    def main_window(self):
        """The app's window, focused or not."""
        return next(iter(self.get_windows()), None)

    def on_notification_action(self, _action, target, method):
        if self.main_window() is None:
            self.activate()
        window = self.main_window()
        if isinstance(window, Window):
            if method == "edit":
                window.present()
            getattr(window, method)(target.get_string())

    def do_activate(self):
        if window := self.main_window():
            window.present()
            return
        try:
            window = Window(self, config.load())
        except config.ConfigMissing as err:
            window = Adw.ApplicationWindow(application=self, title="Dustpan", default_width=600, default_height=400)
            window.set_content(Adw.StatusPage(
                icon_name="dialog-information-symbolic", title="Not connected",
                description=f"{err}.\nAdd your server URL and API token there, then restart."))
        if self.background:
            # Only the first activation. Opening the app later presents the window above.
            self.background = False
            if isinstance(window, Window):
                return
        window.present()
        if folder := os.environ.get("DUSTPAN_SCREENSHOT"):
            GLib.timeout_add(2500, self.screenshot_pages, window, folder)

    def screenshot_pages(self, window, folder):
        """Development aid: save one PNG per sidebar page into folder, then quit."""
        rows = list(getattr(window, "rows_by_key", {}).values())

        def next_page():
            if not rows:
                self.quit()
                return GLib.SOURCE_REMOVE
            row = rows.pop(0)
            window.sidebar.select_row(row)
            GLib.timeout_add(300, shoot, row.name)
            return GLib.SOURCE_REMOVE

        def shoot(name):
            save_screenshot(window, os.path.join(folder, name.lower().replace(" ", "-") + ".png"))
            return next_page()

        next_page()
        return GLib.SOURCE_REMOVE


def main(background=False):
    return App(background).run([sys.argv[0]])
