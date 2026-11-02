import unittest

from dustpan.events import parse


def lines(text):
    return [line.encode() + b"\n" for line in text.split("\n")]


class ParseTest(unittest.TestCase):
    def test_ops_events_yield_their_data(self):
        stream = lines(": connected\n\nevent: ops\ndata: {\"cursor\":158}\n\n: ping\n\nevent: ops\ndata: {}\n\n")
        self.assertEqual(list(parse(stream)), [{"cursor": 158}, {}])

    def test_other_events_and_bad_data_are_safe(self):
        stream = lines("event: other\ndata: {\"cursor\":1}\n\nevent: ops\ndata: nonsense\n\n")
        self.assertEqual(list(parse(stream)), [{}])


if __name__ == "__main__":
    unittest.main()
