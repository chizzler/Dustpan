import pathlib
import unittest

from dustpan.quickadd import Context, active_languages, parse, resolve
from dustpan.quickadd.words import VOCABS

from .vectors import load, read

FIELDS = {"title": "title", "due": "due", "projectId": "project_id", "labels": "labels", "priority": "priority",
          "estimateMinutes": "estimate_minutes", "spentMinutes": "spent_minutes", "recurrence": "recurrence",
          "reminders": "reminders"}
# Compared only when a case states them.
OPTIONAL = {"dayPart": "day_part", "evening": "evening", "energy": "energy", "sector": "sector"}


def context(ctx):
    return Context(ctx["today"], ctx["now"], ctx["languages"], ctx["projects"],
                   day_month_order=ctx.get("dayMonthOrder", ""), week_start=ctx.get("weekStart", 1),
                   day_parts=ctx.get("dayParts", False), energy=ctx.get("energy", False),
                   sectors=ctx.get("sectors", False))


class QuickAddVectorsTest(unittest.TestCase):
    def test_cases(self):
        cases = load("nlp/quickadd")["cases"]
        self.assertGreaterEqual(len(cases), 150)
        for case in cases:
            with self.subTest(case["name"], line=case["line"]):
                got = parse(case["line"], context(case["ctx"]))
                want = case["expect"]
                self.assertEqual({k: getattr(got, f) for k, f in FIELDS.items()}, {k: want[k] for k in FIELDS})
                for key, name in OPTIONAL.items():
                    if key in want:
                        # A day part stated as null or "" means none.
                        self.assertEqual(getattr(got, name) or None, want[key] or None, key)

    def test_vocabulary_is_the_pinned_copy(self):
        ours = (pathlib.Path(__file__).parents[1] / "dustpan/quickadd/vocab.json").read_text()
        self.assertEqual(ours, read("internal/quickadd/vocab.json"))
        for code in ("en", "de", "fr", "it", "es", "pt"):
            self.assertEqual((len(VOCABS[code]["weekdays"]), len(VOCABS[code]["months"])), (7, 12))


class QuickAddTest(unittest.TestCase):
    def test_languages(self):
        self.assertEqual(active_languages(["de-CH", "ja", "fr"]), ["de", "fr", "en"])
        self.assertEqual(active_languages(["en_AU"]), ["en"])

    def test_quoted_text_stays(self):
        got = parse('Read "tomorrow" #nowhere p2', Context("2026-10-31", "10:00"))
        self.assertEqual((got.title, got.due, got.priority), ("Read tomorrow #nowhere", None, 2))

    def test_resolve(self):
        offset = {"kind": "offset", "minutes": -30}
        at_nine = {"kind": "moment", "date": None, "time": "09:00"}
        self.assertEqual(resolve(offset, None, "2026-10-31", "10:00"), ("relative", -30))
        self.assertEqual(resolve(at_nine, {"date": "2026-11-03", "time": "15:00"}, "2026-10-31", "10:00"),
                         ("relative", -360))
        self.assertEqual(resolve(at_nine, {"date": "2026-11-03"}, "2026-10-31", "10:00"), ("relative", 0))
        self.assertEqual(resolve(at_nine, None, "2026-10-31", "10:00"), ("absolute", "2026-11-01", "09:00"))
        self.assertEqual(resolve(at_nine, None, "2026-10-31", "08:00"), ("absolute", "2026-10-31", "09:00"))


if __name__ == "__main__":
    unittest.main()
