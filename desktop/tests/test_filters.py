import json
import re
import unittest
from datetime import datetime

from dustpan.filters import Context, FilterError, blocked_ids, compile_query, parse, resolve_range, with_completed
from dustpan.store import Clock, Row

from .vectors import read


def show(query):
    """The query fully parenthesised, to check how it grouped."""
    def text(node):
        kind = node[0]
        if kind in ("or", "and"):
            return "(" + f" {'|' if kind == 'or' else '&'} ".join(text(n) for n in node[1]) + ")"
        if kind == "not":
            return "!" + text(node[1])
        return {"label": lambda: "@" + node[1], "project": lambda: ("##" if node[2] else "#") + node[1],
                "priority": lambda: f"p{node[1]}", "keyword": lambda: node[1]}.get(kind, lambda: repr(node))()

    return text(parse(query))


def error(query):
    try:
        parse(query)
    except FilterError as err:
        return str(err)
    return None


class SharedParserTest(unittest.TestCase):
    """The examples and messages OpenTodo's parsers are checked against."""

    def test_docs_examples_parse(self):
        blocks = re.findall(r"```filter\n(.*?)```", read("docs/filters.md"), re.S)
        self.assertGreaterEqual(len(blocks), 10)
        for query in blocks:
            with self.subTest(query):
                self.assertIsNotNone(parse(query.strip()))

    def test_docs_error_table(self):
        doc = read("docs/filters.md")
        table = doc[doc.index("## Errors"):doc.index("## The New view page")]
        rows = re.findall(r"^\| `(.+?)` \| `(.+?)` \|$", table, re.M)
        self.assertGreaterEqual(len(rows), 5)
        for query, message in rows:
            with self.subTest(query):
                self.assertEqual(error(query.replace(r"\|", "|")), message.replace(r"\|", "|"))

    def test_formatted_queries_parse(self):
        lines = [line for line in read("internal/filter/testdata/formatted.txt").splitlines()
                 if line and not line.startswith("# ")]
        self.assertGreaterEqual(len(lines), 150)
        for query in lines:
            with self.subTest(query):
                self.assertIsNotNone(parse(query))

    def test_limits(self):
        limits = json.loads(read("internal/filter/testdata/limits.json"))
        for v in limits["vectors"]:
            query = v["prefix"] + v["repeat"] * v["times"] + v["suffix"] + v["close"] * v["closeTimes"]
            with self.subTest(query[:40]):
                self.assertEqual(error(query), v["error"])


class ParserTest(unittest.TestCase):
    def test_precedence(self):
        self.assertEqual(show("@errand | @call & p1"), "(@errand | (@call & p1))")
        self.assertEqual(show("!@a & @b"), "(!@a & @b)")
        self.assertEqual(show("(@errand | @call) & !#Work"), "((@errand | @call) & !#Work)")
        self.assertEqual(show("((p1))"), "p1")
        self.assertEqual(show("p1 | p2 | p3"), "(p1 | p2 | p3)")

    def test_terms(self):
        self.assertEqual(parse('#"Client A" & @"say \\"hi\\""'), ("and", [("project", "Client A", False), ("label", 'say "hi"')]))
        self.assertEqual(parse("due<=tomorrow"), ("date", "due", "<=", ("relative", 1)))
        self.assertEqual(parse("created > 7 days ago"), ("date", "created", ">", ("relative", -7)))
        self.assertEqual(parse("due after friday"), ("date", "due", ">", ("weekday", 5)))
        self.assertEqual(parse("completed = 2 weeks ago"), ("date", "completed", "=", ("period", "week", -2)))
        self.assertEqual(parse("SEARCH: \"oat milk\""), ("search", "oat milk"))
        self.assertEqual(parse("tracked >= 1h30"), ("tracked", ">=", 90))
        self.assertEqual(parse("no cost"), ("nofield", "cost"))
        self.assertEqual(parse("@C#-dev & #Café/Bar"), ("and", [("label", "C#-dev"), ("project", "Café/Bar", False)]))
        self.assertIsNone(parse("   "))

    def test_messages(self):
        for query, message in {
            "@": 'Expected a label name after "@" at position 1',
            '@"open': "Missing closing quote for the text starting at position 2",
            "p1 )": 'Unexpected ")" at position 4',
            "(p1 p2)": 'Expected "&", "|" or ")" before "p2" at position 5',
            "()": 'Expected a term after "(" at position 1',
            '"loose text"': 'Unexpected text "loose text" at position 1; quote names after "@" or "#", or use search:',
            "due < 2026-02-30": 'Invalid date "2026-02-30" at position 7',
            "completed today": 'Expected "&" or "|" before "today" at position 11',
            "tracked = 1h75": 'Expected a duration such as 30m or 1h30 after "=" at position 11',
            "p1 & energy:": "Energy must be deep, medium or low at position 6",
        }.items():
            with self.subTest(query):
                self.assertEqual(error(query), message)


