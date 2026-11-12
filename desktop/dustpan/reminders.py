"""Reminders: when they fire, snooze, and default reminders.

See docs/reminders.md and docs/default-reminders.md. The default reminder rule is
a port of web/src/lib/defaultReminder.ts, checked against defaultReminder.vectors.json.
"""

import re
from datetime import datetime, timedelta

from .dates import DEFAULT_REMINDER_TIME, due_instant
from .ids import default_reminder_id

MAX_OFFSET = 525600  # one year either side, in minutes

# (minutes from the due time, label). Offered in the editor.
RELATIVE_PRESETS = [(0, "At due time"), (-10, "10 minutes before"), (-30, "30 minutes before"),
                    (-60, "1 hour before"), (-1440, "1 day before")]
# (minutes from 09:00 on the deadline, label).
DEADLINE_PRESETS = [(0, "On the deadline"), (-1440, "1 day before the deadline")]
# Presets for Settings → Default reminders (matching OpenTodo's DefaultRemindersSettings.tsx).
DEFAULT_TIMED_PRESETS = list(RELATIVE_PRESETS)
DEFAULT_DATED_PRESETS = [(0, "On the day at 09:00"), (-1440, "1 day before"), (-2880, "2 days before"),
                         (-4320, "3 days before"), (-10080, "1 week before")]


def relative_fire_at(due, offset, local_zone=None):
    """A relative reminder fires at the due instant plus offset minutes. None without a due."""
    if not due:
        return None
    return due_instant(due, local_zone) + (offset or 0) * 60_000


def deadline_fire_at(deadline, offset):
    """A deadline reminder fires at 09:00 local on the deadline plus offset minutes. None without a deadline."""
    if not deadline:
        return None
    return due_instant({"date": deadline}) + (offset or 0) * 60_000


def is_dismissed(r):
    """Dismissed for the current firing. A dismissal older than fire_at was for an earlier one."""
    return r.get("dismissed_at") is not None and r.get("fire_at") is not None and r.get("dismissed_at") >= r.get("fire_at")


def is_due(r, task, now):
    """Fired, live, not dismissed, and its task is live and open."""
    if r.get("deleted_at") is not None or r.get("fire_at") is None or r.get("fire_at") > now:
        return False
    if is_dismissed(r):
        return False
    return task is not None and task.get("completed_at") is None and task.get("deleted_at") is None


def snooze_until(choice, now):
    """New firing instant: "10m", "1h", or "tomorrow" at 09:00 local."""
    if choice == "10m":
        return now + 10 * 60_000
    if choice == "1h":
        return now + 60 * 60_000
    tomorrow = datetime.fromtimestamp(now / 1000).date() + timedelta(days=1)
    return int(datetime.combine(tomorrow, DEFAULT_REMINDER_TIME).timestamp() * 1000)


def offset_label(minutes):
    """ "At due time", "30 minutes before", "2 hours after", "1 day before"."""
    m = minutes or 0
    if m == 0:
        return "At due time"
    n = abs(m)
    if n % 1440 == 0:
        n, unit = n // 1440, "day"
    elif n % 60 == 0:
        n, unit = n // 60, "hour"
    else:
        unit = "minute"
    return f"{n} {unit}{'s' if n != 1 else ''} {'before' if m < 0 else 'after'}"


def describe(r, time_format_12h=False):
    """One line for a reminder in the editor."""
    kind = r.get("kind")
    if kind == "relative":
        return offset_label(r.get("offset_minutes"))
    if kind == "deadline":
        m = r.get("offset_minutes") or 0
        return "On the deadline" if m == 0 else offset_label(m) + " the deadline"
    fire_at = r.get("fire_at")
    if fire_at is None:
        return "No time"
    return datetime.fromtimestamp(fire_at / 1000).strftime("%a %-d %b %Y, %H:%M")


# ---- default reminders ----

def parse_default(value):
    """A stored default: whole minutes within a year, else None."""
    if not isinstance(value, str) or not re.fullmatch(r"-?\d{1,7}", value):
        return None
    n = int(value)
    return n if abs(n) <= MAX_OFFSET else None


def read_defaults(prefs):
    """(timed, dated) defaults from a user_prefs row's values."""
    prefs = prefs or {}
    return parse_default(prefs.get("reminder_default_timed")), parse_default(prefs.get("reminder_default_dated"))


