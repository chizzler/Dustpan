"""Repeat-rule phrases: "every monday", "jeden zweiten Freitag", "every 3 days after completion".

Port of internal/quickadd/recurrence.go. Rules come out in the canonical English form.
"""

import re
from dataclasses import dataclass, replace

from ..recurrence import RuleError, canonical_text, first_occurrence
from .dates import COUNT, DIGITS, any_language, count_at, day_number, match_date_at, weekday_at, weekday_ordinal_at
from .words import lookup_at, phrase_at, tok

WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
ORDINALS = {1: "1st", 2: "2nd", 3: "3rd", 4: "4th", -1: "last"}
DIGIT_START = re.compile(r"[0-9]")


@dataclass
class RepeatMatch:
    rule: str
    start: int
    to: int
    # A phrase the grammar can't express ("every 2 Mondays"): it wins like any match
    # but sets nothing, so it stays whole in the title.
    literal: bool = False
    first: str = ""  # the first date, when the rule can't hold the weekday ("every other friday")


def canonical(rule):
    try:
        return canonical_text(rule)
    except RuleError:
        return None


def rule_unit_at(tokens, i, v):
    for name in ("day", "week", "month", "year"):
        if n := phrase_at(tokens, i, v["units"][name]):
            return n, name
    return 0, ""


def plural_stems(norm):
    """Romance plurals without their s, hyphenated ones without each part's s, German ones without their e."""
    out = []
    if len(norm) >= 4 and norm.endswith("s"):
        out.append(norm[:-1])
    if len(norm) >= 6 and norm.endswith("e"):
        out.append(norm[:-1])
    if "-" in norm:
        out.append("-".join(p.removesuffix("s") for p in norm.split("-")))
    return out


def weekday_plural_at(tokens, i, v):
    """A weekday at i, or its plural ("mondays", "Montage", "segundas-feiras"). 0 = Monday, or -1."""
    if (wd := weekday_at(tokens, i, v)) >= 0:
        return wd
    t = tok(tokens, i)
    if t is None:
        return -1
    for stem in plural_stems(t.norm):
        if (wd := weekday_at([replace(t, norm=stem)], 0, v)) >= 0:
            return wd
    return -1


def ordinal_at(tokens, i, v):
    """(tokens covered, value): "3rd", "third", "last". Bare digits are a count, not an ordinal."""
    t = tok(tokens, i)
    if t is None:
        return None
    if not DIGITS.fullmatch(t.norm) and (d := day_number(t)):
        return 1, d
    n, value = lookup_at(tokens, i, v["ordinals"])
    return (n, value) if n else None


def day_suffix(n):
    if n % 10 == 1 and n != 11:
        return "st"
    if n % 10 == 2 and n != 12:
        return "nd"
    if n % 10 == 3 and n != 13:
        return "rd"
    return "th"


def pattern_at(tokens, k, v):
    """What follows "every": (tokens covered, rule text, monthly), or None."""
    if all_days := phrase_at(tokens, k, v["weekdayAll"]):
        return all_days, "weekday", False
    t = tok(tokens, k)
    count = int(t.norm) if t and COUNT.fullmatch(t.norm) else 0
    skip = 1 if count else 0
    un, unit = rule_unit_at(tokens, k + skip, v)
    if un:
        return skip + un, (f"{count} {unit}s" if count > 1 else unit), False
    if count and any(phrase_at(tokens, k + 1, words) for words in v["units"].values()):
        return None
    # "2nd monday", "2e lundis", "segunda segunda-feira"
    if found := weekday_ordinal_at(tokens, k, v, lambda w: weekday_plural_at(tokens, w, v) >= 0):
        on, value = found
        return on + 1, f"{ORDINALS[value]} {WEEKDAYS[weekday_plural_at(tokens, k + on, v)]}", True
    if found := ordinal_at(tokens, k, v):
        on, value = found
        j = k + on
        if (wd := weekday_plural_at(tokens, j, v)) >= 0 and value <= 4:
            return on + 1, f"{ORDINALS[value]} {WEEKDAYS[wd]}", True
        if value == -1:
            if d := phrase_at(tokens, j, v["units"]["day"]):
                return on + d, "last day", True
            if w := phrase_at(tokens, j, v["weekdayAll"]):
                return on + w, "last weekday", True
            return None
        if DIGIT_START.match(tokens[k].norm) and 1 <= value <= 31:
            return on, f"{value}{day_suffix(value)}", True
        return None
    days, j = [], k
    while (wd := weekday_plural_at(tokens, j, v)) >= 0:
        days.append(WEEKDAYS[wd])
        j += 1
        if (n_and := phrase_at(tokens, j, v["andWords"])) and weekday_plural_at(tokens, j + n_and, v) >= 0:
            j += n_and
        elif not (tokens[j - 1].text.endswith((",", ";")) and weekday_plural_at(tokens, j, v) >= 0):
            break
    return (j - k, ", ".join(days), False) if days else None


