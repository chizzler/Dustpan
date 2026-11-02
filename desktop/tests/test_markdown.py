"""Notes. The first cases are web/src/lib/markdown.test.ts, checked on the parse and on our Pango markup."""

import unittest

from dustpan.markdown import first_line, pango, parse, parse_inline, safe_href


def text(v):
    return {"t": "text", "v": v}


def markup(src):
    """Every block's inline markup, joined: what the note view would show."""
    out = []

    def walk(blocks):
        for b in blocks:
            if b["t"] in ("p", "h"):
                out.append(pango(b["c"]))
            elif b["t"] == "pre":
                out.append(b["v"])
            elif b["t"] == "quote":
                walk(b["c"])
            elif b["t"] == "list":
                for item in b["items"]:
                    walk(item)
            elif b["t"] == "table":
                out.extend(pango(c) for row in [b["head"], *b["rows"]] for c in row)

    walk(parse(src))
    return "\n".join(out)


class MarkdownTest(unittest.TestCase):
    def test_script_tag_is_text(self):
        out = markup("<script>alert(1)</script> and <img src=x onerror=alert(2)>")
        self.assertNotIn("<script", out)
        self.assertNotIn("<img", out)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", out)
        self.assertNotRegex(markup('`<b>x</b>`\n\n> <iframe src="https://evil.example">'), r"<(b|iframe)[ >]")

    def test_links(self):
        out = markup("See [the docs](https://example.com/docs?a=1&b=2) or https://example.org/x.")
        self.assertIn('<a href="https://example.com/docs?a=1&amp;b=2">the docs</a>', out)
        # A bare address becomes a link without its trailing punctuation.
        self.assertIn('<a href="https://example.org/x">https://example.org/x</a>.', out)

    def test_refuses_dangerous_link_targets(self):
        for bad in ("javascript:alert(1)", "JaVaScRiPt:alert(1)", "data:text/html,<b>", "vbscript:x", "/relative",
                    "//evil.example"):
            self.assertIsNone(safe_href(bad))
            out = markup(f"[click]({bad})")
            self.assertNotIn("<a", out)
            self.assertIn("click", out)
        self.assertEqual(safe_href("mailto:a@example.com"), "mailto:a@example.com")

    def test_the_supported_subset(self):
        blocks = parse("\n".join([
            "Hello **bold** and *em* and _em too_ and `code` in snake_case_name.",
            "second line",
            "",
            "- one",
            "- two with **strong**",
            "",
            "1. first",
            "2. second",
            "",
            "> quoted *text*",
            "",
            "```",
            "const a = 1 < 2",
            "```",
        ]))
        self.assertEqual([b["t"] for b in blocks], ["p", "list", "list", "quote", "pre"])
        self.assertEqual(pango(blocks[0]["c"]), "Hello <b>bold</b> and <i>em</i> and <i>em too</i> and "
                                                "<tt>code</tt> in snake_case_name.\nsecond line")
        self.assertEqual(blocks[1]["items"], [[{"t": "p", "c": [text("one")]}],
                                              [{"t": "p", "c": [text("two with "),
                                                                {"t": "strong", "c": [text("strong")]}]}]])
        self.assertEqual((blocks[2]["ordered"], blocks[2]["start"]), (True, 1))
        self.assertEqual(blocks[3]["c"], [{"t": "p", "c": [text("quoted "), {"t": "em", "c": [text("text")]}]}])
        self.assertEqual(blocks[4], {"t": "pre", "v": "const a = 1 < 2"})

    def test_keeps_unmatched_delimiters_and_escapes_literal(self):
        self.assertEqual(parse_inline("2 * 3 = 6 and a ** b"), [text("2 * 3 = 6 and a ** b")])
        self.assertEqual(parse_inline("\\*not em\\*"), [text("*not em*")])
        self.assertEqual(parse(""), [])

    def test_stays_bounded_on_hostile_nesting(self):
        markup("> " * 500 + "[" * 2000 + "*" * 2000)

    def test_headings_and_check_items(self):
        self.assertEqual(parse("## Packing\n\n- [x] Passport\n- [ ] Charger"), [
            {"t": "h", "level": 2, "c": [text("Packing")]},
            {"t": "list", "ordered": False, "start": 1, "checks": [True, False],
             "items": [[{"t": "p", "c": [text("Passport")]}], [{"t": "p", "c": [text("Charger")]}]]},
        ])

    def test_table(self):
        [table] = parse("| Item | Cost |\n| --- | ---: |\n| Paint | 40 |\n| a \\| b | 5 |")
        self.assertEqual(table["align"], [None, "right"])
        self.assertEqual(table["head"], [[text("Item")], [text("Cost")]])
        self.assertEqual(table["rows"], [[[text("Paint")], [text("40")]], [[text("a | b")], [text("5")]]])

    def test_an_image_from_the_web_stays_a_link(self):
        self.assertEqual(markup("![photo](https://example.org/a.png)"), '<a href="https://example.org/a.png">photo</a>')

    def test_an_attachment_image_is_a_placeholder(self):
        self.assertEqual(parse("![The \\[wall\\]](attachment:att-1)"), [{"t": "img", "id": "att-1", "alt": "The [wall]"}])

    def test_strike_and_task_links(self):
        self.assertEqual(parse_inline("~~gone~~"), [{"t": "strike", "c": [text("gone")]}])
        self.assertEqual(parse_inline("[Book hotel](?task=t-1)"), [{"t": "task", "id": "t-1", "c": [text("Book hotel")]}])
        self.assertEqual(pango(parse_inline("[Book hotel](?task=t-1)")), "Book hotel")

    def test_nested_list_items(self):
        [outer] = parse("- one\n  - inner\n- two")
        self.assertEqual(outer["items"][0][1]["t"], "list")
        self.assertEqual(len(outer["items"]), 2)

    def test_first_line(self):
        self.assertEqual(first_line(""), "")
        self.assertEqual(first_line("\n\n**Call** the _bank_\nthen the shop"), "Call the bank")
        self.assertEqual(first_line("## Packing\n\n- [ ] Passport"), "Packing")
        self.assertEqual(first_line("- [ ] Passport\n- [ ] Charger"), "Passport")
        self.assertEqual(first_line("> quoted"), "quoted")


if __name__ == "__main__":
    unittest.main()
