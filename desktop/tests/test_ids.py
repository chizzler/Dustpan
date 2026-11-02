import unittest

from dustpan.ids import detached_id, name_id, occurrence_id


class NameIdTest(unittest.TestCase):
    def test_matches_opentodo(self):
        # Values from web/src/lib/ids.test.ts at v0.18.0.
        self.assertEqual(occurrence_id("series-1", "2026-10-12"), "7106e6f1-b1b0-89c3-a9dc-81493398a2bd")
        self.assertEqual(detached_id("series-1", "2026-10-12"), "8f193c71-c00d-879f-a1fa-51a7b4ff2974")
        self.assertEqual(name_id("occurrence", "ünïcödé ✓:2026-10-12"), "17d11a8d-aec2-8ffd-b6fd-9c4027f03e68")
        self.assertEqual(name_id("", ""), "e7ac0786-668e-8ff0-b02b-62bd04f45ff6")


if __name__ == "__main__":
    unittest.main()
