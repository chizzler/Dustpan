import unittest
from datetime import timezone

from dustpan.ids import default_reminder_id
from dustpan.reminders import (format_default, offset_label, parse_custom_offset, parse_default,
                               plan_default_reminder, read_defaults, relative_fire_at)

from .vectors import load


class DefaultReminderVectorsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.v = load("defaultReminder")

    def test_id(self):
        self.assertEqual(default_reminder_id(self.v["user_id"], self.v["task_id"]), self.v["default_id"])

    def test_parse(self):
        for raw, want in self.v["parse"]:
            self.assertEqual(parse_default(raw), want, raw)

    def test_cases(self):
        def rid(s):
            return self.v["default_id"] if s == "$default" else s

        def fire_at(due, offset):  # the vectors are computed with the device in UTC
            return relative_fire_at(due, offset, timezone.utc)

        for case in self.v["cases"]:
            with self.subTest(case["name"]):
                got = plan_default_reminder(
                    self.v["user_id"], self.v["task_id"], case["before"], case["patch"],
                    [{**r, "id": rid(r["id"])} for r in case["reminders"]],
                    [(rid(c["id"]), c["patch"]) for c in case["batch"]],
                    read_defaults(case["prefs"]), self.v["now"], fire_at)
                self.assertEqual(got, [(rid(e["id"]), e["patch"]) for e in case["expect"]])


class LabelTest(unittest.TestCase):
    def test_offsets(self):
        self.assertEqual([offset_label(m) for m in (0, -30, -60, 120, -1440, -2880)],
                         ["At due time", "30 minutes before", "1 hour before", "2 hours after",
                          "1 day before", "2 days before"])

    def test_custom_offsets_and_format(self):
        self.assertEqual(format_default(None), "")
        self.assertEqual(format_default(-30), "-30")
        self.assertEqual(parse_custom_offset("15m"), -15)
        self.assertEqual(parse_custom_offset("2h"), -120)
        self.assertEqual(parse_custom_offset("3 days before"), -4320)
        self.assertEqual(parse_custom_offset("1w"), -10080)
        self.assertEqual(parse_custom_offset("30m after"), 30)
        self.assertEqual(parse_custom_offset("+45m"), 45)
        self.assertEqual(parse_custom_offset("0"), 0)
        for bad in ("", "nope", "999d", "+10m before"):
            self.assertIsNone(parse_custom_offset(bad), bad)


if __name__ == "__main__":
    unittest.main()
