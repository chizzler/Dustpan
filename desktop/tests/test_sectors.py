import unittest

from dustpan import sectors

from . import vectors


class SectorVectorsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = vectors.load("sectors")

    def test_valid(self):
        for case in self.data["valid"]:
            with self.subTest(case["value"]):
                self.assertEqual(sectors.parse(case["value"]) is not None, case["valid"])

    def test_cases(self):
        for case in self.data["cases"]:
            today, ws = case["today"], case["week_start"]
            with self.subTest(today=today, week_start=ws):
                self.assertEqual(sectors.current(today, ws), case["current"])
                for s in case["sectors"]:
                    self.assertEqual(sectors.relative_name(s["sector"], today, ws), s["name"], s)
                    self.assertEqual(sectors.is_carried(s["sector"], today, ws), s["carried"], s)
                    self.assertEqual(sectors.group(s["sector"], today, ws), s["group"], s)


class SectorTest(unittest.TestCase):
    def test_round_trip_and_ranges(self):
        for value in ("2026-W53", "2026-02", "2026-Q4"):
            self.assertEqual(str(sectors.parse(value)), value)
        self.assertEqual([str(d) for d in sectors.parse("2026-Q4").range()], ["2026-10-01", "2026-12-31"])
        self.assertEqual(str(sectors.parse("2026-W53").next()), "2027-W01")

    def test_resolve_and_sort(self):
        self.assertEqual(sectors.resolve("Next week", "2026-11-04"), "2026-W46")
        self.assertIsNone(sectors.resolve("someday", "2026-11-04"))
        values = ["2026-Q4", "bad", "2026-10", "2026-W40"]
        self.assertEqual(sorted(values, key=sectors.sort_key), ["2026-W40", "2026-10", "2026-Q4", "bad"])

    def test_labels(self):
        today = "2026-11-04"  # a Wednesday in 2026-W45
        self.assertEqual(sectors.label("2026-W45", today), ("This week", False))
        self.assertEqual(sectors.label("2026-W47", today), ("Week 47", False))
        self.assertEqual(sectors.label("2026-W43", today), ("From week 43", True))
        self.assertEqual(sectors.label("2026-10", today), ("From October", True))
        self.assertEqual(sectors.label("2027-02", today), ("February 2027", False))
        self.assertEqual(sectors.label("2027-Q2", today), ("Q2 2027", False))
        self.assertEqual(sectors.label("2026-12", today), ("Next month", False))
        self.assertIsNone(sectors.label("", today))

    def test_rejects_junk(self):
        for value in (None, "", "2026-W5", "1999-01", "2026-13", "2026-Q5", " 2026-01"):
            self.assertIsNone(sectors.parse(value), value)


if __name__ == "__main__":
    unittest.main()
