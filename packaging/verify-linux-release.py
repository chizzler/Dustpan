#!/usr/bin/env python3
"""Check a locally prepared Linux release, including pacman in a disposable root."""

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    folder = args.directory.resolve()
    digest, filename = (folder / "SHA256SUMS").read_text().strip().split("  ")
    archive = folder / filename
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == digest
    with tarfile.open(archive) as tar:
        members = tar.getmembers()
        prefix = members[0].name.split("/")[0] + "/"
        files = {m.name.removeprefix(prefix) for m in members}
        assert files == set((folder / "CONTENTS.txt").read_text().splitlines())
        assert all(m.isfile() and m.name.startswith(prefix) and ".." not in Path(m.name).parts for m in members)
        assert all(not ({".git", "apple", "dev", "__pycache__"} & set(Path(f).parts)) for f in files)
        assert not ({"project.md", "dev-diary.md"} & files)
        assert {"LICENSE", "NOTICE.md", "README.md", "desktop/tests/upstream/LICENSE"} <= files
    package = folder / f"{prefix.rstrip('/')}-1-any.pkg.tar.zst"
    assert package.is_file(), f"build the package first: {package}"
    run("namcap", str(folder / "PKGBUILD"), str(package))
    with tempfile.TemporaryDirectory(prefix="dustpan-package-check-") as scratch:
        root = Path(scratch)
        extracted = root / "extracted"
        extracted.mkdir()
        run("bsdtar", "-xf", str(package), "-C", str(extracted))
        launcher = extracted / "usr/bin/dustpan"
        assert launcher.stat().st_mode & 0o111
        assert launcher.read_text() == "#!/bin/bash\nPYTHONPATH=/usr/lib/dustpan exec /usr/bin/python -m dustpan \"$@\"\n"
        icon = extracted / "usr/lib/dustpan/data/io.github.chizzler.Dustpan.svg"
        assert icon.is_symlink() and icon.resolve().is_relative_to(extracted) and icon.is_file()
        assert not (extracted / "etc").exists(), "autostart and personal config must be opt-in"
        run("desktop-file-validate", str(extracted / "usr/share/applications/io.github.chizzler.Dustpan.desktop"),
            str(extracted / "usr/share/doc/dustpan/dustpan-autostart.desktop"))
        env = {**os.environ, "PYTHONPATH": str(extracted / "usr/lib/dustpan"), "PYTHONDONTWRITEBYTECODE": "1"}
        result = run(sys.executable, "-m", "dustpan", "--version", env=env, cwd=root, capture_output=True)
        assert result.stdout.strip() == f"Dustpan {prefix.rstrip('/').removeprefix('dustpan-')}"
        run(sys.executable, "-c", "from dustpan.app import Window; from dustpan.quickadd.words import VOCABS; assert VOCABS",
            env=env, cwd=root)

        # No sudo, host package database or host hooks: all pacman writes stay in this disposable root.
        pacman_root = root / "pacman-root"
        script = root / "transactions.sh"
        script.write_text('''#!/bin/bash
set -euo pipefail
pkg=$1
target=$2
mkdir -p "$target/var/lib/pacman" "$target/empty-hooks" "$target/home/test/.config/dustpan" \\
  "$target/home/test/.local/share/dustpan"
printf '[options]\\nArchitecture = auto\\nSigLevel = Never\\n' > "$target/pacman.conf"
printf 'keep-config' > "$target/home/test/.config/dustpan/config"
printf 'keep-database' > "$target/home/test/.local/share/dustpan/dustpan.db"
opts=(--root "$target" --dbpath "$target/var/lib/pacman" --config "$target/pacman.conf" \\
      --logfile "$target/pacman.log" --hookdir "$target/empty-hooks" --noscriptlet --noconfirm)
pacman "${opts[@]}" -Udd "$pkg"
test -x "$target/usr/bin/dustpan"
pacman "${opts[@]}" -Udd "$pkg"
pacman "${opts[@]}" -Rdd dustpan
test ! -e "$target/usr/bin/dustpan"
test ! -e "$target/usr/lib/dustpan/dustpan/__init__.py"
test "$(cat "$target/home/test/.config/dustpan/config")" = keep-config
test "$(cat "$target/home/test/.local/share/dustpan/dustpan.db")" = keep-database
''')
        transactions = subprocess.run(["fakeroot", "bash", str(script), str(package), str(pacman_root)],
                                      text=True, capture_output=True)
        (folder / "pacman-test.log").write_text(transactions.stdout + transactions.stderr)
        if transactions.returncode:
            print((transactions.stdout + transactions.stderr)[-8000:], file=sys.stderr)
            transactions.check_returncode()
    print("PASS: archive contents and checksum, packaged imports/assets, desktop files, and scratch-root install/reinstall/removal.")
    print("Host installation, configuration and task data were not changed.")


if __name__ == "__main__":
    main()
