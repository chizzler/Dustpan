import Foundation

// Quick add's vocabularies, tokens and phrase matching. A port of quickadd/words.py
// (internal/quickadd/vocab.go and tokenize.go). See spec/quickadd.md.
// Positions count Unicode scalars, as the Python port counts code points.

/// OpenTodo's vocab.json, copied unchanged from the pinned clone. A test checks it still matches.
let quickAddVocabs: [String: JSON] = {
    guard let url = Bundle.module.url(forResource: "vocab", withExtension: "json"),
          let data = try? Data(contentsOf: url), let json = try? JSON(parsing: data) else { return [:] }
    return json.object ?? [:]
}()

private let fold: [Unicode.Scalar: String] = {
    var map: [Unicode.Scalar: String] = ["ç": "c", "ñ": "n", "ý": "y", "ÿ": "y", "ß": "ss", "‘": "'", "’": "'", "ʼ": "'"]
    for (letters, base) in [("àáâãäåā", "a"), ("èéêëē", "e"), ("ìíîï", "i"), ("òóôõöō", "o"), ("ùúûüū", "u")] {
        for s in letters.unicodeScalars { map[s] = base }
    }
    return map
}()

/// Preferred tags ("de-CH", "ja") as bundled codes in order, always ending with English.
public func quickAddLanguages(_ preferred: [String]) -> [String] {
    var out: [String] = []
    for tag in preferred {
        let code = languageCode(tag)
        if quickAddVocabs[code] != nil && !out.contains(code) { out.append(code) }
    }
    return out.contains("en") ? out : out + ["en"]
}

func languageCode(_ tag: String) -> String {
    String(tag.lowercased().replacing("_", with: "-").split(separator: "-", omittingEmptySubsequences: false)[0])
}

/// Lower case, no diacritics, ß → ss, typographic apostrophes → ', trailing , and ; dropped.
func normalizeWord(_ word: String) -> String {
    var out = String.UnicodeScalarView()
    for s in word.lowercased().unicodeScalars where s.properties.generalCategory != .nonspacingMark {
        if let folded = fold[s] { out.append(contentsOf: folded.unicodeScalars) } else { out.append(s) }
    }
    while let last = out.last, last == "," || last == ";" { out.removeLast() }
    return String(out)
}

struct WordToken {
    var text: String
    var norm: String
    let start: Int
    let end: Int
    let quoted: Bool
}

typealias Span = (start: Int, end: Int)

/// (tokens, quote spans). A balanced pair of double quotes marks its content as literal.
func tokenizeWords(_ line: [Unicode.Scalar]) -> ([WordToken], [Span]) {
    let positions = line.indices.filter { line[$0] == "\"" }
    let closers = Set(positions.prefix(positions.count / 2 * 2))
    var tokens: [WordToken] = [], quotes: [Span] = []
    var quoted = false, start: Int?

    func flush(_ end: Int) {
        if let s = start, end > s {
            let text = String(String.UnicodeScalarView(line[s..<end]))
            tokens.append(WordToken(text: text, norm: normalizeWord(text), start: s, end: end, quoted: quoted))
        }
        start = nil
    }

    for (i, c) in line.enumerated() {
        if closers.contains(i) {
            flush(i)
            quotes.append((i, i + 1))
            quoted.toggle()
        } else if c.properties.isWhitespace {
            flush(i)
        } else if start == nil {
            start = i
        }
    }
    flush(line.count)
    return (tokens, quotes)
}

/// The title: removed spans become word breaks, dropped spans vanish, whitespace collapses.
func stripSpans(_ line: [Unicode.Scalar], remove: [Span], drop: [Span]) -> String {
    var cut = Array(repeating: 0, count: line.count)
    for (spans, mark) in [(drop, 2), (remove, 1)] {
        for span in spans where max(0, span.start) < min(line.count, span.end) {
            for i in max(0, span.start)..<min(line.count, span.end) { cut[i] = mark }
        }
    }
    var out = String.UnicodeScalarView()
    for (c, mark) in zip(line, cut) where mark != 2 { out.append(mark == 1 ? " " : c) }
    return String(out).split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// The token at i, unless it's missing or quoted.
func tok(_ tokens: [WordToken], _ i: Int) -> WordToken? {
    tokens.indices.contains(i) && !tokens[i].quoted ? tokens[i] : nil
}

func wordMatches(_ tokens: [WordToken], _ i: Int, _ word: String) -> Bool {
    guard i < tokens.count, !tokens[i].quoted else { return false }
    let norm = tokens[i].norm
    return norm == word || (!word.hasSuffix(".") && norm.hasSuffix(".") && norm.dropLast() == word)
}

/// How many tokens at i the longest of phrases covers, or 0.
func phraseAt(_ tokens: [WordToken], _ i: Int, _ phrases: [String]) -> Int {
    var best = 0
    for phrase in phrases {
        let words = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > best && words.enumerated().allSatisfy({ wordMatches(tokens, i + $0.offset, $0.element) }) {
            best = words.count
        }
    }
    return best
}

/// (tokens covered, value) for the longest key of table at i, or (0, null).
func lookupAt(_ tokens: [WordToken], _ i: Int, _ table: JSON) -> (Int, JSON) {
    var best = 0, value = JSON.null
    for (phrase, v) in table.object ?? [:] {
        let n = phraseAt(tokens, i, [phrase])
        if n > best { (best, value) = (n, v) }
    }
    return (best, value)
}

/// The longest phrase of key at i, in any active language.
func wordsAt(_ tokens: [WordToken], _ i: Int, _ vocabs: [JSON], _ pick: (JSON) -> JSON) -> Int {
    guard tok(tokens, i) != nil else { return 0 }
    return vocabs.map { phraseAt(tokens, i, pick($0).strings) }.max() ?? 0
}

extension JSON {
    /// An array of strings, or none.
    var strings: [String] { array?.compactMap(\.string) ?? [] }
}
