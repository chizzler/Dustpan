"""The calendar's rules: which tasks show on which day, in what order, and how full a day is.

Ports of web/src/lib/month.ts and parts of calendar.ts (v0.22.0). Pure; calendarwindow.py draws them.
See spec/calendar.md.
"""

from datetime import date, timedelta

from .dates import local_due

DAY_LENGTH = 480  # minutes: the web app's default day length


def _iso(day):
    return day.isoformat()


def week_dates(iso, week_start=1):
    """The seven days of the week holding iso, from week_start (0 = Sunday)."""
    day = date.fromisoformat(iso)
    back = (day.isoweekday() % 7 - week_start) % 7
    first = day - timedelta(days=back)
    return [_iso(first + timedelta(days=i)) for i in range(7)]


def month_grid(anchor, week_start=1):
    """Six weeks of seven days covering anchor's month."""
    first = date.fromisoformat(week_dates(anchor[:7] + "-01", week_start)[0])
    return [[_iso(first + timedelta(days=7 * row + col)) for col in range(7)] for row in range(6)]


def add_months(iso, months):
    """The same day `months` away, clamped to that month's last day."""
    day = date.fromisoformat(iso)
    index = day.year * 12 + day.month - 1 + months
    year, month = divmod(index, 12)
    month += 1
    last = (date(year + (month == 12), month % 12 + 1, 1) - timedelta(days=1)).day
    return _iso(date(year, month, min(day.day, last)))


def viewed_due(task):
    """(day, "HH:MM" or None) of a task's due on this device, or None. A zoned due converts."""
    due = task.get("due")
    if not due or not due.get("date"):
        return None
    day, at = local_due(due)
    return _iso(day), at.strftime("%H:%M") if at else None


def calendar_tasks(tasks, archived, first, last, show_completed=False):
    """Live tasks due in [first, last] on this device, outside archived projects.

    archived: ids of archived projects.
    """
    out = []
    for task in tasks:
        due = viewed_due(task)
        if (due and first <= due[0] <= last and task.get("deleted_at") is None
                and (show_completed or task.get("completed_at") is None)
                and task.get("project_id") not in archived):
            out.append(task)
    return out


def by_day(tasks):
    """{day: tasks} in a day's order: timed first by time, then priority (1 first), then position."""
    days = {}
    for task in tasks:
        day, at = viewed_due(task)
        days.setdefault(day, []).append((at is None, at or "", task.get("priority") or 4, task.get("position") or 0, task))
    return {day: [row[-1] for row in sorted(rows, key=lambda r: r[:4])] for day, rows in days.items()}


def deadline_markers(tasks, archived, first, last):
    """{day: open tasks whose deadline is that day}, leaving out a task due on its deadline day."""
    out = {}
    for task in tasks:
        deadline = task.get("deadline")
        due = viewed_due(task)
        if (not deadline or not first <= deadline <= last or task.get("deleted_at") is not None
                or task.get("completed_at") is not None or task.get("project_id") in archived
                or (due and due[0] == deadline)):
            continue
        out.setdefault(deadline, []).append(task)
    for markers in out.values():
        markers.sort(key=lambda t: (t.get("priority") or 4, (t.get("title") or "").lower()))
    return out


def day_load(tasks, day_length=DAY_LENGTH):
    """(planned minutes, open tasks without an estimate, over) for one day's tasks."""
    planned = unestimated = 0
    for task in tasks:
        if task.get("completed_at") is not None or task.get("deleted_at") is not None:
            continue
        if minutes := task.get("estimate_minutes"):
            planned += minutes
        else:
            unestimated += 1
    return planned, unestimated, planned > day_length


def visible_rows(cell, most):
    """(rows shown, how many are hidden): all when they fit, else most − 1 and a "+N more"."""
    if len(cell) <= most:
        return list(cell), 0
    keep = max(0, most - 1)
    return list(cell[:keep]), len(cell) - keep
