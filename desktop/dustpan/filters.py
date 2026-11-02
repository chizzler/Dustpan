"""The filter query language: parse a query, then test tasks against it.

A port of web/src/lib/filter/parse.ts and evaluate.ts (v0.18.0). The grammar and
messages are in OpenTodo's docs/filters.md. See spec/views.md.

The tree is plain tuples, tagged by their first item:
("or", [nodes]), ("and", [nodes]), ("not", node), ("label", name), ("project", name, descendants),
("priority", n), ("date", field, op, date), ("keyword", word), ("search", text), ("origin", value),
("energy", value), ("workspace", name), ("field", name, op, value), ("nofield", name), ("tracked", op, minutes).
Dates are ("relative", days), ("weekday", 0 = Sunday), ("iso", "YYYY-MM-DD") or ("period", "week" | "month", offset).
"""

import math
import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta

from .dates import local_due

MAX_QUERY_LENGTH = 4096
MAX_NESTING = 64

WEEKDAYS = ("sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday")
SIMPLE_KEYWORDS = {"overdue", "today", "tomorrow", "completed", "open", "subtask", "someday", "deferred", "evening",
                   "morning", "afternoon", "blocked", "unblocked", "available", "habit", "origin", "energy"}
NO_KEYWORDS = ("date", "project", "labels", "time", "deadline", "start", "origin", "energy")
DATE_FIELDS = {"due", "created", "deadline", "start"}
DATE_STARTS = {"today", "tomorrow", "yesterday", "this", "last", "next"}
DATE_UNITS = {"days", "week", "weeks", "month", "months"}
ENERGIES = ("deep", "medium", "low")
SINGLE = {"&": "and", "|": "or", "!": "not", "(": "lparen", ")": "rparen"}
BREAK = re.compile(r'[\s"&|!()<>=]')
INTEGER = re.compile(r"\d+", re.ASCII)
ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}", re.ASCII)
NUMBER = re.compile(r"-?\d+(\.\d+)?", re.ASCII)
PRIORITY = re.compile(r"p([1-4])", re.ASCII | re.IGNORECASE)
HOURS = re.compile(r"(\d+(?:\.\d+)?)h(?:(\d{1,2})(?:m|min)?)?", re.ASCII)
MINUTES = re.compile(r"(\d+)(?:m|min|mins|minutes)?", re.ASCII)
MAX_DURATION = 144000
CMP = {"before": "<", "after": ">"}

# Terms that need data this client doesn't keep yet. They parse, match nothing and warn.
UNSUPPORTED = "{} isn't supported on this device yet"


class FilterError(Exception):
    """A query that doesn't follow the grammar. offset is 0-based; the message counts from 1."""

    def __init__(self, message, offset):
        super().__init__(message)
        self.offset = offset

    @property
    def position(self):
        return self.offset + 1


@dataclass
class Token:
    type: str  # and, or, not, lparen, rparen, cmp, label, project, priority, search, origin, energy, workspace, word, string
    pos: int
    raw: str
    value: object = None  # the name, text, priority or comparison
    descendants: bool = False  # "##"


def duration_minutes(text):
    """ "30m", "1h30", "1.5h" or a bare number of minutes. None when it isn't one."""
    text = text.strip().lower()
    if m := HOURS.fullmatch(text):
        minutes = int(m[2]) if m[2] else 0
        if minutes > 59:
            return None
        total = math.floor(float(m[1]) * 60 + minutes + 0.5)  # half up, like JS
        return total if total <= MAX_DURATION else None
    if m := MINUTES.fullmatch(text):
        return int(m[1]) if int(m[1]) <= MAX_DURATION else None
    return None


# ---- tokens ----


