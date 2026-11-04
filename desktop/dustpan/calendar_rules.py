"""The calendar's rules: which tasks show on which day, in what order, and how full a day is.

Ports of web/src/lib/month.ts and parts of calendar.ts (v0.22.0). Pure; calendarwindow.py draws them.
Not named calendar.py: run from this folder, that would hide the standard library's calendar module.
See spec/calendar.md.
"""

from datetime import date, timedelta

from .dates import local_due
from .dragdrop import Stretch, ToDay, ToSlot

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


# ---- Day and Week: blocks on a time grid (calendar.ts, layout.ts) ----

DAY_MINUTES = 24 * 60
SLOT_MINUTES = 15
DEFAULT_BLOCK_MINUTES = 30  # how long an unestimated block is drawn; it counts for nothing
MIN_BLOCK_MINUTES = 25  # the shortest a block is drawn: room for its title
LAST_SLOT = DAY_MINUTES - SLOT_MINUTES  # the latest a block may start
MAX_ESTIMATE = 7 * DAY_MINUTES  # the longest estimate: one week
MAX_LANES = 4
GRID = {"startHour": 6, "endHour": 22, "dayLength": DAY_LENGTH}  # the web app's per-device defaults
DAY_LENGTHS = (240, 300, 360, 420, 480, 540, 600, 720)  # the settings' choices, as the web app's


def clamp(n, lo, hi):
    return min(hi, max(lo, n))


def hhmm(minutes):
    """Minutes from midnight as "HH:MM"."""
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


def grid_prefs(raw):
    """This device's grid settings (meta calendar_grid), each invalid or missing one at its default.

    A port of normalizeGridPrefs: when the hours cross, the stored one is kept and the other repaired.
    """
    raw = raw if isinstance(raw, dict) else {}

    def whole(name, lo, hi):
        value = raw.get(name)
        return value if type(value) is int and lo <= value <= hi else None

    start, end = whole("startHour", 0, 23), whole("endHour", 1, 24)
    start_hour = GRID["startHour"] if start is None else start
    end_hour = GRID["endHour"] if end is None else end
    if end_hour <= start_hour:
        if start is not None and end is None:
            end_hour = min(24, start_hour + 1)
        elif end is not None and start is None:
            start_hour = max(0, end_hour - 1)
        else:
            start_hour, end_hour = GRID["startHour"], GRID["endHour"]
    day_length = whole("dayLength", SLOT_MINUTES, DAY_MINUTES) or GRID["dayLength"]
    return {"startHour": start_hour, "endHour": end_hour, "dayLength": day_length}


# ---- stretching and keyboard steps (calendar.ts) ----


def resize_estimate(start, offset_px, px_per_minute):
    """The estimate from dragging a block's bottom edge to offset_px below midnight: whole slots, 15 minutes to a week."""
    if not px_per_minute > 0:
        return SLOT_MINUTES
    length = offset_px / px_per_minute - start
    return clamp(round(length / SLOT_MINUTES) * SLOT_MINUTES, SLOT_MINUTES, MAX_ESTIMATE)


