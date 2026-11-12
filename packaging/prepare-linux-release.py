#!/usr/bin/env python3
"""Prepare a Linux source archive and AUR recipe locally. Never publish or install anything."""

import argparse
import ast
import gzip
import hashlib
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_TAG = "v0.22.0"
FIXTURES = (
    "web/src/lib/recurrence.vectors.json", "web/src/lib/defaultReminder.vectors.json",
    "web/src/lib/zoned.vectors.json", "web/src/lib/nlp/quickadd.vectors.json",
    "web/src/lib/filter/evaluate.vectors.json", "web/src/lib/sectors.vectors.json",
    "web/src/lib/inbox.vectors.json", "docs/filters.md", "internal/quickadd/vocab.json",
    "internal/filter/testdata/formatted.txt", "internal/filter/testdata/limits.json",
)


def git(*args, cwd=ROOT):
    return subprocess.check_output(["git", "-C", str(cwd), *args])


def literal(text):
    if any(c in text for c in "'\n\r\0"):
        raise ValueError("recipe values must be single-line strings without single quotes")
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/linux")
    parser.add_argument("--opentodo", type=Path, default=ROOT.parent / "opentodo")
    parser.add_argument("--source-url", help="eventual public https URL; omit for an offline draft")
    parser.add_argument("--homepage", default="https://github.com/chizzler/Dustpan")
    parser.add_argument("--maintainer", default="Chizzler (contact pending before submission)")
    args = parser.parse_args()
    for label, url in (("--source-url", args.source_url), ("--homepage", args.homepage)):
        if url and (urlsplit(url).scheme != "https" or not urlsplit(url).hostname or urlsplit(url).username):
            parser.error(f"{label} must be a public https URL without embedded credentials")

    version_tree = ast.parse((ROOT / "desktop/dustpan/__init__.py").read_text())
    version = next(ast.literal_eval(n.value) for n in version_tree.body
                   if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "__version__"
                                                       for t in n.targets))
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        parser.error("expected a three-part numeric desktop version")
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH") or git("log", "-1", "--format=%ct").strip())
    entries = {}

    def add(source, dest=None):
        path = ROOT / source
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"expected a regular source file: {source}")
        entries[dest or source] = (path.read_bytes(), 0o755 if source.endswith(".sh") or source == "packaging/aur/dustpan" else 0o644)

    # An explicit allowlist: no Git history, Apple code, private notes, config, credentials or databases.
    for folder in ("desktop/dustpan", "desktop/tests"):
        for path in sorted((ROOT / folder).rglob("*.py")):
            add(path.relative_to(ROOT).as_posix())
    for source in ("desktop/dustpan/quickadd/vocab.json", "desktop/data/io.github.chizzler.Dustpan.svg",
                   "desktop/data/io.github.chizzler.Dustpan.desktop", "desktop/data/dustpan-v1.vectorcraft",
                   "desktop/install.sh", "packaging/aur/PKGBUILD.in", "packaging/aur/dustpan",
                   "packaging/aur/io.github.chizzler.Dustpan.desktop", "packaging/aur/dustpan-autostart.desktop"):
        add(source)
    for source, dest in (("packaging/linux/README.md", "README.md"), ("desktop/LICENSE", "LICENSE"),
                         ("desktop/NOTICE.md", "NOTICE.md"), ("desktop/RELEASE_NOTES.md", "RELEASE_NOTES.md")):
        add(source, dest)
    entries["README.md"] = (entries["README.md"][0].replace(b"@VERSION@", version.encode()), 0o644)
    for fixture in FIXTURES:
        entries[f"desktop/tests/upstream/{fixture}"] = (git("show", f"{UPSTREAM_TAG}:{fixture}", cwd=args.opentodo), 0o644)
    entries["desktop/tests/upstream/LICENSE"] = (git("show", f"{UPSTREAM_TAG}:LICENSE", cwd=args.opentodo), 0o644)
    if entries["desktop/dustpan/quickadd/vocab.json"][0] != entries["desktop/tests/upstream/internal/quickadd/vocab.json"][0]:
        raise ValueError("quick-add vocabulary differs from pinned OpenTodo")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    name = f"dustpan-{version}.tar.gz"
    archive = output / name
    with archive.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(mode="w", fileobj=compressed, format=tarfile.PAX_FORMAT) as tar:
            for path, (data, mode) in sorted(entries.items()):
                info = tarfile.TarInfo(f"dustpan-{version}/{path}")
                info.size, info.mode, info.mtime = len(data), mode, epoch
                tar.addfile(info, io.BytesIO(data))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(f"{digest}  {name}\n")
    recipe = (ROOT / "packaging/aur/PKGBUILD.in").read_text()
    values = {"VERSION": version, "SHA256": digest, "HOMEPAGE": args.homepage, "MAINTAINER": args.maintainer,
              "SOURCE": f"{name}::{args.source_url}" if args.source_url else name}
    for key, value in values.items():
        recipe = recipe.replace(f"@{key}@", literal(value))
    (output / "PKGBUILD").write_text(recipe)
    result = subprocess.run(["makepkg", "--printsrcinfo"], cwd=output, check=True, capture_output=True, text=True)
    (output / ".SRCINFO").write_text(result.stdout)
    (output / "CONTENTS.txt").write_text("".join(f"{path}\n" for path in sorted(entries)))
    print(f"Prepared {archive}\nSHA-256: {digest}\nRecipe and .SRCINFO: {output}")
    if not args.source_url:
        print("OFFLINE DRAFT: choose a public archive URL and maintainer contact before AUR submission.")
    print("Nothing was uploaded, installed, tagged or pushed.")


if __name__ == "__main__":
    main()
