"""Local edits: plan the ops, apply them locally, queue them for upload.

See spec/writes.md.
"""

import json
import re
import uuid
from dataclasses import dataclass, field
from datetime import date, datetime, time

from . import labels as label_rules, quickadd, sectors
from .clock import HybridClock, wall_ms
from .dates import day_start_minutes, due_instant, logical_today
from .dragdrop import Place, Stretch, ToDay, ToLabel, ToProject, ToSlot
from .filters import FilterError, parse as parse_query
from .model import build_tree, order_key
from .ordering import GAP, plan_move
from .recurrence import RuleError, canonical, first_occurrence, parse
from .recurring import plan_completion, plan_detach, plan_skip, series_rule
from .quickadd.settings import context_for
from .reminders import (MAX_OFFSET, deadline_fire_at, format_default, parse_default, plan_default_reminder,
                        read_defaults, relative_fire_at)
from .store import Row
from .trash import deleted_with
from .views import DEFAULTS as VIEW_DEFAULTS, GROUP_BY, SORT_BY, SORT_DIR, is_list_view, view_order

LOCAL_USER = "local"  # standalone actor until connected to an OpenTodo account
EDITABLE = ("title", "description", "priority", "due", "recurrence", "project_id", "section_id", "labels",
            "estimate_minutes", "deadline", "sector")
MAX_ESTIMATE = 10080  # minutes: the server's bound
MAX_VALUE_BYTES = 64 * 1024  # the server's bound on one value, as the JSON we send
VIEW_EDITABLE = ("name", "query", "group_by", "sort_by", "sort_dir", "show_completed")
DATE_FORMATS = ("system", "day-month", "month-day", "iso")
TIME_FORMATS = ("system", "24h", "12h")
WEEK_STARTS = ("system", "mon", "sun", "sat")
LANGUAGES = ("system", "en", "de", "fr", "es", "it", "pt")
DAY_STARTS = ("00:00", "01:00", "02:00", "03:00", "04:00", "05:00", "06:00")
PREF_DEFAULTS = {
    "date_format": "system", "time_format": "system", "week_start": "system", "day_start": "",
    "language": "system", "reminder_default_timed": "", "reminder_default_dated": "",
    "time_sectors": "", "day_parts": "", "energy": "",
}
# The web app's label colours (web/src/ui/tokens/palette.ts). A new label takes the first one no label uses.
LABEL_COLOURS = (("#ef4444", "Red"), ("#f97316", "Orange"), ("#eab308", "Yellow"), ("#84cc16", "Lime"),
                 ("#22c55e", "Green"), ("#14b8a6", "Teal"), ("#06b6d4", "Cyan"), ("#3b82f6", "Blue"),
                 ("#6366f1", "Indigo"), ("#8b5cf6", "Violet"), ("#ec4899", "Pink"), ("#64748b", "Slate"))
LABEL_PALETTE = tuple(c for c, _ in LABEL_COLOURS)
# The web app's project colours, with the names the editor shows.
PROJECT_COLOURS = (("#ef4444", "Red"), ("#f97316", "Orange"), ("#eab308", "Yellow"), ("#22c55e", "Green"),
                   ("#14b8a6", "Teal"), ("#3b82f6", "Blue"), ("#8b5cf6", "Violet"), ("#ec4899", "Pink"))
PROJECT_PALETTE = tuple(c for c, _ in PROJECT_COLOURS)


class CannotEdit(Exception):
    """The edit can't be made: bad input, a missing target, or not supported yet."""


@dataclass
class Done:
    """What an action did, and the changes that undo it."""

    undo: list = field(default_factory=list)
    next_due: str | None = None  # where a repeating task moved to
    task_id: str | None = None  # a task the action created


def live(row):
    return row is not None and row.get("deleted_at") is None


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def check_due(due):
    """A due value the server accepts, or CannotEdit."""
    if due is None:
        return None
    try:
        date.fromisoformat(due["date"])
        if "time" in due:
            if len(due["time"]) != 5:
                raise ValueError(due["time"])
            time.fromisoformat(due["time"])
    except (KeyError, TypeError, ValueError):
        raise CannotEdit("That isn't a valid date or time") from None
    if "tz" in due and "time" not in due:
        raise CannotEdit("A time zone needs a time")
    if set(due) - {"date", "time", "tz"}:
        raise CannotEdit("Unknown due date fields")
    return due


def label_key(name, fold=False):
    key = (name if isinstance(name, str) else "").strip().lower()
    return re.sub(r"[\s_-]+", "", key) if fold else key


def children_of(tasks):
    children = {}
    for task in tasks.values():
        if live(task) and task.get("parent_id"):
            children.setdefault(task.get("parent_id"), []).append(task)
    return children


def descendants(task_id, tasks):
    """Every live task below task_id. Safe against cycles."""
    children = children_of(tasks)
    found, stack = [], [task_id]
    seen = {task_id}
    while stack:
        for child in children.get(stack.pop(), []):
            if child.id not in seen:
                seen.add(child.id)
                found.append(child)
                stack.append(child.id)
    return found