def format_default(minutes):
    """The user_prefs string for a default reminder offset, or '' for none."""
    if minutes is None:
        return ""
    if isinstance(minutes, bool) or not isinstance(minutes, int) or abs(minutes) > MAX_OFFSET:
        raise ValueError(f"reminder offset out of range: {minutes!r}")
    return str(minutes)


def parse_custom_offset(text):
    """Parse a custom offset like '15m', '2h', '3d before', '30 min after', or '-45' into signed minutes.

    Without 'after' or '+', a positive duration means before the due time (e.g. '15m' -> -15).
    Returns int within MAX_OFFSET, or None when invalid.
    """
    raw = (text or "").strip().lower()
    if not raw:
        return None
    if raw in ("0", "at due time"):
        return 0
    match = re.fullmatch(r"([+-])?\s*(\d{1,7})\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|wk|wks|week|weeks)?(?:\s*(before|after))?", raw)
    if not match:
        return None
    sign, amount, unit, direction = match.groups()
    if sign and direction:
        return None
    scale = {"h": 60, "hr": 60, "hrs": 60, "hour": 60, "hours": 60,
             "d": 1440, "day": 1440, "days": 1440,
             "w": 10080, "wk": 10080, "wks": 10080, "week": 10080, "weeks": 10080}.get(unit, 1)
    minutes = int(amount) * scale
    if minutes > MAX_OFFSET:
        return None
    if minutes == 0:
        return 0
    after = direction == "after" or sign == "+"
    return minutes if after else -minutes


def _due(value):
    return value if isinstance(value, dict) and isinstance(value.get("date"), str) and value["date"] else None


def _timed(due):
    return isinstance(due.get("time"), str) and due["time"] != ""


def plan_default_reminder(user_id, task_id, before, patch, reminders, batch, defaults, now, fire_at=relative_fire_at):
    """The reminder changes one write adds for one task.

    before: the stored task's values, or None when the write creates it.
    patch: every field the write sets on the task.
    reminders: this person's stored reminders of the task, as dicts with "id".
    batch: [(reminder id, patch)] already in the same write.
    defaults: (timed, dated) from read_defaults.
    Returns [(reminder id, patch)].
    """
    if "due" not in patch:
        return []
    rid = default_reminder_id(user_id, task_id)
    merged = {r["id"]: dict(r) for r in reminders}
    for eid, change in batch:
        prev = merged.get(eid)
        if prev is None and change.get("task_id") != task_id:
            continue
        merged[eid] = {**(prev or {"id": eid}), **change, "id": eid}
    rows = [r for r in merged.values() if r.get("task_id") in (None, task_id)]
    own = next((r for r in rows if r["id"] == rid), None)
    old_due = _due((before or {}).get("due"))
    new_due = _due(patch.get("due"))
    if not new_due:
        return []
    timed, dated = defaults

    def pref(d):
        return timed if _timed(d) else dated

    if old_due:
        # The kind of due changed and the default reminder is untouched.
        if _timed(old_due) == _timed(new_due) or not own or own.get("deleted_at") or own.get("kind", "relative") != "relative":
            return []
        src, dst = pref(old_due), pref(new_due)
        if src is None or dst is None or own.get("offset_minutes") != src or src == dst:
            return []
        return [(rid, {"offset_minutes": dst, "fire_at": fire_at(new_due, dst), "delivered_at": None, "dismissed_at": None})]
    offset = pref(new_due)
    if offset is None:
        return []
    after = {**(before or {}), **patch}
    if after.get("completed_at") or after.get("deleted_at") or after.get("habit") is True:
        return []
    if any(not r.get("deleted_at") and r.get("kind", "relative") == "relative" for r in rows):
        return []
    # A default reminder the person deleted stays deleted; one Undo removed (no offset left) may come back.
    if own and (not own.get("deleted_at") or own.get("offset_minutes") is not None):
        return []
    return [(rid, {"task_id": task_id, "kind": "relative", "offset_minutes": offset, "fire_at": fire_at(new_due, offset),
                   "delivered_at": None, "dismissed_at": None, "created_at": now, "deleted_at": None})]
