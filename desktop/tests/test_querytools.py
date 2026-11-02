"""The query helper and the Anytime and Completed pages."""

import unittest
from datetime import datetime

from dustpan.filters import parse
from dustpan.querytools import KEYWORDS, add_condition, conditions, quote_name, suggest
from dustpan.store import Row
from dustpan.views import in_anytime, logbook, logbook_heading

LABELS = ["errand", "deep work", "Café"]
PROJECTS = ["Home", "Work", "#hash"]


def ms(text):
    return int(datetime.fromisoformat(text).timestamp() * 1000)


class SuggestTest(unittest.TestCase):
    def offered(self, query):
        return [(shown, new) for shown, _, new in suggest(query, LABELS, PROJECTS)]

    def test_labels_after_at(self):
        self.assertEqual(self.offered("p1 & @er"), [("@errand", "p1 & @errand ")])
        self.assertEqual(self.offered("@de"), [("@deep work", '@"deep work" ')])
        self.assertEqual(self.offered('@"deep w'), [("@deep work", '@"deep work" ')])
        self.assertEqual(self.offered("@cafe"), [("@Café", "@Café ")])

    def test_projects_after_hash(self):
        self.assertEqual(self.offered("#w"), [("#Work", "#Work ")])
        self.assertEqual(self.offered("##h"), [("##Home", "##Home ")])
        self.assertEqual(self.offered("#"), [("#Home", "#Home "), ("#Work", "#Work "), ("##hash", '#"#hash" ')])

    def test_keywords_for_a_bare_word(self):
        self.assertEqual([s for s, _ in self.offered("today & ov")], ["overdue"])
        self.assertIn("no date", [s for s, _ in self.offered("no")])
        self.assertEqual(self.offered("overdue"), [])  # typed in full
        self.assertEqual(self.offered("p1 & "), [])

    def test_every_keyword_completes_to_something_that_parses_or_reads_on(self):
        for word, _ in KEYWORDS:
            if word in ("due", "deadline", "created", "search:"):
                continue  # these need what follows them
            parse(word)

    def test_quote_name(self):
        self.assertEqual((quote_name("errand"), quote_name("a b"), quote_name('say "hi"')),
                         ("errand", '"a b"', '"say \\"hi\\""'))


class BuilderTest(unittest.TestCase):
    def test_every_condition_parses(self):
        for _, items in conditions(LABELS, PROJECTS):
            for label, term in items:
                with self.subTest(label=label):
                    parse(term)
                    parse(add_condition("p1", term, negate=True))

    def test_add_condition_keeps_meaning(self):
        self.assertEqual(add_condition("", "p1"), "p1")
        self.assertEqual(add_condition("today", "p1"), "today & p1")
        self.assertEqual(add_condition("today | overdue", "p1"), "(today | overdue) & p1")
        self.assertEqual(add_condition("today", "no date", negate=True), "today & !(no date)")
        self.assertEqual(add_condition("today", "p1", negate=True), "today & !p1")
        self.assertEqual(add_condition("today & (", "p1"), "today & ( & p1")  # unfinished: left for the user


class PagesTest(unittest.TestCase):
    def task(self, task_id, **fields):
        return Row(task_id, {"completed_at": None, "deleted_at": None, **fields})

    def test_anytime(self):
        today = "2026-11-02"
        self.assertTrue(in_anytime(self.task("a"), today))
        for fields in ({"due": {"date": today}}, {"deadline": today}, {"start": "someday"}, {"start": "2026-12-01"},
                       {"completed_at": 5}):
            self.assertFalse(in_anytime(self.task("b", **fields), today), fields)

    def test_logbook_by_day_newest_first_with_paging(self):
        tasks = [self.task("a", completed_at=ms("2026-11-02T09:00")), self.task("b", completed_at=ms("2026-11-02T18:00")),
                 self.task("c", completed_at=ms("2026-11-01T12:00")), self.task("d"),
                 self.task("e", completed_at=ms("2026-10-20T12:00"), deleted_at=1)]
        groups, total = logbook(tasks, 100, "2026-11-02")
        self.assertEqual(total, 3)
        self.assertEqual([(g.heading, [t.id for t in g.tasks]) for g in groups], [("Today", ["b", "a"]), ("Yesterday", ["c"])])
        groups, total = logbook(tasks, 2, "2026-11-02")
        self.assertEqual(([t.id for g in groups for t in g.tasks], total), (["b", "a"], 3))

    def test_logbook_follows_the_day_start(self):
        groups, _ = logbook([self.task("a", completed_at=ms("2026-11-02T01:30"))], 100, "2026-11-02", day_start=240)
        self.assertEqual(groups[0].key, "2026-11-01")

    def test_logbook_heading(self):
        self.assertEqual(logbook_heading("2026-10-28", "2026-11-02"), "Wednesday 28 October")
        self.assertEqual(logbook_heading("2025-12-31", "2026-11-02"), "Wednesday 31 December 2025")


if __name__ == "__main__":
    unittest.main()
