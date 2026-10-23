#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
for HB_TARGET_ARCH in arm64 x86_64; do
    HB_NATIVE_BUILD="$root/work/native-build-$HB_TARGET_ARCH"
    source "$root/scripts/compile-native.sh"
done
app="$root/outputs/Human Browser.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Fixtures"
xcrun lipo -create "$root/work/native-build-arm64/HumanBrowser" "$root/work/native-build-x86_64/HumanBrowser" -output "$app/Contents/MacOS/HumanBrowser"
cp "$root/tests/fixtures/welcome-example.html" "$app/Contents/Resources/Fixtures/"
/usr/libexec/PlistBuddy -c Clear "$app/Contents/Info.plist" >/dev/null 2>&1 || true
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HumanBrowser</string>
<key>CFBundleIdentifier</key><string>org.humanbrowser.alpha</string>
<key>CFBundleName</key><string>Human Browser</string>
<key>CFBundleDisplayName</key><string>사람 브라우저</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
archive="$root/outputs/human-browser-macos-0.1.0-alpha-universal.zip"
ditto -c -k --keepParent "$app" "$archive"
(cd "$root/outputs" && LC_ALL=C shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
printf '%s\n' "$app"
printf '%s\n' "$archive"
