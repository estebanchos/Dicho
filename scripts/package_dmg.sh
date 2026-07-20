#!/bin/bash
# Packages a signed Dicho.app into a distributable DMG with a
# drag-to-Applications installer layout (background image, app icon left,
# /Applications symlink right).
#
# Usage: scripts/package_dmg.sh <version> [path/to/Dicho.app]
#   version : marketing version, e.g. 0.1 -> produces build/Dicho-v0.1.dmg
#   app path: defaults to build/export/Dicho.app
#
# The app must already be Developer ID signed (and ideally notarized +
# stapled). The output DMG is signed here; notarize and staple it afterwards:
#   xcrun notarytool submit build/Dicho-v<version>.dmg \
#     --keychain-profile "dicho-notary" --wait
#   xcrun stapler staple build/Dicho-v<version>.dmg
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version> [path/to/Dicho.app]" >&2
  exit 1
fi

VERSION="$1"
APP_PATH="${2:-build/export/Dicho.app}"
SIGNING_IDENTITY="Developer ID Application: CARLOS ESTEBAN OCAMPO FLOR (6WGQ9965VP)"
BACKGROUND_TIFF="scripts/dmg/background.tiff"
VOLUME_NAME="Dicho"
STAGING_DIR="build/dmg-staging"
RW_DMG="build/Dicho-rw.dmg"
OUTPUT_DMG="build/Dicho-v${VERSION}.dmg"
MOUNT_POINT="/Volumes/${VOLUME_NAME}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found at $APP_PATH" >&2
  exit 1
fi
if [[ ! -f "$BACKGROUND_TIFF" ]]; then
  echo "error: background image not found at $BACKGROUND_TIFF" >&2
  exit 1
fi

echo "==> Verifying code signature of $APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "==> Staging DMG contents"
rm -rf "$STAGING_DIR" "$RW_DMG" "$OUTPUT_DMG"
mkdir -p "$STAGING_DIR/.background"
ditto "$APP_PATH" "$STAGING_DIR/Dicho.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$BACKGROUND_TIFF" "$STAGING_DIR/.background/background.tiff"

# Detach a stale mount from a previous failed run, if any.
if [[ -d "$MOUNT_POINT" ]]; then
  hdiutil detach "$MOUNT_POINT" -force || true
fi

echo "==> Creating read-write image"
APP_SIZE_MB=$(du -sm "$STAGING_DIR" | cut -f1)
DMG_SIZE_MB=$((APP_SIZE_MB + 20))
hdiutil create -srcfolder "$STAGING_DIR" -volname "$VOLUME_NAME" \
  -fs HFS+ -format UDRW -size "${DMG_SIZE_MB}m" "$RW_DMG"

echo "==> Mounting and applying Finder layout"
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_POINT" -nobrowse

osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Dicho"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 800, 590}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Dicho.app" of container window to {150, 195}
        set position of item "Applications" of container window to {450, 195}
        close
        open
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_POINT"

echo "==> Converting to compressed read-only DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG"
rm -rf "$RW_DMG" "$STAGING_DIR"

echo "==> Signing DMG"
codesign --sign "$SIGNING_IDENTITY" "$OUTPUT_DMG"
codesign --verify "$OUTPUT_DMG"

echo "==> Done: $OUTPUT_DMG"
