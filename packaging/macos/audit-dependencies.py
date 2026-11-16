#!/usr/bin/env python3
"""Check the Mac dependency surface and vendored-data hashes. No downloads or package resolution."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, help="also inspect the linked libraries of a built Mac executable")
    args = parser.parse_args()
    manifest = json.loads(subprocess.check_output(
        ["swift", "package", "--package-path", str(ROOT / "apple/DustpanCore"), "dump-package"], text=True))
    if manifest["dependencies"]:
        raise SystemExit("External Swift package dependencies require review")
    for target in manifest["targets"]:
        if target["type"] not in {"regular", "executable", "test"} or target.get("pluginUsages"):
            raise SystemExit("Binary targets and build plugins require review")
        if any("unsafeFlags" in setting.get("kind", {}) for setting in target.get("settings", [])):
            raise SystemExit("Unsafe compiler flags require review")
    project = (ROOT / "apple/Dustpan.xcodeproj/project.pbxproj").read_text()
    if "XCRemoteSwiftPackageReference" in project or "PBXShellScriptBuildPhase" in project:
        raise SystemExit("Remote Xcode dependencies or build scripts require review")
    inventory = json.loads((ROOT / "apple/DEPENDENCIES.json").read_text())
    resources = ROOT / "apple/DustpanCore/Sources/DustpanCore/Resources"
    if {p.relative_to(ROOT).as_posix() for p in resources.rglob("*") if p.is_file()} != set(inventory["resource_sha256"]):
        raise SystemExit("The vendored resource file list changed; review and update the inventory")
    for name, expected in inventory["resource_sha256"].items():
        path = ROOT / name
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise SystemExit(f"Vendored resource changed; review provenance and update the inventory: {name}")
    imports = set()
    for folder in ("apple/Dustpan", "apple/DustpanCore/Sources"):
        for path in (ROOT / folder).rglob("*.swift"):
            imports.update(re.findall(r"^import (\w+)", path.read_text(), re.MULTILINE))
    if imports - set(inventory["allowed_modules"]):
        raise SystemExit(f"New modules require review: {sorted(imports - set(inventory['allowed_modules']))}")
    if args.binary:
        binaries = [args.binary.resolve()]
        debug = args.binary.resolve().with_name("Dustpan.debug.dylib")
        if debug.is_file() and not debug.is_symlink():
            binaries.append(debug)
        for binary in binaries:
            linked = subprocess.check_output(["otool", "-L", str(binary)], text=True)
            for line in linked.splitlines()[1:]:
                if not line[:1].isspace():
                    continue  # universal binaries have a separate unindented header for each architecture
                library = line.strip().split(" (", 1)[0]
                if library == "@rpath/Dustpan.debug.dylib" and debug in binaries:
                    continue  # Xcode's first-party Debug code is inspected separately above
                if not library.startswith(("/System/Library/", "/usr/lib/", "@rpath/libswift")):
                    raise SystemExit(f"Non-system linked library requires review: {library}")
    print("PASS: no external packages, binary targets, build plugins or Xcode build scripts; vendored hashes and modules match.")
    if args.binary:
        print("PASS: linked libraries are system frameworks and Swift runtime libraries.")


if __name__ == "__main__":
    main()
