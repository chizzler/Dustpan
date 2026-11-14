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

    def test_word_like_days(self):
        # Dustpan differs from upstream: "sun", "sat" and "wed" are everyday words too.
        ctx = Context("2026-11-14", "15:00")  # a Saturday
        cases = {
            "Stack the turtles in the sun today": ("Stack the turtles in the sun", {"date": "2026-11-14"}),
            "Sit in the sun": ("Sit in the sun", None),
            "Read on the sun deck tomorrow": ("Read on the sun deck", {"date": "2026-11-15"}),
            "Lunch with Sat friday": ("Lunch with Sat", {"date": "2026-11-20"}),
            "Sun cream": ("Sun cream", None),
            "Call Mum sun": ("Call Mum", {"date": "2026-11-15"}),
            "Call Mum on sun": ("Call Mum", {"date": "2026-11-15"}),
            "Call Mum next sun": ("Call Mum", {"date": "2026-11-22"}),
            "Call Mum sun 4pm": ("Call Mum", {"date": "2026-11-15", "time": "16:00"}),
            "Call Mum sun p1": ("Call Mum", {"date": "2026-11-15"}),
            "Gym sat +1h": ("Gym", {"date": "2026-11-21"}),
            "Gym sat 1h": ("Gym", {"date": "2026-11-21"}),
            "Dinner sat #nowhere": ("Dinner sat #nowhere", None),
            "Meet wed 10am @work": ("Meet", {"date": "2026-11-18", "time": "10:00"}),
            "Wed the fri": ("Wed the", {"date": "2026-11-20"}),
        }
        for line, want in cases.items():
            with self.subTest(line):
                got = parse(line, ctx)
                self.assertEqual((got.title, got.due), want)
        self.assertEqual(parse("Bins every sun", ctx).recurrence, "every sunday")
        self.assertEqual(parse("Send report deadline sun for review", ctx).deadline, "2026-11-15")

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
