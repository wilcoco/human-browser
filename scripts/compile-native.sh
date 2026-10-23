#!/bin/bash
# Sourced by build-macos.sh; requires root.
mkdir -p "$root/work/overlay-module-cache" "$root/work/native-build" "$root/work/toolchain" "$root/outputs"
swiftc="$(xcrun --find swiftc)"
sdk="$(xcrun --show-sdk-path)"
# Hide a leftover duplicate module map in this invocation; do not edit the system.
python3 - "$root" "$swiftc" <<'PY'
import json, pathlib, sys
root, compiler = map(pathlib.Path, sys.argv[1:])
include = compiler.parent.parent / "include/swift"
old, new = include / "module.modulemap", include / "bridging.modulemap"
overlay = root / "work/toolchain/overlay.json"
empty = root / "work/toolchain/empty.modulemap"
empty.write_text("// Workspace-only compatibility overlay.\n")
roots = []
if old.exists() and new.exists() and "module SwiftBridging" in old.read_text() and "module SwiftBridging" in new.read_text():
    roots.append({"type":"file", "name":str(old), "external-contents":str(empty)})
overlay.write_text(json.dumps({"version":0,"roots":roots}))
PY
compile() {
    "$swiftc" -swift-version 5 -target "${HB_TARGET_ARCH:-$(uname -m)}-apple-macosx14.0" -sdk "$sdk" \
        -module-cache-path "$root/work/overlay-module-cache" \
        -vfsoverlay "$root/work/toolchain/overlay.json" \
        -Xcc -ivfsoverlay -Xcc "$root/work/toolchain/overlay.json" "$@"
}
build="${HB_NATIVE_BUILD:-$root/work/native-build}"
mkdir -p "$build"
compile -emit-library -static -emit-module -enable-testing \
    -module-name HumanBrowserCore -I "$root/packages/sqlite" \
    -emit-module-path "$build/HumanBrowserCore.swiftmodule" \
    "$root"/packages/client-core/Sources/*.swift -o "$build/libHumanBrowserCore.a"
compile -parse-as-library -I "$build" -I "$root/packages/sqlite" \
    -L "$build" -lHumanBrowserCore -lsqlite3 "$root"/apps/macos/Sources/*.swift \
    -o "$build/HumanBrowser"
