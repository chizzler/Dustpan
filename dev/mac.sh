#!/usr/bin/env bash
# Build and run the Mac client against the local dev server.
# Uses dev/credentials and keeps its data in dev/data/mac, apart from any real install.
set -euo pipefail

DEV=$(cd "$(dirname "$0")" && pwd)
BUILD=$DEV/data/mac-build
xcodebuild -project "$DEV/../apple/Dustpan.xcodeproj" -scheme Dustpan -configuration Debug \
  -derivedDataPath "$BUILD" -quiet build
export DUSTPAN_CONFIG=$DEV/credentials
export DUSTPAN_DATA=$DEV/data/mac
exec "$BUILD/Build/Products/Debug/Dustpan.app/Contents/MacOS/Dustpan"