def tokenize(src):
    out = []
    i, n = 0, len(src)

    def read_bare():
        nonlocal i
        start = i
        while i < n and not BREAK.match(src[i]):
            i += 1
        return src[start:i]

    def read_string():
        # src[i] is the opening quote. A backslash escapes the next character.
        nonlocal i
        start = i
        i += 1
        text = ""
        while i < n and src[i] != '"':
            if src[i] == "\\" and i + 1 < n:
                i += 1
            text += src[i]
            i += 1
        if i >= n:
            raise FilterError(f"Missing closing quote for the text starting at position {start + 1}", start)
        i += 1
        return text

    def read_name(what, after, at):
        if i < n and src[i] == '"':
            return read_string()
        name = read_bare()
        if not name:
            raise FilterError(f'Expected a {what} name after "{after}" at position {at + 1}', at)
        return name

    def read_prefixed(word, prefix):
        # "search:text", "search: text" or 'search: "several words"'.
        nonlocal i
        if text := word[len(prefix):]:
            return text
        while i < n and src[i].isspace():
            i += 1
        return read_string() if i < n and src[i] == '"' else read_bare()

    while i < n:
        c = src[i]
        if c.isspace():
            i += 1
            continue
        pos = i
        if c in SINGLE:
            i += 1
            out.append(Token(SINGLE[c], pos, c))
        elif c in "<>=":
            op = c + "=" if c != "=" and src[i + 1:i + 2] == "=" else c
            i += len(op)
            out.append(Token("cmp", pos, op, op))
        elif c == "@":
            i += 1
            name = read_name("label", "@", pos)
            out.append(Token("label", pos, src[pos:i], name))
        elif c == "#":
            descendants = src[i + 1:i + 2] == "#"
            i += 2 if descendants else 1
            name = read_name("project", "##" if descendants else "#", pos)
            out.append(Token("project", pos, src[pos:i], name, descendants))
        elif c == '"':
            value = read_string()
            out.append(Token("string", pos, src[pos:i], value))
        else:
            word = read_bare()
            prefix = word[:word.find(":") + 1].lower() if ":" in word else ""
            if prefix in ("search:", "workspace:", "origin:", "energy:"):
                value = read_prefixed(word, prefix)
                if prefix == "energy:":
                    value = value.lower()
                    if value not in ENERGIES:
                        raise FilterError(f"Energy must be deep, medium or low at position {pos + 1}", pos)
                elif not value:
                    raise FilterError({
                        "search:": f'Expected text after "search:" at position {pos + 1}',
                        "workspace:": f'Expected a workspace name after "workspace:" at position {pos + 1}',
                        "origin:": f'Expected a provider or kind after "origin:" at position {pos + 1}',
                    }[prefix], pos)
                out.append(Token(prefix[:-1], pos, src[pos:i], value))
            elif m := PRIORITY.fullmatch(word):
                out.append(Token("priority", pos, word, int(m[1])))
            else:
                out.append(Token("word", pos, word, word))
    return out


# ---- parser ----


def parse(src):
    """The query's tree, or None for an empty query. Raises FilterError."""
    if len(src) > MAX_QUERY_LENGTH:
        raise FilterError(f"Query is too long: {len(src)} characters, at most {MAX_QUERY_LENGTH}", MAX_QUERY_LENGTH)
    tokens = tokenize(src)
    if not tokens:
        return None
    return Parser(tokens, len(src)).query()


def valid_iso(text):
    try:
        date.fromisoformat(text)
        return True
    except ValueError:
        return False


