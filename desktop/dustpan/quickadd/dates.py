"""Date and time phrases. Port of internal/quickadd/dates.go.

Matchers take the tokens and a start index, and return a match ending before token `to`, or None.
"""

import calendar
import re
from dataclasses import dataclass
from datetime import date, timedelta

from .. import sectors
from ..recurrence import format_date, nth_weekday_of
from .words import lookup_at, phrase_at, tok


@dataclass
class DateCtx:
    today: str
    now: str  # HH:MM, or "" when unknown
    vocabs: list
    day_month_order: str  # "DM" or "MD"
    week_start: int  # 0 = Sunday


@dataclass
class DateMatch:
    date: str
    start: int
    to: int
    bare: bool = False  # a month name alone; a later complete date replaces it


@dataclass
class TimeMatch:
    time: str
    date: str  # "" unless the time moves the day ("in 20 hours")
    start: int
    to: int


# ---- calendar ----


def ymd(iso):
    d = date.fromisoformat(iso)
    return d.year, d.month, d.day


def month_index(y, m):
    """(year, month) with an overflowing month carried, like JS Date."""
    y, m = divmod(y * 12 + m - 1, 12)
    return y, m + 1


def add_days(iso, n):
    return (date.fromisoformat(iso) + timedelta(days=n)).isoformat()


def days_in_month(y, m):
    return calendar.monthrange(y, m)[1]


def is_valid(y, m, d):
    return 1 <= m <= 12 and 1 <= y <= 9999 and 1 <= d <= days_in_month(y, m)


def add_months(iso, n):
    y, m, d = ymd(iso)
    y, m = month_index(y, m + n)
    return date(y, m, min(d, days_in_month(y, m))).isoformat()


def js_day(iso):
    """0 = Sunday."""
    return (date.fromisoformat(iso).weekday() + 1) % 7


def weekday_index(iso):
    """0 = Monday."""
    return date.fromisoformat(iso).weekday()


def next_weekday(today, wd):
    """The next such weekday after today (0 = Monday), never today."""
    return add_days(today, (wd - weekday_index(today)) % 7 or 7)


def days_into_week(iso, week_start):
    return (js_day(iso) - week_start) % 7


def next_next_weekday(today, wd, week_start):
    """ "next friday": that day in next week."""
    bare = next_weekday(today, wd)
    return add_days(bare, 7) if bare <= add_days(today, 6 - days_into_week(today, week_start)) else bare


def next_occurrence(today, month, day):
    year = int(today[:4])
    for y in range(year, year + 9):
        if is_valid(y, month, day) and (iso := date(y, month, day).isoformat()) >= today:
            return iso
    return ""


def resolve_month_day(today, year, month, day):
    if year:
        return date(year, month, day).isoformat() if is_valid(year, month, day) else ""
    return next_occurrence(today, month, day)


def clock(h, m):
    return f"{h:02d}:{m:02d}"


# ---- small matchers ----

DAY = re.compile(r"(\d{1,2})(?:st|nd|rd|th|er|o|a|º|°|ª|\.)?", re.ASCII)
YEAR = re.compile(r"\d{4}", re.ASCII)
COUNT = re.compile(r"\d{1,3}", re.ASCII)
DIGITS = re.compile(r"\d+", re.ASCII)
# A number from 1 to 4 with an ordinal suffix, only before a weekday.
ORDINAL = re.compile(r"([1-4])(?:st|nd|rd|th|er|re|eme|e|o|a|º|°|ª|\.)", re.ASCII)


def weekday_at(tokens, i, v):
    """0 = Monday, or -1."""
    return next((wd for wd in range(7) if phrase_at(tokens, i, v["weekdays"][wd])), -1)


def month_at(tokens, i, v, abbr=True):
    """1–12, or 0."""
    for m, month in enumerate(v["months"], 1):
        if phrase_at(tokens, i, month["names"]) or (abbr and phrase_at(tokens, i, month["abbr"])):
            return m
    return 0


def day_number(t):
    m = DAY.fullmatch(t.norm) if t else None
    return int(m[1]) if m and 1 <= int(m[1]) <= 31 else 0


def year_at(t):
    return int(t.norm) if t and YEAR.fullmatch(t.norm) else 0


def count_at(tokens, i, v):
    """(tokens covered, count): a number up to three digits, or "a", "one"."""
    t = tok(tokens, i)
    if t is None:
        return 0, 0
    if COUNT.fullmatch(t.norm):
        return 1, int(t.norm)
    return (n, 1) if (n := phrase_at(tokens, i, v["oneWords"])) else (0, 0)