def count_weekday_at(tokens, k, v):
    """ "every 2 Mondays": a count before a weekday, which no rule holds. The token count, or 0."""
    t = tok(tokens, k)
    return 2 if t and COUNT.fullmatch(t.norm) and weekday_plural_at(tokens, k + 1, v) >= 0 else 0


def every_other_at(tokens, i, v, today):
    """ "every other week" (every 2 weeks), "every other friday" (every 2 weeks from the next Friday),
    and the French "un vendredi sur deux". (tokens covered, pattern, first date), or None.
    """
    def noun(k):
        n, unit = rule_unit_at(tokens, k, v)
        if n:
            return n, f"2 {unit}s", ""
        if (wd := weekday_plural_at(tokens, k, v)) >= 0:
            return 1, "2 weeks", first_occurrence(f"every {WEEKDAYS[wd]}", today)
        return None

    if ev := phrase_at(tokens, i, v["everyOther"]):
        found = noun(i + ev)
        return (ev + found[0], found[1], found[2]) if found else None
    around = v["everyOtherAround"]
    if not (pre := phrase_at(tokens, i, around["before"])) or not (found := noun(i + pre)):
        return None
    post = phrase_at(tokens, i + pre + found[0], around["after"])
    return (pre + found[0] + post, found[1], found[2]) if post else None


def tails(tokens, rule, k, ctx):
    """The rule with any tails after it (after completion, until <date>, for N times), and where it ends."""
    if (n := any_language(ctx, tokens, k, "afterCompletion")) and canonical(rule + " after completion"):
        rule += " after completion"
        k += n
    if until := any_language(ctx, tokens, k, "untilWords"):
        if (dm := match_date_at(tokens, k + until, ctx)) and canonical(f"{rule} until {dm.date}"):
            return f"{rule} until {dm.date}", dm.to
        return rule, k
    for v in ctx.vocabs:
        pre = phrase_at(tokens, k, v["timesWords"]["before"])
        cn, count = count_at(tokens, k + pre, v)
        if not cn or not DIGITS.fullmatch(tokens[k + pre].norm):
            continue
        if (post := phrase_at(tokens, k + pre + cn, v["timesWords"]["after"])) and canonical(f"{rule} for {count} times"):
            return f"{rule} for {count} times", k + pre + cn + post
    return rule, k


def match_repeat_at(tokens, i, ctx):
    if tok(tokens, i) is None:
        return None
    best = None

    def consider(pattern, k, first):
        nonlocal best
        rule, k = tails(tokens, "every " + pattern, k, ctx)
        if (c := canonical(rule)) and (best is None or k > best.to):
            best = RepeatMatch(c, i, k, first=first)

    for v in ctx.vocabs:
        # "every other" first: on a tie it wins over the ordinal reading of "jeden zweiten Freitag".
        if found := every_other_at(tokens, i, v, ctx.today):
            consider(found[1], i + found[0], found[2])
        n, pattern = lookup_at(tokens, i, v["everyOne"])
        if n:
            consider(pattern, i + n, "")
            continue
        if not (ev := phrase_at(tokens, i, v["every"])):
            continue
        found = pattern_at(tokens, i + ev, v)
        if found is None:
            n = count_weekday_at(tokens, i + ev, v)
            if n and (best is None or i + ev + n > best.to):
                best = RepeatMatch("", i, i + ev + n, literal=True)
            continue
        n, text, monthly = found
        k = i + ev + n
        if monthly:
            k += any_language(ctx, tokens, k, "ofMonthWords")
        consider(text, k, "")
    return best

