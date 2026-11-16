import XCTest
@testable import OpenWisprLib

/// Lints `BillingCopy` with the same brand-voice rules `CopyLintTests` and
/// `RewriteNoticeTests` apply elsewhere (Tasks 4.7/4.8), and checks the exact
/// mapping from every `BillingError` case to its notice.
final class BillingCopyTests: XCTestCase {
    private var allStrings: [String] {
        [
            BillingCopy.menuUpgrade,
            BillingCopy.menuManageSubscription,
            BillingCopy.upgradePrompt,
            BillingCopy.upgradeComplete,
            BillingCopy.signedOutNotice,
            BillingCopy.alreadyProNotice,
            BillingCopy.noCustomerNotice,
            BillingCopy.rateLimitedNotice,
            BillingCopy.offlineNotice,
            BillingCopy.timedOutNotice,
            BillingCopy.unreachableNotice,
            BillingCopy.invalidResponseNotice,
        ]
    }

    func testNoBannedWords() {
        for str in allStrings {
            let lower = str.lowercased()
            for banned in CopyLint.banned {
                XCTAssertFalse(lower.contains(banned), "'\(banned)' in \"\(str)\"")
            }
        }
    }

    func testNoExclamationMarks() {
        for str in allStrings {
            XCTAssertFalse(str.contains("!"), "\"\(str)\"")
        }
    }

    func testSentenceCountBounded() {
        for str in allStrings {
            XCTAssertLessThanOrEqual(CopyLint.sentenceCount(str), 2, "\"\(str)\"")
        }
    }

    /// The upgrade prompt is a verbatim quote from brand-voice-tone-guide.md's
    /// "Upgrade prompt (Free → Pro)" sample — pinned here so an edit to either
    /// place is caught as a test failure, not discovered later as drift.
    func testUpgradePromptMatchesVoiceGuideVerbatim() {
        XCTAssertEqual(
            BillingCopy.upgradePrompt,
            "Rewrite cleans up filler words and punctuation automatically. It costs us a small amount per use, which is why it's the one thing we charge for — everything else stays free."
        )
    }

    /// One assertion per `BillingError` case, so a case added to the enum
    /// without being added here is caught by the compiler-enforced exhaustive
    /// switch inside `BillingCopy.notice(for:)` itself, and the mapping is
    /// pinned so nobody can change it without a visible test failure.
    func testNoticeMapping() {
        XCTAssertNil(BillingCopy.notice(for: .cancelled))
        XCTAssertEqual(BillingCopy.notice(for: .notAuthenticated), BillingCopy.signedOutNotice)
        XCTAssertEqual(BillingCopy.notice(for: .unauthorized), BillingCopy.signedOutNotice)
        XCTAssertEqual(BillingCopy.notice(for: .alreadyPro), BillingCopy.alreadyProNotice)
        XCTAssertEqual(BillingCopy.notice(for: .noCustomer), BillingCopy.noCustomerNotice)
        XCTAssertEqual(BillingCopy.notice(for: .rateLimited), BillingCopy.rateLimitedNotice)
        XCTAssertEqual(BillingCopy.notice(for: .offline), BillingCopy.offlineNotice)
        XCTAssertEqual(BillingCopy.notice(for: .timedOut), BillingCopy.timedOutNotice)
        XCTAssertEqual(BillingCopy.notice(for: .unreachable), BillingCopy.unreachableNotice)
        XCTAssertEqual(BillingCopy.notice(for: .unavailable), BillingCopy.unreachableNotice)
        XCTAssertEqual(BillingCopy.notice(for: .providerFailed), BillingCopy.unreachableNotice)
        XCTAssertEqual(BillingCopy.notice(for: .unexpectedStatus(418)), BillingCopy.invalidResponseNotice)
        XCTAssertEqual(BillingCopy.notice(for: .invalidResponse), BillingCopy.invalidResponseNotice)
    }
}
