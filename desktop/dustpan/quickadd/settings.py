"""The parse context from the user's preferences and this device's locale (web/src/lib/nlp/settings.ts)."""

import os

from ..views import WEEK_START
from .parse import Context
from .words import VOCABS


def system_language():
    """This device's language tag, like "en_AU", from the locale variables."""
    for name in ("LC_ALL", "LC_MESSAGES", "LANG"):
        if value := os.environ.get(name, "").split(".")[0]:
            return value
    return "en"


def day_month_order(prefs, first_language):
    """The user's date format when it names an order, else the language's. English is MD only in the US."""
    if prefs.get("date_format") in ("day-month", "month-day"):
        return "DM" if prefs["date_format"] == "day-month" else "MD"
    lang, _, region = first_language.lower().replace("_", "-").partition("-")
    if lang == "en":
        return "MD" if region in ("", "us") else "DM"
    return VOCABS.get(lang, {}).get("dayMonthOrder", "MD")


def context_for(prefs, projects, today, now, system=None):
    """prefs: the user_prefs values. projects: live project Rows, archived too."""
    system = system or system_language()
    language = prefs.get("language")
    languages = [language, system] if language and language != "system" else [system]
    first = next((tag for tag in languages if tag.lower().replace("_", "-").split("-")[0] in VOCABS), "en")
    return Context(
        today, now, languages,
        [{"id": p.id, "name": p.get("name") or "", "parent_id": p.get("parent_id"), "archived": bool(p.get("archived"))}
         for p in projects],
        day_month_order=day_month_order(prefs, first),
        week_start=WEEK_START.get(prefs.get("week_start"), 1),
        day_parts=prefs.get("day_parts") == "on",
        energy=prefs.get("energy") == "on",
    )
