"""Vocabularies, tokens and phrase matching. Port of internal/quickadd/vocab.go and tokenize.go.

vocab.json is OpenTodo's shared vocabulary file, copied unchanged from the pinned clone
(internal/quickadd/vocab.json). A test checks that it still matches.
"""

import json
import pathlib
import unicodedata
from dataclasses import dataclass

VOCABS = json.loads((pathlib.Path(__file__).parent / "vocab.json").read_text())
BUNDLED = ("en", "de", "fr", "it", "es", "pt")

FOLD = {**{c: "a" for c in "àáâãäåā"}, "ç": "c", **{c: "e" for c in "èéêëē"}, **{c: "i" for c in "ìíîï"}, "ñ": "n",
        **{c: "o" for c in "òóôõöō"}, **{c: "u" for c in "ùúûüū"}, "ý": "y", "ÿ": "y", "ß": "ss",
        "‘": "'", "’": "'", "ʼ": "'"}


def active_languages(preferred):
    """Preferred tags ("de-CH", "ja") as bundled codes in order, always ending with English."""
    out = []
    for tag in preferred:
        code = tag.lower().replace("_", "-").split("-")[0]
        if code in VOCABS and code not in out:
            out.append(code)
    return out if "en" in out else out + ["en"]


def normalize(word):
    """Lower case, no diacritics, ß → ss, typographic apostrophes → ', trailing , and ; dropped."""
    out = "".join(FOLD.get(c, c) for c in word.lower() if unicodedata.category(c) != "Mn")
    return out.rstrip(",;")


@dataclass
class Token:
    text: str
    norm: str
    start: int
    end: int
    quoted: bool


def tokenize(line):
    """(tokens, quote spans). A balanced pair of double quotes marks its content as literal."""
    positions = [i for i, c in enumerate(line) if c == '"']
    closers = set(positions[:len(positions) // 2 * 2])
    tokens, quotes = [], []
    quoted, start = False, None

    def flush(end):
        nonlocal start
        if start is not None and end > start:
            text = line[start:end]
            tokens.append(Token(text, normalize(text), start, end, quoted))
        start = None

    for i, c in enumerate(line):
        if i in closers:
            flush(i)
            quotes.append((i, i + 1))
            quoted = not quoted
        elif c.isspace():
            flush(i)
        elif start is None:
            start = i
    flush(len(line))
    return tokens, quotes


def strip_spans(line, remove, drop):
    """The title: removed spans become word breaks, dropped spans vanish, whitespace collapses."""
    cut = [0] * len(line)
    for spans, mark in ((drop, 2), (remove, 1)):
        for start, end in spans:
            for i in range(max(0, start), min(len(line), end)):
                cut[i] = mark
    return " ".join("".join(" " if m == 1 else c for c, m in zip(line, cut) if m != 2).split())


def tok(tokens, i):
    """The token at i, unless it's missing or quoted."""
    return tokens[i] if 0 <= i < len(tokens) and not tokens[i].quoted else None


def word_matches(tokens, i, word):
    if i >= len(tokens) or tokens[i].quoted:
        return False
    norm = tokens[i].norm
    return norm == word or (not word.endswith(".") and norm.endswith(".") and norm[:-1] == word)


def phrase_at(tokens, i, phrases):
    """How many tokens at i the longest of phrases covers, or 0."""
    best = 0
    for phrase in phrases:
        words = phrase.split()
        if len(words) > best and all(word_matches(tokens, i + k, w) for k, w in enumerate(words)):
            best = len(words)
    return best


def lookup_at(tokens, i, table):
    """(tokens covered, value) for the longest key of table at i, or (0, None)."""
    best, value = 0, None
    for phrase, v in table.items():
        if (n := phrase_at(tokens, i, [phrase])) > best:
            best, value = n, v
    return best, value


def words_at(tokens, i, vocabs, pick):
    """The longest phrase of pick(vocab) at i, in any active language."""
    if tok(tokens, i) is None:
        return 0
    return max(phrase_at(tokens, i, pick(v)) for v in vocabs)