class Parser:
    def __init__(self, tokens, end):
        self.tokens = tokens
        self.i = 0
        self.depth = 0
        self.end = end

    def peek(self, ahead=0):
        k = self.i + ahead
        return self.tokens[k] if k < len(self.tokens) else None

    def lower(self, tok):
        return tok.value.lower() if tok and tok.type == "word" else ""

    def take(self):
        tok = self.tokens[self.i]
        self.i += 1
        return tok

    def query(self):
        ast = self.parse_or(None)
        if rest := self.peek():
            if rest.type == "rparen":
                raise FilterError(f'Unexpected ")" at position {rest.pos + 1}', rest.pos)
            raise FilterError(f'Expected "&" or "|" before "{rest.raw}" at position {rest.pos + 1}', rest.pos)
        return ast

    def missing_term(self, prev):
        """prev is the operator or parenthesis just read, if any."""
        if prev:
            raise FilterError(f'Expected a term after "{prev.raw}" at position {prev.pos + 1}', prev.pos)
        tok = self.peek()
        at = tok.pos if tok else self.end
        raise FilterError(f"Expected a term at position {at + 1}", at)

    def parse_or(self, prev):
        items = [self.parse_and(prev)]
        while (tok := self.peek()) and tok.type == "or":
            items.append(self.parse_and(self.take()))
        return items[0] if len(items) == 1 else ("or", items)

    def parse_and(self, prev):
        items = [self.parse_not(prev)]
        while (tok := self.peek()) and tok.type == "and":
            items.append(self.parse_not(self.take()))
        return items[0] if len(items) == 1 else ("and", items)

    def enter(self, tok):
        self.depth += 1
        if self.depth > MAX_NESTING:
            raise FilterError(f'Too deeply nested at position {tok.pos + 1}; use at most {MAX_NESTING} levels of "(" and "!"',
                              tok.pos)

    def parse_not(self, prev):
        tok = self.peek()
        if tok is None:
            self.missing_term(prev)
        if tok.type == "not":
            self.take()
            self.enter(tok)
            item = self.parse_not(tok)
            self.depth -= 1
            return ("not", item)
        if tok.type == "lparen":
            self.take()
            self.enter(tok)
            inner = self.parse_or(tok)
            close = self.peek()
            if close is None:
                raise FilterError('Missing ")" at end of query', self.end)
            if close.type != "rparen":
                raise FilterError(f'Expected "&", "|" or ")" before "{close.raw}" at position {close.pos + 1}', close.pos)
            self.take()
            self.depth -= 1
            return inner
        return self.parse_term(prev)

    def parse_term(self, prev):
        tok = self.peek()
        if tok.type in ("label", "search", "origin", "energy", "workspace", "priority"):
            self.take()
            return (tok.type, tok.value)
        if tok.type == "project":
            self.take()
            return ("project", tok.value, tok.descendants)
        if tok.type == "word":
            return self.parse_word_term(self.take())
        if tok.type == "string":
            # A quoted name followed by a comparison is a custom field term.
            if (nxt := self.peek(1)) and nxt.type == "cmp":
                self.take()
                return self.parse_field_term(tok.value)
            raise FilterError(f'Unexpected text {tok.raw} at position {tok.pos + 1}; '
                              'quote names after "@" or "#", or use search:', tok.pos)
        self.missing_term(prev)

    def comparison(self):
        """The comparison at the cursor, if there is one: <, <=, =, >=, >, before or after."""
        tok = self.peek()
        if tok and tok.type == "cmp":
            return tok.value
        return CMP.get(self.lower(tok))

    def parse_word_term(self, entry):
        w = entry.value.lower()
        # "completed" is the state keyword unless a comparison follows.
        if w in DATE_FIELDS or (w == "completed" and self.comparison()):
            op = self.comparison()
            if op is None:
                raise FilterError(f'Expected a comparison (<, <=, =, >=, >, before or after) after "{entry.raw}" '
                                  f"at position {entry.pos + 1}", entry.pos)
            return ("date", w, op, self.parse_date(self.take()))
        if w == "tracked":
            c = self.peek()
            if not c or c.type != "cmp":
                return ("keyword", "tracked")
            self.take()
            v = self.peek()
            minutes = duration_minutes(v.value) if v and v.type == "word" else None
            if minutes is None:
                at = v.pos if v and v.type == "word" else c.pos
                raise FilterError(f'Expected a duration such as 30m or 1h30 after "{c.raw}" at position {at + 1}', at)
            self.take()
            return ("tracked", c.value, minutes)
        if w == "no":
            nxt = self.peek()
            if self.lower(nxt) in NO_KEYWORDS:
                self.take()
                return ("keyword", "no " + self.lower(nxt))
            # Any other name is a custom field without a value.
            if nxt and nxt.type in ("word", "string"):
                self.take()
                return ("nofield", nxt.value)
            raise FilterError('Expected "date", "project", "labels", "time", "deadline", "start", "origin" or a field name '
                              f'after "no" at position {entry.pos + 1}', entry.pos)
        if w in SIMPLE_KEYWORDS:
            return ("keyword", w)
        if re.fullmatch(r"p\d+", w, re.ASCII):
            raise FilterError(f"Priority must be p1, p2, p3 or p4 at position {entry.pos + 1}", entry.pos)
        if (nxt := self.peek()) and nxt.type == "cmp":
            return self.parse_field_term(entry.value)
        raise FilterError(f'Unknown term "{entry.raw}" at position {entry.pos + 1}', entry.pos)

    def parse_field_term(self, name):
        c = self.take()
        return ("field", name, c.value, self.parse_field_value(c))

    def parse_field_value(self, after):
        """A quoted text, true or false, a date, a number, or any other word as text."""
        tok = self.peek()
        if tok and tok.type == "string":
            self.take()
            return ("text", tok.value)
        if not tok or tok.type != "word":
            raise FilterError(f'Expected a value after "{after.raw}" at position {after.pos + 1}', after.pos)
        w = tok.value.lower()
        if w in ("true", "false"):
            self.take()
            return ("bool", w == "true")
        unit = self.lower(self.peek(1)) if INTEGER.fullmatch(w) else ""
        if w in DATE_STARTS or w in WEEKDAYS or ISO_DATE.fullmatch(w) or unit in DATE_UNITS:
            return ("date", self.parse_date(after))
        self.take()
        if NUMBER.fullmatch(w):
            return ("number", float(w))
        return ("text", tok.value)

    def parse_date(self, after):
        tok = self.peek()
        if not tok or tok.type != "word":
            raise FilterError(f'Expected a date after "{after.raw}" at position {after.pos + 1}', after.pos)
        w = tok.value.lower()
        self.take()
        if w in ("today", "tomorrow", "yesterday"):
            return ("relative", {"today": 0, "tomorrow": 1, "yesterday": -1}[w])
        if w in WEEKDAYS:
            return ("weekday", WEEKDAYS.index(w))
        if ISO_DATE.fullmatch(w):
            if not valid_iso(w):
                raise FilterError(f'Invalid date "{tok.raw}" at position {tok.pos + 1}', tok.pos)
            return ("iso", w)
        if w in ("this", "last", "next"):
            unit = self.lower(self.peek())
            if unit not in ("week", "month"):
                raise FilterError(f'Expected "week" or "month" after "{tok.raw}" at position {tok.pos + 1}', tok.pos)
            self.take()
            return ("period", unit, {"this": 0, "last": -1, "next": 1}[w])
        if INTEGER.fullmatch(w):
            count = int(w)
            unit_tok = self.peek()
            unit = self.lower(unit_tok)
            if unit == "days":
                self.take()
                if self.lower(self.peek()) == "ago":
                    self.take()
                    return ("relative", -count)
                return ("relative", count)
            if unit in ("week", "weeks", "month", "months"):
                self.take()
                if self.lower(self.peek()) != "ago":
                    raise FilterError(f'Expected "ago" after "{unit_tok.raw}" at position {unit_tok.pos + 1}', unit_tok.pos)
                self.take()
                return ("period", "week" if unit.startswith("week") else "month", -count)
            raise FilterError(f'Expected "days", "weeks" or "months" after "{tok.raw}" at position {tok.pos + 1}', tok.pos)
        raise FilterError(f'Invalid date "{tok.raw}" at position {tok.pos + 1}', tok.pos)


