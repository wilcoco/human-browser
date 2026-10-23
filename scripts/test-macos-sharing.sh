#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
build="$root/work/native-build-$(uname -m)"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -sdk "$(xcrun --show-sdk-path)" -module-cache-path "$root/work/overlay-module-cache" \
  -vfsoverlay "$root/work/toolchain/overlay.json" -Xcc -ivfsoverlay -Xcc "$root/work/toolchain/overlay.json" \
  -I "$build" -I "$root/packages/sqlite" -L "$build" -lHumanBrowserCore -lsqlite3 \
  apps/macos/Sources/SharedRecords.swift tests/macos/SharedChecks.swift -o work/macos-shared-checks
work/macos-shared-checks
node --input-type=module - <<'JS'
import {readFileSync} from 'node:fs';
import {validateRecord} from './services/api/records.mjs';
validateRecord(JSON.parse(readFileSync('work/macos-shared-fixture.json','utf8')));
console.log('PASS: Mac envelope verified by unchanged Railway/Android protocol validator');
JS