class DateRangeTest(unittest.TestCase):
    """The tables in docs/filters.md, "Dates" and "Periods"."""

    def range(self, expr, today, week_start=1):
        return resolve_range(parse(f"due = {expr}")[3], today, week_start)

    def test_days(self):
        sat = "2026-10-10"
        for expr, day in (("today", "2026-10-10"), ("tomorrow", "2026-10-11"), ("yesterday", "2026-10-09"),
                          ("friday", "2026-10-16"), ("saturday", "2026-10-10"), ("3 days", "2026-10-13"),
                          ("7 days ago", "2026-10-03")):
            self.assertEqual(self.range(expr, sat), (day, day), expr)

    def test_periods(self):
        fri = "2026-10-16"
        for expr, want in (("this week", ("2026-10-12", "2026-10-18")), ("last week", ("2026-10-05", "2026-10-11")),
                           ("next week", ("2026-10-19", "2026-10-25")), ("2 weeks ago", ("2026-09-28", "2026-10-04")),
                           ("this month", ("2026-10-01", "2026-10-31")), ("last month", ("2026-09-01", "2026-09-30")),
                           ("3 months ago", ("2026-07-01", "2026-07-31"))):
            self.assertEqual(self.range(expr, fri), want, expr)
        self.assertEqual(self.range("this week", fri, week_start=0), ("2026-10-11", "2026-10-17"))
        self.assertEqual(self.range("next month", "2026-12-15"), ("2027-01-01", "2027-01-31"))


def task(task_id, **fields):
    return Row(task_id, {"title": task_id, "description": "", "project_id": None, "parent_id": None, "priority": 4,
                         "due": None, "labels": [], "completed_at": None, "deleted_at": None, **fields})


def at(iso, hour=12):
    return int(datetime.fromisoformat(f"{iso}T{hour:02d}:00").timestamp() * 1000)


