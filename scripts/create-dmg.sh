#!/bin/bash
# scripts/create-dmg.sh
#
# Task 8.6: Create a signed disk image (DMG) for release distribution.
#
# Usage:
#   ./scripts/create-dmg.sh [Dictation-WIP.app] [Dictation-WIP.dmg]

set -euo pipefail

APP_PATH="${1:-Dictation-WIP.app}"
DMG_PATH="${2:-Dictation-WIP.dmg}"
VOLUME_NAME="Dictation (WIP)"

if [ ! -d "$APP_PATH" ]; then
    echo "✗ Error: App bundle not found at $APP_PATH"
    echo "  Run ./scripts/bundle-app.sh first."
    exit 1
fi

echo "=== Task 8.6: Creating DMG for $APP_PATH ==="

TEMP_DIR="$(mktemp -d /tmp/open-wispr-dmg.XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT

# Copy app into temp folder alongside Applications symlink
cp -R "$APP_PATH" "$TEMP_DIR/"
ln -s /Applications "$TEMP_DIR/Applications"

# Build read-write DMG first
RAW_DIR="$(mktemp -d /tmp/open-wispr-raw.XXXXXX)"
RAW_DMG="$RAW_DIR/raw.dmg"
rm -f "$DMG_PATH" "$RAW_DMG"

hdiutil create -volname "$VOLUME_NAME" -srcfolder "$TEMP_DIR" -ov -format UDRW "$RAW_DMG"

# Convert to compressed read-only DMG
hdiutil convert "$RAW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -rf "$RAW_DIR"

# Sign DMG if Developer ID certificate is available
IDENTITY="${DEVELOPER_ID_KEYCHAIN_IDENTITY:-}"
if [ -n "$IDENTITY" ]; then
    codesign --sign "$IDENTITY" --timestamp "$DMG_PATH"
    echo "✓ Signed DMG with identity: $IDENTITY"
else
    echo "! Ad-hoc codesign on DMG (set DEVELOPER_ID_KEYCHAIN_IDENTITY for release build)"
    codesign --force --sign - "$DMG_PATH"
fi

echo "════════════════════════════════════════════════════"
echo "  ✅ Created DMG: $DMG_PATH"
echo "════════════════════════════════════════════════════"