def unit_at(tokens, i, v, names=("hour", "day", "week", "month")):
    """(tokens covered, unit name), or (0, "")."""
    for name in names:
        if n := phrase_at(tokens, i, v["units"][name]):
            return n, name
    return 0, ""


def any_language(ctx, tokens, i, key):
    """The longest phrase of v[key] at i, in any active language."""
    return max(phrase_at(tokens, i, v[key]) for v in ctx.vocabs)


# ---- dates ----


def match_deadline_at(tokens, i, ctx):
    if tok(tokens, i) is None:
        return None
    best = None
    for v in ctx.vocabs:
        if (n := phrase_at(tokens, i, v["deadlineWords"])) and (dm := match_date_at(tokens, i + n, ctx)):
            if best is None or dm.to > best.to:
                best = DateMatch(dm.date, i, dm.to)
    return best


def match_date_at(tokens, i, ctx):
    if tok(tokens, i) is None:
        return None
    best = None

    def consider(m):
        nonlocal best
        if m is not None and (best is None or m.to > best.to):
            best = m

    for v in ctx.vocabs:
        n, d = lookup_at(tokens, i, v["dayWords"])
        if n:
            consider(DateMatch(add_days(ctx.today, d), i, i + n))
        pre = phrase_at(tokens, i, v["before"])
        for j in ([i + pre, i] if pre else [i]):
            for matcher in (weekday_phrase_at, ordinal_weekday_at, next_period_at, in_period_at):
                if found := matcher(tokens, j, v, ctx):
                    consider(DateMatch(found[0], i, j + found[1]))
            # A month name alone is a weak date, and none right after "from", "since", "of", "for".
            if found := month_day_at(tokens, j, v, ctx):
                if found[1] > 1:
                    consider(DateMatch(found[0], i, j + found[1]))
                elif j != i or not month_text_before(tokens, i, ctx):
                    consider(DateMatch(found[0], i, j + found[1], bare=True))
            if found := numeric_date_at(tokens, j, ctx):
                consider(DateMatch(found[0], i, j + found[1]))
    return best


def weekday_phrase_at(tokens, j, v, ctx):
    """ "friday", "this friday", "next friday": (date, tokens covered) or None."""
    k, qualifier = j, ""
    if nb := phrase_at(tokens, k, v["nextBefore"]):
        qualifier, k = "next", k + nb
    elif tb := phrase_at(tokens, k, v["thisBefore"]):
        qualifier, k = "this", k + tb
    wd = weekday_at(tokens, k, v)
    if wd < 0:
        return None
    k += 1
    if not qualifier and (na := phrase_at(tokens, k, v["nextAfter"])):
        qualifier, k = "next", k + na
    if qualifier == "next":
        return next_next_weekday(ctx.today, wd, ctx.week_start), k - j
    return next_weekday(ctx.today, wd), k - j


def weekday_ordinal_at(tokens, i, v, is_weekday):
    """An ordinal directly before a weekday at i: (tokens covered, 1–4 or -1 for last), or None.

    Never when a list separator follows the ordinal.
    """
    t = tok(tokens, i)
    if t is None:
        return None

    def direct(n):
        return not tokens[i + n - 1].text.endswith((",", ";")) and is_weekday(i + n)

    if m := ORDINAL.fullmatch(t.norm):
        return (1, int(m[1])) if direct(1) else None
    for table in (v["ordinals"], v["ordinalsBeforeWeekday"]):
        n, value = lookup_at(tokens, i, table)
        if n and direct(n):
            return n, value
    return None


def ordinal_out_of_range_at(tokens, i, ctx):
    """ "5th Friday": no fifth weekday exists, so both tokens stay literal. The token count, or 0."""
    t = tok(tokens, i)
    if t is None or DIGITS.fullmatch(t.norm) or day_number(t) <= 4 or t.text.endswith((",", ";")):
        return 0
    return 2 if any(weekday_at(tokens, i + 1, v) >= 0 for v in ctx.vocabs) else 0


def nth_weekday_date(y, m, ordinal, wd):
    """wd: 1 = Monday."""
    return format_date(nth_weekday_of(y, m, ordinal, wd))


