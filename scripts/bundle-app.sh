#!/bin/bash
set -euo pipefail

BINARY="${1:-.build/release/open-wispr}"
APP_DIR="${2:-Dictation-WIP.app}"
VERSION="${3:-0.3.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

cp "$BINARY" "$APP_DIR/Contents/MacOS/open-wispr"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Task: embed Sparkle.framework. open-wispr links @rpath/Sparkle.framework/...
# (see `import Sparkle` in UpdaterController.swift + Package.swift dependency)
# but nothing was copying the framework into the bundle, so the binary would
# fail to launch at all once Sparkle is wired in:
#   dyld: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
# SwiftPM resolves Sparkle as a prebuilt binary xcframework; find the slice
# for this platform rather than assuming a fixed path (checkout dir name and
# xcframework internals can change between Sparkle releases).
SPARKLE_FRAMEWORK="$(find "$REPO_DIR/.build" -type d -path '*Sparkle.xcframework/*/Sparkle.framework' -print -quit 2>/dev/null || true)"

if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "✗ Error: Sparkle.framework not found under $REPO_DIR/.build" >&2
    echo "  Run 'swift build' (or 'swift build -c release') first so SwiftPM" >&2
    echo "  resolves the Sparkle.xcframework binary dependency." >&2
    exit 1
fi

# Use ditto, not cp -R: it preserves the framework's own code signature,
# resource forks and the Versions/Current symlink structure exactly.
# Sparkle ships each nested component (the framework itself, Autoupdate,
# Updater.app, and the Downloader/Installer XPC services under XPCServices/)
# already signed with the hardened runtime as its own independent code
# object — verified with `codesign -dvvv` on each. Do NOT re-sign or --deep
# sign over these; that would strip valid nested signatures. Only the outer
# .app gets signed below, non-deep, per release-engineer convention.
ditto "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
echo "✓ Embedded Sparkle.framework from $SPARKLE_FRAMEWORK"

# The binary's rpath list (@loader_path, /usr/lib/swift, the toolchain path)
# does not include the standard app-bundle location for embedded frameworks.
# @loader_path for Contents/MacOS/open-wispr resolves to Contents/MacOS, not
# Contents/Frameworks, so @rpath/Sparkle.framework/... would still fail to
# resolve without this.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/open-wispr"
cp "$REPO_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# MIT requires the licence and notices to travel with binary distributions.
cp "$REPO_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
cp "$REPO_DIR/NOTICE" "$APP_DIR/Contents/Resources/NOTICE"

# Task 8.2 & 8.3: Bundle whisper-cli and default ggml model into the app bundle
mkdir -p "$APP_DIR/Contents/Resources/whisper"
mkdir -p "$APP_DIR/Contents/Resources/models"

# Copy whisper-cli binary if available
WHISPER_SRC=""
if [ -f "/opt/homebrew/bin/whisper-cli" ]; then
    WHISPER_SRC="/opt/homebrew/bin/whisper-cli"
elif command -v whisper-cli &>/dev/null; then
    WHISPER_SRC="$(which whisper-cli)"
fi

if [ -n "$WHISPER_SRC" ]; then
    cp "$WHISPER_SRC" "$APP_DIR/Contents/Resources/whisper/whisper-cli"
    chmod +x "$APP_DIR/Contents/Resources/whisper/whisper-cli"
    echo "✓ Bundled whisper-cli binary"
fi

# Copy default model if available
MODEL_SRC="$HOME/.config/open-wispr/models/ggml-base.en.bin"
if [ -f "$MODEL_SRC" ]; then
    cp "$MODEL_SRC" "$APP_DIR/Contents/Resources/models/ggml-base.en.bin"
    echo "✓ Bundled default model ggml-base.en.bin"
fi

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>open-wispr</string>
    <key>CFBundleIdentifier</key>
    <string>com.goprimy.dictation-wip</string>
    <key>CFBundleName</key>
    <string>Dictation-WIP</string>
    <key>CFBundleDisplayName</key>
    <string>Dictation (WIP)</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Dictation needs microphone access to record speech for transcription.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_IDENTITY" --identifier com.goprimy.dictation-wip "$APP_DIR"

echo "Built $APP_DIR"
