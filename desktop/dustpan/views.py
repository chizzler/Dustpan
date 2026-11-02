"""What the Inbox, Today, Upcoming and saved views list, and in what order.

Ports web/src/lib/inbox.ts and views.ts (v0.18.0). See spec/views.md.
"""

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from functools import cmp_to_key

from .dates import local_due, logical_today
from .filters import Context, FilterError, compile_query, due_day, parse, shift, with_completed

GROUP_BY = ("project", "due", "priority", "label", "none")
SORT_BY = ("due", "priority", "position", "created", "deadline", "title")
SORT_DIR = ("asc", "desc")
DEFAULTS = {"group_by": "project", "sort_by": "due", "sort_dir": "asc", "color": "#64748b"}
WEEK_START = {"sun": 0, "mon": 1, "sat": 6}  # user_prefs.week_start; "system" reads as Monday
MAX_PARENT_DEPTH = 64


@dataclass
class Group:
    key: str
    heading: str
    tasks: list  # Rows


@dataclass
class Result:
    groups: list
    count: int  # open matches
    warnings: list
    error: str | None = None


# ---- the Inbox: open tasks with no place yet ----


def is_placed(task):
    """A project, a do-on date, a start date or Someday. A deadline alone doesn't place a task."""
    return task.get("project_id") is not None or bool(task.get("due")) or bool(task.get("start"))


def is_inbox_task(task, parent_of=lambda _id: None):
    """Open, live and unplaced, and so is every parent that can be found."""
    if task.get("completed_at") is not None or task.get("deleted_at") is not None or is_placed(task):
        return False
    parent_id = task.get("parent_id")
    for _ in range(MAX_PARENT_DEPTH):
        parent = parent_of(parent_id) if parent_id else None
        if parent is None:
            break
        if is_placed(parent):
            return False
        parent_id = parent.get("parent_id")
    return True


# ---- start dates ----


def is_someday(task):
    return task.get("start") == "someday"


def is_deferred(task, today):
    start = task.get("start")
    return bool(start) and start != "someday" and start > today


def is_active(task, today):
    """Neither parked nor deferred: what the planning views and counts consider."""
    return not is_someday(task) and not is_deferred(task, today)


def open_count(task, today):
    """Counted in the sidebar."""
    return task.get("completed_at") is None and is_active(task, today)


# ---- Today and Upcoming ----


def due_date(task):
    return due_day(task.get("due")) if task.get("due") else None


def in_today(task, today):
    """Due or deadline today or earlier, or a start date that has come. A hard date beats deferral."""
    if task.get("completed_at") is not None:
        return False
    due, deadline, start = due_date(task), task.get("deadline"), task.get("start")
    hard = (due is not None and due <= today) or (bool(deadline) and deadline <= today)
    return hard or (bool(start) and start != "someday" and start <= today)


def overdue_in_today(task, today):
    """Today's Earlier group: due before today, or a passed deadline not planned for today."""
    due, deadline = due_date(task), task.get("deadline")
    return (due is not None and due < today) or (bool(deadline) and deadline < today and due != today)


def deferred_unplaced(task, today):
    """Deferred, with no project and no do-on date: listed in Upcoming on its start date."""
    return (task.get("completed_at") is None and task.get("project_id") is None and not task.get("due")
            and is_deferred(task, today))


def in_upcoming(task, today):
    if deferred_unplaced(task, today):
        return True
    if task.get("completed_at") is not None or not is_active(task, today):
        return False
    if task.get("due"):
        return due_date(task) > today
    return bool(task.get("deadline")) and task.get("deadline") > today


def upcoming_date(task, today):
    """The day Upcoming lists a task under: its due date, else a deferred start, else its deadline."""
    if task.get("due"):
        return due_date(task)
    if deferred_unplaced(task, today):
        return task.get("start")
    return task.get("deadline")


# ---- sorting ----


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def sign(a, b):
    return (a > b) - (a < b)


def compare_due(a, b):
    """Earlier first, all-day after timed on the same day, undated last."""
    if not a or not b:
        return bool(not a) - bool(not b)
    (da, ta), (db, tb) = local_due(a), local_due(b)
    return sign((da, ta.isoformat() if ta else "99:99"), (db, tb.isoformat() if tb else "99:99"))


