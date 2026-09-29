import XCTest
@testable import OpenWisprLib

/// Covers `UpgradeAttemptGuard`, the fix for security-engineer's Day 7 review
/// finding "no guard against overlapping poll loops": a few rapid or
/// accidental clicks on "Upgrade to Pro" must start at most one
/// checkout-then-poll sequence at a time.
///
/// This is tested in isolation rather than by driving `StatusBarController`
/// end to end: constructing a real `StatusBarController` and calling
/// `startUpgrade()` reaches `buildMenu()`, which calls `SessionStore()` (the
/// real system Keychain) directly with no way to inject a fake — in a
/// non-interactive test environment that hangs for minutes instead of
/// failing fast, which is a pre-existing property of `StatusBarController`
/// unrelated to this fix. `UpgradeAttemptGuard` carries the entire
/// concurrency-guard behavior `startUpgrade()` relies on, with none of that
/// baggage, so it is tested directly.
final class UpgradeAttemptGuardTests: XCTestCase {
    func testFirstBeginSucceeds() {
        XCTAssertTrue(UpgradeAttemptGuard().begin())
    }

    /// The core of the fix: a second click while the first attempt is still
    /// running must not be able to start another one.
    func testSecondBeginWhileInProgressReturnsFalse() {
        let upgradeGuard = UpgradeAttemptGuard()
        XCTAssertTrue(upgradeGuard.begin())
        XCTAssertFalse(upgradeGuard.begin(), "a repeat click while an attempt is already running must be a no-op")
        XCTAssertFalse(upgradeGuard.begin(), "still a no-op on a third rapid click")
    }

    /// Once the in-flight attempt ends (success or failure — `end()` doesn't
    /// distinguish, matching `startUpgrade()`'s `switch result` running only
    /// after clearing the guard), a new click must be able to start again.
    func testBeginSucceedsAgainAfterEnd() {
        let upgradeGuard = UpgradeAttemptGuard()
        XCTAssertTrue(upgradeGuard.begin())
        upgradeGuard.end()
        XCTAssertTrue(upgradeGuard.begin(), "a click after the previous attempt finished must be able to start a new one")
    }

    /// `end()` before any `begin()` (should never happen given how
    /// `startUpgrade()` calls it, but costs nothing to make safe) must not
    /// leave the guard in a state that blocks the next attempt.
    func testEndWithoutBeginIsHarmless() {
        let upgradeGuard = UpgradeAttemptGuard()
        upgradeGuard.end()
        XCTAssertTrue(upgradeGuard.begin())
    }
}