class Writer:
    def __init__(self, store, clock=None, now=wall_ms, today=None):
        self.store = store
        self.now = now
        self.clock = clock or HybridClock(store, now)
        self._today = today

    def today(self):
        """The logical today, after the user's day start."""
        if self._today:
            return self._today()
        prefs = self.store.rows("user_prefs").get("me")
        return logical_today(day_start_minutes(prefs.get("day_start") if prefs else None),
                             datetime.fromtimestamp(self.now() / 1000))

    def commit(self, plan):
        """Run plan() in one transaction and write the changes it returns as one batch.

        plan returns [(entity, entity_id, {field: value})]. Returns plan's second value, if any.
        """
        with self.store.transaction():
            planned = plan()
            changes, result = planned if isinstance(planned, tuple) else (planned, None)
            changes = self._completed_by(changes)
            changes = self._sector_clears(changes)
            changes = changes + self._default_reminders(changes)
            changes = changes + self._reminder_follow_ups(changes)
            if not changes:
                return result
            ts = self.clock.stamp()
            device = self.store.device()
            ops = [
                {"id": str(uuid.uuid4()), "entity": entity, "entityId": entity_id,
                 "field": name, "value": value, "ts": ts, "device": device}
                for entity, entity_id, patch in changes
                for name, value in patch.items()
            ]
            for op in ops:
                self.store.apply(op)
            self.store.outbox_add(ops)
        return result

    # ---- reads inside a plan ----

    def _task(self, tasks, task_id):
        task = tasks.get(task_id)
        if not live(task):
            raise CannotEdit("That task no longer exists")
        return task

    def _check_project(self, project_id):
        if project_id is None:
            return
        project = self.store.rows("project").get(project_id)
        if not live(project) or project.get("archived"):
            raise CannotEdit("That project no longer exists")

    def _check_section(self, section_id, project_id):
        if section_id is None:
            return
        section = self.store.rows("section").get(section_id)
        if not live(section) or section.get("project_id") != project_id:
            raise CannotEdit("That section isn't in the project")

    def _new_position(self, tasks):
        now = self.now()
        top = max((p for t in tasks.values() if (p := number(t.get("position"))) is not None), default=None)
        return top + GAP if top is not None and top >= now else now

    def _end_of_list(self, tasks, project_id, section_id, skip):
        """Past the last open top-level task of one list, or the wall time when it's empty."""
        positions = [
            p for t in tasks.values()
            if t.id != skip and live(t) and t.get("completed_at") is None and not t.get("parent_id")
            and t.get("project_id") == project_id and t.get("section_id") == section_id
            and (p := number(t.get("position"))) is not None
        ]
        return max(positions) + GAP if positions else self.now()

    def user_id(self):
        """The signed-in OpenTodo user id, or LOCAL_USER when running standalone."""
        return self.store.get_meta("user_id") or LOCAL_USER

    def _completed_by(self, changes):
        """A write of completed_at carries completed_by: us when completing, null when reopening."""
        me = self.user_id()
        return [
            (entity, eid, {**patch, "completed_by": me if patch["completed_at"] is not None else None})
            if entity == "task" and "completed_at" in patch and "completed_by" not in patch else (entity, eid, patch)
            for entity, eid, patch in changes
        ]

    def _sector_clears(self, changes):
        """One "when" at a time: a do-on date, a start or Someday clears a task's sector in the same batch.

        As in the web app's sectorWrites.ts. The deadline stays.
        """
        tasks = self.store.rows("task")

        def dates(patch):
            return patch.get("due") is not None or bool(patch.get("start"))

        return [
            (entity, eid, {**patch, "sector": ""})
            if entity == "task" and "sector" not in patch and dates(patch) and (tasks.get(eid) or {}).get("sector")
            else (entity, eid, patch)
            for entity, eid, patch in changes
        ]

    def _default_reminders(self, changes):
        """A task that gets its first due date gets the user's default reminder, in the same batch."""
        patches = {}
        for entity, eid, patch in changes:
            if entity == "task":
                patches[eid] = {**patches.get(eid, {}), **patch}
        scheduled = {eid: p for eid, p in patches.items() if isinstance(p.get("due"), dict)}
        user_id = self.user_id()
        prefs = self.store.rows("user_prefs").get("me")
        defaults = read_defaults(prefs.values if prefs else None)
        if not scheduled or defaults == (None, None):
            return []
        tasks = self.store.rows("task")
        reminders = list(self.store.rows("reminder").values())
        batch = [(eid, patch) for entity, eid, patch in changes if entity == "reminder"]
        out = []
        for task_id, patch in scheduled.items():
            before = tasks[task_id].values if task_id in tasks else None
            own = [{**r.values, "id": r.id} for r in reminders if r.get("task_id") == task_id]
            planned = plan_default_reminder(user_id, task_id, before, patch, own, batch, defaults, self.now())
            out += [("reminder", rid, p) for rid, p in planned]
        return out

    def _reminder_follow_ups(self, changes):
        """Relative reminders follow their task's due, and deadline reminders its deadline, in the same batch."""
        follow = {"relative": ("due", relative_fire_at), "deadline": ("deadline", deadline_fire_at)}
        patches = {}
        for entity, eid, patch in changes:
            if entity == "task" and ("due" in patch or "deadline" in patch):
                patches[eid] = {**patches.get(eid, {}), **patch}
        if not patches:
            return []
        # A reminder whose firing time the batch already writes keeps that value.
        written = {eid for entity, eid, patch in changes if entity == "reminder" and "fire_at" in patch}
        out = []
        for reminder in self.store.rows("reminder").values():
            name, fire_at_of = follow.get(reminder.get("kind"), (None, None))
            task_patch = patches.get(reminder.get("task_id"), {})
            if name not in task_patch or not live(reminder) or reminder.id in written:
                continue
            fire_at = fire_at_of(task_patch[name], reminder.get("offset_minutes"))
            patch = {"fire_at": fire_at}
            if fire_at != reminder.get("fire_at"):
                if reminder.get("delivered_at") is not None:
                    patch["delivered_at"] = None
                if reminder.get("dismissed_at") is not None:
                    patch["dismissed_at"] = None
            out.append(("reminder", reminder.id, patch))
        return out

    # ---- actions ----

    def _new_task(self, tasks, title, project_id=None, section_id=None, parent_id=None, due=None, **fields):
        """The fields of a new task at the end of its list. Optional fields are written only when set."""
        title = title.strip()
        if not title:
            raise CannotEdit("A task needs a title")
        if parent_id is not None:
            parent = self._task(tasks, parent_id)
            project_id, section_id = parent.get("project_id"), None
        self._check_project(project_id)
        self._check_section(section_id, project_id)
        patch = {
            "title": title, "description": "", "project_id": project_id, "parent_id": parent_id,
            "priority": fields.pop("priority", None) or 4, "due": check_due(due), "labels": fields.pop("labels", []),
            "position": self._new_position(tasks), "created_at": self.now(), "completed_at": None, "deleted_at": None,
            "estimate_minutes": fields.pop("estimate_minutes", None),
        }
        return {**patch, **{k: v for k, v in {"section_id": section_id, **fields}.items() if v}}

    def add_task(self, title, project_id=None, section_id=None, parent_id=None, due=None):
        """Add a task at the end of its list. Returns its id."""
        task_id = str(uuid.uuid4())
        self.commit(lambda: [("task", task_id, self._new_task(self.store.rows("task"), title, project_id, section_id,
                                                             parent_id, due))])
        return task_id

    def quick_add(self, line, project_id=None, section_id=None, due=None, parent_id=None, labels=()):
        """Add a task from a quick-add line, in one batch with its new labels, reminders and time spent.

        The page's project and section, or due date, apply unless the line sets its own. labels: the page's label ids,
        added to any the line names.
        A subtask (parent_id) always takes its parent's project. Returns its id.
        """
        task_id = str(uuid.uuid4())
        now = datetime.fromtimestamp(self.now() / 1000)

        def plan():
            parsed = self.parse_line(line)
            live_ids = {r.id for r in self._live_labels()}
            ids, created = self._label_ids([*(i for i in labels if i in live_ids), *parsed.labels])
            where = {"project_id": parsed.project_id} if parsed.project_id else \
                {"project_id": project_id, "section_id": section_id}
            task = self._new_task(
                self.store.rows("task"), parsed.title, **where, parent_id=parent_id,
                due=parsed.due or (None if parsed.someday or parsed.sector else due),
                priority=parsed.priority, labels=ids, estimate_minutes=parsed.estimate_minutes,
                deadline=parsed.deadline, start="someday" if parsed.someday else None, evening=parsed.evening,
                day_part=None if parsed.evening else parsed.day_part, energy=parsed.energy, sector=parsed.sector,
                recurrence=parsed.recurrence)
            changes = created + [("task", task_id, task)]
            changes += [("reminder", str(uuid.uuid4()), self._typed_reminder(task_id, task["due"], r, now))
                        for r in parsed.reminders]
            if parsed.spent_minutes:
                me = self.user_id()
                end = self.now()
                changes.append(("time_entry", str(uuid.uuid4()), {
                    "task_id": task_id, "user_id": me, "started_at": end - parsed.spent_minutes * 60_000,
                    "ended_at": end, "device_id": self.store.device(), "note": "", "created_at": end, "deleted_at": None,
                }))
            return changes

        self.commit(plan)
        return task_id

    def parse_line(self, line):
        """What a quick-add line sets, read with the user's preferences."""
        prefs = self.store.rows("user_prefs").get("me")
        projects = [p for p in self.store.rows("project").values() if live(p)]
        now = datetime.fromtimestamp(self.now() / 1000)
        return quickadd.parse(line, context_for(prefs.values if prefs else {}, projects, self.today(), f"{now:%H:%M}"))

    def _label_ids(self, refs):
        """(label ids in the order given, changes creating the missing ones).

        refs are ids of live labels, or names. Names ignore case, then spaces, dashes and underscores.
        With two labels of one name, the first in sidebar order wins.
        """
        labels = sorted((r for r in self.store.rows("label").values() if live(r)),
                        key=lambda r: (number(r.get("position")) or 0, number(r.get("created_at")) or 0, r.id))
        known = {r.id for r in labels}
        used = {r.get("color") for r in labels}
        ids, created = [], []
        for ref in refs:
            name = ref.strip()
            label_id = ref if ref in known else \
                next((r.id for r in labels if label_key(r.get("name")) == label_key(name)), None) or \
                next((r.id for r in labels if label_key(r.get("name"), fold=True) == label_key(name, fold=True)), None)
            if label_id is None:
                if not name:
                    continue
                label_id, now = str(uuid.uuid4()), self.now()
                color = next((c for c in LABEL_PALETTE if c not in used), LABEL_PALETTE[now % len(LABEL_PALETTE)])
                used.add(color)
                row = Row(label_id, {"name": name, "color": color, "position": now, "created_at": now, "deleted_at": None})
                labels.append(row)
                known.add(label_id)
                created.append(("label", label_id, dict(row.values)))
            if label_id not in ids:
                ids.append(label_id)
        return ids, created

    def _typed_reminder(self, task_id, due, typed, now):
        """A reminder typed in quick add, resolved against the task's due."""
        resolved = quickadd.resolve(typed, due, now.date().isoformat(), f"{now:%H:%M}")
        relative = resolved[0] == "relative"
        return {
            "task_id": task_id, "kind": resolved[0], "offset_minutes": resolved[1] if relative else None,
            "fire_at": relative_fire_at(due, resolved[1]) if relative else due_instant({"date": resolved[1], "time": resolved[2]}),
            "delivered_at": None, "dismissed_at": None, "created_at": self.now(), "deleted_at": None,
        }

    def complete(self, task_id):
        """Complete a task and its open descendants, or roll a repeating task to its next occurrence."""

        def plan():
            tasks = self.store.rows("task")
            task = self._task(tasks, task_id)
            if task.get("completed_at") is not None:
                return [], Done()
            now = self.now()
            rule = series_rule(task)
            if rule is not None:
                rolled = plan_completion(task, rule, tasks.values(), now, self.today())
                if rolled is not None:
                    changes, record_id, nxt = rolled
                    return changes, Done(self._undo_move(task, changes, record_id, now), next_due=nxt)
            done = [task] + [d for d in descendants(task_id, tasks) if d.get("completed_at") is None]
            return ([("task", t.id, {"completed_at": now}) for t in done],
                    Done([("task", t.id, {"completed_at": None}) for t in done]))

        return self.commit(plan)

    def delete_task(self, task_id):
        """Delete a task and its subtasks."""

        def plan():
            tasks = self.store.rows("task")
            gone = [self._task(tasks, task_id)] + descendants(task_id, tasks)
            now = self.now()
            return ([("task", t.id, {"deleted_at": now}) for t in gone],
                    Done([("task", t.id, {"deleted_at": None}) for t in gone]))

        return self.commit(plan)

    def restore_task(self, task_id):
        """Bring a task back from the Trash, with the subtasks deleted with it.

        Its project still in the Trash: it goes to the Inbox. Its parent still there: it goes to the top level.
        The Done's task_id is set when it went to the Inbox.
        """

        def plan():
            tasks = self.store.rows("task")
            task = tasks.get(task_id)
            if task is None or task.get("deleted_at") is None:
                raise CannotEdit("That task isn't in the Trash")
            project_id = task.get("project_id")
            project = self.store.rows("project").get(project_id)
            project_gone = project_id is not None and not live(project)
            restored = [task] + deleted_with(task, tasks)
            changes = [("task", t.id, {"deleted_at": None}) for t in restored]
            if project_gone:
                for _, _, patch in changes:
                    patch.update(project_id=None, section_id=None)
                changes[0][2]["parent_id"] = None
            elif task.get("parent_id") is not None and not live(tasks.get(task.get("parent_id"))):
                changes[0][2]["parent_id"] = None
            section = self.store.rows("section").get(task.get("section_id"))
            if task.get("section_id") is not None and (not live(section) or section.get("project_id") != project_id):
                changes[0][2]["section_id"] = None
            return changes

        done = self.commit(self._undoable(plan))
        if "project_id" in done.undo[0][2]:
            done.task_id = task_id
        return done

    def restore_project(self, project_id):
        """Bring a project back from the Trash. Its tasks kept project_id, so they come back with it."""

        def plan():
            project = self.store.rows("project").get(project_id)
            if project is None or project.get("deleted_at") is None:
                raise CannotEdit("That project isn't in the Trash")
            return [("project", project_id, {"deleted_at": None})]

        return self.commit(self._undoable(plan))

    def reopen(self, task_id):
        """Reopen one completed task. Its subtasks stay as they are."""

        def plan():
            task = self._task(self.store.rows("task"), task_id)
            if task.get("completed_at") is None:
                return [], Done()
            return [("task", task_id, {"completed_at": None})], Done([("task", task_id, {"completed_at": self.now()})])

        return self.commit(plan)

    def skip(self, task_id):
        """Move a repeating task to its next occurrence without completing it."""

        def plan():
            task = self._task(self.store.rows("task"), task_id)
            rule = series_rule(task)
            if rule is None:
                raise CannotEdit("Only an open repeating task can be skipped")
            now = self.now()
            skipped = plan_skip(task, rule, now, self.today())
            if skipped is None:
                raise CannotEdit("This is the last occurrence. Complete or delete it instead")
            changes, nxt = skipped
            record_id = changes[0][1] if len(changes) > 1 else None
            return changes, Done(self._undo_move(task, changes, record_id, now), next_due=nxt)

        return self.commit(plan)

    def detach(self, task_id):
        """"This occurrence only": a standalone copy of the current occurrence, and the series moves on."""

        def plan():
            task = self._task(self.store.rows("task"), task_id)
            rule = series_rule(task)
            if rule is None:
                raise CannotEdit("Only an open repeating task has occurrences")
            now = self.now()
            detached = plan_detach(task, rule, now, self.today())
            if detached is None:
                raise CannotEdit("This is the last occurrence. Edit the task itself instead")
            changes, copy_id, nxt = detached
            return changes, Done(self._undo_move(task, changes, copy_id, now), next_due=nxt, task_id=copy_id)

        return self.commit(plan)

    def _undo_move(self, series, changes, created_id, now):
        """Undo for a series that moved on: its old dates back, and the record or copy deleted."""
        moved = next(patch for entity, eid, patch in changes if eid == series.id)
        undo = [("task", series.id, {name: series.get(name) for name in moved})]
        if created_id:
            undo.append(("task", created_id, {"deleted_at": now}))
        return undo

    def revert(self, undo):
        """Apply the undo changes of an earlier action, as a new batch."""
        self.commit(lambda: [(entity, eid, dict(patch)) for entity, eid, patch in undo])

    def edit(self, task_id, changes):
        """Write the changed fields of one task: any of EDITABLE. One batch.

        labels are names: a name with no label creates one in the same batch.
        """
        unknown = set(changes) - set(EDITABLE)
        if unknown:
            raise ValueError(f"not editable: {sorted(unknown)}")
        self.commit(lambda: self._plan_edit(task_id, changes))

    def _plan_edit(self, task_id, changes):
        """The changes that edit makes, for use inside another plan."""
        tasks = self.store.rows("task")
        task = self._task(tasks, task_id)
        patch, out = {}, []
        if "title" in changes:
            title = changes["title"].strip()
            if not title:
                raise CannotEdit("A task needs a title")
            patch["title"] = title
        if "description" in changes:
            # Markdown only. The web app folds it into its rich-text notes_doc, which we never write.
            note = (changes["description"] or "").rstrip()
            if len(json.dumps(note)) > MAX_VALUE_BYTES:
                raise CannotEdit("Notes are too long: the limit is 64 KB")
            patch["description"] = note
        if "priority" in changes:
            if changes["priority"] not in (1, 2, 3, 4):
                raise CannotEdit("Priority is 1 to 4")
            patch["priority"] = changes["priority"]
        if "due" in changes:
            due = check_due(changes["due"])
            patch["due"] = due
            if due is None and task.get("recurrence") and "recurrence" not in changes:
                patch["recurrence"] = None
            if due is not None and task.get("start") == "someday":
                patch["start"] = None
        if "labels" in changes:
            patch["labels"], created = self._label_ids(changes["labels"])
            out += created
        if "estimate_minutes" in changes:
            minutes = changes["estimate_minutes"]
            if minutes is not None and not (isinstance(minutes, int) and 1 <= minutes <= MAX_ESTIMATE):
                raise CannotEdit("An estimate is 1 minute to 1 week")
            patch["estimate_minutes"] = minutes
        if "sector" in changes:
            # Choosing a sector clears the do-on date, the start and the part of the day. "" clears it.
            sector = changes["sector"] or ""
            if sector and not sectors.parse(sector):
                raise CannotEdit("A time sector is a week, month or quarter, like 2026-W45")
            if task.get("recurrence") and sector:
                raise CannotEdit("A repeating task keeps its date")
            if (task.get("sector") or "") != sector:
                patch["sector"] = sector
            if sector:
                patch.update({k: v for k, v in (("due", None), ("start", None), ("evening", False), ("day_part", None))
                              if task.get(k)})
        if "deadline" in changes:
            patch["deadline"] = check_due({"date": changes["deadline"]})["date"] if changes["deadline"] else None
        if "recurrence" in changes:
            text = (changes["recurrence"] or "").strip()
            if not text:
                patch["recurrence"] = None
            else:
                try:
                    rule = parse(text)
                except RuleError as err:
                    raise CannotEdit(f"Repeat: {err}") from None
                patch["recurrence"] = canonical(rule)
                # A rule needs a due date: the first occurrence from today.
                if patch.get("due", task.get("due")) is None:
                    patch["due"] = {"date": first_occurrence(rule, self.today())}
        if "project_id" in changes or "section_id" in changes:
            out += self._plan_move(tasks, task, changes, patch)
        # New labels come first in the batch, so they exist before the task refers to them.
        return out + [("task", task_id, patch)] if patch else out

    def _plan_move(self, tasks, task, changes, patch):
        """Add a move to patch. Returns the ops for descendants."""
        project_id = changes.get("project_id", task.get("project_id"))
        moved_project = project_id != task.get("project_id")
        section_id = changes.get("section_id", None if moved_project else task.get("section_id"))
        self._check_project(project_id)
        self._check_section(section_id, project_id)
        if not moved_project and section_id == task.get("section_id") and not task.get("parent_id"):
            return []

        if moved_project:
            patch["project_id"] = project_id
        if section_id != task.get("section_id"):
            patch["section_id"] = section_id
        if task.get("parent_id"):
            patch["parent_id"] = None
        patch["position"] = self._end_of_list(tasks, project_id, section_id, task.id)
        return self._carry_subtree(tasks, task.id, project_id)

    def _carry_subtree(self, tasks, task_id, project_id):
        """Subtasks follow their parent into another project, out of its sections."""
        return [("task", d.id, {"project_id": project_id, **({"section_id": None} if d.get("section_id") else {})})
                for d in descendants(task_id, tasks) if d.get("project_id") != project_id]

    def _plan_place(self, tasks, task, place):
        """The changes that put an open task at a Place: one position write, unless the list needs renumbering.

        The list is a parent's open subtasks, or the open top-level tasks of one section.
        """
        project_id, parent_id, section_id = place.project_id, place.parent_id, place.section_id
        self._check_project(project_id)
        if parent_id is None:
            self._check_section(section_id, project_id)
        open_tasks = [t for t in tasks.values() if live(t) and t.get("completed_at") is None
                      and t.get("project_id") == project_id]
        parents = {}

        def walk(nodes, parent):
            for node in nodes:
                parents[node.id] = parent
                walk(node.children, node.id)

        walk(build_tree(open_tasks, lambda t: t.get("parent_id")), None)
        if parent_id is not None and (parent_id not in parents or parent_id == task.id
                                      or parent_id in {d.id for d in descendants(task.id, tasks)}):
            raise CannotEdit("A task can't go under itself")
        sections = {s.id for s in self.store.rows("section").values() if live(s) and s.get("project_id") == project_id}

        def section_of(t):
            return t.get("section_id") if t.get("section_id") in sections else None

        if parent_id is None:
            siblings = [t for t in open_tasks if parents[t.id] is None and section_of(t) == section_id]
        else:
            siblings = [t for t in open_tasks if parents.get(t.id) == parent_id]
        others = [t.id for t in sorted(siblings, key=lambda t: (number(t.get("position")) or 0, t.id)) if t.id != task.id]
        anchor = place.before or place.after
        if anchor is not None and anchor not in others:
            raise CannotEdit("That task is no longer in the list")
        index = len(others) if anchor is None else others.index(anchor) + (1 if place.after else 0)

        patch, out = {}, []
        same_project = project_id == task.get("project_id")
        if not same_project:
            patch["project_id"] = project_id
            out = self._carry_subtree(tasks, task.id, project_id)
        # In its own project the parent is the one the tree shows; a stale reference stays unwritten.
        if parent_id != (parents.get(task.id) if same_project else task.get("parent_id")):
            patch["parent_id"] = parent_id
        if parent_id is None and section_id != (section_of(task) if same_project else task.get("section_id")):
            patch["section_id"] = section_id
        elif parent_id is not None and not same_project and task.get("section_id"):
            patch["section_id"] = None  # that section belongs to the old project
        # A task from another list isn't among siblings, so it always gets a position here.
        moves = plan_move([(t.id, number(t.get("position")) or 0) for t in siblings], task.id, index, self.now())
        changes = [("task", tid, {**(patch if tid == task.id else {}), "position": p}) for tid, p in moves]
        return changes + out

    def drop(self, task_id, target):
        """Apply a drag-and-drop target (dragdrop.Place, ToProject, ToDay, ToSlot, Stretch or ToLabel) to an open task, as one batch.

        Returns Done whose undo restores every field written. Nothing changed: an empty undo.
        """

        def plan():
            tasks = self.store.rows("task")
            task = self._task(tasks, task_id)
            if task.get("completed_at") is not None:
                raise CannotEdit("Only open tasks can be moved")
            if isinstance(target, Place):
                return self._plan_place(tasks, task, target)
            if isinstance(target, ToProject):
                return self._plan_edit(task_id, {"project_id": target.project_id, "section_id": None})
            if isinstance(target, ToDay):
                due = task.get("due")
                if due and due.get("date") == target.day:
                    return []
                return self._plan_edit(task_id, {"due": {**(due or {}), "date": target.day}})
            if isinstance(target, (ToSlot, Stretch)):
                # A floating time: where it was dropped on this device's grid. The lane drops the time.
                slot = target.slot if isinstance(target, Stretch) else target
                changes = {}
                if slot is not None:
                    due = {"date": slot.day, **({"time": slot.time} if slot.time else {})}
                    if task.get("due") != due:
                        changes["due"] = due
                if isinstance(target, Stretch) and task.get("estimate_minutes") != target.estimate:
                    changes["estimate_minutes"] = target.estimate
                return self._plan_edit(task_id, changes) if changes else []
            if isinstance(target, ToLabel):
                self._label(target.label_id)
                labels = list(task.get("labels") or [])
                return [] if target.label_id in labels else [("task", task_id, {"labels": labels + [target.label_id]})]
            raise ValueError(f"not a drop target: {target!r}")

        return self.commit(self._undoable(plan))

    def _undoable(self, plan):
        """plan, also returning a Done whose undo puts back every field the changes write."""

        def wrapped():
            changes = plan()
            rows = {}
            undo = []
            for entity, entity_id, patch in changes:
                row = rows.setdefault(entity, self.store.rows(entity)).get(entity_id)
                if row is not None:
                    undo.append((entity, entity_id, {name: row.get(name) for name in patch}))
            return changes, Done(undo=undo)

        return wrapped

    # ---- reminders ----

    def add_reminder(self, task_id, kind, offset_minutes=None, fire_at=None):
        """A relative reminder (offset from the due time), a deadline one (offset from 09:00 on the deadline),
        or an absolute one (fire_at). Returns its id.
        """
        if (kind == "absolute") != (fire_at is not None) or (kind == "absolute") == (offset_minutes is not None):
            raise ValueError("an absolute reminder needs a time; the others an offset")
        if offset_minutes is not None and abs(offset_minutes) > MAX_OFFSET:
            raise CannotEdit("A reminder can be at most a year from the due time")
        reminder_id = str(uuid.uuid4())

        def plan():
            task = self._task(self.store.rows("task"), task_id)
            if kind == "relative":
                at = relative_fire_at(task.get("due"), offset_minutes)
            else:
                at = deadline_fire_at(task.get("deadline"), offset_minutes) if kind == "deadline" else fire_at
            return [("reminder", reminder_id, {
                "task_id": task_id, "kind": kind, "offset_minutes": offset_minutes, "fire_at": at,
                "delivered_at": None, "dismissed_at": None, "created_at": self.now(), "deleted_at": None,
            })]

        self.commit(plan)
        return reminder_id

    def moment(self, text):
        """The instant a typed time names, like “tomorrow 9am” or “3 Nov at 14:00”. A time alone is
        today if it's still ahead, else tomorrow. CannotEdit when the text isn't one.
        """
        parsed = self.parse_line("remind me " + text)
        if len(parsed.reminders) != 1 or parsed.title or parsed.reminders[0]["kind"] != "moment":
            raise CannotEdit("Write a time, like “tomorrow 9am”")
        now = datetime.fromtimestamp(self.now() / 1000)
        _, day, at = quickadd.resolve(parsed.reminders[0], None, now.date().isoformat(), f"{now:%H:%M}")
        return due_instant({"date": day, "time": at})

    def _reminder_change(self, reminder_id, patch):
        def plan():
            if not live(self.store.rows("reminder").get(reminder_id)):
                raise CannotEdit("That reminder no longer exists")
            return [("reminder", reminder_id, patch)]

        self.commit(plan)

    def delete_reminder(self, reminder_id):
        self._reminder_change(reminder_id, {"deleted_at": self.now()})

    def snooze(self, reminder_id, until):
        """Fire again at until."""
        self._reminder_change(reminder_id, {"fire_at": until, "delivered_at": None, "dismissed_at": None})

    def dismiss(self, reminder_id):
        """Silence the current firing."""
        self._reminder_change(reminder_id, {"dismissed_at": self.now()})

    # ---- saved views ----

    def _check_view(self, changes):
        """The view fields as written: a name, a query that parses, known options."""
        out = dict(changes)
        if "name" in out:
            out["name"] = out["name"].strip()
            if not out["name"]:
                raise CannotEdit("A view needs a name")
        if "query" in out:
            out["query"] = out["query"].strip()
            try:
                if parse_query(out["query"]) is None:
                    raise CannotEdit("A view needs a query")
            except FilterError as err:
                raise CannotEdit(str(err)) from None
        for name, allowed in (("group_by", GROUP_BY), ("sort_by", SORT_BY), ("sort_dir", SORT_DIR)):
            if name in out and out[name] not in allowed:
                raise ValueError(f"{name}: {out[name]!r}")
        return out

    def add_view(self, name, query, **options):
        """A list view, last in the sidebar and pinned. Returns its id."""
        unknown = set(options) - set(VIEW_EDITABLE)
        if unknown:
            raise ValueError(f"not a view option: {sorted(unknown)}")
        fields = self._check_view({"name": name, "query": query, **options})
        view_id = str(uuid.uuid4())

        def plan():
            now = self.now()
            positions = [p for v in self.store.rows("view").values()
                         if live(v) and (p := number(v.get("position"))) is not None]
            # Display options only when they differ from the defaults, like the web app.
            show_completed = {"show_completed": True} if fields.get("show_completed") else {}
            return [("view", view_id, {
                "name": fields["name"], "query": fields["query"], "kind": "list",
                **{k: fields.get(k, VIEW_DEFAULTS[k]) for k in ("group_by", "sort_by", "sort_dir")},
                "pinned": True, "position": max([now] + [p + 1 for p in positions]),
                "color": VIEW_DEFAULTS["color"], "panels": [], **show_completed,
                "created_at": now, "deleted_at": None,
            })]

        self.commit(plan)
        return view_id

    def edit_view(self, view_id, changes):
        """Write the changed fields of a view: any of VIEW_EDITABLE. One batch."""
        unknown = set(changes) - set(VIEW_EDITABLE)
        if unknown:
            raise ValueError(f"not editable: {sorted(unknown)}")
        fields = self._check_view(changes)

        def plan():
            view = self.store.rows("view").get(view_id)
            if not live(view):
                raise CannotEdit("That view no longer exists")
            patch = {k: v for k, v in fields.items() if view.get(k, False if k == "show_completed" else None) != v}
            return [("view", view_id, patch)] if patch else []

        self.commit(plan)

    def delete_view(self, view_id):
        def plan():
            if not live(self.store.rows("view").get(view_id)):
                raise CannotEdit("That view no longer exists")
            return [("view", view_id, {"deleted_at": self.now()})]

        self.commit(plan)

    # ---- projects and sections (spec/projects.md) ----

    def _project(self, projects, project_id):
        project = projects.get(project_id)
        if not live(project):
            raise CannotEdit("That project no longer exists")
        return project

    def _check_parent(self, projects, parent_id, project_id=None):
        """A parent a project may go under: live, not archived, not the project or below it."""
        if parent_id is None:
            return
        parent = projects.get(parent_id)
        if not live(parent) or parent.get("archived"):
            raise CannotEdit("That parent project no longer exists")
        if project_id is not None and (parent_id == project_id
                                       or parent_id in {p.id for p in project_descendants(project_id, projects)}):
            raise CannotEdit("A project can't go under itself")

    def _last_project_position(self, projects, parent_id, skip=None):
        """Last among the live projects under parent_id: the web app's rule, + 1 rather than + GAP."""
        position = self.now()
        for p in projects.values():
            if p.id != skip and live(p) and p.get("parent_id") == parent_id and (n := number(p.get("position"))) is not None:
                position = max(position, n + 1)
        return position

    def add_project(self, name, parent_id=None, color=None):
        """A project, last at the top level or under parent_id. Returns its id."""
        name = name.strip()
        if not name:
            raise CannotEdit("A project needs a name")
        project_id = str(uuid.uuid4())

        def plan():
            projects = self.store.rows("project")
            self._check_parent(projects, parent_id)
            used = {p.get("color") for p in projects.values() if live(p)}
            return [("project", project_id, {
                "name": name, "color": color or next((c for c in PROJECT_PALETTE if c not in used), PROJECT_PALETTE[0]),
                "position": self._last_project_position(projects, parent_id), "archived": False,
                "parent_id": parent_id, "created_at": self.now(), "deleted_at": None,
            })]

        self.commit(plan)
        return project_id

    def edit_project(self, project_id, changes):
        """Write the changed fields of a project: any of name, color and parent_id. One batch.

        A new parent also writes a position, last among the new siblings.
        """
        unknown = set(changes) - {"name", "color", "parent_id"}
        if unknown:
            raise ValueError(f"not editable: {sorted(unknown)}")

        def plan():
            projects = self.store.rows("project")
            project = self._project(projects, project_id)
            patch = {}
            if "name" in changes:
                name = changes["name"].strip()
                if not name:
                    raise CannotEdit("A project needs a name")
                if name != project.get("name"):
                    patch["name"] = name
            if "color" in changes and changes["color"] != project.get("color"):
                if not re.fullmatch(r"#[0-9a-fA-F]{6}", changes["color"] or ""):
                    raise ValueError(f"color: {changes['color']!r}")
                patch["color"] = changes["color"]
            if "parent_id" in changes and changes["parent_id"] != project.get("parent_id"):
                self._check_parent(projects, changes["parent_id"], project_id)
                patch["parent_id"] = changes["parent_id"]
                patch["position"] = self._last_project_position(projects, changes["parent_id"], skip=project_id)
            return [("project", project_id, patch)] if patch else []

        return self.commit(self._undoable(plan))

    def archive_project(self, project_id):
        """Archive a project and every live sub-project below it."""

        def plan():
            projects = self.store.rows("project")
            project = self._project(projects, project_id)
            below = [p for p in project_descendants(project_id, projects) if not p.get("archived")]
            archived = ([project] if not project.get("archived") else []) + below
            # Undo writes false, never null: archived is a boolean even where it was never set.
            return ([("project", p.id, {"archived": True}) for p in archived],
                    Done([("project", p.id, {"archived": False}) for p in archived]))

        return self.commit(plan)

    def unarchive_project(self, project_id):
        """Unarchive one project. Its archived sub-projects stay archived, as in the web app."""

        def plan():
            project = self._project(self.store.rows("project"), project_id)
            return [("project", project_id, {"archived": False})] if project.get("archived") else []

        return self.commit(self._undoable(plan))

    def delete_project(self, project_id):
        """Tombstone a project. Its direct sub-projects move up to its parent. Its tasks keep project_id."""

        def plan():
            projects = self.store.rows("project")
            project = self._project(projects, project_id)
            parent_id = project.get("parent_id")
            changes = [("project", p.id, {"parent_id": None if parent_id == p.id else parent_id})
                       for p in projects.values()
                       if live(p) and p.get("parent_id") == project_id and p.id != project_id]
            return changes + [("project", project_id, {"deleted_at": self.now()})]

        return self.commit(self._undoable(plan))

    def _sections(self, project_id):
        """The project's live sections, in order."""
        return sorted((s for s in self.store.rows("section").values()
                       if live(s) and s.get("project_id") == project_id),
                      key=lambda s: (number(s.get("position")) or 0, s.id))

    def _section(self, section_id):
        section = self.store.rows("section").get(section_id)
        if not live(section):
            raise CannotEdit("That section no longer exists")
        return section

    def add_section(self, project_id, name):
        """A section, last in its project. Returns its id."""
        name = name.strip()
        if not name:
            raise CannotEdit("A section needs a name")
        section_id = str(uuid.uuid4())

        def plan():
            if project_id is None:
                raise CannotEdit("The Inbox has no sections")
            self._check_project(project_id)
            positions = [p for s in self._sections(project_id) if (p := number(s.get("position"))) is not None]
            return [("section", section_id, {
                "name": name, "project_id": project_id,
                "position": max(positions) + GAP if positions else self.now(),
                "created_at": self.now(), "deleted_at": None,
            })]

        self.commit(plan)
        return section_id

    def rename_section(self, section_id, name):
        name = name.strip()
        if not name:
            raise CannotEdit("A section needs a name")

        def plan():
            section = self._section(section_id)
            return [("section", section_id, {"name": name})] if name != section.get("name") else []

        return self.commit(self._undoable(plan))

    def move_section(self, section_id, step):
        """Move a section one place up (-1) or down (+1) among its project's sections."""

        def plan():
            siblings = [(s.id, number(s.get("position")) or 0)
                        for s in self._sections(self._section(section_id).get("project_id"))]
            index = [sid for sid, _ in siblings].index(section_id) + step
            if not 0 <= index < len(siblings):
                return []
            return [("section", sid, {"position": p}) for sid, p in plan_move(siblings, section_id, index, self.now())]

        return self.commit(self._undoable(plan))

    def delete_section(self, section_id):
        """Tombstone a section. Its live open tasks go to "No section", in the same batch."""

        def plan():
            self._section(section_id)
            tasks = [t for t in self.store.rows("task").values()
                     if live(t) and t.get("completed_at") is None and t.get("section_id") == section_id]
            return ([("section", section_id, {"deleted_at": self.now()})] +
                    [("task", t.id, {"section_id": None}) for t in tasks])

        return self.commit(self._undoable(plan))

    # ---- the sidebar's order: projects, labels, views (spec/dragdrop.md, "In the sidebar") ----

    def _reorder(self, entity, rows, moved_id, index):
        """The position writes that put moved_id at index of rows (live, in sidebar order), counted without it."""
        siblings = [(r.id, number(r.get("position")) or 0) for r in rows]
        return [(entity, i, {"position": p}) for i, p in plan_move(siblings, moved_id, index, self.now())]

    def _step(self, entity, rows, moved_id, step):
        """One place up (-1) or down (+1) among rows. Nothing at an edge."""
        index = [r.id for r in rows].index(moved_id) + step
        return self._reorder(entity, rows, moved_id, index) if 0 <= index < len(rows) else []

    def _place(self, entity, rows, moved_id, before=None, after=None):
        """Right before or after a sibling in rows, or last when neither is named or found."""
        order = [r.id for r in rows if r.id != moved_id]
        index = order.index(before) if before in order else order.index(after) + 1 if after in order else len(order)
        return self._reorder(entity, rows, moved_id, index)

    def _project_siblings(self, parent_id):
        """The live, unarchived projects under parent_id, in sidebar order."""
        return sorted((p for p in self.store.rows("project").values()
                       if live(p) and not p.get("archived") and p.get("parent_id") == parent_id), key=order_key)

    def place_project(self, project_id, parent_id=None, before=None, after=None):
        """Put a project under parent_id (None: the top level), right before or after a sibling, or last.

        One batch: the parent when it changes, and the positions. Never under itself or below it.
        """

        def plan():
            projects = self.store.rows("project")
            project = self._project(projects, project_id)
            changes = self._place("project", self._project_siblings(parent_id), project_id, before, after)
            if parent_id != project.get("parent_id"):
                self._check_parent(projects, parent_id, project_id)
                changes = [("project", project_id, {"parent_id": parent_id})] + changes
            return changes

        return self.commit(self._undoable(plan))

    def move_project(self, project_id, step):
        """Move a project one place up (-1) or down (+1) among its siblings."""

        def plan():
            project = self._project(self.store.rows("project"), project_id)
            return self._step("project", self._project_siblings(project.get("parent_id")), project_id, step)

        return self.commit(self._undoable(plan))

    def _list_views(self):
        """The views the sidebar lists, in its order. Dashboards keep their positions."""
        return sorted((v for v in self.store.rows("view").values() if is_list_view(v)), key=view_order)

    def _view(self, view_id):
        view = self.store.rows("view").get(view_id)
        if not live(view):
            raise CannotEdit("That view no longer exists")
        return view

    def place_view(self, view_id, before=None, after=None):
        """Put a view right before or after another in the sidebar (a drag)."""

        def plan():
            self._view(view_id)
            return self._place("view", self._list_views(), view_id, before, after)

        return self.commit(self._undoable(plan))

    def move_view(self, view_id, step):
        """Move a view one place up (-1) or down (+1) in the sidebar."""

        def plan():
            self._view(view_id)
            return self._step("view", self._list_views(), view_id, step)

        return self.commit(self._undoable(plan))

    # ---- labels (spec/labels.md) ----

    def _live_labels(self):
        return [r for r in self.store.rows("label").values() if live(r)]

    def _label(self, label_id):
        label = self.store.rows("label").get(label_id)
        if not live(label):
            raise CannotEdit("That label no longer exists")
        return label

    def _label_name(self, name, label_id=None):
        """A name a label may take: not empty, and no other label's, ignoring case."""
        name = (name or "").strip()
        if not name:
            raise CannotEdit("A label needs a name")
        other = label_rules.exact([r for r in self._live_labels() if r.id != label_id], name)
        if other is not None:
            raise CannotEdit(f"There's already a label called “{other.get('name')}”")
        return name

    def add_label(self, name, color=None):
        """A label, last in the sidebar. Returns its id."""
        label_id = str(uuid.uuid4())

        def plan():
            used = {r.get("color") for r in self._live_labels()}
            now = self.now()
            return [("label", label_id, {
                "name": self._label_name(name), "position": now, "created_at": now, "deleted_at": None,
                "color": color or next((c for c in LABEL_PALETTE if c not in used), LABEL_PALETTE[now % len(LABEL_PALETTE)]),
            })]

        self.commit(plan)
        return label_id

    def edit_label(self, label_id, changes):
        """Rename or recolour. One op per changed field; no task is written, since tasks hold ids."""
        unknown = set(changes) - {"name", "color"}
        if unknown:
            raise ValueError(f"not editable: {sorted(unknown)}")

        def plan():
            label = self._label(label_id)
            patch = {}
            if "name" in changes and changes["name"].strip() != label.get("name"):
                patch["name"] = self._label_name(changes["name"], label_id)
            if "color" in changes and changes["color"] != label.get("color"):
                if not re.fullmatch(r"#[0-9a-fA-F]{6}", changes["color"] or ""):
                    raise ValueError(f"color: {changes['color']!r}")
                patch["color"] = changes["color"]
            return [("label", label_id, patch)] if patch else []

        return self.commit(self._undoable(plan))

    def move_label(self, label_id, step):
        """Move a label one place up (-1) or down (+1) in the sidebar."""

        def plan():
            self._label(label_id)
            return self._step("label", label_rules.in_order(self._live_labels()), label_id, step)

        return self.commit(self._undoable(plan))

    def place_label(self, label_id, before=None, after=None):
        """Put a label right before or after another in the sidebar (a drag)."""

        def plan():
            self._label(label_id)
            return self._place("label", label_rules.in_order(self._live_labels()), label_id, before, after)

        return self.commit(self._undoable(plan))

    def delete_label(self, label_id):
        """Tombstone a label and take its id off every live task, one op per task."""

        def plan():
            self._label(label_id)
            changes = [("task", t.id, {"labels": [i for i in t.get("labels") if i != label_id]})
                       for t in label_rules.carrying(self.store.rows("task").values(), label_id)]
            return changes + [("label", label_id, {"deleted_at": self.now()})]

        return self.commit(self._undoable(plan))

    def merge_labels(self, source_id, target_id):
        """Every live task with source carries target instead, once. Then source is deleted."""

        def plan():
            if source_id == target_id:
                raise CannotEdit("A label can't merge into itself")
            self._label(source_id)
            self._label(target_id)
            changes = []
            for task in label_rules.carrying(self.store.rows("task").values(), source_id):
                merged = list(dict.fromkeys(target_id if i == source_id else i for i in task.get("labels")))
                changes.append(("task", task.id, {"labels": merged}))
            return changes + [("label", source_id, {"deleted_at": self.now()})]

        return self.commit(self._undoable(plan))

    def change_task_labels(self, task_id, add=(), remove=()):
        """Add labels (ids, or names that create one) and remove ids, from the task's current array.

        Reads the array in the same transaction as the write, so edits in a row never lose a label.
        Returns a Done whose undo puts the array back.
        """

        def plan():
            task = self._task(self.store.rows("task"), task_id)
            current = list(task.get("labels") or [])
            added, created = self._label_ids(add)
            wanted = [i for i in dict.fromkeys(current + added) if i not in set(remove)]
            if wanted == current:
                return []
            return created + [("task", task_id, {"labels": wanted})]

        return self.commit(self._undoable(plan))

    # ---- preferences (user_prefs "me") ----

    def set_prefs(self, changes):
        """Write changed fields on user_prefs 'me', working both standalone and synced."""
        unknown = set(changes) - set(PREF_DEFAULTS)
        if unknown:
            raise ValueError(f"not editable: {sorted(unknown)}")
        enums = {"date_format": DATE_FORMATS, "time_format": TIME_FORMATS,
                 "week_start": WEEK_STARTS, "language": LANGUAGES}

        def normalize(name, value):
            if name in enums:
                if value not in enums[name]:
                    raise CannotEdit(f"Unsupported {name}: {value!r}")
                return value
            if name == "day_start":
                if value == "":
                    return ""
                if not isinstance(value, str) or not re.fullmatch(r"\d{2}:[0-5]\d", value):
                    raise CannotEdit("Write the day start as HH:MM from 00:00 to 06:00")
                minutes = int(value[:2]) * 60 + int(value[3:])
                if minutes > 6 * 60:
                    raise CannotEdit("Day start can be at most 06:00")
                return value
            if name in ("reminder_default_timed", "reminder_default_dated"):
                if value in (None, ""):
                    return ""
                if isinstance(value, int) and not isinstance(value, bool):
                    if abs(value) > MAX_OFFSET:
                        raise CannotEdit("A reminder can be at most a year from the due time")
                    return format_default(value)
                parsed = parse_default(value)
                if parsed is None:
                    raise CannotEdit("A reminder can be at most a year from the due time")
                return format_default(parsed)
            if isinstance(value, bool):
                return "on" if value else "off"
            if value not in ("on", "off", ""):
                raise CannotEdit(f"Unsupported {name}: {value!r}")
            return value

        normalized = {k: normalize(k, v) for k, v in changes.items()}

        def plan():
            row = self.store.rows("user_prefs").get("me")
            cur_vals = row.values if row else {}
            patch = {}
            for name, want in normalized.items():
                cur = cur_vals.get(name)
                if name in enums:
                    if want != (cur if cur in enums[name] else "system"):
                        patch[name] = want
                elif name == "day_start":
                    want_min = day_start_minutes(want)
                    cur_min = day_start_minutes(cur)
                    if want_min != cur_min or (want_min == 0 and cur not in (None, "", "00:00")):
                        patch[name] = want
                elif name in ("reminder_default_timed", "reminder_default_dated"):
                    if parse_default(want) != parse_default(cur) or (want == "" and cur not in (None, "")):
                        patch[name] = want
                else:
                    if (want == "on") != (cur == "on"):
                        patch[name] = want
            return [("user_prefs", "me", patch)] if patch else []

        self.commit(plan)


def project_descendants(project_id, projects):
    """Every live project below project_id. Safe against cycles."""
    children = {}
    for p in projects.values():
        if live(p) and p.get("parent_id"):
            children.setdefault(p.get("parent_id"), []).append(p)
    found, stack, seen = [], [project_id], {project_id}
    while stack:
        for child in children.get(stack.pop(), []):
            if child.id not in seen:
                seen.add(child.id)
                found.append(child)
                stack.append(child.id)
    return found
