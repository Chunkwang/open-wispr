#!/bin/bash
# scripts/notarize.sh
#
# Task 8.5: Notarize and staple the macOS DMG build.
#
# Usage:
#   KEYCHAIN_PROFILE="AC_NOTARY" ./scripts/notarize.sh [Dictation-WIP.dmg]

set -euo pipefail

DMG_PATH="${1:-Dictation-WIP.dmg}"

if [ ! -f "$DMG_PATH" ]; then
    echo "✗ Error: DMG file not found at $DMG_PATH"
    echo "  Run ./scripts/create-dmg.sh first."
    exit 1
fi

echo "=== Task 8.5: Notarizing $DMG_PATH ==="

KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-${NOTARY_KEYCHAIN_PROFILE:-}}"

if [ -z "$KEYCHAIN_PROFILE" ]; then
    echo "! KEYCHAIN_PROFILE environment variable not set."
    echo "  For production release, store credentials with:"
    echo "    xcrun notarytool store-credentials \"AC_NOTARY\" --apple-id \"...\" --team-id \"...\""
    echo "  And run: KEYCHAIN_PROFILE=\"AC_NOTARY\" ./scripts/notarize.sh $DMG_PATH"
    echo ""
    echo "  Verifying local signature on DMG:"
    codesign -v --deep --strict "$DMG_PATH" && echo "  ✓ Local signature valid" || echo "  ! Ad-hoc signature"
    exit 0
fi

echo "Submitting $DMG_PATH to Apple Notary Service..."
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "Stapling notarization ticket to $DMG_PATH..."
xcrun stapler staple "$DMG_PATH"

echo "════════════════════════════════════════════════════"
echo "  ✅ Notarized and stapled: $DMG_PATH"
echo "════════════════════════════════════════════════════"
spctl -a -vv --type install "$DMG_PATH"
