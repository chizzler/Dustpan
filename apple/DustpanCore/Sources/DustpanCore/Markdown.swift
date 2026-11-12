import Foundation

// Task notes: the small, safe Markdown subset of OpenTodo's web app. See spec/notes.md.
// A port of the desktop's markdown.py, itself a port of web/src/lib/markdown.ts. Mentions are left out.
// attributed() is the only way a note becomes formatted text, and links are kept only for http(s) and mailto.

public indirect enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, [MarkdownInline])
    case code(String, language: String?)
    case quote([MarkdownBlock])
    /// checks: one per item, nil for an item without a box. Nil when no item has one.
    case list(ordered: Bool, start: Int, items: [[MarkdownBlock]], checks: [Bool?]?)
    case table(align: [MarkdownAlignment?], head: [[MarkdownInline]], rows: [[[MarkdownInline]]])
    /// An attachment image. Dustpan doesn't fetch attachments yet.
    case image(id: String, alt: String)
}

public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case lineBreak
    case code(String)
    case strong([MarkdownInline])
    case emphasis([MarkdownInline])
    case strike([MarkdownInline])
    case link(href: String, [MarkdownInline])
    /// A link to another task: shown as its words.
    case task(id: String, [MarkdownInline])
}

public enum MarkdownAlignment: Sendable { case left, center, right }

// Regex isn't Sendable; these are constants, only read.
nonisolated(unsafe) private let listItem = /^ {0,3}([-*+]|(\d{1,9})[.)])\s+(.*)$/
nonisolated(unsafe) private let fence = /^ {0,3}(```+|~~~+)\s*([^`\s]*)/
nonisolated(unsafe) private let attachmentImage = /^ {0,3}!\[((?:\\.|[^\]\\])*)\]\(attachment:([A-Za-z0-9_-]+)\)\s*$/
nonisolated(unsafe) private let headingLine = /^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/
nonisolated(unsafe) private let quoteLine = /^ {0,3}>/
nonisolated(unsafe) private let ruleCell = /^:?-+:?$/
nonisolated(unsafe) private let taskHref = /^\?task=([A-Za-z0-9_-]+)$/
private let punctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
/// Quotes and lists nest at most this deep; deeper lines are text.
private let maxBlockDepth = 8
private let maxInlineDepth = 4

/// Only absolute http(s) and mailto links are links.
public func safeHref(_ url: String) -> String? {
    let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    return url.wholeMatch(of: /(https?:\/\/|mailto:)\S+/.ignoresCase()) != nil ? url : nil
}

/// Table cells: split on unescaped |, outer pipes dropped, \| read as |.
private func cells(_ line: String) -> [String] {
    var s = Array(line.trimmingCharacters(in: .whitespaces))
    if s.first == "|" { s.removeFirst() }
    var out: [String] = [], cur = ""
    var i = 0
    while i < s.count {
        if s[i] == "\\" && i + 1 < s.count && s[i + 1] == "|" {
            cur.append("|")
            i += 1
        } else if s[i] == "|" {
            out.append(cur)
            cur = ""
        } else {
            cur.append(s[i])
        }
        i += 1
    }
    if !cur.trimmingCharacters(in: .whitespaces).isEmpty || !line.trimmingCharacters(in: .whitespaces).hasSuffix("|") {
        out.append(cur)
    }
    return out.map { $0.trimmingCharacters(in: .whitespaces) }
}

private func isTableStart(_ lines: [String], _ i: Int) -> Bool {
    guard lines[i].contains("|"), i + 1 < lines.count else { return false }
    let rule = cells(lines[i + 1])
    return rule.count == cells(lines[i]).count && rule.allSatisfy { $0.wholeMatch(of: ruleCell) != nil }
}

