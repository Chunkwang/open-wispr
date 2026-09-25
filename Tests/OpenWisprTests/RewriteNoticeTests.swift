import XCTest
@testable import OpenWisprLib

final class RewriteNoticeTests: XCTestCase {
    /// One instance of every case. `RewriteError` has no `CaseIterable`, so this
    /// switch (no `default`) fails to compile when a case is added, forcing the
    /// list, and therefore the lint below, to cover it.
    private func representative(of error: RewriteError) -> RewriteError {
        switch error {
        case .notAuthenticated, .unauthorized, .requiresPro, .rateLimited, .tooLong,
             .offline, .timedOut, .cancelled, .unreachable, .unavailable, .invalidResponse:
            return error
        case .unexpectedStatus:
            return .unexpectedStatus(503)
        }
    }

    private var everyError: [RewriteError] {
        let all: [RewriteError] = [
            .notAuthenticated, .unauthorized, .requiresPro, .rateLimited, .tooLong,
            .offline, .timedOut, .cancelled, .unreachable, .unavailable,
            .unexpectedStatus(302), .unexpectedStatus(418), .unexpectedStatus(500), .invalidResponse,
        ]
        return all.map(representative(of:))
    }

    private let banned = ["smart", "seamless", "powerful", "magic", "simply", "oops", "just", "sorry", "apolog", "unfortunately"]

    private func sentenceCount(_ text: String) -> Int {
        var count = 0
        let chars = Array(text)
        for (i, c) in chars.enumerated() where c == "." || c == "?" {
            if i + 1 == chars.count || chars[i + 1] == " " { count += 1 }
        }
        return count
    }

    func testCancelledShowsNothing() {
        XCTAssertNil(RewriteError.cancelled.userNotice)
    }

    func testEveryOtherErrorHasANotice() {
        for error in everyError where error != .cancelled {
            XCTAssertNotNil(error.userNotice, "\(error)")
        }
    }

    func testNoticesHaveNoExclamationMarks() {
        for error in everyError {
            XCTAssertFalse((error.userNotice ?? "").contains("!"), "\(error)")
        }
    }

    func testNoticesAvoidBannedWords() {
        for error in everyError {
            let lower = (error.userNotice ?? "").lowercased()
            for word in banned {
                XCTAssertFalse(lower.contains(word), "\(error) contains \"\(word)\"")
            }
        }
    }

    func testNoticesAreTwoSentencesAtMost() {
        for error in everyError {
            guard let notice = error.userNotice else { continue }
            let n = sentenceCount(notice)
            XCTAssertTrue(n >= 1 && n <= 2, "\(error) has \(n) sentences: \(notice)")
        }
    }

    func testNoticesSayWhatHappenedToTheText() {
        for error in everyError {
            guard let notice = error.userNotice else { continue }
            XCTAssertTrue(notice.contains("raw transcript was inserted"), "\(error): \(notice)")
        }
    }

    func testNoticesAreShortEnoughForAMenuLine() {
        for error in everyError {
            XCTAssertTrue((error.userNotice ?? "").count <= 120, "\(error)")
        }
    }

    func testUnreachableFailuresUseTheVerbatimGuideCopy() {
        let verbatim = "Couldn't reach the rewrite service. Your raw transcript was inserted instead — nothing was lost."
        for error in [RewriteError.unreachable, .unavailable, .timedOut] {
            XCTAssertEqual(error.userNotice, verbatim, "\(error)")
        }
    }

    func testAnswersWeCouldNotUseDoNotClaimTheServiceWasUnreachable() {
        let unusable = "The rewrite service sent back something unusable. Your raw transcript was inserted instead."
        for error in [RewriteError.invalidResponse, .unexpectedStatus(302), .unexpectedStatus(418), .unexpectedStatus(500)] {
            XCTAssertEqual(error.userNotice, unusable, "\(error)")
            XCTAssertFalse((error.userNotice ?? "").contains("reach"), "\(error)")
        }
    }

    func testOnlyErrorsThatMeanNoConnectionMentionReaching() {
        for error in everyError {
            guard let notice = error.userNotice else { continue }
            let mentionsReaching = notice.contains("reach the rewrite service")
            let expected = [RewriteError.unreachable, .unavailable, .timedOut].contains(error)
            XCTAssertEqual(mentionsReaching, expected, "\(error)")
        }
    }

    func testTheSwitchedAppsNoticePassesTheSameLint() {
        let notice = DictationNotice.switchedApps
        XCTAssertFalse(notice.contains("!"))
        for word in banned {
            XCTAssertFalse(notice.lowercased().contains(word), word)
        }
        XCTAssertTrue(sentenceCount(notice) >= 1 && sentenceCount(notice) <= 2)
        XCTAssertTrue(notice.contains("clipboard"))
        XCTAssertTrue(notice.count <= 120)
    }

    func testSignedOutErrorsShareOneNotice() {
        XCTAssertEqual(RewriteError.unauthorized.userNotice, RewriteError.notAuthenticated.userNotice)
        XCTAssertTrue(RewriteError.unauthorized.userNotice?.contains("Sign in to keep using rewrite") ?? false)
        XCTAssertTrue(RewriteError.unauthorized.userNotice?.hasPrefix("You're signed out.") ?? false)
    }

    func testEachSpecificCaseNamesItsReason() {
        XCTAssertTrue(RewriteError.offline.userNotice?.contains("connection") ?? false)
        XCTAssertTrue(RewriteError.requiresPro.userNotice?.contains("Pro") ?? false)
        XCTAssertTrue(RewriteError.rateLimited.userNotice?.contains("limit") ?? false)
        XCTAssertTrue(RewriteError.tooLong.userNotice?.contains("too long") ?? false)
    }

    func testDistinctReasonsGetDistinctNotices() {
        let notices = [RewriteError.offline, .requiresPro, .rateLimited, .tooLong, .unauthorized, .unreachable]
            .compactMap { $0.userNotice }
        XCTAssertEqual(Set(notices).count, notices.count)
    }
}
