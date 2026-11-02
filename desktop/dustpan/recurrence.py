"""Recurrence rules: parser, canonical form and next occurrence. See docs/recurrence.md.

A port of web/src/lib/recurrence.ts, checked against recurrence.vectors.json.
Dates are floating YYYY-MM-DD strings. Arithmetic runs on date ordinals,
never through a time zone, so daylight saving has no effect.
"""

import calendar
import re
from dataclasses import dataclass, replace
from datetime import date

MAX_RULE_LENGTH = 200
MAX_INTERVAL = 999
MAX_COUNT = 10000

WEEKDAY_NAMES = ["", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
WEEKDAY_ALIASES = {
    "monday": 1, "mon": 1, "tuesday": 2, "tue": 2, "wednesday": 3, "wed": 3, "thursday": 4, "thu": 4,
    "friday": 5, "fri": 5, "saturday": 6, "sat": 6, "sunday": 7, "sun": 7,
}
WORD_ORDINALS = {"first": 1, "second": 2, "third": 3, "fourth": 4, "last": -1}
UNITS = ("day", "week", "month", "year")
MONDAY_TO_FRIDAY = 0b00111110  # bit n is ISO weekday n


class RuleError(ValueError):
    """The rule doesn't parse. The message is for the user."""


@dataclass(frozen=True)
class Rule:
    kind: str  # interval, weekday, weekdays, month_day, last_day, last_weekday, nth_weekday
    interval: int = 1
    unit: str = "day"
    days: int = 0
    month_day: int = 0
    ordinal: int = 0  # 1 to 4, or -1 for last
    weekday: int = 0
    after_completion: bool = False
    until: str | None = None
    count: int = 0  # "for N times", 0 when absent


def ordinal_suffix(n):
    if 11 <= n % 100 <= 13:
        return "th"
    return {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")


def numeric_ordinal(tok):
    m = re.fullmatch(r"([1-9][0-9]?)(st|nd|rd|th)", tok)
    if not m:
        return None
    n = int(m[1])
    return n if n <= 31 and m[2] == ordinal_suffix(n) else None


def positive_int(tok, limit):
    if tok is None or not re.fullmatch(r"[1-9][0-9]*", tok):
        return None
    n = int(tok)
    return n if n <= limit else None


def parse(text):
    """Parse a rule, or raise RuleError."""
    if len(text) > MAX_RULE_LENGTH:
        raise RuleError(f"longer than {MAX_RULE_LENGTH} characters")
    toks = text.lower().replace(",", " , ").split()
    if not toks or toks[0] != "every":
        raise RuleError('must start with "every"')
    i = 1

    def peek(k=0):
        return toks[i + k] if i + k < len(toks) else None

    tok = peek()
    if tok is None:
        raise RuleError('missing pattern after "every"')
    if tok in UNITS:
        rule = Rule("interval", unit=tok)
        i += 1
    elif tok in ("weekday", "weekdays"):
        rule = Rule("weekday", days=MONDAY_TO_FRIDAY)
        i += 1
    elif re.fullmatch(r"[0-9]+", tok):
        n = positive_int(tok, MAX_INTERVAL)
        if n is None:
            raise RuleError(f"interval must be from 1 to {MAX_INTERVAL}")
        singular = (peek(1) or "").removesuffix("s")
        if singular not in UNITS:
            raise RuleError(f"expected day(s), week(s), month(s) or year(s) after {tok}")
        rule = Rule("interval", interval=n, unit=singular)
        i += 2
    elif tok == "last" and peek(1) in ("day", "weekday"):
        rule = Rule("last_day" if peek(1) == "day" else "last_weekday")
        i += 2
    elif tok in WEEKDAY_ALIASES:
        days = 0
        while True:
            item = peek()
            if item not in WEEKDAY_ALIASES:
                raise RuleError(f'expected a weekday, got "{item}"')
            days |= 1 << WEEKDAY_ALIASES[item]
            i += 1
            j = i
            if j < len(toks) and toks[j] == ",":
                j += 1
            if j < len(toks) and toks[j] == "and":
                j += 1
            if j == i:
                break
            if j >= len(toks):
                raise RuleError("expected a weekday after the list separator")
            i = j
        rule = Rule("weekdays", days=days)
    else:
        word = WORD_ORDINALS.get(tok)
        num = numeric_ordinal(tok)
        if word is None and num is None:
            raise RuleError(f'unknown pattern "{tok}"')
        nxt = peek(1)
        if nxt in WEEKDAY_ALIASES:
            ordinal = num if num is not None else word
            if ordinal > 4:
                raise RuleError("weekday ordinal must be 1st to 4th or last")
            rule = Rule("nth_weekday", ordinal=ordinal, weekday=WEEKDAY_ALIASES[nxt])
            i += 2
        else:
            if num is None:
                raise RuleError(f'expected a weekday after "{tok}"')
            rule = Rule("month_day", month_day=num)
            i += 1
    if peek() == "after":
        if peek(1) != "completion":
            raise RuleError('expected "completion" after "after"')
        if rule.kind != "interval":
            raise RuleError('"after completion" only applies to day, week, month and year intervals')
        rule = replace(rule, after_completion=True)
        i += 2
    if peek() == "until":
        until = peek(1)
        if until is None or day_number(until) is None:
            raise RuleError("until needs a date YYYY-MM-DD")
        rule = replace(rule, until=until)
        i += 2
    elif peek() == "for":
        n = positive_int(peek(1), MAX_COUNT)
        if n is None or peek(2) not in ("times", "time"):
            raise RuleError(f'expected "for N times" with N from 1 to {MAX_COUNT}')
        rule = replace(rule, count=n)
        i += 3
    if i < len(toks):
        raise RuleError(f'unexpected "{toks[i]}"')
    return rule


def canonical(rule):
    s = "every "
    if rule.kind == "interval":
        s += rule.unit if rule.interval == 1 else f"{rule.interval} {rule.unit}s"
    elif rule.kind == "weekday":
        s += "weekday"
    elif rule.kind == "weekdays":
        s += ", ".join(name for wd, name in enumerate(WEEKDAY_NAMES) if wd and rule.days & (1 << wd))
    elif rule.kind == "month_day":
        s += f"{rule.month_day}{ordinal_suffix(rule.month_day)}"
    elif rule.kind == "last_day":
        s += "last day"
    elif rule.kind == "last_weekday":
        s += "last weekday"
    elif rule.kind == "nth_weekday":
        which = "last" if rule.ordinal < 0 else f"{rule.ordinal}{ordinal_suffix(rule.ordinal)}"
        s += f"{which} {WEEKDAY_NAMES[rule.weekday]}"
    if rule.after_completion:
        s += " after completion"
    if rule.until:
        s += f" until {rule.until}"
    if rule.count == 1:
        s += " for 1 time"
    elif rule.count > 1:
        s += f" for {rule.count} times"
    return s


def canonical_text(text):
    """The stored form of a rule, or RuleError."""
    return canonical(parse(text))


# ---- calendar arithmetic on day numbers (date ordinals) ----

def day_number(s):
    """Ordinal of a valid YYYY-MM-DD date, or None."""
    m = re.fullmatch(r"([0-9]{4})-([0-9]{2})-([0-9]{2})", s or "")
    if not m:
        return None
    try:
        return date(int(m[1]), int(m[2]), int(m[3])).toordinal()
    except ValueError:
        return None


def format_date(z):
    return date.fromordinal(z).isoformat()


def must_date(s, what):
    z = day_number(s)
    if z is None:
        raise ValueError(f'recurrence: {what} "{s}" is not a valid YYYY-MM-DD date')
    return z


def month_len(y, m):
    return calendar.monthrange(y, m)[1]


def iso_weekday(z):
    return date.fromordinal(z).isoweekday()


def ordinal_of(y, m, d):
    return date(y, m, d).toordinal()


def add_months(z, n):
    d = date.fromordinal(z)
    idx = d.year * 12 + (d.month - 1) + n
    ny, nm = divmod(idx, 12)
    nm += 1
    return ordinal_of(ny, nm, min(d.day, month_len(ny, nm)))


def step(rule, anchor, k):
    if rule.unit == "week":
        return anchor + 7 * rule.interval * k
    if rule.unit == "month":
        return add_months(anchor, rule.interval * k)
    if rule.unit == "year":
        return add_months(anchor, 12 * rule.interval * k)
    return anchor + rule.interval * k


def last_weekday_of(y, m):
    z = ordinal_of(y, m, month_len(y, m))
    while iso_weekday(z) > 5:
        z -= 1
    return z


def nth_weekday_of(y, m, ordinal, wd):
    if ordinal < 0:
        z = ordinal_of(y, m, month_len(y, m))
        return z - ((iso_weekday(z) - wd + 7) % 7)
    first = ordinal_of(y, m, 1)
    return first + ((wd - iso_weekday(first) + 7) % 7) + 7 * (ordinal - 1)


def in_month(rule, y, m):
    if rule.kind == "month_day":
        return ordinal_of(y, m, min(rule.month_day, month_len(y, m)))
    if rule.kind == "last_day":
        return ordinal_of(y, m, month_len(y, m))
    if rule.kind == "last_weekday":
        return last_weekday_of(y, m)
    if rule.kind == "nth_weekday":
        return nth_weekday_of(y, m, rule.ordinal, rule.weekday)
    raise ValueError("recurrence: not a month pattern")


def first_after(rule, z):
    """First date matching the pattern strictly after day z."""
    if rule.kind == "interval":
        return step(rule, z, 1)
    if rule.kind in ("weekday", "weekdays"):
        for i in range(1, 8):
            if rule.days & (1 << iso_weekday(z + i)):
                return z + i
        return z + 7
    d = date.fromordinal(z)
    c = in_month(rule, d.year, d.month)
    if c > z:
        return c
    return in_month(rule, d.year + 1, 1) if d.month == 12 else in_month(rule, d.year, d.month + 1)


def as_rule(rule):
    return parse(rule) if isinstance(rule, str) else rule


def next_calendar(rule, due, today):
    """The first match strictly after due, or after today when that's already past (catch-up)."""
    r = as_rule(rule)
    item = must_date(today, "today")
    d = must_date(due, "due") if due else item
    c = first_after(r, d)
    if c >= item:
        return format_date(c)
    if r.kind != "interval":
        return format_date(first_after(r, item))
    if r.unit in ("day", "week"):
        size = 7 * r.interval if r.unit == "week" else r.interval
        return format_date(d + size * ((item - d) // size + 1))
    k = 2
    while True:
        c = step(r, d, k)
        if c > item:
            return format_date(c)
        k += 1


def next_after_completion(rule, completed_on):
    r = as_rule(rule)
    if r.kind != "interval":
        raise ValueError("recurrence: only interval rules are completion-relative")
    return format_date(step(r, must_date(completed_on, "completedOn"), 1))


def following_occurrence(rule, due, today, completed_on, done=0):
    """The next due date after completing the current occurrence, or None at the end condition.

    done is the number of completed occurrence records already in the series.
    """
    r = as_rule(rule)
    nxt = next_after_completion(r, completed_on) if r.after_completion else next_calendar(r, due, today)
    if r.count > 0 and done + 1 >= r.count:
        return None
    if r.until and nxt > r.until:
        return None
    return nxt


def first_occurrence(rule, start):
    """First occurrence on or after start: the due date for an undated task that gets a rule."""
    r = as_rule(rule)
    z = must_date(start, "from")
    return start if r.kind == "interval" else format_date(first_after(r, z - 1))


def preview_occurrences(rule, due, today, done=0, n=3):
    """Up to n occurrences after the current one, stopping at the end condition."""
    r = as_rule(rule)
    out = []
    cur = due
    for i in range(1, n + 1):
        completed_on = cur if r.after_completion and i > 1 and cur else today
        nxt = following_occurrence(r, cur, today, completed_on, done + i - 1)
        if nxt is None:
            break
        out.append(nxt)
        cur = nxt
    return out


def shift_date(day, start, end):
    """day moved by as many calendar days as from start to end."""
    return format_date(must_date(day, "date") + must_date(end, "to") - must_date(start, "from"))
