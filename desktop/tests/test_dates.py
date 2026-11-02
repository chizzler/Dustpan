import os
import time
import unittest
from datetime import datetime, timezone

from dustpan.dates import due_instant, format_due, format_minutes

from .vectors import load


class FormatMinutesTest(unittest.TestCase):
    def test_formats(self):
        self.assertEqual([format_minutes(m) for m in (15, 60, 90, 120)], ["15 min", "1h", "1h 30m", "2h"])


class FormatDueTest(unittest.TestCase):
    NOW = datetime(2026, 10, 31, 13, 0)

    def fmt(self, due, time_format="24h"):
        result = format_due(due, now=self.NOW, time_format=time_format)
        return (result.text, result.state) if result else None

    def test_relative_days(self):
        self.assertEqual(self.fmt({"date": "2026-10-31"}), ("Today", "today"))
        self.assertEqual(self.fmt({"date": "2026-11-01"}), ("Tomorrow", "later"))
        self.assertEqual(self.fmt({"date": "2026-10-30"}), ("Yesterday", "overdue"))
        self.assertEqual(self.fmt({"date": "2026-11-04"}), ("Wed", "later"))
        self.assertEqual(self.fmt({"date": "2026-11-15"}), ("15 Nov", "later"))
        self.assertEqual(self.fmt({"date": "2027-01-02"}), ("2 Jan 2027", "later"))

    def test_time_formats(self):
        due = {"date": "2026-11-01", "time": "16:30"}
        self.assertEqual(self.fmt(due)[0], "Tomorrow 16:30")
        self.assertEqual(self.fmt(due, "12h")[0], "Tomorrow 4:30pm")
        self.assertEqual(self.fmt({"date": "2026-11-01", "time": "09:00"}, "12h")[0], "Tomorrow 9am")

    def test_timed_due_earlier_today_is_overdue(self):
        self.assertEqual(self.fmt({"date": "2026-10-31", "time": "09:00"}), ("Today 09:00", "overdue"))
        self.assertEqual(self.fmt({"date": "2026-10-31", "time": "17:00"}), ("Today 17:00", "today"))

    def test_no_due(self):
        self.assertIsNone(self.fmt(None))


class ZonedDueTest(unittest.TestCase):
    """Runs in a fixed local zone so the conversion is predictable."""

    def setUp(self):
        self.saved = os.environ.get("TZ")
        os.environ["TZ"] = "Australia/Sydney"
        time.tzset()

    def tearDown(self):
        if self.saved is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = self.saved
        time.tzset()

    def test_zoned_due_converts_to_local_time(self):
        due = {"date": "2026-11-04", "time": "09:00", "tz": "Europe/Berlin"}
        result = format_due(due, now=datetime(2026, 10, 31, 13, 0), time_format="24h")
        self.assertEqual(result.text, "Wed 19:00")

    def test_floating_due_does_not_convert(self):
        due = {"date": "2026-11-04", "time": "09:00"}
        self.assertEqual(format_due(due, now=datetime(2026, 10, 31), time_format="24h").text, "Wed 09:00")


class ZonedVectorsTest(unittest.TestCase):
    def test_instants(self):
        for case in load("zoned")["instant"]:
            got = datetime.fromtimestamp(due_instant(case) / 1000, timezone.utc)
            self.assertEqual(got.strftime("%Y-%m-%dT%H:%M:%SZ"), case["utc"], case["note"])


if __name__ == "__main__":
    unittest.main()
