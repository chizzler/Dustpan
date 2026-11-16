#!/usr/bin/env python3
"""Build a local Mac release candidate, notices, corresponding source and checksums. Never upload."""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/macos")
    parser.add_argument("--identity", help="Developer ID Application identity; omit for a local ad-hoc build")
    args = parser.parse_args()
    if args.identity and not args.identity.startswith("Developer ID Application:"):
        parser.error("public distribution requires a Developer ID Application identity")
    output = args.output.resolve()
    if output.is_relative_to(ROOT / "apple") or output.is_relative_to(ROOT / "packaging/macos"):
        parser.error("output must be outside the source folders")
    output.mkdir(parents=True, exist_ok=True)
    run(sys.executable, str(ROOT / "packaging/macos/audit-dependencies.py"))
    with tempfile.TemporaryDirectory(prefix="dustpan-mac-release-") as temporary:
        work = Path(temporary)
        run("xcodebuild", "-project", str(ROOT / "apple/Dustpan.xcodeproj"), "-scheme", "Dustpan",
            "-configuration", "Release", "-destination", "generic/platform=macOS", "-derivedDataPath", str(work / "build"),
            "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=NO", "-quiet", "build")
        stage = work / "stage"
        stage.mkdir()
        app = stage / "Dustpan.app"
        run("ditto", str(work / "build/Build/Products/Release/Dustpan.app"), str(app))
        resources = app / "Contents/Resources"
        for name in ("LICENSE", "NOTICE.md", "PRIVACY.md"):
            shutil.copyfile(ROOT / name, resources / name)
        signing = ["codesign", "--force", "--options", "runtime", "--sign", args.identity or "-"]
        if args.identity:
            signing.append("--timestamp")
        run(*signing, str(app))
        run("codesign", "--verify", "--deep", "--strict", str(app))
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        version = info["CFBundleShortVersionString"]
        if not re.fullmatch(r"\d+\.\d+\.\d+", version):
            raise ValueError("expected a three-part release version")
        archs = run("lipo", "-archs", str(app / "Contents/MacOS/Dustpan"), capture_output=True).stdout.split()
        if set(archs) != {"arm64", "x86_64"}:
            raise ValueError(f"expected a universal executable, got {archs}")
        run(sys.executable, str(ROOT / "packaging/macos/audit-dependencies.py"), "--binary", str(app / "Contents/MacOS/Dustpan"))
        mode = "signed" if args.identity else "local"
        stem = f"dustpan-mac-{version}"
        archive = output / f"{stem}-universal-{mode}.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))

        # Allowlist corresponding Apple source and build instructions. Never include .git, dev data or credentials.
        epoch = int(os.environ.get("SOURCE_DATE_EPOCH") or run(
            "git", "-C", str(ROOT), "log", "-1", "--format=%ct", capture_output=True).stdout.strip())
        paths = [ROOT / p for p in ("LICENSE", "NOTICE.md", "PRIVACY.md", "README.md", "CHANGELOG.md", "RELEASING.md",
                                     "CONTRIBUTING.md", "SECURITY.md")]
        for folder in ("apple", "packaging/macos"):
            for path in (ROOT / folder).rglob("*"):
                if set(path.relative_to(ROOT).parts) & {".build", ".swiftpm", "xcuserdata", ".DS_Store", "__pycache__"}:
                    continue
                if path.suffix in {".swift", ".json", ".txt", ".png", ".svg", ".md", ".pbxproj",
                                    ".xcscheme", ".xcworkspacedata", ".py", ".html"} and path.is_file() and not path.is_symlink():
                    paths.append(path)
        source = output / f"{stem}-source.tar.gz"
        with source.open("wb") as raw, gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode="w") as tar:
                for path in sorted(paths):
                    member = tarfile.TarInfo(f"{stem}/{path.relative_to(ROOT).as_posix()}")
                    data = path.read_bytes()
                    member.size, member.mode, member.mtime = len(data), 0o644, epoch
                    tar.addfile(member, io.BytesIO(data))
        report = {
            "version": version, "build": info["CFBundleVersion"], "architectures": archs,
            "signing": "Developer ID; notarization required" if args.identity else "ad-hoc; local testing only",
            "notarized": False,
            "commit": run("git", "-C", str(ROOT), "rev-parse", "HEAD", capture_output=True).stdout.strip(),
            "working_tree_dirty": bool(run("git", "-C", str(ROOT), "status", "--porcelain", capture_output=True).stdout),
        }
        metadata = output / f"{stem}-build.json"
        metadata.write_text(json.dumps(report, indent=2) + "\n")
        (output / "SHA256SUMS").write_text("".join(
            f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in (archive, source, metadata)))
        print(f"Prepared {archive}\n{source}\n{metadata}")
        print(report["signing"] + ". Nothing uploaded or installed.")


if __name__ == "__main__":
    main()
