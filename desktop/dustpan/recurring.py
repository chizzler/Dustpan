"""Repeating tasks: what completing, skipping and detaching write.

A port of web/src/lib/recurring.ts. Every value is a function of inputs all devices
share (series id, rule, due date, occurrence date), so devices acting on the same
occurrence offline write identical entities and converge. See docs/recurrence.md.
"""

from .ids import detached_id, occurrence_id
from .recurrence import RuleError, following_occurrence, next_after_completion, next_calendar, parse, shift_date

# Optional fields an occurrence copy carries only when the series has them set.
COPIED_WHEN_SET = ("section_id", "deadline", "start", "day_part", "energy")


def series_rule(task):
    """The parsed rule of an open, live series, or None."""
    if task is None or not task.get("recurrence") or task.get("completed_at") or task.get("deleted_at"):
        return None
    try:
        return parse(task.get("recurrence"))
    except RuleError:
        return None


def occurrence_date(series, today):
    """The date of the occurrence the series stands on."""
    due = series.get("due")
    return due["date"] if due else today


def completed_occurrences(series_id, tasks, except_date=None):
    """Completed occurrence records of a series. Detached copies, reopened and skipped records don't count."""
    n = 0
    for t in tasks:
        due = t.get("due")
        if t.get("series_id") != series_id or not t.get("completed_at") or t.get("deleted_at") or not due:
            continue
        if t.get("skipped") or due.get("date") == except_date:
            continue
        if t.id == occurrence_id(series_id, due.get("date")):
            n += 1
    return n


def move_due(due, day):
    """The series' due on another date, keeping its time and zone."""
    if not due or not due.get("time"):
        return {"date": day}
    return {"date": day, "time": due["time"], **({"tz": due["tz"]} if due.get("tz") else {})}


def move_dates(series, nxt, today):
    """The series on its next occurrence. A deadline and a start date move by the same days."""
    current = occurrence_date(series, today)
    out = {"due": move_due(series.get("due"), nxt)}
    if series.get("deadline"):
        out["deadline"] = shift_date(series.get("deadline"), current, nxt)
    start = series.get("start")
    if start and start != "someday":
        out["start"] = shift_date(start, current, nxt)
    return out


def copy_of(series, now):
    """Fields an occurrence copy inherits from its series."""
    v = series.values
    out = {
        "title": v.get("title", ""), "description": v.get("description", ""),
        "project_id": v.get("project_id"), "parent_id": v.get("parent_id"),
        "priority": v.get("priority", 4), "due": v.get("due"), "labels": list(v.get("labels") or []),
        "created_at": now, "deleted_at": None, "estimate_minutes": v.get("estimate_minutes"),
        "recurrence": None, "series_id": series.id,
    }
    if isinstance(v.get("position"), (int, float)):
        out["position"] = v["position"]
    for name in COPIED_WHEN_SET:
        if v.get(name):
            out[name] = v[name]
    if v.get("evening"):
        out["evening"] = True
    # Custom field values, null included.
    out.update({name: value for name, value in v.items() if name.startswith("fields.")})
    return out


def occurrence_record(series, day, now):
    return {**copy_of(series, now), "due": series.get("due") or {"date": day}, "completed_at": now}


def plan_completion(series, rule, tasks, now, today):
    """(changes, record id, next date) for completing the current occurrence, or None at the end condition."""
    day = occurrence_date(series, today)
    done = completed_occurrences(series.id, tasks, day)
    due = series.get("due")
    nxt = following_occurrence(rule, due["date"] if due else None, today, today, done)
    if nxt is None:
        return None
    record_id = occurrence_id(series.id, day)
    record = occurrence_record(series, day, now)
    if series.get("habit"):
        record["skipped"] = False
    return [("task", record_id, record), ("task", series.id, move_dates(series, nxt, today))], record_id, nxt


def next_on_skip(series, rule, today):
    """The occurrence after the current one for skip and detach. None past "until"."""
    due = series.get("due")
    if rule.after_completion:
        nxt = next_after_completion(rule, today)
    else:
        nxt = next_calendar(rule, due["date"] if due else None, today)
    return None if rule.until and nxt > rule.until else nxt


def plan_skip(series, rule, now, today):
    """(changes, next date), or None on the last occurrence. A habit also records the skipped day."""
    nxt = next_on_skip(series, rule, today)
    if nxt is None:
        return None
    move = ("task", series.id, move_dates(series, nxt, today))
    if not series.get("habit"):
        return [move], nxt
    day = occurrence_date(series, today)
    record = {**occurrence_record(series, day, now), "skipped": True}
    return [("task", occurrence_id(series.id, day), record), move], nxt


def plan_detach(series, rule, now, today):
    """(changes, copy id, next date): a standalone copy of this occurrence, and the series moves on."""
    nxt = next_on_skip(series, rule, today)
    if nxt is None:
        return None
    day = occurrence_date(series, today)
    copy_id = detached_id(series.id, day)
    copy = {**copy_of(series, now), "due": series.get("due") or {"date": day}, "completed_at": None}
    return [("task", copy_id, copy), ("task", series.id, move_dates(series, nxt, today))], copy_id, nxt
