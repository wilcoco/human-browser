#!/bin/bash
# Explicitly opt-in. Posts synthetic records to production and then withdraws them.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
build="$root/work/native-build-$(uname -m)"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -sdk "$(xcrun --show-sdk-path)" -module-cache-path "$root/work/overlay-module-cache" \
  -vfsoverlay "$root/work/toolchain/overlay.json" -Xcc -ivfsoverlay -Xcc "$root/work/toolchain/overlay.json" \
  -I "$build" -I "$root/packages/sqlite" -L "$build" -lHumanBrowserCore -lsqlite3 \
  apps/macos/Sources/SharedRecords.swift tests/macos/LiveSharingChecks.swift -o work/macos-live-sharing-checks
work/macos-live-sharing-checks
