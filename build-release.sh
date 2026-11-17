#!/bin/bash
# Universal (arm64 + x86_64) Velto.app zipped for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must have the form MAJOR.MINOR.PATCH" >&2
  exit 1
fi

# Build each architecture separately so the script also works with Command Line Tools.
# Separate scratch paths: newer SwiftPM versions share one output folder across triples.
for ARCH in arm64 x86_64; do
  for PRODUCT in VeltoApp velto; do
    swift build -c release --triple "$ARCH-apple-macosx13.0" --product "$PRODUCT" --scratch-path ".build/release-$ARCH"
  done
done
ARM_DIR="$(swift build -c release --triple arm64-apple-macosx13.0 --scratch-path .build/release-arm64 --show-bin-path)"
INTEL_DIR="$(swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path .build/release-x86_64 --show-bin-path)"

# build-app.sh reads VERSION for Info.plist; publish-release.sh has already written the new one.
VELTO_APP_DIR="$PWD" bash build-app.sh
APP="$PWD/Velto.app"
lipo -create "$ARM_DIR/VeltoApp" "$INTEL_DIR/VeltoApp" -output "$APP/Contents/MacOS/Velto"
# See build-app.sh: without the real SDK version macOS draws the app in its pre-26 style.
vtool -set-build-version macos 13.0 "$(xcrun --show-sdk-version)" -replace -output "$APP/Contents/MacOS/Velto" "$APP/Contents/MacOS/Velto" 2>/dev/null
lipo -create "$ARM_DIR/velto" "$INTEL_DIR/velto" -output "$APP/Contents/Helpers/velto"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
# Local ad-hoc signature only: this is NOT a Developer ID signature or notarization.
codesign --force --sign - "$APP/Contents/Helpers/velto"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
for ARCH in arm64 x86_64; do
  lipo "$APP/Contents/MacOS/Velto" -verify_arch "$ARCH"
  lipo "$APP/Contents/Helpers/velto" -verify_arch "$ARCH"
done
mkdir -p dist
ARCHIVE="$PWD/dist/Velto-$VERSION-universal.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
echo "Created $ARCHIVE (ad-hoc signed, not notarized)"