def ordinal_weekday_at(tokens, j, v, ctx):
    """[article] ordinal weekday [of MONTH [YEAR] | of the month]: this month's, or next month's once passed."""
    k = j + phrase_at(tokens, j, v["ordinalArticles"])
    found = weekday_ordinal_at(tokens, k, v, lambda w: weekday_at(tokens, w, v) >= 0)
    if not found:
        return None
    on, ordinal = found
    k += on
    wd = weekday_at(tokens, k, v) + 1
    k += 1
    ty, tm, _ = ymd(ctx.today)
    of = phrase_at(tokens, k, v["ordinalOf"])
    month = month_at(tokens, k + of, v) if of else 0
    if month:
        k += of + 1
        if y := year_at(tok(tokens, k)):
            return nth_weekday_date(y, month, ordinal, wd), k + 1 - j
        day = nth_weekday_date(ty, month, ordinal, wd)
        return (day if day >= ctx.today else nth_weekday_date(ty + 1, month, ordinal, wd)), k - j
    k += any_language(ctx, tokens, k, "ofMonthWords")
    day = nth_weekday_date(ty, tm, ordinal, wd)
    if day < ctx.today:
        day = nth_weekday_date(*month_index(ty, tm + 1), ordinal, wd)
    return day, k - j


def next_period_at(tokens, j, v, ctx):
    """ "next week", "next month": the first day of it."""
    nb = phrase_at(tokens, j, v["nextBefore"])
    k = j + nb
    un, unit = unit_at(tokens, k, v)
    if unit not in ("week", "month"):
        return None
    k += un
    if not nb:
        if not (na := phrase_at(tokens, k, v["nextAfter"])):
            return None
        k += na
    if unit == "week":
        return add_days(ctx.today, 7 - days_into_week(ctx.today, ctx.week_start)), k - j
    y, m, _ = ymd(ctx.today)
    return date(*month_index(y, m + 1), 1).isoformat(), k - j


def in_period_at(tokens, j, v, ctx):
    """ "in 3 days", "in a week", "in 2 months"."""
    if not (n_in := phrase_at(tokens, j, v["inWords"])):
        return None
    cn, count = count_at(tokens, j + n_in, v)
    if not cn:
        return None
    un, unit = unit_at(tokens, j + n_in + cn, v)
    if not un or unit == "hour":
        return None
    n = n_in + cn + un
    if unit == "day":
        return add_days(ctx.today, count), n
    if unit == "week":
        return add_days(ctx.today, 7 * count), n
    return add_months(ctx.today, count), n


def month_text_before(tokens, i, ctx):
    """True when the word before i keeps a month name alone as text ("invoices from September")."""
    if i == 0 or tokens[i - 1].quoted:
        return False
    return any(phrase_at(tokens, i - 1, v["monthTextBefore"]) == 1 for v in ctx.vocabs)


def month_day_at(tokens, j, v, ctx):
    """ "3 Nov", "3rd of November 2027", "Nov 3", or a month name alone (its first day)."""
    if d1 := day_number(tok(tokens, j)):
        k = j + 1
        k += phrase_at(tokens, k, v["ofWords"])
        if m := month_at(tokens, k, v):
            k += 1
            if y := year_at(tok(tokens, k)):
                k += 1
            day = resolve_month_day(ctx.today, y, m, d1)
            return (day, k - j) if day else None
    if m := month_at(tokens, j, v):
        if d2 := day_number(tok(tokens, j + 1)):
            k = j + 2
            if y := year_at(tok(tokens, k)):
                k += 1
            day = resolve_month_day(ctx.today, y, m, d2)
            return (day, k - j) if day else None
        if full := month_at(tokens, j, v, abbr=False):
            day = resolve_month_day(ctx.today, 0, full, 1)
            return (day, 1) if day else None
    return None


ISO = re.compile(r"(\d{4})-(\d{1,2})-(\d{1,2})", re.ASCII)
NUMERIC = re.compile(r"(\d{1,2})([/.-])(\d{1,2})(?:\2(\d{2}|\d{4}))?(\.?)", re.ASCII)


def numeric_date_at(tokens, j, ctx):
    """2026-11-03, 3/11, 3.11.26 (day first only when the order is DM)."""
    t = tok(tokens, j)
    if t is None:
        return None
    if m := ISO.fullmatch(t.norm):
        y, mo, d = int(m[1]), int(m[2]), int(m[3])
        return (date(y, mo, d).isoformat(), 1) if is_valid(y, mo, d) else None
    m = NUMERIC.fullmatch(t.norm)
    if not m:
        return None
    dotted = m[2] == "."
    if (t.norm.endswith(".") and not dotted) or (dotted and ctx.day_month_order != "DM"):
        return None
    a, b = int(m[1]), int(m[3])
    year = int(m[4]) if m[4] else 0
    if m[4] and year < 100:
        year += 2000
    day, month = (a, b) if ctx.day_month_order == "DM" else (b, a)
    probe = year or int(ctx.today[:4])
    if not dotted and not is_valid(probe, month, day) and is_valid(probe, day, month):
        day, month = month, day
    found = resolve_month_day(ctx.today, year, month, day)
    return (found, 1) if found else None


