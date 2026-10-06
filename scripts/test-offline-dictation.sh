#!/bin/bash
# scripts/test-offline-dictation.sh
#
# Task 5.4: Prove that dictation works with no network access.
#
# This runs the REAL production code path — Transcriber.transcribe(audioURL:)
# in Sources/OpenWisprLib/Transcriber.swift, exercised by a real XCTest
# (OfflineDictationTests.testRealTranscriberSucceedsOnSilentAudio in
# Tests/OpenWisprTests/OfflineDictationTests.swift) — inside a macOS sandbox
# that denies ALL network access. If that test still passes, dictation is
# proven to work fully offline using the exact whisper-cli argument list and
# output-validation logic that ships (including -l, -nt and --suppress-nst,
# and Transcriber.resolveOutput's silent-failure detection), not a
# hand-copied shell approximation of it that can silently drift out of sync
# with Transcriber.swift (as the prior version of this script had).
#
# This script also adversarially proves the sandbox profile is actually
# doing something: it makes a real network request (curl to a public IP)
# both outside and inside the sandbox, and requires it to succeed outside and
# fail inside. Without that check, a silently-broken or overly-permissive
# sandbox profile would make the "offline" claim above meaningless.
#
# Usage:
#   ./scripts/test-offline-dictation.sh
#
# Requirements:
#   - Xcode (for `swift build` and the `xctest` CLI; Command Line Tools alone
#     are not enough to run XCTest)
#   - whisper-cli installed with a model downloaded, to exercise the real
#     transcription. If neither is present, OfflineDictationTests skips
#     itself (XCTSkip) rather than failing — this script still fails loudly
#     if the sandbox-blocking proof itself doesn't hold.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SANDBOX_PROFILE="$SCRIPT_DIR/no-network.sb"
XCTEST_BIN="$(xcrun --find xctest 2>/dev/null || true)"
RUN_OUTPUT="$(mktemp /tmp/offline-dictation-test-output.XXXXXX)"

# Runs on every exit path (pass, fail, or an unexpected error from `set -e`),
# not just the success path — the previous version of this script only
# cleaned up right before its final success echo, so any failure above that
# point left the sandbox profile and temp files behind.
cleanup() {
    rm -f "$SANDBOX_PROFILE" "$RUN_OUTPUT"
}
trap cleanup EXIT

echo "=== Task 5.4: No-Network Dictation Test ==="
echo ""

if [ -z "$XCTEST_BIN" ]; then
    echo "✗ xctest CLI not found. Full Xcode is required (Command Line Tools alone lack it)."
    exit 1
fi

# Step 1: sandbox profile that denies all network access.
cat > "$SANDBOX_PROFILE" <<'EOF'
(version 1)
(allow default)
(deny network*)
EOF
echo "✓ Created sandbox profile: $SANDBOX_PROFILE"

# Step 2: adversarial proof the profile actually blocks network, before
# trusting it for anything below. A real IP literal (not a hostname) is used
# so this isn't just proving DNS is blocked.
echo ""
echo "--- Adversarial check: does the sandbox profile actually block network? ---"

if curl -s --max-time 3 -o /dev/null https://1.1.1.1; then
    echo "✓ Baseline: network call succeeds with NO sandbox (as expected)."
else
    echo "✗ Baseline network call failed even without a sandbox."
    echo "  This machine may have no network right now, which would make the"
    echo "  adversarial proof below meaningless either way. Aborting."
    exit 1
fi

if sandbox-exec -f "$SANDBOX_PROFILE" curl -s --max-time 3 -o /dev/null https://1.1.1.1; then
    echo "✗ FAIL: the SAME network call SUCCEEDED inside the sandbox."
    echo "  The profile is not blocking network — nothing below this point"
    echo "  would prove anything about offline dictation."
    exit 1
else
    echo "✓ Proof: the same network call FAILS inside the sandbox."
    echo "  (deny network*) is confirmed to be doing real work, not just"
    echo "  sitting in a comment."
fi

# Step 3: build the real test target. This happens OUTSIDE the sandbox,
# same as CI's own separate build step — nothing below this line runs
# outside the sandbox.
echo ""
echo "--- Building the real Swift test target ---"
(cd "$PROJECT_DIR" && swift build --build-tests)

BUNDLE="$PROJECT_DIR/.build/out/Products/Debug/OpenWisprTests.xctest"
if [ ! -d "$BUNDLE" ]; then
    echo "✗ Expected test bundle not found at: $BUNDLE"
    echo "  (swift build layout may have changed; update this script's BUNDLE path)"
    exit 1
fi
echo "✓ Built: $BUNDLE"

# Step 4: run the REAL Transcriber.transcribe(audioURL:) path inside the
# network-denying sandbox. This invokes the already-compiled .xctest bundle
# directly with Xcode's `xctest` CLI rather than `swift test`, because
# `swift test` re-invokes SwiftPM's own manifest/plugin compilation, which
# internally applies its own sandbox — nesting that inside this script's
# sandbox-exec fails with "sandbox_apply: Operation not permitted" before
# the actual test ever runs. That collision is in SwiftPM's tooling, not in
# anything this test is trying to prove, so the build (step 3) happens
# outside the sandbox and only the already-compiled test binary runs inside
# it, which is sufficient to exercise the real whisper-cli subprocess
# Transcriber.transcribe(audioURL:) spawns under a network-denying sandbox
# (macOS sandbox profiles are inherited across fork/exec).
echo ""
echo "--- Running OfflineDictationTests inside the network-denying sandbox ---"
echo ""

set +e
sandbox-exec -f "$SANDBOX_PROFILE" \
    "$XCTEST_BIN" -XCTest OpenWisprTests.OfflineDictationTests "$BUNDLE" \
    > "$RUN_OUTPUT" 2>&1
TEST_EXIT=$?
set -e

cat "$RUN_OUTPUT"
echo ""

if [ "$TEST_EXIT" -ne 0 ]; then
    echo "════════════════════════════════════════════════════"
    echo "  FAIL: OfflineDictationTests failed under the"
    echo "  network-denying sandbox (exit $TEST_EXIT)."
    echo "════════════════════════════════════════════════════"
    exit "$TEST_EXIT"
fi

if grep -q "with 0 failures (0 unexpected) in" "$RUN_OUTPUT" && grep -q "1 test skipped" "$RUN_OUTPUT"; then
    echo "════════════════════════════════════════════════════"
    echo "  PASS (SKIPPED): sandbox-blocking is proven, but whisper-cli"
    echo "  or a model isn't installed on this machine, so the real"
    echo "  transcription itself wasn't exercised. Install whisper-cpp"
    echo "  and a model, then re-run, to exercise it for real."
    echo "════════════════════════════════════════════════════"
else
    echo "════════════════════════════════════════════════════"
    echo "  PASS: real Transcriber.transcribe(audioURL:) succeeded"
    echo "  with ALL network access denied."
    echo "════════════════════════════════════════════════════"
fi
