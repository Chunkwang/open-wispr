import XCTest
@testable import OpenWisprLib

/// The copy lint for the sign-in window (docs/design/sign-in-copy.md, section 7),
/// plus a check that `SignInCopy` has exactly the keys, and texts, of the copy doc.
final class SignInCopyTests: XCTestCase {
    private let sampleEmail = "sam@example.com"
    private let waits = [1, 2, 30, 60, 120, 121, 3600]
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private typealias Entry = (key: String, text: String)

    /// Messages: a full sentence or two that ends with a full stop.
    private var messages: [Entry] {
        var list: [Entry] = [
            ("emailPrompt", SignInCopy.emailPrompt),
            ("codeSentTo(email)", SignInCopy.codeSentTo(sampleEmail)),
            ("codePrompt", SignInCopy.codePrompt),
            ("signedIn", SignInCopy.signedIn),
            ("signedOut", SignInCopy.signedOut),
            ("signOutSignedOutNotice", SignInCopy.signOutSignedOutNotice),
            ("invalidEmail", SignInCopy.invalidEmail),
            ("codeRejected", SignInCopy.codeRejected),
            ("codeExpiredLocal", SignInCopy.codeExpiredLocal),
            ("offline", SignInCopy.offline),
            ("timedOut", SignInCopy.timedOut),
            ("serviceDown", SignInCopy.serviceDown),
            ("storageFailed", SignInCopy.storageFailed),
            ("signOutFailed", SignInCopy.signOutFailed),
            ("sessionRevoked", SignInCopy.sessionRevoked),
            ("emailPrivacyNote", SignInCopy.emailPrivacyNote),
            ("signedInAs(email)", SignInCopy.signedInAs(sampleEmail)),
            ("lockoutEnded", SignInCopy.lockoutEnded),
            ("resendReady", SignInCopy.resendReady),
            ("vo.emailField.hint", SignInCopy.voEmailFieldHint),
            ("vo.sendCode.hint", SignInCopy.voSendCodeHint),
            ("vo.codeField.hint", SignInCopy.voCodeFieldHint),
            ("vo.signIn.hint", SignInCopy.voSignInHint),
            ("vo.resend.hint", SignInCopy.voResendHint),
            ("vo.changeEmail.hint", SignInCopy.voChangeEmailHint),
            ("vo.haveCode.hint", SignInCopy.voHaveCodeHint),
            ("vo.done.hint", SignInCopy.voDoneHint),
            ("vo.retrySave.hint", SignInCopy.voRetrySaveHint),
        ]
        for wait in waits {
            list.append(("tooManyAttempts(waitSeconds)@\(wait)", SignInCopy.tooManyAttempts(waitSeconds: wait)))
            list.append(("resendCooldown(waitSeconds)@\(wait)", SignInCopy.resendCooldown(waitSeconds: wait)))
        }
        return list
    }

    /// Labels: buttons, field labels, menu titles, progress text. No full stop.
    private var labels: [Entry] {
        [
            ("windowTitle", SignInCopy.windowTitle),
            ("sendingCode", SignInCopy.sendingCode),
            ("verifyingCode", SignInCopy.verifyingCode),
            ("savingSession", SignInCopy.savingSession),
            ("emailFieldLabel", SignInCopy.emailFieldLabel),
            ("emailPlaceholder", SignInCopy.emailPlaceholder),
            ("codeFieldLabel", SignInCopy.codeFieldLabel),
            ("codePlaceholder", SignInCopy.codePlaceholder),
            ("sendCodeButton", SignInCopy.sendCodeButton),
            ("signInButton", SignInCopy.signInButton),
            ("resendCodeButton", SignInCopy.resendCodeButton),
            ("changeEmailButton", SignInCopy.changeEmailButton),
            ("haveCodeButton", SignInCopy.haveCodeButton),
            ("doneButton", SignInCopy.doneButton),
            ("retrySaveButton", SignInCopy.retrySaveButton),
            ("menuSignIn", SignInCopy.menuSignIn),
            ("menuSignedInAs(email)", SignInCopy.menuSignedInAs(sampleEmail)),
            ("menuSignOut", SignInCopy.menuSignOut),
            ("menuSignInUnavailable", SignInCopy.menuSignInUnavailable),
            ("vo.errorPrefix", SignInCopy.voErrorPrefix),
            ("vo.statusPrefix", SignInCopy.voStatusPrefix),
        ]
    }

    private var everything: [Entry] { messages + labels }

    // MARK: - Rules for every string

    func testNoExclamationMarks() {
        for (key, text) in everything { XCTAssertFalse(text.contains("!"), key) }
    }

    func testNoBannedWords() {
        for (key, text) in everything {
            for word in CopyLint.banned { XCTAssertFalse(text.lowercased().contains(word), "\(key) contains \(word)") }
        }
    }

    func testNothingHintsWhetherAnAccountExists() {
        let words = ["account", "register", "sign up", "signup", "exist", "not found", "no user"]
        for (key, text) in everything {
            for word in words { XCTAssertFalse(text.lowercased().contains(word), "\(key) contains \(word)") }
        }
    }

