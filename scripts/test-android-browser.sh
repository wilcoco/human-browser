#!/bin/bash
set -euo pipefail
export LC_ALL=C
root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
tools="$sdk/build-tools/34.0.0"
platform="$sdk/platforms/android-35/android.jar"
build="$root/work/android/browser-tests"
keys="$root/.release-keys/android"
mkdir -p "$build/classes" "$build/dex"
"$tools/aapt2" link -I "$platform" --manifest "$root/tests/android/browser-tests/AndroidManifest.xml" -o "$build/base.apk"
javac --release 8 -encoding UTF-8 -classpath "$platform" -d "$build/classes" "$root/tests/android/browser-tests/BrowserChecks.java"
find "$build/classes" -name '*.class' -print > "$build/classes.txt"
"$tools/d8" --release --min-api 26 --lib "$platform" --output "$build/dex" @"$build/classes.txt"
cp "$build/base.apk" "$build/unsigned.apk"
(cd "$build/dex" && zip -q -j "$build/unsigned.apk" classes*.dex)
"$tools/zipalign" -f -p 4 "$build/unsigned.apk" "$build/aligned.apk"
"$tools/apksigner" sign --ks "$keys/release.jks" --ks-key-alias human-browser-release --ks-pass "file:$keys/password" --out "$build/tests.apk" "$build/aligned.apk"
echo "$build/tests.apk"