private func startsBlock(_ lines: [String], _ i: Int) -> Bool {
    let line = lines[i]
    return line.prefixMatch(of: fence) != nil || line.prefixMatch(of: quoteLine) != nil
        || line.wholeMatch(of: listItem) != nil || line.prefixMatch(of: /^ {0,3}#{1,6}\s/) != nil
        || line.wholeMatch(of: attachmentImage) != nil || isTableStart(lines, i)
}

private func alignment(_ cell: String) -> MarkdownAlignment? {
    if cell.hasPrefix(":") && cell.hasSuffix(":") { return .center }
    if cell.hasPrefix(":") { return .left }
    return cell.hasSuffix(":") ? .right : nil
}

private func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

/// "  - x" continues a list item: two or more spaces, then text.
private func isIndented(_ line: String) -> Bool { line.prefixMatch(of: /^\s{2,}\S/) != nil }

/// A note's blocks.
public func parseMarkdown(_ src: String, depth: Int = 0) -> [MarkdownBlock] {
    let lines = src.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var out: [MarkdownBlock] = []
    var i = 0
    while i < lines.count {
        let line = lines[i]
        if isBlank(line) {
            i += 1
            continue
        }
        if let open = line.prefixMatch(of: fence) {
            let marker = String(open.1)
            var body: [String] = []
            i += 1
            while i < lines.count && !lines[i].trimmingPrefix(while: \.isWhitespace).hasPrefix(marker) {
                body.append(lines[i])
                i += 1
            }
            i += 1  // the closing fence, or the end
            out.append(.code(body.joined(separator: "\n"), language: open.2.isEmpty ? nil : String(open.2)))
            continue
        }
        if line.prefixMatch(of: quoteLine) != nil && depth < maxBlockDepth {
            var body: [String] = []
            while i < lines.count && lines[i].prefixMatch(of: quoteLine) != nil {
                body.append(lines[i].replacing(/^ {0,3}> ?/, with: "", maxReplacements: 1))
                i += 1
            }
            out.append(.quote(parseMarkdown(body.joined(separator: "\n"), depth: depth + 1)))
            continue
        }
        if let heading = line.wholeMatch(of: headingLine) {
            out.append(.heading(level: heading.1.count, parseInline(String(heading.2))))
            i += 1
            continue
        }
        if let image = line.wholeMatch(of: attachmentImage) {
            out.append(.image(id: String(image.2), alt: String(image.1).replacing(/\\(.)/) { String($0.1) }))
            i += 1
            continue
        }
        if isTableStart(lines, i) {
            let align = cells(lines[i + 1]).map(alignment)
            func row(_ text: String) -> [[MarkdownInline]] {
                let found = cells(text)
                return align.indices.map { parseInline($0 < found.count ? found[$0] : "") }
            }
            let head = row(lines[i])
            var rows: [[[MarkdownInline]]] = []
            i += 2
            while i < lines.count && !isBlank(lines[i]) && lines[i].contains("|") {
                rows.append(row(lines[i]))
                i += 1
            }
            out.append(.table(align: align, head: head, rows: rows))
            continue
        }
        if let first = line.wholeMatch(of: listItem), depth < maxBlockDepth {
            let ordered = first.2 != nil
            var items: [[MarkdownBlock]] = [], checks: [Bool?] = []
            while i < lines.count {
                guard let m = lines[i].wholeMatch(of: listItem), (m.2 != nil) == ordered else { break }
                let box = String(m.3).wholeMatch(of: /\[([ xX])\]\s+(.*)/)
                checks.append(box.map { $0.1 != " " })
                var item = [box.map { String($0.2) } ?? String(m.3)]
                i += 1
                // Indented lines continue the item, and may hold a nested list.
                while i < lines.count
                    && (isIndented(lines[i]) || (isBlank(lines[i]) && i + 1 < lines.count && isIndented(lines[i + 1]))) {
                    item.append(lines[i].replacing(/^\s{2,4}/, with: "", maxReplacements: 1))
                    i += 1
                }
                items.append(parseMarkdown(item.joined(separator: "\n"), depth: depth + 1))
            }
            out.append(.list(ordered: ordered, start: first.2.flatMap { Int($0) } ?? 1, items: items,
                             checks: checks.contains { $0 != nil } ? checks : nil))
            continue
        }
        var para: [String] = []
        while i < lines.count && !isBlank(lines[i]) && (para.isEmpty || !startsBlock(lines, i)) {
            para.append(lines[i].trimmingCharacters(in: .whitespaces))
            i += 1
        }
        out.append(.paragraph(parseInline(para.joined(separator: "\n"))))
    }
    return out
}

/// The inline nodes of one block's text.
public func parseInline(_ text: String, depth: Int = 0) -> [MarkdownInline] {
    let s = Array(text)
    var out: [MarkdownInline] = []
    var pending = ""

    func flush() {
        if !pending.isEmpty { out.append(.text(pending)) }
        pending = ""
    }
    /// Where needle next starts at or after from, or nil.
    func find(_ needle: [Character], from: Int) -> Int? {
        guard needle.count <= s.count else { return nil }
        var k = max(from, 0)
        while k + needle.count <= s.count {
            if s[k] == needle[0] && Array(s[k..<k + needle.count]) == needle { return k }
            k += 1
        }
        return nil
    }
    func string(_ a: Int, _ b: Int) -> String { String(s[a..<b]) }
    func at(_ k: Int) -> Character? { k < s.count ? s[k] : nil }

    var i = 0
    while i < s.count {
        let ch = s[i]
        if ch == "\\", let next = at(i + 1), punctuation.contains(next) {
            pending.append(next)
            i += 2
            continue
        }
        if ch == "\n" {
            flush()
            out.append(.lineBreak)
            i += 1
            continue
        }
        if ch == "`" {
            var n = 0
            while at(i + n) == "`" { n += 1 }
            let run = Array(repeating: Character("`"), count: n)
            if let end = find(run, from: i + n), end > 0 {
                flush()
                out.append(.code(string(i + n, end).replacingOccurrences(of: "\n", with: " ")))
                i = end + n
            } else {
                pending += String(run)
                i += n
            }
            continue
        }
        // ![name](address) from the web is a link named "name": nothing is loaded.
        let open = ch == "!" && at(i + 1) == "[" ? i + 1 : ch == "[" ? i : nil
        if let open, depth < maxInlineDepth, let close = find(["]", "("], from: open + 1), close > 0,
           let end = find([")"], from: close + 2), !s[(open + 1)..<close].contains("[") {
            let target = string(close + 2, end).trimmingCharacters(in: .whitespacesAndNewlines)
            let label = parseInline(string(open + 1, close), depth: depth + 1)
            flush()
            if let task = target.wholeMatch(of: taskHref) {
                out.append(.task(id: String(task.1), label))
            } else if let href = safeHref(target) {
                out.append(.link(href: href, label))
            } else {
                out += label
            }
            i = end + 1
            continue
        }
        if ch == "h" || ch == "H", string(i, min(i + 8, s.count)).prefixMatch(of: /https?:\/\//.ignoresCase()) != nil,
           i == 0 || " \t\n\r\u{0C}\u{0B}(".contains(s[i - 1]) {
            var stop = i
            while stop < s.count && !s[stop].isWhitespace && s[stop] != "<" { stop += 1 }
            let url = string(i, stop).replacing(/[.,:;!?)]+$/, with: "")
            if let href = safeHref(url) {
                flush()
                out.append(.link(href: href, [.text(url)]))
                i += url.count
                continue
            }
        }
        if ch == "~", at(i + 1) == "~", depth < maxInlineDepth, let end = find(["~", "~"], from: i + 2),
           end > i + 2, !s[i + 2].isWhitespace, !s[end - 1].isWhitespace {
            flush()
            out.append(.strike(parseInline(string(i + 2, end), depth: depth + 1)))
            i = end + 2
            continue
        }
        if ch == "*" || ch == "_", depth < maxInlineDepth {
            // Underscores inside words (snake_case) are literal.
            if ch == "_" && i > 0 && (s[i - 1].isLetter || s[i - 1].isNumber) {
                pending.append(ch)
                i += 1
                continue
            }
            let double = at(i + 1) == ch
            let delim: [Character] = double ? [ch, ch] : [ch]
            let start = i + delim.count
            var end = find(delim, from: start)
            // A single delimiter must not match half of a double one.
            while !double, let e = end, e > 0, at(e + 1) == ch { end = find(delim, from: e + 2) }
            if let end, end > start, !s[start].isWhitespace, !s[end - 1].isWhitespace {
                flush()
                let inner = parseInline(string(start, end), depth: depth + 1)
                out.append(double ? .strong(inner) : .emphasis(inner))
                i = end + delim.count
                continue
            }
        }
        pending.append(ch)
        i += 1
    }
    flush()
    return out
}

// MARK: - Output

/// Inline nodes as formatted text for SwiftUI's Text. Links keep only safe addresses.
public func attributed(_ nodes: [MarkdownInline], _ intent: InlinePresentationIntent = [],
                       link: URL? = nil) -> AttributedString {
    var out = AttributedString()
    func piece(_ text: String, _ extra: InlinePresentationIntent = []) {
        var run = AttributedString(text)
        let all = intent.union(extra)
        if !all.isEmpty { run.inlinePresentationIntent = all }
        if let link { run.link = link }
        out += run
    }
    for node in nodes {
        switch node {
        case .text(let text): piece(text)
        case .code(let text): piece(text, .code)
        case .lineBreak: piece("\n")
        case .strong(let inner): out += attributed(inner, intent.union(.stronglyEmphasized), link: link)
        case .emphasis(let inner): out += attributed(inner, intent.union(.emphasized), link: link)
        case .strike(let inner): out += attributed(inner, intent.union(.strikethrough), link: link)
        case .link(let href, let inner): out += attributed(inner, intent, link: URL(string: href) ?? link)
        case .task(_, let inner): out += attributed(inner, intent, link: link)
        }
    }
    return out
}

/// The words of inline nodes, without formatting.
public func plainText(_ nodes: [MarkdownInline]) -> String {
    nodes.map { node in
        switch node {
        case .text(let text), .code(let text): text
        case .lineBreak: " "
        case .strong(let inner), .emphasis(let inner), .strike(let inner), .link(_, let inner), .task(_, let inner):
            plainText(inner)
        }
    }.joined()
}

/// A note's first line of text, for its task's row. Empty when the note is.
public func firstLine(_ src: String) -> String { firstLine(of: parseMarkdown(src)) }

func firstLine(of blocks: [MarkdownBlock]) -> String {
    for block in blocks {
        let text: String
        switch block {
        case .paragraph(let nodes), .heading(_, let nodes):
            text = plainText(Array(nodes.prefix { $0 != .lineBreak })).trimmingCharacters(in: .whitespacesAndNewlines)
        case .code(let body, _):
            text = body.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
        case .quote(let inner):
            text = firstLine(of: inner)
        case .list(_, _, let items, _):
            text = items.first.map { firstLine(of: $0) } ?? ""
        case .table, .image:
            text = ""
        }
        if !text.isEmpty { return text }
    }
    return ""
}
