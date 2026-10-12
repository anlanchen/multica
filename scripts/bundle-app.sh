#!/usr/bin/env bash
# Builds Multica.app from the SwiftPM executable.
#
#   scripts/bundle-app.sh            # release build for this Mac's architecture
#   UNIVERSAL=1 scripts/bundle-app.sh  # arm64 + x86_64
#
# The bundle is ad-hoc signed so it runs locally; distribute with a Developer
# ID signature and notarization instead.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP="dist/Multica.app"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --product MulticaApp --arch arm64 --arch x86_64
  BIN_DIR=".build/apple/Products/Release"
else
  swift build -c release --product MulticaApp
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MulticaApp" "$APP/Contents/MacOS/Multica"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Multica</string>
  <key>CFBundleDisplayName</key><string>Multica</string>
  <key>CFBundleIdentifier</key><string>ai.multica.native</string>
  <key>CFBundleExecutable</key><string>Multica</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>ai.multica.native.auth</string>
      <key>CFBundleURLSchemes</key><array><string>multica</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
