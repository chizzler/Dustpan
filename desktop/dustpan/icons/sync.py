"""Builds paths.json and lucide.json from Lucide 1.48.0 (spec/icons.md). Run by hand; the app never downloads.

Two downloads, each unpacked into its own empty folder:

    lucide-static 1.48.0 from npm: the SVG files and the licence.
        https://registry.npmjs.org/lucide-static/-/lucide-static-1.48.0.tgz
        sha512-ZUGgZ4rzlLfVbhN2Zi37TMrTaSpXAbWx6Y/xZxKSDLPiqxtTK7Mw2M+oBJa0gjV8p3+CWBHh48u+IC9+jKlUjA==
    Lucide's source at the tag 1.48.0: each icon's tags, categories and old names, in icons/*.json.
        https://github.com/lucide-icons/lucide/archive/refs/tags/1.48.0.tar.gz

Then, from desktop/:

    python -I -m dustpan.icons.sync <static>/package <source>/lucide-1.48.0

paths.json holds each icon's SVG body, as OpenTodo cuts it (scripts/icons-sync.mjs). lucide.json holds the
tags and categories, and the old names Lucide still answers to. A test checks that every icon in OpenTodo's
catalogue has the same body here as in the pinned OpenTodo clone.
"""

import json
import pathlib
import re
import sys

FOLDER = "web/src/ui/icons"  # in the OpenTodo clone
VERSION = "1.48.0"
LINE = re.compile(r'^\s*"([a-z0-9-]+)": (".*"),?$')
HERE = pathlib.Path(__file__).parent


def bodies(text):
    """{name: SVG body} from one of OpenTodo's generated .ts files."""
    return {m[1]: json.loads(m[2]) for m in map(LINE.match, text.splitlines()) if m}


def body(svg):
    """What is inside an SVG file's <svg> element, on one line: OpenTodo's cut."""
    inner = svg[svg.index(">", svg.index("<svg")) + 1:svg.rindex("</svg>")]
    return "".join(line.strip() for line in inner.splitlines() if line.strip())


def build(static, source):
    """(paths.json, lucide.json) text from the two unpacked downloads."""
    static, source = pathlib.Path(static), pathlib.Path(source)
    version = json.loads((static / "package.json").read_text())["version"]
    if version != VERSION:
        raise ValueError(f"lucide-static is {version}, not {VERSION}")
    paths, icons, aliases = {}, {}, {}
    for meta in sorted((source / "icons").glob("*.json")):
        name = meta.stem
        info = json.loads(meta.read_text())
        paths[name] = body((static / "icons" / f"{name}.svg").read_text())
        icons[name] = {"categories": info["categories"], "tags": info["tags"]}
        for alias in info.get("aliases", []):
            aliases[alias if isinstance(alias, str) else alias["name"]] = name
    paths_text = json.dumps(paths, indent=0, ensure_ascii=False) + "\n"
    lucide_text = json.dumps({"version": version, "icons": icons, "aliases": dict(sorted(aliases.items()))},
                             indent=0, ensure_ascii=False) + "\n"
    return paths_text, lucide_text


def main(static, source):
    paths_text, lucide_text = build(static, source)
    (HERE / "paths.json").write_text(paths_text)
    (HERE / "lucide.json").write_text(lucide_text)
    print(f"wrote {len(json.loads(paths_text))} icons from Lucide {VERSION}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
