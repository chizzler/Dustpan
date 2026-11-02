"""Help writing a filter query, without GTK: suggestions for the word being typed, and the builder's conditions.

The terms are written as OpenTodo's web builder writes them (web/src/lib/filter/builder.ts), so a view made here
reads the same there. See spec/views.md, "The Filter page".
"""

import re

from .filters import FilterError, parse
from .labels import fold

BREAK = re.compile(r'[\s"&|!()<>=]')
MAX_SUGGESTIONS = 8

# Words the parser knows, offered as a bare word is typed. (word, what it means)
KEYWORDS = (
    ("today", "due today or earlier"), ("tomorrow", "due tomorrow"), ("overdue", "past its due date"),
    ("open", "not completed"), ("completed", "completed"), ("subtask", "under another task"),
    ("someday", "parked for later"), ("deferred", "starts later"), ("blocked", "waiting for an open task"),
    ("unblocked", "not waiting for a task"), ("habit", "a repeating habit"),
    ("no date", "no due date"), ("no deadline", "no deadline"), ("no labels", "no label at all"),
    ("no project", "in the Inbox"), ("no time", "due on a day, at no set time"),
    ("due", "compare the due date: due <= 7 days"), ("deadline", "compare the deadline: deadline < friday"),
    ("created", "compare when it was added: created >= 7 days ago"),
    ("search:", "words in the title or notes"),
    ("p1", "priority 1"), ("p2", "priority 2"), ("p3", "priority 3"), ("p4", "no priority"),
)


def quote_name(name):
    """A label or project name as the parser reads it: bare unless it holds a break character or starts with #."""
    if BREAK.search(name) or not name or name.startswith("#"):
        return '"' + re.sub(r'(["\\])', r"\\\1", name) + '"'
    return name


def label_term(name):
    return "@" + quote_name(name)


def project_term(name, with_subprojects=False):
    return ("##" if with_subprojects else "#") + quote_name(name)


def suggest(query, label_names, project_names):
    """What to offer for the word at the end of query: [(text shown, hint, the query with it completed)].

    After @ the labels, after # or ## the projects, otherwise the keywords. A name typed in full isn't offered.
    """
    named = re.search(r'(^|[\s(!&|])(@|##|#)("?)([^"&|()!<>=]*)$', query)
    if named:
        sigil, quoted, typed = named[2], named[3], named[4]
        if not quoted and re.search(r"\s", typed):
            named = None  # a space ends a bare name: the word being typed is something else
    if named:
        names = label_names if sigil == "@" else project_names
        start = named.start(2)
        prefix = fold(typed)
        out = []
        for name in names:
            # Typed in full is not offered; typed without its accents is, as the parser wants them.
            if fold(name).startswith(prefix) and name.lower() != typed.lower():
                out.append((sigil + name, "label" if sigil == "@" else "project",
                            query[:start] + sigil + quote_name(name) + " "))
        return out[:MAX_SUGGESTIONS]
    word = re.search(r"(^|[\s(!&|])([A-Za-z:]+)$", query)
    if not word:
        return []
    typed = word[2].lower()
    start = word.start(2)
    return [(kw, hint, query[:start] + kw + " ") for kw, hint in KEYWORDS
            if kw.startswith(typed) and kw != typed][:MAX_SUGGESTIONS]


def add_condition(query, term, negate=False):
    """query with term joined on by &. A query whose top level is an | keeps its meaning in brackets."""
    if negate:
        term = f"!({term})" if " " in term else "!" + term
    query = query.strip()
    if not query:
        return term
    try:
        tree = parse(query)
    except FilterError:
        tree = None
    if tree is not None and tree[0] == "or":
        query = f"({query})"
    return f"{query} & {term}"


def conditions(label_names, project_names):
    """The builder's menu: [(group, [(label, term)])]. Every term parses."""
    return [
        ("When", [
            ("Due today or earlier", "today"), ("Due tomorrow", "tomorrow"), ("Overdue", "overdue"),
            ("Due in the next 7 days", "due <= 7 days"), ("Due this week", "due <= this week"),
            ("No due date", "no date"), ("Deadline in the next 7 days", "deadline <= 7 days"),
            ("Added in the last 7 days", "created >= 7 days ago"),
            ("Completed in the last 7 days", "completed >= 7 days ago"),
        ]),
        ("Priority", [("Priority 1", "p1"), ("Priority 2", "p2"), ("Priority 3", "p3"), ("No priority", "p4")]),
        ("State", [
            ("Open", "open"), ("Completed", "completed"), ("A subtask", "subtask"), ("Blocked", "blocked"),
            ("Someday", "someday"), ("Starts later", "deferred"), ("A habit", "habit"),
        ]),
        ("Label", [(name, label_term(name)) for name in label_names] + [("No labels", "no labels")]),
        ("Project", [(name, project_term(name)) for name in project_names] +
         [(name + " and its sub-projects", project_term(name, True)) for name in project_names] +
         [("No project (Inbox)", "no project")]),
    ]