# ---- times ----


def match_time_at(tokens, i, ctx):
    if tok(tokens, i) is None:
        return None
    best = None

    def consider(m):
        nonlocal best
        if m is not None and (best is None or m.to > best.to):
            best = m

    hour_suffix = any(v["hourSuffixH"] for v in ctx.vocabs)
    for v in ctx.vocabs:
        consider(in_hours_at(tokens, i, v, ctx))
        at = phrase_at(tokens, i, v["atWords"])
        j = i + at
        n, value = lookup_at(tokens, j, v["timeWords"])
        if n:
            consider(TimeMatch(value, "", i, j + n))
        if found := clock_at(tokens, j, v, at > 0, hour_suffix):
            consider(TimeMatch(found[0], "", i, j + found[1]))
    return best


def in_hours_at(tokens, i, v, ctx):
    """ "in 2 hours": now plus the hours, perhaps on a later day."""
    if not ctx.now or not (n_in := phrase_at(tokens, i, v["inWords"])):
        return None
    cn, count = count_at(tokens, i + n_in, v)
    if not cn:
        return None
    un, unit = unit_at(tokens, i + n_in + cn, v)
    if unit != "hour":
        return None
    h, m = (int(x) for x in ctx.now.split(":"))
    total = h + count
    return TimeMatch(clock(total % 24, m), add_days(ctx.today, total // 24), i, i + n_in + cn + un)


HM = re.compile(r"(\d{1,2}):(\d{2})(am|pm|a\.m\.|p\.m\.)?", re.ASCII)
H_DOT_M = re.compile(r"(\d{1,2})\.(\d{2})", re.ASCII)
H12 = re.compile(r"(\d{1,2})(am|pm|a\.m\.|p\.m\.)", re.ASCII)
H_H = re.compile(r"(\d{1,2})h(\d{2})?", re.ASCII)
H = re.compile(r"(\d{1,2})", re.ASCII)


def meridiem(tokens, k, v):
    """(tokens covered, pm), or None."""
    if phrase_at(tokens, k, v["pm"]):
        return 1, True
    if phrase_at(tokens, k, v["am"]):
        return 1, False
    return None


def to24(h, pm):
    if h == 12:
        return 12 if pm else 0
    return h + 12 if pm else h


def clock_at(tokens, j, v, after_at, hour_suffix):
    """(HH:MM, tokens covered), or None. A bare number is a time only after "at" or before "o'clock"."""
    t = tok(tokens, j)
    if t is None:
        return None
    s = t.norm

    def hour_word(k):
        return phrase_at(tokens, k, v["hourWords"])

    if m := HM.fullmatch(s):
        h, mins = int(m[1]), int(m[2])
        if mins > 59:
            return None
        am_pm = (0, m[3].startswith("p")) if m[3] else meridiem(tokens, j + 1, v)
        if am_pm:
            return (clock(to24(h, am_pm[1]), mins), 1 + am_pm[0]) if 1 <= h <= 12 else None
        return (clock(h, mins), 1 + hour_word(j + 1)) if h <= 23 else None
    if m := H_DOT_M.fullmatch(s):
        h, mins = int(m[1]), int(m[2])
        hw = hour_word(j + 1)
        if (not after_at and not hw) or h > 23 or mins > 59:
            return None
        return clock(h, mins), 1 + hw
    if m := H12.fullmatch(s):
        h = int(m[1])
        return (clock(to24(h, m[2].startswith("p")), 0), 1) if 1 <= h <= 12 else None
    if m := H_H.fullmatch(s):
        h, mins = int(m[1]), int(m[2] or 0)
        if h > 23 or mins > 59 or (not m[2] and not after_at and not hour_suffix):
            return None
        return clock(h, mins), 1
    if m := H.fullmatch(s):
        h = int(m[1])
        if am_pm := meridiem(tokens, j + 1, v):
            return (clock(to24(h, am_pm[1]), 0), 1 + am_pm[0]) if 1 <= h <= 12 else None
        hw = hour_word(j + 1)
        if (not after_at and not hw) or h > 23:
            return None
        return clock(h, 0), 1 + hw
    return None


def sector_phrase_at(tokens, i, ctx):
    """(tokens covered, sector word) for the longest time sector phrase at i in any active language, or (0, None)."""
    best, word = 0, None
    if tok(tokens, i) is None:
        return best, word
    for v in ctx.vocabs:
        for w in sectors.WORDS:
            if (n := phrase_at(tokens, i, v.get("sectorPhrases", {}).get(w, []))) > best:
                best, word = n, w
    return best, word
