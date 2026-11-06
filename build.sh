#!/bin/bash
# Builds Wakeline Preview.app and Wakeline.saver with Command Line Tools only.
set -euo pipefail
cd "$(dirname "$0")"
SDK=$(xcrun --show-sdk-path)
TARGET=arm64-apple-macos14.0
FLAGS=(-swift-version 5 -O -wmo -sdk "$SDK" -target "$TARGET")
CORE=(Sources/Core/*.swift)
# WAKELINE_SIGN_ID names a Developer ID certificate. Without it, the build signs for this Mac only.
SIGN_ID="${WAKELINE_SIGN_ID:--}"
SIGN_FLAGS=(--force --options runtime --sign "$SIGN_ID")
if [ "$SIGN_ID" != "-" ]; then SIGN_FLAGS+=(--timestamp); fi
# WAKELINE_TEST=1 adds the record, load-saver and soak modes to the preview app.
if [ -n "${WAKELINE_TEST:-}" ]; then FLAGS+=(-D WAKELINE_TEST); fi
RES=(Resources/Wakeline.metal Resources/runner.mesh Resources/pylon.mesh)

APP="build/Wakeline Preview.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${FLAGS[@]}" -module-name WakelinePreview "${CORE[@]}" Sources/Preview/main.swift \
  -framework ScreenSaver -o "$APP/Contents/MacOS/Wakeline Preview"
cp "${RES[@]}" Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>Wakeline Preview</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>co.1upcreative.wakeline.preview</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Wakeline Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHumanReadableCopyright</key><string>Copyright 2026 1UP Creative. MIT License.</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
codesign "${SIGN_FLAGS[@]}" "$APP"

SAVER="build/Wakeline.saver"
OBJ=build/saver.o
if [ -f Sources/Saver/WakelineSaverView.swift ]; then
  rm -rf "$SAVER"; mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
  swiftc "${FLAGS[@]}" -module-name Wakeline -parse-as-library -c "${CORE[@]}" Sources/Saver/*.swift -o "$OBJ"
  xcrun clang -bundle -target "$TARGET" -isysroot "$SDK" "$OBJ" \
    -L"$SDK/usr/lib/swift" -L/usr/lib/swift -Wl,-rpath,/usr/lib/swift \
    -framework AppKit -framework ScreenSaver -framework Metal -framework QuartzCore \
    -o "$SAVER/Contents/MacOS/Wakeline"
  cp "${RES[@]}" "$SAVER/Contents/Resources/"
  [ -f Resources/thumbnail.png ] && cp Resources/thumbnail*.png "$SAVER/Contents/Resources/"
  cat > "$SAVER/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>Wakeline</string>
<key>CFBundleIdentifier</key><string>co.1upcreative.wakeline.saver</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Wakeline</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHumanReadableCopyright</key><string>Copyright 2026 1UP Creative. MIT License.</string>
<key>NSPrincipalClass</key><string>WakelineSaverView</string>
</dict></plist>
P
  codesign "${SIGN_FLAGS[@]}" "$SAVER"
fi
echo BUILD OK
