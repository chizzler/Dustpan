"""Due dates: display, and the instant a due denotes. See docs/sync.md, "Zoned due values"."""

import locale
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

# The time a date-only due counts as, for reminders.
DEFAULT_REMINDER_TIME = time(9, 0)


@dataclass
class Due:
    text: str
    state: str  # "overdue", "today" or "later"


def local_due(due):
    """(date, time or None) in the local zone. A zoned due converts; a floating one doesn't."""
    day = date.fromisoformat(due["date"])
    if not due.get("time"):
        return day, None
    at = time.fromisoformat(due["time"])
    if tz := due.get("tz"):
        try:
            moment = datetime.combine(day, at, ZoneInfo(tz)).astimezone()
            return moment.date(), moment.time().replace(tzinfo=None)
        except ZoneInfoNotFoundError:
            pass
    return day, at


def zoned_instant(day, at, zone):
    """Unix ms of a wall time in zone. A gap moves forward to the transition; an overlap takes the first."""
    wall = datetime.combine(day, at)
    first = wall.replace(tzinfo=zone, fold=0)
    utc = first.astimezone(timezone.utc)
    if utc.astimezone(zone).replace(tzinfo=None) == wall:
        return int(utc.timestamp() * 1000)
    # In a gap: the transition lies between the two readings. Find it to the minute.
    low = wall.replace(tzinfo=zone, fold=1).astimezone(timezone.utc)
    high = utc
    while high - low > timedelta(minutes=1):
        mid = low + (high - low) / 2
        mid = mid.replace(second=0, microsecond=0)
        if mid.astimezone(zone).utcoffset() == low.astimezone(zone).utcoffset():
            low = mid
        else:
            high = mid
    return int(high.timestamp() * 1000)


def due_instant(due, local_zone=None):
    """Unix ms a due denotes. Zoned: its wall time in its zone. Floating: local time, 09:00 without a time.

    local_zone overrides this device's zone for floating dues (tests).
    """
    day = date.fromisoformat(due["date"])
    at = time.fromisoformat(due["time"]) if due.get("time") else DEFAULT_REMINDER_TIME
    if due.get("time") and (tz := due.get("tz")):
        try:
            return zoned_instant(day, at, ZoneInfo(tz))
        except ZoneInfoNotFoundError:
            pass
    if local_zone is not None:
        return zoned_instant(day, at, local_zone)
    return int(datetime.combine(day, at).timestamp() * 1000)


def day_start_minutes(value):
    """user_prefs.day_start: "HH:MM" from 00:00 to 06:00. Anything else reads as midnight."""
    if not isinstance(value, str) or len(value) != 5 or value[2] != ":":
        return 0
    try:
        minutes = int(value[:2]) * 60 + int(value[3:])
    except ValueError:
        return 0
    return minutes if 0 <= minutes <= 6 * 60 and int(value[3:]) < 60 else 0


def logical_today(day_start=0, now=None):
    """Today's date as YYYY-MM-DD, where a day begins day_start minutes after midnight."""
    now = now or datetime.now()
    return (now - timedelta(minutes=day_start)).date().isoformat()


def uses_12h(time_format):
    """The user_prefs.time_format value: "12h", "24h", or "system" (the locale decides)."""
    if time_format in ("12h", "24h"):
        return time_format == "12h"
    try:
        return "%p" in locale.nl_langinfo(locale.T_FMT) or "%r" in locale.nl_langinfo(locale.T_FMT)
    except (AttributeError, locale.Error):
        return False


def format_time(at, twelve_hour):
    if not twelve_hour:
        return at.strftime("%H:%M")
    hour = at.hour % 12 or 12
    suffix = "am" if at.hour < 12 else "pm"
    return f"{hour}{suffix}" if at.minute == 0 else f"{hour}:{at.minute:02d}{suffix}"


def format_minutes(minutes):
    """An estimate: "15 min", "2h", "1h 30m"."""
    if minutes < 60:
        return f"{minutes} min"
    hours, rest = divmod(minutes, 60)
    return f"{hours}h {rest}m" if rest else f"{hours}h"


def day_heading(iso, today):
    """A list heading for a day: "Today", "Tomorrow", a weekday this week, else the date."""
    day, now = date.fromisoformat(iso), date.fromisoformat(today)
    delta = (day - now).days
    if delta in (0, 1):
        return "Today" if delta == 0 else "Tomorrow"
    if 1 < delta < 7:
        return day.strftime("%A")
    return day.strftime("%a %-d %b") + (f" {day.year}" if day.year != now.year else "")


def format_due(due, now=None, time_format="system"):
    if not due or not due.get("date"):
        return None
    now = now or datetime.now()
    today = now.date()
    day, at = local_due(due)

    delta = (day - today).days
    if delta == 0:
        text = "Today"
    elif delta == 1:
        text = "Tomorrow"
    elif delta == -1:
        text = "Yesterday"
    elif 1 < delta < 7:
        text = day.strftime("%a")
    else:
        text = f"{day.day} {day.strftime('%b')}"
        if day.year != today.year:
            text += f" {day.year}"
    if at is not None:
        text += " " + format_time(at, uses_12h(time_format))

    if at is not None:
        overdue = datetime.combine(day, at) < now
    else:
        overdue = day < today
    state = "overdue" if overdue else "today" if delta == 0 else "later"
    return Due(text, state)
