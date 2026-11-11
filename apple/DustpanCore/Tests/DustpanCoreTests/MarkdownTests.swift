import Foundation
import Testing
@testable import DustpanCore

// Notes. A port of tests/test_markdown.py, checked on the parse and on the formatted text the note view shows.

private func text(_ v: String) -> MarkdownInline { .text(v) }

/// Every block's formatted text, as the note view would show it.
private func shown(_ src: String) -> [AttributedString] {
    var out: [AttributedString] = []
    func walk(_ blocks: [MarkdownBlock]) {
        for block in blocks {
            switch block {
            case .paragraph(let c), .heading(_, let c): out.append(attributed(c))
            case .code(let v, _): out.append(AttributedString(v))
            case .quote(let inner): walk(inner)
            case .list(_, _, let items, _): items.forEach(walk)
            case .table(_, let head, let rows): out += ([head] + rows).joined().map { attributed($0) }
            case .image: break
            }
        }
    }
    walk(parseMarkdown(src))
    return out
}

/// The links in formatted text: (words, address).
private func linksIn(_ texts: [AttributedString]) -> [(String, String)] {
    texts.flatMap { t in
        t.runs.compactMap { run in run.link.map { (String(t[run.range].characters), $0.absoluteString) } }
    }
}

private func plain(_ texts: [AttributedString]) -> String { texts.map { String($0.characters) }.joined(separator: "\n") }

@Suite struct MarkdownTests {
    @Test func htmlIsText() {
        let out = shown("<script>alert(1)</script> and <img src=x onerror=alert(2)>")
        #expect(plain(out) == "<script>alert(1)</script> and <img src=x onerror=alert(2)>")
        #expect(linksIn(out).isEmpty)
    }

    @Test func links() {
        let out = shown("See [the docs](https://example.com/docs?a=1&b=2) or https://example.org/x.")
        #expect(linksIn(out).map(\.0) == ["the docs", "https://example.org/x"])
        #expect(linksIn(out).map(\.1) == ["https://example.com/docs?a=1&b=2", "https://example.org/x"])
        // A bare address becomes a link without its trailing punctuation.
        #expect(plain(out).hasSuffix("https://example.org/x."))
    }

    @Test func refusesDangerousLinkTargets() {
        for bad in ["javascript:alert(1)", "JaVaScRiPt:alert(1)", "data:text/html,<b>", "vbscript:x", "/relative",
                    "//evil.example"] {
            #expect(safeHref(bad) == nil)
            let out = shown("[click](\(bad))")
            #expect(linksIn(out).isEmpty)
            #expect(plain(out).hasPrefix("click"))  // javascript:alert(1)'s own ")" is left over, as on the desktop
        }
        #expect(safeHref("mailto:a@example.com") == "mailto:a@example.com")
    }

    @Test func theSupportedSubset() {
        let blocks = parseMarkdown([
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
        ].joined(separator: "\n"))
        #expect(blocks.count == 5)
        #expect(blocks[0] == .paragraph([
            text("Hello "), .strong([text("bold")]), text(" and "), .emphasis([text("em")]), text(" and "),
            .emphasis([text("em too")]), text(" and "), .code("code"), text(" in snake_case_name."), .lineBreak,
            text("second line"),
        ]))
        #expect(blocks[1] == .list(ordered: false, start: 1, items: [
            [.paragraph([text("one")])], [.paragraph([text("two with "), .strong([text("strong")])])],
        ], checks: nil))
        guard case .list(true, 1, let numbered, nil) = blocks[2] else { Issue.record("not a numbered list"); return }
        #expect(numbered.count == 2)
        #expect(blocks[3] == .quote([.paragraph([text("quoted "), .emphasis([text("text")])])]))
        #expect(blocks[4] == .code("const a = 1 < 2", language: nil))
    }

    @Test func formattingBecomesPresentationIntents() throws {
        let out = attributed(parseInline("a **b** *c* `d` ~~e~~ *__f__*"))
        let intents = out.runs.map { (String(out[$0.range].characters), $0.inlinePresentationIntent ?? []) }
        try #require(intents.map(\.0) == ["a ", "b", " ", "c", " ", "d", " ", "e", " ", "f"])
        #expect(intents.map(\.1) == [[], .stronglyEmphasized, [], .emphasized, [], .code, [], .strikethrough, [],
                                     [.emphasized, .stronglyEmphasized]])
    }

    @Test func keepsUnmatchedDelimitersAndEscapesLiteral() {
        #expect(parseInline("2 * 3 = 6 and a ** b") == [text("2 * 3 = 6 and a ** b")])
        #expect(parseInline("\\*not em\\*") == [text("*not em*")])
        #expect(parseMarkdown("").isEmpty)
    }

    @Test func staysBoundedOnHostileNesting() {
        _ = shown(String(repeating: "> ", count: 500) + String(repeating: "[", count: 2000)
                  + String(repeating: "*", count: 2000))
    }

    @Test func headingsAndCheckItems() {
        #expect(parseMarkdown("## Packing\n\n- [x] Passport\n- [ ] Charger") == [
            .heading(level: 2, [text("Packing")]),
            .list(ordered: false, start: 1, items: [[.paragraph([text("Passport")])], [.paragraph([text("Charger")])]],
                  checks: [true, false]),
        ])
    }

    @Test func table() {
        #expect(parseMarkdown("| Item | Cost |\n| --- | ---: |\n| Paint | 40 |\n| a \\| b | 5 |") == [
            .table(align: [nil, .right], head: [[text("Item")], [text("Cost")]],
                   rows: [[[text("Paint")], [text("40")]], [[text("a | b")], [text("5")]]]),
        ])
    }

    @Test func anImageFromTheWebStaysALink() {
        let out = shown("![photo](https://example.org/a.png)")
        #expect(plain(out) == "photo")
        #expect(linksIn(out).map(\.1) == ["https://example.org/a.png"])
    }

    @Test func anAttachmentImageIsAPlaceholder() {
        #expect(parseMarkdown("![The \\[wall\\]](attachment:att-1)") == [.image(id: "att-1", alt: "The [wall]")])
    }

    @Test func strikeAndTaskLinks() {
        #expect(parseInline("~~gone~~") == [.strike([text("gone")])])
        #expect(parseInline("[Book hotel](?task=t-1)") == [.task(id: "t-1", [text("Book hotel")])])
        let out = attributed(parseInline("[Book hotel](?task=t-1)"))
        #expect(String(out.characters) == "Book hotel")
        #expect(out.runs.allSatisfy { $0.link == nil })
    }

    @Test func nestedListItems() {
        guard case .list(_, _, let items, _) = parseMarkdown("- one\n  - inner\n- two").first else {
            Issue.record("not a list")
            return
        }
        #expect(items.count == 2)
        guard case .list = items[0][1] else { Issue.record("no inner list"); return }
    }

    @Test func firstLines() {
        #expect(firstLine("") == "")
        #expect(firstLine("\n\n**Call** the _bank_\nthen the shop") == "Call the bank")
        #expect(firstLine("## Packing\n\n- [ ] Passport") == "Packing")
        #expect(firstLine("- [ ] Passport\n- [ ] Charger") == "Passport")
        #expect(firstLine("> quoted") == "quoted")
    }
}