# ---- dates ----


def shift(iso, days):
    return (date.fromisoformat(iso) + timedelta(days=days)).isoformat()


def weekday_of(iso):
    """0 = Sunday."""
    return (date.fromisoformat(iso).weekday() + 1) % 7


def month_start(iso, months):
    day = date.fromisoformat(iso)
    index = day.year * 12 + day.month - 1 + months
    return date(index // 12, index % 12 + 1, 1).isoformat()


def resolve_range(expr, today, week_start=1):
    """The inclusive (first, last) days a date expression denotes. week_start: 0 = Sunday."""
    kind = expr[0]
    if kind == "iso":
        return expr[1], expr[1]
    if kind == "relative":
        day = shift(today, expr[1])
        return day, day
    if kind == "weekday":  # the next such day, today included
        day = shift(today, (expr[1] - weekday_of(today)) % 7)
        return day, day
    _, unit, offset = expr
    if unit == "week":
        start = shift(today, -((weekday_of(today) - week_start) % 7) + 7 * offset)
        return start, shift(start, 6)
    return month_start(today, offset), shift(month_start(today, offset + 1), -1)


def compare_days(day, op, first, last):
    """A day against a range of days. A one-day range is a plain comparison."""
    return {"<": day < first, "<=": day <= last, "=": first <= day <= last, ">=": day >= first, ">": day > last}[op]


def due_day(due):
    """The due's date in this device's zone, as YYYY-MM-DD."""
    return local_due(due)[0].isoformat()


# ---- blocked tasks ----


def components(ids, edges):
    """Strongly connected components of a graph, iteratively (Kosaraju)."""
    order, seen = [], set()
    for root in ids:
        if root in seen:
            continue
        seen.add(root)
        stack = [(root, iter(edges(root)))]
        while stack:
            node, rest = stack[-1]
            nxt = next((w for w in rest if w not in seen), None)
            if nxt is None:
                stack.pop()
                order.append(node)
            else:
                seen.add(nxt)
                stack.append((nxt, iter(edges(nxt))))
    reverse = {}
    for node in ids:
        for w in edges(node):
            reverse.setdefault(w, []).append(node)
    found, assigned = [], set()
    for root in reversed(order):
        if root in assigned:
            continue
        assigned.add(root)
        comp, stack = [], [root]
        while stack:
            node = stack.pop()
            comp.append(node)
            for w in reverse.get(node, []):
                if w not in assigned:
                    assigned.add(w)
                    stack.append(w)
        found.append(comp)
    return found


def blocked_ids(tasks):
    """Open tasks waiting for a live, open task. In each cycle, the member whose blocked_by
    has the newest clock stops blocking, the same on every device (web/src/lib/dependencies.ts).
    """
    by_id = {t.id: t for t in tasks}

    def blockers(task):
        value = task.get("blocked_by")
        return value if isinstance(value, list) else []

    def newer(a, b):
        ca, cb = a.clocks.get("blocked_by"), b.clocks.get("blocked_by")
        ka = (ca.ts, ca.device) if ca else (0, "")
        kb = (cb.ts, cb.device) if cb else (0, "")
        return ka > kb or (ka == kb and a.id > b.id)

    broken = set()

    def edges(task_id):
        return [b for b in blockers(by_id[task_id]) if b in by_id and (task_id, b) not in broken]

    while cycles := [c for c in components(sorted(by_id), edges) if len(c) > 1]:
        for cycle in cycles:
            members = set(cycle)
            loser = by_id[cycle[0]]
            for task_id in cycle[1:]:
                if newer(by_id[task_id], loser):
                    loser = by_id[task_id]
            broken.update((loser.id, b) for b in edges(loser.id) if b in members)

    def open_task(task):
        return task is not None and task.get("deleted_at") is None and task.get("completed_at") is None

    return {t.id for t in tasks if open_task(t) and any(
        open_task(by_id.get(b)) and (t.id, b) not in broken for b in blockers(t))}


# ---- evaluation ----


@dataclass
class Context:
    today: str  # the logical today
    tasks: list  # every task Row, for "blocked"
    labels: list  # live label Rows
    projects: list  # live project Rows
    week_start: int = 1  # 0 = Sunday
    day_start: int = 0  # minutes after midnight a day begins


def mentions_state(node):
    """True when the query says "completed" or "open", or compares the completion date."""
    kind = node[0]
    if kind in ("or", "and"):
        return any(mentions_state(n) for n in node[1])
    if kind == "not":
        return mentions_state(node[1])
    return (kind == "keyword" and node[1] in ("completed", "open")) or (kind == "date" and node[1] == "completed")


def name_key(name):
    return name.strip().lower()


def text(value):
    return value if isinstance(value, str) else ""


def origin_of(task):
    origin = task.get("origin")
    return origin if isinstance(origin, dict) and isinstance(origin.get("kind"), str) else None


def energy_of(task):
    return task.get("energy") if task.get("energy") in ENERGIES else None


def day_part_of(task):
    if task.get("evening"):
        return "evening"
    return task.get("day_part") if task.get("day_part") in ("morning", "afternoon") else None


def compile_query(ast, ctx):
    """(predicate over task Rows, warnings). Unknown names and unsupported terms match nothing and warn."""
    warnings = []

    def warn(message):
        if message not in warnings:
            warnings.append(message)

    by_name = {}
    for kind, rows in (("label", ctx.labels), ("project", ctx.projects)):
        for row in rows:
            by_name.setdefault((kind, name_key(text(row.get("name")))), set()).add(row.id)
    children = {}
    for project in ctx.projects:
        children.setdefault(project.get("parent_id"), []).append(project.id)
    today, tomorrow = ctx.today, shift(ctx.today, 1)
    blocked = None

    def subprojects(ids):
        found, stack = set(ids), list(ids)
        while stack:
            for child in children.get(stack.pop(), []):
                if child not in found:
                    found.add(child)
                    stack.append(child)
        return found

    def start_of_day(iso):
        """The first instant of a logical day, as Unix ms."""
        return int((datetime.fromisoformat(iso) + timedelta(minutes=ctx.day_start)).timestamp() * 1000)

    def instant(name, op, first, last):
        start, nxt = start_of_day(first), start_of_day(shift(last, 1))
        tests = {"<": lambda ms: ms < start, "<=": lambda ms: ms < nxt, "=": lambda ms: start <= ms < nxt,
                 ">=": lambda ms: ms >= start, ">": lambda ms: ms >= nxt}[op]
        return lambda t: isinstance(t.get(name), (int, float)) and tests(t.get(name))

    def keyword(word):
        nonlocal blocked
        if word in ("blocked", "unblocked"):
            if blocked is None:
                blocked = blocked_ids(ctx.tasks)
            return (lambda t: t.id in blocked) if word == "blocked" else (lambda t: t.id not in blocked)
        if word in ("available", "tracked"):
            warn(UNSUPPORTED.format(f"“{word}”"))
            return lambda t: False
        due = lambda t: due_day(t.get("due")) if t.get("due") else None  # noqa: E731
        start = lambda t: t.get("start")  # noqa: E731
        return {
            "overdue": lambda t: (d := due(t)) is not None and d < today,
            "today": lambda t: due(t) == today,
            "tomorrow": lambda t: due(t) == tomorrow,
            "no date": lambda t: not t.get("due"),
            "no time": lambda t: bool(t.get("due")) and not t.get("due").get("time"),
            "no project": lambda t: t.get("project_id") is None,
            "no labels": lambda t: not t.get("labels"),
            "no deadline": lambda t: not t.get("deadline"),
            "no start": lambda t: not start(t),
            "someday": lambda t: start(t) == "someday",
            "deferred": lambda t: bool(start(t)) and start(t) != "someday" and start(t) > today,
            "evening": lambda t: bool(t.get("evening")),
            "morning": lambda t: day_part_of(t) == "morning",
            "afternoon": lambda t: day_part_of(t) == "afternoon",
            # A habit's skipped day isn't a completion.
            "completed": lambda t: t.get("completed_at") is not None and not t.get("skipped"),
            "open": lambda t: t.get("completed_at") is None,
            "subtask": lambda t: t.get("parent_id") is not None,
            "habit": lambda t: t.get("habit") is True,
            "origin": lambda t: origin_of(t) is not None,
            "no origin": lambda t: origin_of(t) is None,
            "energy": lambda t: energy_of(t) is not None,
            "no energy": lambda t: energy_of(t) is None,
        }[word]

    def build(node):
        kind = node[0]
        if kind in ("or", "and"):
            preds = [build(n) for n in node[1]]
            combine = any if kind == "or" else all
            return lambda t: combine(p(t) for p in preds)
        if kind == "not":
            pred = build(node[1])
            return lambda t: not pred(t)
        if kind in ("label", "project"):
            # Several labels or projects may share a name: any of them matches.
            ids = by_name.get((kind, name_key(node[1])))
            if not ids:
                warn(f'No {kind} named "{node[1]}"')
                return lambda t: False
            if kind == "label":
                return lambda t: any(i in ids for i in t.get("labels") or [])
            ids = subprojects(ids) if node[2] else ids
            return lambda t: t.get("project_id") in ids
        if kind == "priority":
            return lambda t: t.get("priority") == node[1]
        if kind == "date":
            _, name, op, expr = node
            first, last = resolve_range(expr, today, ctx.week_start)
            if name in ("created", "completed"):
                return instant(f"{name}_at", op, first, last)
            if name == "due":
                return lambda t: bool(t.get("due")) and compare_days(due_day(t.get("due")), op, first, last)
            if name == "start":
                return lambda t: bool(t.get("start")) and t.get("start") != "someday" and compare_days(t.get("start"), op, first, last)
            return lambda t: bool(t.get("deadline")) and compare_days(t.get("deadline"), op, first, last)
        if kind == "search":
            needle = node[1].lower()
            return lambda t: needle in text(t.get("title")).lower() or needle in text(t.get("description")).lower()
        if kind == "origin":
            want = node[1].lower()

            def provider(t):
                origin = origin_of(t)
                return origin and text(origin.get("provider") if origin.get("provider") is not None else origin["kind"]).lower()

            return lambda t: provider(t) == want
        if kind == "energy":
            return lambda t: energy_of(t) == node[1]
        if kind == "keyword":
            return keyword(node[1])
        warn(UNSUPPORTED.format({"workspace": "Workspaces", "tracked": "Tracked time"}.get(kind, "Custom fields")))
        return lambda t: False

    pred = build(ast)
    if not mentions_state(ast):
        return (lambda t: t.get("deleted_at") is None and t.get("completed_at") is None and pred(t)), warnings
    # A habit's skipped day matches no query.
    return (lambda t: t.get("deleted_at") is None and not t.get("skipped") and pred(t)), warnings


def with_completed(ast):
    """The query with completed matches shown too, unless it already names a state."""
    return ast if mentions_state(ast) else ("and", [ast, ("or", [("keyword", "open"), ("keyword", "completed")])])
