"""Single-token attributes: #project, @label, p1, ~energy, +30m, 30m/2h. Port of internal/quickadd/attributes.go.

Projects are dicts with id, name and, when set, parent_id, archived and deleted.
"""

import math
import re

from .words import normalize

MAX_ESTIMATE_MINUTES = 10080  # the server's bound: one week
SEPARATORS = re.compile(r"[\s_-]+")
PRIORITY = re.compile(r"p([1-4])", re.ASCII | re.IGNORECASE)
ENERGY = re.compile(r"~([A-Za-z]+)")
HOURS = re.compile(r"(\d+(?:[.,]\d+)?)h(?:(\d{1,2})(?:m|min)?)?", re.ASCII)
MINUTES = re.compile(r"(\d+)(m|min|mins|minutes)", re.ASCII)
NUMBER = re.compile(r"\d+", re.ASCII)
SPENT_PART = r"(\d+(?:[.,]\d+)?h(?:\d{1,2}(?:m|min)?)?|\d+(?:m|min|mins|minutes))"
SPENT = re.compile(SPENT_PART + "/" + SPENT_PART, re.ASCII)


def fold_name(name):
    return SEPARATORS.sub("", normalize(name))


def trim(token):
    return token.rstrip(",;")


def live_projects(projects):
    return [p for p in projects if not p.get("archived") and not p.get("deleted")]


def by_depth(found, projects):
    """The shallowest project, then the smallest id."""
    by_id = {p["id"]: p for p in projects}

    def depth(p):
        n, seen = 0, {p["id"]}
        while (parent := by_id.get(p.get("parent_id"))) and parent["id"] not in seen:
            seen.add(parent["id"])
            n, p = n + 1, parent
        return n

    return min(found, key=lambda p: (depth(p), p["id"]))


def match_project(token, projects):
    """#Name: an exact folded name (the shallowest wins), else the only prefix. #Parent/Child: an exact path."""
    if not token.startswith("#") or len(token) < 2:
        return None
    live = live_projects(projects)
    if "/" in token:
        parts = [fold_name(part) for part in token[1:].split("/")]
        if "" in parts or len(parts) < 2:
            return None
        by_id = {p["id"]: p for p in live}

        def fits(p):
            for i in range(len(parts) - 1, -1, -1):
                if p is None or fold_name(p["name"]) != parts[i]:
                    return False
                p = by_id.get(p.get("parent_id")) if i else p
            return True

        found = [p for p in live if fits(p)]
        return by_depth(found, live) if found else None
    want = fold_name(token[1:])
    if not want:
        return None
    exact = [p for p in live if fold_name(p["name"]) == want]
    if exact:
        return by_depth(exact, live)
    prefix = [p for p in live if fold_name(p["name"]).startswith(want)]
    return prefix[0] if len(prefix) == 1 else None


def match_label(token):
    if not token.startswith("@") or len(token) < 2:
        return None
    name = trim(token[1:])
    return name if name and not any(c in name for c in " \t\n") else None


def match_priority(token):
    return int(m[1]) if (m := PRIORITY.fullmatch(trim(token))) else 0


def match_energy(token):
    """~deep, ~medium, ~low or any prefix of them, any case. "" otherwise, so ~6 stays text."""
    if not (m := ENERGY.fullmatch(trim(token))):
        return ""
    word = m[1].lower()
    return next((e for e in ("deep", "medium", "low") if e.startswith(word)), "")


def hours_minutes(m):
    """Minutes from a HOURS match, or None when the minutes are over 59."""
    minutes = int(m[2]) if m[2] else 0
    # Half up, like Go and JS (Python's round() goes to even).
    return None if minutes > 59 else math.floor(float(m[1].replace(",", ".", 1)) * 60 + minutes + 0.5)


def match_duration(token, bare_hour_is_time):
    """An estimate: +30, +30m, +2h, +1h30, 45min, 2h. 0 when it isn't one."""
    text = trim(token).lower()
    plus = text.startswith("+")
    body = text.removeprefix("+")
    if not body:
        return 0
    minutes = -1
    if m := HOURS.fullmatch(body):
        if (not plus and (bare_hour_is_time or m[2])) or (minutes := hours_minutes(m)) is None:
            return 0
    elif m := MINUTES.fullmatch(body):
        if not plus and m[2] == "m":
            return 0
        minutes = int(m[1])
    elif plus and NUMBER.fullmatch(body):
        minutes = int(body)
    return minutes if 1 <= minutes <= MAX_ESTIMATE_MINUTES else 0


def spent_part(text):
    if m := HOURS.fullmatch(text):
        value = hours_minutes(m)
    elif m := MINUTES.fullmatch(text):
        value = int(m[1])
    else:
        return 0
    return value if value is not None and 1 <= value <= MAX_ESTIMATE_MINUTES else 0


def match_spent(token):
    """30m/2h: (30 minutes spent, a two-hour estimate), or None. A date such as 30/12 never matches."""
    if not (m := SPENT.fullmatch(trim(token).lower())):
        return None
    spent, estimate = spent_part(m[1]), spent_part(m[2])
    return (spent, estimate) if spent and estimate else None
