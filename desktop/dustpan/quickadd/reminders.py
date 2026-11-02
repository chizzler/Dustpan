"""Reminder phrases: "remind me 30 min before", "remind me tomorrow at 9". Port of internal/quickadd/reminders.go.

A reminder as typed is {"kind": "offset", "minutes": -30} (negative is before the due)
or {"kind": "moment", "date": "YYYY-MM-DD" or None, "time": "HH:MM"}.
"""

from datetime import date

from .attributes import match_duration
from .dates import add_days, count_at, match_date_at, match_time_at
from .words import phrase_at, tok

UNIT_MINUTES = (("minute", 1), ("hour", 60), ("day", 1440), ("week", 10080))


def offset_at(tokens, k, ctx):
    """(tokens covered, minutes) for "30 min before", "2h after", or None."""
    best = None
    for v in ctx.vocabs:
        n, amount = 0, 0
        cn, count = count_at(tokens, k, v)
        if cn:
            for unit, minutes in UNIT_MINUTES:
                if un := phrase_at(tokens, k + cn, v["units"][unit]):
                    n, amount = cn + un, count * minutes
                    break
        if not n and (t := tok(tokens, k)) and (m := match_duration(t.text, False)):
            n, amount = 1, m
        if not n or amount <= 0:
            continue
        before = phrase_at(tokens, k + n, v["beforeWords"])
        after = 0 if before else phrase_at(tokens, k + n, v["afterWords"])
        if not before and not after:
            continue
        if best is None or n + before + after > best[0]:
            best = n + before + after, -amount if before else amount
    return best


def moment_at(tokens, k, ctx):
    """(tokens covered, date or None, time) for "tomorrow at 9", "at 9 on Friday", "at 9", or None."""
    if (dm := match_date_at(tokens, k, ctx)) and (tm := match_time_at(tokens, dm.to, ctx)):
        return tm.to - k, dm.date, tm.time
    if not (tm := match_time_at(tokens, k, ctx)):
        return None
    if dm := match_date_at(tokens, tm.to, ctx):
        return dm.to - k, dm.date, tm.time
    return tm.to - k, tm.date or None, tm.time


def parse_reminder_at(tokens, k, ctx):
    """(reminder, end), or None. An offset wins a tie."""
    offset, moment = offset_at(tokens, k, ctx), moment_at(tokens, k, ctx)
    if offset and (not moment or offset[0] >= moment[0]):
        return {"kind": "offset", "minutes": offset[1]}, k + offset[0]
    if moment:
        return {"kind": "moment", "date": moment[1], "time": moment[2]}, k + moment[0]
    return None


def match_reminder_at(tokens, i, ctx):
    """(reminder, start, end) for a phrase starting with "remind me", or None."""
    if tok(tokens, i) is None:
        return None
    word = max(phrase_at(tokens, i, v["remindWords"]) for v in ctx.vocabs)
    if not word or not (found := parse_reminder_at(tokens, i + word, ctx)):
        return None
    return found[0], i, found[1]


def minutes_of(hhmm):
    return int(hhmm[:2]) * 60 + int(hhmm[3:5])


def day_minutes(iso, hhmm):
    return date.fromisoformat(iso).toordinal() * 1440 + minutes_of(hhmm)


def resolve(reminder, due, today, now):
    """How to store a typed reminder: ("relative", offset minutes) or ("absolute", date, time).

    With a due, a moment becomes an offset from the due time (09:00 for a date-only due).
    Without one, a time alone is today if it's still ahead, else tomorrow.
    """
    if reminder["kind"] == "offset":
        return "relative", reminder["minutes"]
    if due:
        at = reminder["date"] or due["date"]
        return "relative", day_minutes(at, reminder["time"]) - day_minutes(due["date"], due.get("time") or "09:00")
    if reminder["date"]:
        return "absolute", reminder["date"], reminder["time"]
    if minutes_of(reminder["time"]) > minutes_of(now):
        return "absolute", today, reminder["time"]
    return "absolute", add_days(today, 1), reminder["time"]
