"""Task notes: the small, safe Markdown subset of OpenTodo's web app. See spec/notes.md.

A port of web/src/lib/markdown.ts. Paragraphs with line breaks, headings, *em*, **strong**, ~~strike~~, `code`,
fenced code, [links](https://…) and bare https:// links, bulleted, numbered and check lists, > quotes, pipe tables,
attachment images and task links. Mentions are left out: the client doesn't know members.

parse() gives plain dicts shaped like the web app's ({"t": "p", "c": [...]}), so its tests port as they are.
pango() turns inline nodes into Pango markup. Nothing in a note becomes markup except through it,
and links are kept only for http(s) and mailto.
"""

import html
import re

LIST = re.compile(r"^ {0,3}([-*+]|(\d{1,9})[.)])\s+(.*)$")
FENCE = re.compile(r"^ {0,3}(```+|~~~+)\s*([^`\s]*)")
IMAGE = re.compile(r"^ {0,3}!\[((?:\\.|[^\]\\])*)\]\(attachment:([A-Za-z0-9_-]+)\)\s*$")
HEADING = re.compile(r"^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
QUOTE = re.compile(r"^ {0,3}>")
RULE_CELL = re.compile(r"^:?-+:?$")
TASK_HREF = re.compile(r"^\?task=([A-Za-z0-9_-]+)$")
SAFE_HREF = re.compile(r"(https?://|mailto:)\S+", re.IGNORECASE)
PUNCT = re.compile(r"[!-/:-@\[-`{-~]")
MAX_BLOCK_DEPTH = 8  # quotes and lists nest at most this deep; deeper lines are text
MAX_INLINE_DEPTH = 4


def safe_href(url):
    """Only absolute http(s) and mailto links are links."""
    url = url.strip()
    return url if SAFE_HREF.fullmatch(url) else None


def cells(line):
    """Table cells: split on unescaped |, outer pipes dropped, \\| read as |."""
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    out, cur, i = [], "", 0
    while i < len(s):
        if s[i] == "\\" and s[i + 1:i + 2] == "|":
            cur += "|"
            i += 1
        elif s[i] == "|":
            out.append(cur)
            cur = ""
        else:
            cur += s[i]
        i += 1
    if cur.strip() or not line.strip().endswith("|"):
        out.append(cur)
    return [c.strip() for c in out]


def is_table_start(lines, i):
    if "|" not in lines[i] or i + 1 >= len(lines):
        return False
    rule = cells(lines[i + 1])
    return len(rule) == len(cells(lines[i])) and all(RULE_CELL.match(c) for c in rule)


def starts_block(lines, i):
    line = lines[i]
    return bool(FENCE.match(line) or QUOTE.match(line) or LIST.match(line) or re.match(r"^ {0,3}#{1,6}\s", line)
                or IMAGE.match(line) or is_table_start(lines, i))


def alignment(cell):
    if cell.startswith(":") and cell.endswith(":"):
        return "center"
    if cell.startswith(":"):
        return "left"
    return "right" if cell.endswith(":") else None


def parse(src, depth=0):
    """A note's blocks."""
    lines = src.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if fence := FENCE.match(line):
            body = []
            i += 1
            while i < len(lines) and not lines[i].lstrip().startswith(fence[1]):
                body.append(lines[i])
                i += 1
            i += 1  # the closing fence, or the end
            out.append({"t": "pre", "v": "\n".join(body), **({"lang": fence[2]} if fence[2] else {})})
            continue
        if QUOTE.match(line) and depth < MAX_BLOCK_DEPTH:
            body = []
            while i < len(lines) and QUOTE.match(lines[i]):
                body.append(re.sub(r"^ {0,3}> ?", "", lines[i]))
                i += 1
            out.append({"t": "quote", "c": parse("\n".join(body), depth + 1)})
            continue
        if heading := HEADING.match(line):
            out.append({"t": "h", "level": len(heading[1]), "c": parse_inline(heading[2])})
            i += 1
            continue
        if image := IMAGE.match(line):
            out.append({"t": "img", "id": image[2], "alt": re.sub(r"\\(.)", r"\1", image[1])})
            i += 1
            continue
        if is_table_start(lines, i):
            align = [alignment(c) for c in cells(lines[i + 1])]

            def row(text):
                found = cells(text)
                return [parse_inline(found[k] if k < len(found) else "") for k in range(len(align))]

            head, rows = row(lines[i]), []
            i += 2
            while i < len(lines) and lines[i].strip() and "|" in lines[i]:
                rows.append(row(lines[i]))
                i += 1
            out.append({"t": "table", "align": align, "head": head, "rows": rows})
            continue
        first = LIST.match(line)
        if first and depth < MAX_BLOCK_DEPTH:
            ordered = first[2] is not None
            items, checks = [], []
            while i < len(lines):
                m = LIST.match(lines[i])
                if not m or (m[2] is not None) != ordered:
                    break
                box = re.match(r"^\[([ xX])\]\s+(.*)$", m[3])
                checks.append(box[1] != " " if box else None)
                item = [box[2] if box else m[3]]
                i += 1
                # Indented lines continue the item, and may hold a nested list.
                while i < len(lines) and (re.match(r"^\s{2,}\S", lines[i]) or (
                        not lines[i].strip() and i + 1 < len(lines) and re.match(r"^\s{2,}\S", lines[i + 1]))):
                    item.append(re.sub(r"^\s{2,4}", "", lines[i]))
                    i += 1
                items.append(parse("\n".join(item), depth + 1))
            block = {"t": "list", "ordered": ordered, "start": int(first[2]) if ordered else 1, "items": items}
            if any(c is not None for c in checks):
                block["checks"] = checks
            out.append(block)
            continue
        para = []
        while i < len(lines) and lines[i].strip() and (not para or not starts_block(lines, i)):
            para.append(lines[i].strip())
            i += 1
        out.append({"t": "p", "c": parse_inline("\n".join(para))})
    return out


def parse_inline(s, depth=0):
    """The inline nodes of one block's text."""
    out, text = [], ""

    def flush():
        nonlocal text
        if text:
            out.append({"t": "text", "v": text})
        text = ""

    i = 0
    while i < len(s):
        ch = s[i]
        if ch == "\\" and i + 1 < len(s) and PUNCT.match(s[i + 1]):
            text += s[i + 1]
            i += 2
            continue
        if ch == "\n":
            flush()
            out.append({"t": "br"})
            i += 1
            continue
        if ch == "`":
            run = re.match(r"`+", s[i:])[0]
            end = s.find(run, i + len(run))
            if end > 0:
                flush()
                out.append({"t": "code", "v": s[i + len(run):end].replace("\n", " ")})
                i = end + len(run)
            else:
                text += run
                i += len(run)
            continue
        # ![name](address) from the web is a link named "name": nothing is loaded.
        at = i + 1 if ch == "!" and s[i + 1:i + 2] == "[" else i if ch == "[" else -1
        if at >= 0 and depth < MAX_INLINE_DEPTH:
            close = s.find("](", at + 1)
            end = s.find(")", close + 2) if close > 0 else -1
            if close > 0 and end > 0 and "[" not in s[at + 1:close]:
                target = s[close + 2:end].strip()
                task, href = TASK_HREF.match(target), safe_href(target)
                label = parse_inline(s[at + 1:close], depth + 1)
                flush()
                if task:
                    out.append({"t": "task", "id": task[1], "c": label})
                elif href:
                    out.append({"t": "link", "href": href, "c": label})
                else:
                    out.extend(label)
                i = end + 1
                continue
        if ch in "hH" and re.match(r"https?://", s[i:i + 8], re.IGNORECASE) and (i == 0 or s[i - 1] in " \t\n\r\f\v("):
            url = re.sub(r"[.,:;!?)]+$", "", re.match(r"[^\s<]+", s[i:])[0])
            if href := safe_href(url):
                flush()
                out.append({"t": "link", "href": href, "c": [{"t": "text", "v": url}]})
                i += len(url)
                continue
        if ch == "~" and s[i + 1:i + 2] == "~" and depth < MAX_INLINE_DEPTH:
            end = s.find("~~", i + 2)
            if end > i + 2 and not s[i + 2].isspace() and not s[end - 1].isspace():
                flush()
                out.append({"t": "strike", "c": parse_inline(s[i + 2:end], depth + 1)})
                i = end + 2
                continue
        if ch in "*_" and depth < MAX_INLINE_DEPTH:
            # Underscores inside words (snake_case) are literal.
            if ch == "_" and i > 0 and s[i - 1].isalnum():
                text += ch
                i += 1
                continue
            double = s[i + 1:i + 2] == ch
            delim = ch * 2 if double else ch
            start = i + len(delim)
            end = s.find(delim, start)
            # A single delimiter must not match half of a double one.
            while not double and end > 0 and s[end + 1:end + 2] == ch:
                end = s.find(delim, end + 2)
            if end > start and not s[start].isspace() and not s[end - 1].isspace():
                flush()
                out.append({"t": "strong" if double else "em", "c": parse_inline(s[start:end], depth + 1)})
                i = end + len(delim)
                continue
        text += ch
        i += 1
    flush()
    return out


# ---- output ----

TAGS = {"em": "i", "strong": "b", "strike": "s"}


def pango(nodes):
    """Pango markup for inline nodes. Text is escaped; links keep only safe addresses."""
    out = []
    for node in nodes:
        kind = node["t"]
        if kind == "text":
            out.append(html.escape(node["v"]))
        elif kind == "code":
            out.append(f"<tt>{html.escape(node['v'])}</tt>")
        elif kind == "br":
            out.append("\n")
        elif kind in TAGS:
            out.append(f"<{TAGS[kind]}>{pango(node['c'])}</{TAGS[kind]}>")
        elif kind == "link":
            out.append(f'<a href="{html.escape(node["href"])}">{pango(node["c"])}</a>')
        else:  # a task link: its words
            out.append(pango(node.get("c", [])))
    return "".join(out)


def plain(nodes):
    """The words of inline nodes, without formatting."""
    return "".join(n["v"] if n["t"] in ("text", "code") else " " if n["t"] == "br" else plain(n.get("c", []))
                   for n in nodes)


def first_line(src):
    """A note's first line of text, for its task's row. Empty when the note is."""
    return first_line_of(parse(src))


def first_line_of(blocks):
    for block in blocks:
        kind = block["t"]
        if kind in ("p", "h"):
            nodes = block["c"]
            cut = next((k for k, n in enumerate(nodes) if n["t"] == "br"), len(nodes))
            text = plain(nodes[:cut]).strip()
        elif kind == "pre":
            text = block["v"].strip().split("\n")[0]
        elif kind == "quote":
            text = first_line_of(block["c"])
        elif kind == "list":
            text = first_line_of(block["items"][0]) if block["items"] else ""
        else:
            text = ""
        if text:
            return text
    return ""
