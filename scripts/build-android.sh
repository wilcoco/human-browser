#!/bin/bash
set -euo pipefail
export LC_ALL=C
root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
tools="$sdk/build-tools/34.0.0"
platform="$sdk/platforms/android-35/android.jar"
build="$root/work/android/build"
keys="$root/.release-keys/android"
app="$root/apps/android/app/src/main"
mkdir -p "$build/classes" "$build/dex" "$root/outputs" "$keys"
chmod 700 "$root/.release-keys" "$keys"
if [ ! -f "$keys/release.jks" ]; then
  if [ -f "$keys/password" ]; then echo 'Signing key is missing; refusing to replace the existing release identity.' >&2; exit 1; fi
  umask 077
  openssl rand -base64 36 > "$keys/password"
  keytool -genkeypair -keystore "$keys/release.jks" -alias human-browser-release -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=Human Browser Android Release' -storepass:file "$keys/password" -keypass:file "$keys/password" >/dev/null
fi
if [ ! -f "$keys/password" ]; then echo 'Release key password is missing.' >&2; exit 1; fi
"$tools/aapt2" compile --dir "$app/res" -o "$build/resources.zip"
"$tools/aapt2" link -I "$platform" --manifest "$app/AndroidManifest.xml" -A "$app/assets" -o "$build/base.apk" "$build/resources.zip"
find "$app/java" -name '*.java' -print > "$build/sources.txt"
javac --release 8 -encoding UTF-8 -classpath "$platform" -d "$build/classes" @"$build/sources.txt"
find "$build/classes" -name '*.class' -print > "$build/classes.txt"
"$tools/d8" --release --min-api 26 --lib "$platform" --output "$build/dex" @"$build/classes.txt"
cp "$build/base.apk" "$build/unsigned.apk"
(cd "$build/dex" && zip -q -j "$build/unsigned.apk" classes*.dex)
"$tools/zipalign" -f -p 4 "$build/unsigned.apk" "$build/aligned.apk"
output="$root/outputs/human-browser-android-0.1.0-alpha.apk"
"$tools/apksigner" sign --ks "$keys/release.jks" --ks-key-alias human-browser-release --ks-pass "file:$keys/password" --out "$output" "$build/aligned.apk"
"$tools/apksigner" verify --verbose --print-certs "$output"
(cd "$root/outputs" && shasum -a 256 human-browser-android-0.1.0-alpha.apk > human-browser-android-0.1.0-alpha.apk.sha256)
printf '\nAPK: %s\n' "$output"
