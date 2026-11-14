#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
DIST_DIR="$ROOT/dist"
APP_NAME="System Screen Recorder"
EXECUTABLE="system-screen-recorder"
STAGING="$(mktemp -d "$BUILD_DIR/dmg-staging.XXXXXX")"
APP_BUNDLE="$STAGING/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"

mkdir -p "$DIST_DIR" "$APP_BUNDLE/Contents/MacOS"
swift build --configuration release --package-path "$ROOT"
ditto "$BUILD_DIR/release/$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
ditto "$ROOT/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
ln -s /Applications "$STAGING/Applications"

# Ad-hoc signing lets macOS validate the app bundle, but is not Developer ID notarization.
codesign --force --deep --sign - "$APP_BUNDLE"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "Created $DMG_PATH"