def compare_tasks(sort_by, sort_dir):
    """A comparator for one sort. Undated tasks stay last under due and deadline sorts.
    For priority, descending lists priority 1 first. Ties fall back to due, priority, position, id.
    """
    flip = -1 if sort_dir == "desc" else 1

    def fallback(a, b):
        return (compare_due(a.get("due"), b.get("due")) or sign(number(a.get("priority")), number(b.get("priority")))
                or sign(number(a.get("position")), number(b.get("position"))) or sign(a.id, b.id))

    def by(a, b):
        if sort_by == "due":
            if not a.get("due") or not b.get("due"):
                return compare_due(a.get("due"), b.get("due"))
            return flip * compare_due(a.get("due"), b.get("due"))
        if sort_by == "deadline":
            da, db = a.get("deadline"), b.get("deadline")
            return bool(not da) - bool(not db) if not da or not db else flip * sign(da, db)
        if sort_by == "priority":
            return flip * sign(number(b.get("priority")), number(a.get("priority")))
        if sort_by == "title":
            return flip * sign(str(a.get("title", "")).casefold(), str(b.get("title", "")).casefold())
        name = {"position": "position", "created": "created_at"}[sort_by]
        return flip * sign(number(a.get(name)), number(b.get(name)))

    return lambda a, b: by(a, b) or fallback(a, b)


def manual_order(order, sort_dir):
    """A view's own order: placed tasks in the stored order, then the rest by position."""
    rank = {}
    for task_id in order if isinstance(order, list) else []:
        if isinstance(task_id, str):
            rank.setdefault(task_id, len(rank))

    def asc(a, b):
        ra, rb = rank.get(a.id), rank.get(b.id)
        if ra is not None or rb is not None:
            return sign(ra, rb) if ra is not None and rb is not None else (-1 if ra is not None else 1)
        return (sign(number(a.get("position")), number(b.get("position"))) or compare_due(a.get("due"), b.get("due"))
                or sign(number(a.get("priority")), number(b.get("priority"))) or sign(a.id, b.id))

    return (lambda a, b: asc(b, a)) if sort_dir == "desc" else asc


def sorted_tasks(tasks, comparator):
    return sorted(tasks, key=cmp_to_key(comparator))


# ---- grouping ----


def group_tasks(tasks, group_by, today, labels, projects, day_heading):
    """Sorted tasks split into headed groups, in a fixed order.

    labels: live label Rows in sidebar order. projects: (id, path) in sidebar order.
    day_heading(iso) names a later day.
    """
    buckets = {}

    def put(key, task):
        buckets.setdefault(key, []).append(task)

    def emit(order):
        return [Group(key, heading, buckets[key]) for key, heading in order if key in buckets]

    if group_by == "none":
        return [Group("all", "", tasks)] if tasks else []
    if group_by == "priority":
        for task in tasks:
            put(f"p{task.get('priority')}", task)
        return emit([(f"p{p}", f"Priority {p}" if p < 4 else "No priority") for p in (1, 2, 3, 4)])
    if group_by == "due":
        tomorrow = shift(today, 1)
        later = set()
        for task in tasks:
            day = due_date(task)
            key = "none" if day is None else "overdue" if day < today else "today" if day == today else \
                "tomorrow" if day == tomorrow else day
            if key == day:
                later.add(day)
            put(key, task)
        return emit([("overdue", "Earlier"), ("today", "Today"), ("tomorrow", "Tomorrow"),
                     *((d, day_heading(d)) for d in sorted(later)), ("none", "No date")])
    if group_by == "label":
        # A task with several labels is listed under each.
        known = {label.id for label in labels}
        for task in tasks:
            own = [i for i in dict.fromkeys(task.get("labels") or []) if i in known]
            for key in own or ["none"]:
                put(key, task)
        return emit([*((label.id, label.get("name", "")) for label in labels), ("none", "No label")])
    known = {pid for pid, _ in projects}
    for task in tasks:
        pid = task.get("project_id")
        put("inbox" if pid is None else pid if pid in known else "other", task)
    return emit([("inbox", "Inbox"), *projects, ("other", "Other")])


# ---- Anytime and Completed (web/src/lib/views.ts inAnytime, lib/logbook.ts) ----