def _snap(minutes, delta):
    """Onto the 15-minute grid, in the direction of travel."""
    return (minutes // SLOT_MINUTES if delta > 0 else -(-minutes // SLOT_MINUTES)) * SLOT_MINUTES


def step_estimate(current, delta):
    """The estimate delta minutes longer; an unestimated block starts from its drawn 30 minutes."""
    return clamp(_snap(current or DEFAULT_BLOCK_MINUTES, delta) + delta, SLOT_MINUTES, MAX_ESTIMATE)


def step_start(start, estimate, delta):
    """(start, estimate) with the start delta minutes later and the end where it was."""
    end = start + (estimate or DEFAULT_BLOCK_MINUTES)
    moved = clamp(_snap(start, delta) + delta, max(0, end - MAX_ESTIMATE), clamp(end - SLOT_MINUTES, 0, LAST_SLOT))
    return moved, end - moved


def _shift(day, days):
    return _iso(date.fromisoformat(day) + timedelta(days=days))


GRID_MOVES = ("earlier", "later", "day-before", "day-after", "shorter", "longer", "start-earlier", "start-later",
              "unschedule")


def grid_moves(task, grid_start, on_grid=True):
    """{move: drop target, or None when it would change nothing} for the keys and menu of a calendar task.

    On the grid (Day and Week): earlier and later by 15 minutes (a task without a time goes to the grid's
    first hour), a day either way, the estimate or the start 15 minutes either way, and back to the lane.
    Times set here are floating, as a drop on the grid. In Month only the day moves, keeping the time (ToDay).
    """
    due = viewed_due(task)
    if due is None:
        return {}
    day, at = due
    if not on_grid:
        return {"day-before": ToDay(_shift(day, -1)), "day-after": ToDay(_shift(day, 1))}
    start = parse_time(at)
    minutes = task.get("estimate_minutes")
    estimate = minutes if isinstance(minutes, int) and minutes > 0 else None

    def at_time(minute):
        minute = clamp(minute, 0, LAST_SLOT)
        return None if minute == start else ToSlot(day, hhmm(minute))

    moves = {"day-before": ToSlot(_shift(day, -1), at), "day-after": ToSlot(_shift(day, 1), at)}
    if start is None:
        place = ToSlot(day, hhmm(clamp(grid_start, 0, LAST_SLOT)))
        return {"earlier": place, "later": place, **moves, **dict.fromkeys(GRID_MOVES[4:])}
    moves.update(earlier=at_time(start - SLOT_MINUTES), later=at_time(start + SLOT_MINUTES), unschedule=ToSlot(day))
    for name, delta in (("shorter", -SLOT_MINUTES), ("longer", SLOT_MINUTES)):
        stepped = step_estimate(estimate, delta)
        moves[name] = None if stepped == estimate else Stretch(stepped)
    for name, delta in (("start-earlier", -SLOT_MINUTES), ("start-later", SLOT_MINUTES)):
        moved, length = step_start(start, estimate, delta)
        moves[name] = None if moved == start else Stretch(length, ToSlot(day, hhmm(moved)))
    return {name: moves[name] for name in GRID_MOVES}


def parse_time(text):
    """"HH:MM" as minutes from midnight, or None."""
    if not isinstance(text, str) or len(text) != 5 or text[2] != ":" or not (text[:2] + text[3:]).isdigit():
        return None
    hours, minutes = int(text[:2]), int(text[3:])
    return hours * 60 + minutes if hours < 24 and minutes < 60 else None


def block_for(task):
    """(start, end, estimated) of a task's block on its day, in minutes; None without a time.

    An unestimated block is drawn 30 minutes long. A block past midnight stops at the day's end.
    """
    due = viewed_due(task)
    start = parse_time(due[1]) if due else None
    if start is None:
        return None
    minutes = task.get("estimate_minutes")
    estimated = isinstance(minutes, int) and minutes > 0
    return start, min(DAY_MINUTES, start + (minutes if estimated else DEFAULT_BLOCK_MINUTES)), estimated


def layout_day(blocks, max_lanes=MAX_LANES, min_length=0):
    """Side by side layout of overlapping blocks. A port of layout.ts's layoutDay.

    blocks: (id, start, end). Returns (placed, overflow): placed are dicts with id, start, end, lane, lanes,
    overlap and hidden, in time order; overflow are dicts with lane, lanes, start, end and the hidden ids.
    Blocks that overlap, as drawn at least min_length tall, form a cluster split into equal lanes.
    A cluster needing more than max_lanes shows max_lanes − 1 lanes and a "+N" marker in the last.
    """
    cap = max(2, int(max_lanes))
    ordered = sorted(((i, s, e if e > s else s + 1) for i, s, e in blocks), key=lambda b: (b[1], -b[2], b[0]))
    placed, overflow = [], []
    cluster, lane_ends, cluster_end = [], [], float("-inf")

    def flush():
        if not cluster:
            return
        needed = len(lane_ends)

        def overlaps(x):
            return any(b is not x and b[1] < x[2] and x[1] < b[2] for b, _ in cluster)

        if needed <= cap:
            placed.extend(dict(id=b[0], start=b[1], end=b[2], lane=lane, lanes=needed, overlap=overlaps(b), hidden=False)
                          for b, lane in cluster)
            return
        marker = cap - 1
        hidden = []
        for b, lane in cluster:
            hide = lane >= marker
            placed.append(dict(id=b[0], start=b[1], end=b[2], lane=marker if hide else lane, lanes=cap,
                               overlap=overlaps(b), hidden=hide))
            if hide:
                hidden.append(b)
        overflow.append(dict(lane=marker, lanes=cap, start=min(b[1] for b in hidden), end=max(b[2] for b in hidden),
                             ids=[b[0] for b in hidden]))

    for b in ordered:
        if b[1] >= cluster_end:
            flush()
            cluster, lane_ends, cluster_end = [], [], float("-inf")
        end = max(b[2], b[1] + min_length)
        lane = next((i for i, e in enumerate(lane_ends) if e <= b[1]), None)
        if lane is None:
            lane = len(lane_ends)
            lane_ends.append(end)
        else:
            lane_ends[lane] = end
        cluster.append((b, lane))
        cluster_end = max(cluster_end, end)
    flush()
    return placed, overflow