class EvaluateTest(unittest.TestCase):
    def setUp(self):
        self.labels = [Row("l1", {"name": "Errand"}), Row("l2", {"name": "errand"}), Row("l3", {"name": "call"})]
        self.projects = [Row("work", {"name": "Work"}), Row("client", {"name": "Client A", "parent_id": "work"}),
                         Row("home", {"name": "Home"})]

    def match(self, query, tasks, today="2026-10-16", **ctx):
        context = Context(today, tasks, self.labels, self.projects, **ctx)
        test, warnings = compile_query(parse(query), context)
        return sorted(t.id for t in tasks if test(t)), warnings

    def test_names_ignore_case_and_shared_names_all_match(self):
        tasks = [task("a", labels=["l1"]), task("b", labels=["l2"]), task("c", labels=["l3"])]
        self.assertEqual(self.match("@ERRAND", tasks), (["a", "b"], []))

    def test_unknown_names_warn_and_match_nothing(self):
        tasks = [task("a", labels=["l3"])]
        self.assertEqual(self.match("@gone | @call", tasks), (["a"], ['No label named "gone"']))
        self.assertEqual(self.match("!#Nowhere", tasks), (["a"], ['No project named "Nowhere"']))

    def test_projects_with_and_without_subprojects(self):
        tasks = [task("a", project_id="work"), task("b", project_id="client"), task("c", project_id="home"), task("d")]
        self.assertEqual(self.match("#work", tasks)[0], ["a"])
        self.assertEqual(self.match("##Work", tasks)[0], ["a", "b"])
        self.assertEqual(self.match("no project", tasks)[0], ["d"])

    def test_due_terms_use_calendar_days(self):
        tasks = [task("past", due={"date": "2026-10-15"}), task("now", due={"date": "2026-10-16", "time": "23:00"}),
                 task("next", due={"date": "2026-10-19"}), task("none")]
        self.assertEqual(self.match("overdue", tasks)[0], ["past"])
        self.assertEqual(self.match("due <= today", tasks)[0], ["now", "past"])
        self.assertEqual(self.match("due = next week", tasks)[0], ["next"])
        self.assertEqual(self.match("no date | no time", tasks)[0], ["next", "none", "past"])

    def test_only_open_tasks_unless_the_query_names_a_state(self):
        tasks = [task("open", priority=1), task("done", priority=1, completed_at=at("2026-10-14")),
                 task("skipped", priority=1, completed_at=at("2026-10-14"), skipped=True),
                 task("gone", priority=1, deleted_at=1)]
        self.assertEqual(self.match("p1", tasks)[0], ["open"])
        self.assertEqual(self.match("p1 & completed", tasks)[0], ["done"])
        self.assertEqual(self.match("completed = this week", tasks)[0], ["done"])
        context = Context("2026-10-16", tasks, [], [])
        test, _ = compile_query(with_completed(parse("p1")), context)
        self.assertEqual(sorted(t.id for t in tasks if test(t)), ["done", "open"])

    def test_created_counts_the_day_start(self):
        tasks = [task("late", created_at=at("2026-10-16", hour=2))]
        self.assertEqual(self.match("created = today", tasks)[0], ["late"])
        self.assertEqual(self.match("created = yesterday", tasks, day_start=3 * 60)[0], ["late"])

    def test_start_dates(self):
        tasks = [task("parked", start="someday"), task("later", start="2026-10-20"), task("started", start="2026-10-01")]
        self.assertEqual(self.match("someday", tasks)[0], ["parked"])
        self.assertEqual(self.match("deferred", tasks)[0], ["later"])
        self.assertEqual(self.match("start <= today", tasks)[0], ["started"])
        self.assertEqual(self.match("no start", tasks)[0], [])

    def test_task_fields(self):
        tasks = [task("a", origin={"kind": "url", "provider": "GitHub"}, energy="deep", day_part="morning"),
                 task("b", origin={"kind": "email"}, evening=True, habit=True), task("c", energy="huge")]
        self.assertEqual(self.match("origin: github", tasks)[0], ["a"])
        self.assertEqual(self.match("origin: EMAIL", tasks)[0], ["b"])
        self.assertEqual(self.match("no origin", tasks)[0], ["c"])
        self.assertEqual(self.match("energy: deep | no energy", tasks)[0], ["a", "b", "c"])
        self.assertEqual(self.match("morning | evening", tasks)[0], ["a", "b"])
        self.assertEqual(self.match("habit", tasks)[0], ["b"])

    def test_search_reads_title_and_notes(self):
        tasks = [task("Buy OAT milk"), task("b", description="oat milk, 2L"), task("c")]
        self.assertEqual(self.match('search: "oat milk"', tasks)[0], ["Buy OAT milk", "b"])

    def test_unsupported_terms_warn(self):
        tasks = [task("a")]
        for query in ("available", "tracked > 1h", "workspace: Home", "cost > 5", "no client"):
            matched, warnings = self.match(query, tasks)
            self.assertEqual(matched, [], query)
            self.assertEqual(len(warnings), 1, query)


def blocked(task_id, *blockers, ts=0, device="d"):
    row = task(task_id, blocked_by=list(blockers))
    row.clocks["blocked_by"] = Clock(ts, device)
    return row


class BlockedTest(unittest.TestCase):
    def test_open_blockers_only(self):
        tasks = [blocked("a", "b", "gone"), task("b"), blocked("c", "d"), task("d", completed_at=1),
                 blocked("e", "f"), task("f", deleted_at=1)]
        self.assertEqual(blocked_ids(tasks), {"a"})

    def test_cycle_breaks_at_the_newest_clock(self):
        tasks = [blocked("x", "y", ts=10), blocked("y", "x", ts=20)]
        self.assertEqual(blocked_ids(tasks), {"x"})
        tasks = [blocked("x", "y", ts=5), blocked("y", "z", ts=9), blocked("z", "x", ts=7)]
        self.assertEqual(blocked_ids(tasks), {"x", "z"})

    def test_ties_break_on_device_then_id(self):
        tasks = [blocked("x", "y", ts=5, device="b"), blocked("y", "x", ts=5, device="a")]
        self.assertEqual(blocked_ids(tasks), {"y"})
        tasks = [blocked("x", "y", ts=5), blocked("y", "x", ts=5)]
        self.assertEqual(blocked_ids(tasks), {"x"})


if __name__ == "__main__":
    unittest.main()