    func testNoCodeSizedNumbersAndNoLinks() {
        let longDigits = try! NSRegularExpression(pattern: "[0-9]{6,}")
        for (key, text) in everything {
            XCTAssertNil(longDigits.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), key)
            XCTAssertFalse(text.lowercased().contains("http"), key)
        }
    }

    func testNoStrayWhitespaceOrNewlines() {
        for (key, text) in everything {
            XCTAssertFalse(text.isEmpty, key)
            XCTAssertEqual(text, text.trimmingCharacters(in: .whitespacesAndNewlines), key)
            XCTAssertFalse(text.contains("  "), key)
            XCTAssertFalse(text.contains("\n"), key)
        }
    }

    func testEllipsisIsTheSingleCharacter() {
        for (key, text) in everything { XCTAssertFalse(text.contains("..."), key) }
        XCTAssertTrue(SignInCopy.menuSignIn.hasSuffix("\u{2026}"))
        XCTAssertTrue(SignInCopy.sendingCode.hasSuffix("\u{2026}"))
    }

    // MARK: - Messages

    func testMessagesAreOneOrTwoSentencesEndingInAFullStop() {
        for (key, text) in messages {
            let n = CopyLint.sentenceCount(text)
            XCTAssertTrue(n >= 1 && n <= 2, "\(key) has \(n) sentences: \(text)")
            XCTAssertTrue(text.hasSuffix("."), key)
        }
    }

    func testMessagesFitOnOneMenuLine() {
        for (key, text) in messages { XCTAssertTrue(text.count <= 120, "\(key): \(text.count)") }
    }

    func testOnlyTheEmailStringsRenderTheAddress() {
        let allowed: Set<String> = ["codeSentTo(email)", "signedInAs(email)", "menuSignedInAs(email)"]
        for (key, text) in everything where text.contains(sampleEmail) {
            XCTAssertTrue(allowed.contains(key), key)
        }
        for key in allowed { XCTAssertTrue(everything.contains { $0.key == key && $0.text.contains(sampleEmail) }, key) }
    }

    // MARK: - Labels

    func testLabelsAreShortAndHaveNoFullStop() {
        for (key, text) in labels {
            XCTAssertTrue(text.count <= 30, "\(key): \(text.count)")
            // No full stop ending a sentence (a dot inside an address is fine).
            XCTAssertEqual(CopyLint.sentenceCount(text), 0, key)
            XCTAssertFalse(text.hasSuffix("."), key)
        }
    }

    // MARK: - Specific behaviours

    func testTheCodeLifetimeInTheCopyIsTheOneThatDrivesTheTimer() {
        XCTAssertTrue(SignInCopy.codeSentTo(sampleEmail).contains("\(SignInTimings.codeLifetimeSeconds / 60) minutes"))
        XCTAssertEqual(SignInTimings.codeLifetimeSeconds, 600)
    }

    func testSecondsPhrase() {
        XCTAssertEqual(SignInCopy.secondsPhrase(1), "1 second")
        XCTAssertEqual(SignInCopy.secondsPhrase(2), "2 seconds")
        XCTAssertEqual(SignInCopy.secondsPhrase(30), "30 seconds")
        XCTAssertEqual(SignInCopy.secondsPhrase(120), "120 seconds")
        XCTAssertEqual(SignInCopy.secondsPhrase(121), "3 minutes")
        XCTAssertEqual(SignInCopy.secondsPhrase(180), "3 minutes")
        XCTAssertEqual(SignInCopy.secondsPhrase(3600), "60 minutes")
        XCTAssertEqual(SignInCopy.secondsPhrase(0), "1 second")
        XCTAssertEqual(SignInCopy.secondsPhrase(-5), "1 second")
    }

    func testDistinctReasonsGetDistinctText() {
        let texts = [
            SignInCopy.offline, SignInCopy.timedOut, SignInCopy.serviceDown, SignInCopy.invalidEmail,
            SignInCopy.codeRejected, SignInCopy.codeExpiredLocal, SignInCopy.tooManyAttempts(waitSeconds: 30),
            SignInCopy.resendCooldown(waitSeconds: 30), SignInCopy.storageFailed,
        ]
        XCTAssertEqual(Set(texts).count, texts.count)
    }

    func testNothingClaimsTheServiceWasUnreachable() {
        for (key, text) in messages { XCTAssertFalse(text.lowercased().contains("reach"), key) }
    }

    func testWrongAndExpiredCodesShareOneServerFacingString() {
        // The server cannot tell them apart, so neither does the client: a rejected
        // code is always `codeRejected`; only the local timer says "expired".
        XCTAssertEqual(SignInCopy.message(for: .codeRejected, phase: .verify, now: now), SignInCopy.codeRejected)
        XCTAssertTrue(SignInCopy.codeRejected.contains("wrong or has expired"))
        XCTAssertNotEqual(SignInCopy.codeRejected, SignInCopy.codeExpiredLocal)
    }

    // MARK: - AuthError mapping

    /// No `default`: a new `AuthError` case fails to compile here until the list,
    /// and therefore the mapping test below, covers it.
    private func representative(of error: AuthError) -> AuthError {
        switch error {
        case .invalidEmail, .codeRejected, .offline, .timedOut, .cancelled, .unreachable, .unavailable,
             .invalidResponse, .sessionRevoked, .storageFailed:
            return error
        case .tooManyAttempts: return .tooManyAttempts(retryAfter: 45)
        case .sendRateLimited: return .sendRateLimited(retryAfter: 45)
        }
    }

    private var everyError: [AuthError] {
        let all: [AuthError] = [
            .invalidEmail, .codeRejected, .tooManyAttempts(retryAfter: 45), .sendRateLimited(retryAfter: 45),
            .offline, .timedOut, .cancelled, .unreachable, .unavailable, .invalidResponse, .sessionRevoked, .storageFailed,
        ]
        return all.map(representative(of:))
    }

    func testEveryAuthErrorHasCopyExceptCancelled() {
        for error in everyError {
            for phase in [SignInPhase.send, .verify] {
                let message = SignInCopy.message(for: error, phase: phase, now: now)
                if error == .cancelled {
                    XCTAssertNil(message)
                } else {
                    XCTAssertNotNil(message, "\(error) \(phase)")
                    XCTAssertTrue(messages.contains { $0.text == message }
                        || message == SignInCopy.tooManyAttempts(waitSeconds: 45)
                        || message == SignInCopy.resendCooldown(waitSeconds: 45), "\(error) \(phase): \(message ?? "")")
                }
            }
        }
    }

    func testServiceProblemsAllUseTheSameString() {
        for error in [AuthError.unreachable, .unavailable, .invalidResponse] {
            for phase in [SignInPhase.send, .verify] {
                XCTAssertEqual(SignInCopy.message(for: error, phase: phase, now: now), SignInCopy.serviceDown, "\(error)")
            }
        }
    }

    func testRateLimitsShowTheServersWait() {
        XCTAssertEqual(SignInCopy.message(for: .tooManyAttempts(retryAfter: 45), phase: .verify, now: now), SignInCopy.tooManyAttempts(waitSeconds: 45))
        XCTAssertEqual(SignInCopy.message(for: .sendRateLimited(retryAfter: 45), phase: .send, now: now), SignInCopy.resendCooldown(waitSeconds: 45))
        XCTAssertEqual(SignInCopy.message(for: .sendRateLimited(retryAfter: 3600), phase: .send, now: now), SignInCopy.resendCooldown(waitSeconds: 3600))
    }

    // MARK: - Menu titles

    func testTruncatedMiddle() {
        XCTAssertEqual(SignInCopy.truncatedMiddle("short@example.com", limit: 40), "short@example.com")
        let long = String(repeating: "a", count: 60) + "@example.com"
        let cut = SignInCopy.truncatedMiddle(long, limit: 40)
        XCTAssertEqual(cut.count, 40)
        XCTAssertTrue(cut.contains("\u{2026}"))
        XCTAssertTrue(cut.hasSuffix("@example.com".suffix(19)))
        XCTAssertTrue(SignInCopy.menuSignedInAs(long).hasPrefix("Signed in as aaa"))
    }

    // MARK: - Same keys and texts as the copy doc

    private struct DocEntry { let key: String; let text: String }

    private func copyDocEntries() throws -> [DocEntry] {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/design/sign-in-copy.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"^\| `([^`]+)` \| `([^`]+)` \|"#, options: [.anchorsMatchLines])
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let k = Range(match.range(at: 1), in: text), let t = Range(match.range(at: 2), in: text) else { return nil }
            return DocEntry(key: String(text[k]), text: String(text[t]))
        }
    }

    func testCopyHasEveryKeyOfTheCopyDocWithTheSameText() throws {
        let doc = try copyDocEntries()
        XCTAssertEqual(doc.count, 51, "the copy doc lists 51 strings")

        // The doc text with its placeholders filled the same way the code does.
        func rendered(_ raw: String) -> String {
            raw.replacingOccurrences(of: "\\(email)", with: sampleEmail).replacingOccurrences(of: "\\(secs)", with: "30 seconds")
        }
        var ours: [String: String] = [:]
        for (key, text) in everything where !key.contains("@") { ours[key] = text }
        ours["tooManyAttempts(waitSeconds)"] = SignInCopy.tooManyAttempts(waitSeconds: 30)
        ours["resendCooldown(waitSeconds)"] = SignInCopy.resendCooldown(waitSeconds: 30)

        for entry in doc {
            XCTAssertEqual(ours[entry.key], rendered(entry.text), entry.key)
        }
        XCTAssertEqual(Set(doc.map { $0.key }), Set(ours.keys), "keys in the doc and in SignInCopy differ")
    }
}
