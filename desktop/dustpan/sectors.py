"""Time sectors: a task planned for a week, month or quarter instead of a day.

A port of web/src/lib/sectors.ts (v0.22.0), checked against sectors.vectors.json. See spec/sectors.md.
The stored value is absolute: "2026-W45", "2026-11" or "2026-Q4". Relative names (This week,
carried over) come from the viewer's date and first day of the week, and are never written.
"""

import calendar
import re
from dataclasses import dataclass, replace
from datetime import date, timedelta

WORDS = ("this-week", "next-week", "this-month", "next-month", "this-quarter", "next-quarter")
GROUPS = ("carried", *WORDS, "later")

_RE = re.compile(r"(\d{4})-(?:W(\d{2})|(\d{2})|Q(\d))")
_RANK = {"week": 0, "month": 1, "quarter": 2}


@dataclass(frozen=True)
class Period:
    kind: str  # "week", "month" or "quarter"
    year: int
    n: int  # the week (1–53), month (1–12) or quarter (1–4)

    def __str__(self):
        if self.kind == "week":
            return f"{self.year}-W{self.n:02d}"
        if self.kind == "month":
            return f"{self.year}-{self.n:02d}"
        return f"{self.year}-Q{self.n}"

    def range(self):
        """The first and last day, as dates."""
        if self.kind == "week":
            start = date.fromisocalendar(self.year, self.n, 1)
            return start, start + timedelta(days=6)
        first = self.n if self.kind == "month" else (self.n - 1) * 3 + 1
        months = 1 if self.kind == "month" else 3
        start = date(self.year, first, 1)
        after = date(self.year + 1, 1, 1) if first + months > 12 else date(self.year, first + months, 1)
        return start, after - timedelta(days=1)

    def next(self):
        """The period after this one, of the same kind."""
        last = weeks_in(self.year) if self.kind == "week" else 12 if self.kind == "month" else 4
        return replace(self, n=self.n + 1) if self.n < last else Period(self.kind, self.year + 1, 1)


def weeks_in(year):
    """52 or 53: 28 December is always in a year's last ISO week."""
    return date(year, 12, 28).isocalendar()[1]


def parse(value):
    """A stored sector as a Period, or None when empty or invalid (years 2000–2999)."""
    m = _RE.fullmatch(value) if isinstance(value, str) else None
    if not m:
        return None
    year = int(m[1])
    if not 2000 <= year <= 2999:
        return None
    if m[2] is not None:
        n, kind, last = int(m[2]), "week", weeks_in(year)
    elif m[3] is not None:
        n, kind, last = int(m[3]), "month", 12
    else:
        n, kind, last = int(m[4]), "quarter", 4
    return Period(kind, year, n) if 1 <= n <= last else None


def current(today, week_start=1):
    """The viewer's periods by relative word. today is "YYYY-MM-DD"; week_start is 0 (Sunday) to 6.

    This week is the ISO week holding the Monday inside the viewer's week,
    so a Sunday-start week on Sunday 1 November 2026 is 2026-W45.
    """
    day = date.fromisoformat(today)
    ws = week_start % 7
    dow = day.isoweekday() % 7  # 0 Sunday … 6 Saturday
    start = day - timedelta(days=(dow - ws) % 7)
    monday = start + timedelta(days=(1 - ws) % 7)
    iso = monday.isocalendar()
    week = Period("week", iso[0], iso[1])
    month = Period("month", day.year, day.month)
    quarter = Period("quarter", day.year, (day.month - 1) // 3 + 1)
    return {
        "this-week": str(week), "next-week": str(week.next()),
        "this-month": str(month), "next-month": str(month.next()),
        "this-quarter": str(quarter), "next-quarter": str(quarter.next()),
    }


def resolve(word, today, week_start=1):
    """The sector a relative word ("this week", "next-month") means today, or None."""
    key = re.sub(r"[\s_]+", "-", word.strip().lower())
    return current(today, week_start)[key] if key in WORDS else None


def relative_name(sector, today, week_start=1):
    """The relative word a sector goes by today, or None (then it goes by its period)."""
    if not parse(sector):
        return None
    cur = current(today, week_start)
    return next((w for w in WORDS if cur[w] == sector), None)


def is_carried(sector, today, week_start=1):
    """The period ended before the viewer's current period of its kind."""
    p = parse(sector)
    if not p:
        return False
    now = parse(current(today, week_start)[f"this-{p.kind}"])
    return (p.year, p.n) < (now.year, now.n)


def group(sector, today, week_start=1):
    """The planning group: carried, its own relative word, else the first later
    group whose period holds its first day (a week two weeks out is in This month), else later."""
    p = parse(sector)
    if not p:
        return None
    if is_carried(sector, today, week_start):
        return "carried"
    own = relative_name(sector, today, week_start)
    if own:
        return own
    start = p.range()[0]
    cur = current(today, week_start)
    for word in ("this-month", "next-month", "this-quarter", "next-quarter"):
        first, last = parse(cur[word]).range()
        if first <= start <= last:
            return word
    return "later"


NAMES = {"this-week": "This week", "next-week": "Next week", "this-month": "This month",
         "next-month": "Next month", "this-quarter": "This quarter", "next-quarter": "Next quarter"}


def period_name(p, today):
    """A period by its own name: "Week 47", "January", "Q2 2027". The year shows when it isn't today's."""
    other_year = str(p.year) != today[:4]
    if p.kind == "week":
        return f"Week {p.n}, {p.year}" if other_year else f"Week {p.n}"
    if p.kind == "month":
        return f"{calendar.month_name[p.n]} {p.year}" if other_year else calendar.month_name[p.n]
    return f"Q{p.n} {p.year}"


def label(sector, today, week_start=1):
    """How a stored sector reads today, as (text, carried), or None. Like sectorNames.ts's sectorLabel.

    "This week", "Week 47", or "From week 43" once the period has ended.
    """
    p = parse(sector)
    if not p:
        return None
    if is_carried(sector, today, week_start):
        return f"From {f'week {p.n}' if p.kind == 'week' else period_name(p, today)}", True
    word = relative_name(sector, today, week_start)
    return (NAMES[word] if word else period_name(p, today)), False


def sort_key(sector):
    """Orders sectors by first day, then week before month before quarter. Invalid ones go last."""
    p = parse(sector)
    return (1, date.max, 0) if not p else (0, p.range()[0], _RANK[p.kind])
