#!/bin/bash
# Builds Velto.app (the menu bar app plus the `velto` CLI inside it) and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_PATH="$PWD/.build/local-app"
swift build -c release --scratch-path "$BUILD_PATH"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_PATH" --show-bin-path)"
APP="$BUILD_PATH/bundle/Velto.app"
DESTINATION="${VELTO_APP_DIR:-$HOME/Applications}/Velto.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/VeltoApp" "$APP/Contents/MacOS/Velto"
# SwiftPM records the deployment target (13.0) as the SDK version. macOS then draws the app in its
# old style: no Liquid Glass toolbar, sidebar or controls on macOS 26+. Record the real SDK instead.
stamp_sdk() { vtool -set-build-version macos 13.0 "$(xcrun --show-sdk-version)" -replace -output "$1" "$1" 2>/dev/null; }
stamp_sdk "$APP/Contents/MacOS/Velto"
# Helpers/, not MacOS/: "Velto" and "velto" are the same name on a case-insensitive disk.
cp "$BIN_DIR/velto" "$APP/Contents/Helpers/velto"
cp Branding/Velto.icns "$APP/Contents/Resources/Velto.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Velto</string>
  <key>CFBundleIdentifier</key><string>co.varell.velto</string>
  <key>CFBundleName</key><string>Velto</string>
  <key>CFBundleDisplayName</key><string>Velto</string>
  <key>CFBundleIconFile</key><string>Velto</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Velto by Varell</string>
</dict></plist>
PLIST
# Inside out: the helper first, then the app that seals it.
codesign --force --sign - "$APP/Contents/Helpers/velto"
codesign --force --sign - "$APP"
mkdir -p "$(dirname "$DESTINATION")"
# A running copy keeps the old code; quit it before replacing, start the new build after.
WAS_RUNNING=false
if pgrep -xq Velto; then WAS_RUNNING=true; pkill -x Velto; sleep 0.5; fi
rm -rf "$DESTINATION"
ditto "$APP" "$DESTINATION"
codesign --verify --strict "$DESTINATION"
echo "Done: $DESTINATION"
if $WAS_RUNNING; then open "$DESTINATION"; fi