LOGBOOK_PAGE = 100  # completions shown at first, and added by each "Show more"


def in_anytime(task, today):
    """Open and active, with no date of any kind and no start: for whenever there's time."""
    return (task.get("completed_at") is None and is_active(task, today) and not task.get("due")
            and not task.get("deadline") and task.get("start") is None)


def logbook_heading(iso, today):
    """ "Today", "Yesterday", then the weekday and date, with the year outside this year."""
    day, now = date.fromisoformat(iso), date.fromisoformat(today)
    if day == now:
        return "Today"
    if day == now - timedelta(days=1):
        return "Yesterday"
    return day.strftime("%A %-d %B") + (f" {day.year}" if day.year != now.year else "")


def logbook(tasks, limit, today, day_start=0):
    """(Groups of the first limit completed tasks, newest first, by the day they were completed; how many in all).

    The day follows the user's day start, so a 01:30 completion with a 04:00 start belongs to the day before.
    """
    done = sorted((t for t in tasks if isinstance(t.get("completed_at"), (int, float)) and t.get("deleted_at") is None),
                  key=lambda t: (-t.get("completed_at"), t.id))
    groups = []
    for task in done[:max(0, limit)]:
        day = logical_today(day_start, datetime.fromtimestamp(task.get("completed_at") / 1000))
        if groups and groups[-1].key == day:
            groups[-1].tasks.append(task)
        else:
            groups.append(Group(day, logbook_heading(day, today), [task]))
    return groups, len(done)


def today_groups(tasks, today):
    """Today: the Earlier group, then today's tasks by time."""
    listed = sorted_tasks([t for t in tasks if in_today(t, today)], compare_tasks("due", "asc"))
    earlier = [t for t in listed if overdue_in_today(t, today)]
    rest = [t for t in listed if not overdue_in_today(t, today)]
    return [g for g in (Group("earlier", "Earlier", earlier), Group("today", "Today", rest)) if g.tasks]


def upcoming_groups(tasks, today, day_heading):
    """Upcoming: one group per day. On each day, tasks due then come before ones with only a deadline."""
    by_due = compare_tasks("due", "asc")

    def order(a, b):
        return (sign(upcoming_date(a, today), upcoming_date(b, today))
                or bool(not a.get("due")) - bool(not b.get("due")) or by_due(a, b))

    groups = {}
    for task in sorted_tasks([t for t in tasks if in_upcoming(t, today)], order):
        groups.setdefault(upcoming_date(task, today), []).append(task)
    return [Group(day, day_heading(day), listed) for day, listed in groups.items()]


# ---- saved views ----


def view_options(view):
    """(group_by, sort_by, sort_dir). A value this client doesn't know reads as the default."""
    def pick(name, allowed):
        value = view.get(name)
        return value if value in allowed else DEFAULTS[name]

    return pick("group_by", GROUP_BY), pick("sort_by", SORT_BY), pick("sort_dir", SORT_DIR)


def is_list_view(view):
    """Live and not a dashboard. An unknown kind reads as a list."""
    return view.get("deleted_at") is None and view.get("kind") != "dashboard"


def view_order(view):
    return (number(view.get("position")), number(view.get("created_at")), view.id)


def run_query(query, ctx, candidates, show_completed=False):
    """(matching tasks, open count, warnings). Raises FilterError."""
    ast = parse(query)
    if ast is None:
        raise FilterError("This view has no query", 0)
    test, warnings = compile_query(with_completed(ast) if show_completed else ast, ctx)
    matches = [t for t in candidates if test(t)]
    return matches, sum(t.get("completed_at") is None for t in matches), warnings


def run_view(view, ctx: Context, candidates, labels, projects, day_heading):
    """A saved view's groups. A query this client can't parse gives its error and no results."""
    try:
        matches, count, warnings = run_query(view.get("query") or "", ctx, candidates, view.get("show_completed") is True)
    except FilterError as err:
        return Result([], 0, [], str(err))
    group_by, sort_by, sort_dir = view_options(view)
    comparator = manual_order(view.get("manual_order"), sort_dir) if sort_by == "position" else compare_tasks(sort_by, sort_dir)
    tasks = sorted_tasks(matches, comparator)
    return Result(group_tasks(tasks, group_by, ctx.today, labels, projects, day_heading), count, warnings)
