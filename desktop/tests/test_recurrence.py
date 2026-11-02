import unittest

from dustpan.recurrence import (RuleError, canonical_text, first_occurrence, following_occurrence,
                                preview_occurrences, shift_date)

from .vectors import load


class RecurrenceVectorsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vectors = load("recurrence")

    def test_parse(self):
        for v in self.vectors["parse"]:
            with self.subTest(v["input"]):
                if v.get("error"):
                    with self.assertRaises(RuleError):
                        canonical_text(v["input"])
                else:
                    self.assertEqual(canonical_text(v["input"]), v["canonical"])

    def test_next(self):
        for v in self.vectors["next"]:
            with self.subTest(v["name"]):
                got = following_occurrence(v["rule"], v["due"], v["today"], v["completedOn"] or v["today"], v["done"])
                self.assertEqual(got, v["expected"])

    def test_first(self):
        for v in self.vectors["first"]:
            with self.subTest(f"{v['rule']} from {v['from']}"):
                self.assertEqual(first_occurrence(v["rule"], v["from"]), v["expected"])

    def test_preview(self):
        for v in self.vectors["preview"]:
            with self.subTest(v["name"]):
                self.assertEqual(preview_occurrences(v["rule"], v["due"], v["today"], v["done"], 3), v["expected"])

    def test_deadline_shift(self):
        for v in self.vectors["deadline"]:
            with self.subTest(v["name"]):
                self.assertEqual(shift_date(v["deadline"], v["from"], v["to"]), v["expected"])


if __name__ == "__main__":
    unittest.main()
