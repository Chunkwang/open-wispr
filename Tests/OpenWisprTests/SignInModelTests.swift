import XCTest
@testable import OpenWisprLib

/// The sign-in state machine (docs/design/sign-in.md, section 10), driven with an
/// explicit clock: advancing 600 s costs nothing.
final class SignInModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let address = "sam@example.com"
    private let session = AuthSession(
        accessToken: "access-value", refreshToken: "refresh-value",
        expiresAt: Date(timeIntervalSince1970: 1_790_003_600), email: "sam@example.com"
    )

    private var model = SignInModel()
    private var now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        model = SignInModel()
        now = t0
    }

    // MARK: - Helpers

    @discardableResult
    private func send(_ event: SignInEvent) -> [SignInEffect] {
        model.handle(event, now: now)
    }

    private func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    private func requestedGeneration(_ effects: [SignInEffect]) -> Int? {
        for case .requestCode(_, let generation) in effects { return generation }
        return nil
    }

    private func verifyGeneration(_ effects: [SignInEffect]) -> Int? {
        for case .verifyCode(_, _, let generation) in effects { return generation }
        return nil
    }

    private func requestCount(_ effects: [SignInEffect]) -> Int {
        effects.filter { if case .requestCode = $0 { return true } else { return false } }.count
    }

    private func verifyCount(_ effects: [SignInEffect]) -> Int {
        effects.filter { if case .verifyCode = $0 { return true } else { return false } }.count
    }

    /// Email step to code step: types the address, sends, and gets the code sent.
    private func reachCodeEntry(email: String? = nil) {
        send(.emailEdited(email ?? address))
        let gen = requestedGeneration(send(.submitEmail))!
        send(.sendSucceeded(generation: gen))
        XCTAssertEqual(model.state, .codeEntry)
    }

    /// Types `digits`, submits, and returns the verify generation.
    @discardableResult
    private func submitCode(_ digits: String = "123456") -> Int? {
        send(.codeEdited(digits))
        return verifyGeneration(send(.submitCode))
    }

    private func announcements(_ effects: [SignInEffect]) -> [String] {
        effects.compactMap { if case .announce(let text, _) = $0 { return text } else { return nil } }
    }

    // MARK: - Test 1: send

    func testValidAddressSendsOneRequestAndStampsTheRequestTime() {
        send(.emailEdited(address))
        XCTAssertEqual(model.state, .emailEntry)
        let effects = send(.submitEmail)
        XCTAssertEqual(model.state, .sendingCode(.email))
        XCTAssertEqual(requestCount(effects), 1)
        XCTAssertEqual(effects.first, .requestCode(email: address, generation: model.generation))

        advance(3)
        let done = send(.sendSucceeded(generation: model.generation))
        XCTAssertEqual(model.state, .codeEntry)
        // The request start, not the response: the client expires slightly early.
        XCTAssertEqual(model.codeSentAt, t0)
        XCTAssertEqual(model.resendAvailableAt, t0.addingTimeInterval(63))
        XCTAssertEqual(model.resendEmail, address)
        XCTAssertTrue(done.contains(.focus(.code(selectAll: false))))
        XCTAssertEqual(announcements(done), [SignInCopy.codeSentTo(address)])
    }

    // MARK: - Test 2: invalid addresses

    func testInvalidAddressesNeverSendARequest() {
        for bad in ["nosign", "a@@b.co", "a@b@c.co", "a b@c.co", "a@", "@a", "a\u{7}@b.co", "a\u{A0}@b.co", "a\t@b.co"] {
            setUp()
            send(.emailEdited(bad))
            let effects = send(.submitEmail)
            XCTAssertEqual(requestCount(effects), 0, bad)
            XCTAssertEqual(model.state, .emailEntry, bad)
            XCTAssertEqual(model.status, .invalidEmail, bad)
            XCTAssertEqual(announcements(effects), ["\(SignInCopy.voErrorPrefix): \(SignInCopy.invalidEmail)"], bad)
        }
    }

    func testTheLocalEmailCheck() {
        XCTAssertTrue(SignInModel.isPlausibleEmail("a@b"))
        XCTAssertTrue(SignInModel.isPlausibleEmail("  sam@example.com \n"))
        XCTAssertTrue(SignInModel.isPlausibleEmail(String(repeating: "x", count: 248) + "@b.com"))     // 254
        XCTAssertFalse(SignInModel.isPlausibleEmail(String(repeating: "x", count: 249) + "@b.com"))    // 255
        XCTAssertFalse(SignInModel.isPlausibleEmail(""))
        XCTAssertFalse(SignInModel.isPlausibleEmail("   "))
    }

    func testEditingTrimsAndCapsTheAddressAndEmptyStaysDisabled() {
        send(.emailEdited("  sam@example.com \n"))
        XCTAssertEqual(model.email, address)
        XCTAssertTrue(model.canSendCode(now: now))
        send(.emailEdited(String(repeating: "x", count: 300)))
        XCTAssertEqual(model.email.count, 254)
        send(.emailEdited("   "))
        XCTAssertFalse(model.canSendCode(now: now))
        let effects = send(.submitEmail)
        XCTAssertEqual(effects, [])
        XCTAssertNil(model.status)
        XCTAssertEqual(model.state, .emailEntry)
    }

    func testEditingClearsTheInvalidEmailMessage() {
        send(.emailEdited("nope"))
        send(.submitEmail)
        XCTAssertEqual(model.statusRow(now: now), .invalidEmail)
        send(.emailEdited("nope@"))
        XCTAssertNil(model.statusRow(now: now))
    }

    // MARK: - Test 3: digit filter

    func testDigitFilter() {
        XCTAssertEqual(SignInModel.filterDigits("123 456"), "123456")
        XCTAssertEqual(SignInModel.filterDigits("123-456"), "123456")
        XCTAssertEqual(SignInModel.filterDigits("12a3456"), "123456")
        XCTAssertEqual(SignInModel.filterDigits("123456789012"), "1234567890")
        XCTAssertEqual(SignInModel.filterDigits("123\u{A0}456"), "123456")
        XCTAssertEqual(SignInModel.filterDigits("123\u{2013}456\u{2011}7"), "1234567")
        XCTAssertEqual(SignInModel.filterDigits("\u{FF11}\u{FF12}\u{FF13}456"), "456")   // full-width digits
        XCTAssertEqual(SignInModel.filterDigits(" \n\t"), "")
    }

    func testTypedAndPastedCodesGoThroughTheFilter() {
        reachCodeEntry()
        send(.codeEdited("123 456"))
        XCTAssertEqual(model.digits, "123456")
        send(.codeEdited("12a3-4x56 78901234"))
        XCTAssertEqual(model.digits, "1234567890")
    }

    // MARK: - Test 4: submit guards

    func testSubmitDoesNothingWithFiveDigitsAndSubmitsFromSix() {
        reachCodeEntry()
        send(.codeEdited("12345"))
        XCTAssertFalse(model.canSubmitCode(now: now))
        XCTAssertEqual(send(.submitCode), [])
        XCTAssertEqual(model.state, .codeEntry)

        send(.codeEdited("123456"))
        XCTAssertTrue(model.canSubmitCode(now: now))
        XCTAssertEqual(verifyCount(send(.submitCode)), 1)
        XCTAssertEqual(model.state, .verifying)
    }

    func testSevenToTenDigitsAlsoSubmit() {
        for digits in ["1234567", "12345678", "123456789", "1234567890"] {
            setUp()
            reachCodeEntry()
            XCTAssertNotNil(submitCode(digits), digits)
        }
    }

    // MARK: - Test 5: five wrong tries

    func testFourWrongCodesShowTheMessageAndTheFifthLocksFor30Seconds() {
        reachCodeEntry()
        for attempt in 1...4 {
            let gen = submitCode()!
            advance(1)
            let effects = send(.verifyFailed(.codeRejected, generation: gen))
            XCTAssertEqual(model.state, .codeEntry)
            XCTAssertEqual(model.attempts, attempt)
            XCTAssertEqual(model.statusRow(now: now), .codeRejected)
            XCTAssertTrue(effects.contains(.focus(.code(selectAll: true))))
            XCTAssertEqual(model.digits, "123456", "the digits stay, selected")
            XCTAssertTrue(model.canSubmitCode(now: now))
        }
        let gen = submitCode()!
        advance(1)
        let lockStart = now
        let effects = send(.verifyFailed(.codeRejected, generation: gen))
        XCTAssertEqual(model.attempts, 5)
        XCTAssertEqual(model.lockedUntil, lockStart.addingTimeInterval(30))
        XCTAssertEqual(model.statusRow(now: now), .tooManyAttempts(until: lockStart.addingTimeInterval(30)))
        XCTAssertEqual(announcements(effects), ["\(SignInCopy.voErrorPrefix): \(SignInCopy.tooManyAttempts(waitSeconds: 30))"])
        XCTAssertFalse(model.canSubmitCode(now: now))

        // During the lockout: nothing is sent, even with six digits.
        advance(10)
        send(.codeEdited("654321"))
        XCTAssertEqual(send(.submitCode), [])
        XCTAssertEqual(model.state, .codeEntry)
        XCTAssertEqual(model.statusRow(now: now), .tooManyAttempts(until: lockStart.addingTimeInterval(30)),
                       "editing the digits does not hide the lockout")

        // 29 s in: still locked. 30 s in: the tick lifts it and resets the counter.
        now = lockStart.addingTimeInterval(29)
        XCTAssertFalse(announcements(send(.tick)).contains(SignInCopy.lockoutEnded))
        XCTAssertTrue(model.isLockedOut(now: now))
        now = lockStart.addingTimeInterval(30)
        let ended = send(.tick)
        XCTAssertTrue(announcements(ended).contains(SignInCopy.lockoutEnded))
        XCTAssertNil(model.lockedUntil)
        XCTAssertEqual(model.attempts, 0)
        XCTAssertNil(model.statusRow(now: now))
        XCTAssertTrue(model.canSubmitCode(now: now))
        XCTAssertEqual(verifyCount(send(.submitCode)), 1)
    }

    func testTransientFailuresDoNotCountAsWrongTries() {
        reachCodeEntry()
        for _ in 0..<6 {
            let gen = submitCode()!
            send(.verifyFailed(.offline, generation: gen))
        }
        XCTAssertEqual(model.attempts, 0)
        XCTAssertFalse(model.isLockedOut(now: now))
    }

    func testANewCodeResetsTheCounterAndTheLockout() {
        reachCodeEntry()
        for _ in 0..<5 { send(.verifyFailed(.codeRejected, generation: submitCode()!)) }
        XCTAssertTrue(model.isLockedOut(now: now))
        advance(61)
        let gen = requestedGeneration(send(.resendTapped))!
        XCTAssertEqual(model.state, .sendingCode(.resend))
        send(.sendSucceeded(generation: gen))
        XCTAssertEqual(model.attempts, 0)
        XCTAssertNil(model.lockedUntil)
        XCTAssertNil(model.statusRow(now: now))
        XCTAssertEqual(model.digits, "")
    }

    // MARK: - Test 6: server lockout

    func testServerRateLimitOnVerifyLocksForItsWait() {
        reachCodeEntry()
        advance(5)
        send(.verifyFailed(.tooManyAttempts(retryAfter: 45), generation: submitCode()!))
        XCTAssertEqual(model.lockedUntil, now.addingTimeInterval(45))
        XCTAssertEqual(model.attempts, 0, "a server limit is not a wrong try")
        XCTAssertFalse(model.canSubmitCode(now: now))
    }

    func testServerRateLimitWithoutRetryAfterLocksForSixtySeconds() {
        reachCodeEntry()
        // AuthService replaces a missing Retry-After with AuthError.defaultRetryAfter.
        send(.verifyFailed(.tooManyAttempts(retryAfter: AuthError.defaultRetryAfter), generation: submitCode()!))
        XCTAssertEqual(model.lockedUntil, now.addingTimeInterval(60))
    }

    func testWaitSecondsRoundsUpAndIsBounded() {
        XCTAssertEqual(SignInModel.waitSeconds(0), 1)
        XCTAssertEqual(SignInModel.waitSeconds(-4), 1)
        XCTAssertEqual(SignInModel.waitSeconds(0.2), 1)
        XCTAssertEqual(SignInModel.waitSeconds(29.1), 30)
        XCTAssertEqual(SignInModel.waitSeconds(.nan), 60)
        XCTAssertEqual(SignInModel.waitSeconds(.infinity), 60)
        XCTAssertEqual(SignInModel.waitSeconds(1e12), SignInTimings.maxWaitSeconds)
    }

    // MARK: - Test 7: local expiry

    func testAWrongCodeAfterTenMinutesIsExpiredNotRejected() {
        reachCodeEntry()
        send(.codeEdited("123456"))
        advance(599)
        let gen = verifyGeneration(send(.submitCode))!
        advance(2)                                          // the answer arrives at 601 s
        let effects = send(.verifyFailed(.codeRejected, generation: gen))
        XCTAssertEqual(model.statusRow(now: now), .codeExpiredLocal)
        XCTAssertEqual(model.attempts, 0, "an expired code is not a wrong try")
        XCTAssertEqual(announcements(effects), ["\(SignInCopy.voErrorPrefix): \(SignInCopy.codeExpiredLocal)"])
    }

    func testSubmitAfterTenMinutesSendsNothing() {
        reachCodeEntry()
        send(.codeEdited("123456"))
        now = t0.addingTimeInterval(600)
        XCTAssertFalse(model.canSubmitCode(now: now))
        let effects = send(.submitCode)
        XCTAssertEqual(verifyCount(effects), 0)
        XCTAssertEqual(model.state, .codeEntry)
        XCTAssertEqual(model.status, .codeExpiredLocal)
        XCTAssertEqual(announcements(effects), ["\(SignInCopy.voErrorPrefix): \(SignInCopy.codeExpiredLocal)"])
    }

    func testOneSecondBeforeExpiryStillSubmits() {
        reachCodeEntry()
        now = t0.addingTimeInterval(599)
        XCTAssertNotNil(submitCode())
    }

    // MARK: - Test 8: tick

    func testTickAtTenMinutesExpiresAnIdleCodeAndAnnouncesOnce() {
        reachCodeEntry()
        now = t0.addingTimeInterval(60)
        XCTAssertEqual(announcements(send(.tick)), [SignInCopy.resendReady])
        now = t0.addingTimeInterval(599)
        XCTAssertEqual(announcements(send(.tick)), [])
        XCTAssertNil(model.status)
        now = t0.addingTimeInterval(600)
        let effects = send(.tick)
        XCTAssertEqual(model.status, .codeExpiredLocal)
        XCTAssertEqual(announcements(effects).count, 1)
        advance(1)
        XCTAssertEqual(announcements(send(.tick)), [], "no repeat announcement")
    }

    func testTickDoesNotExpireWhileVerifyingButTheAnswerDoes() {
        reachCodeEntry()
        now = t0.addingTimeInterval(599)
        let gen = submitCode()!
        now = t0.addingTimeInterval(601)
        send(.tick)
        XCTAssertNil(model.status, "busy states are never changed by a tick")
        XCTAssertEqual(model.state, .verifying)
        send(.verifyFailed(.offline, generation: gen))
        XCTAssertEqual(model.state, .codeEntry)
        send(.tick)
        XCTAssertEqual(model.status, .codeExpiredLocal, "applied on the first tick after the request ends")
    }

    func testAnExpiredCodeTurnsThePrimaryIntoSendANewCode() {
        reachCodeEntry()
        send(.codeEdited("123456"))
        now = t0.addingTimeInterval(601)
        XCTAssertTrue(model.isCodeExpired(now: now))
        XCTAssertFalse(model.canSubmitCode(now: now), "typing does not bring Sign in back")
        XCTAssertTrue(model.canResend(now: now))
        XCTAssertEqual(requestCount(send(.resendTapped)), 1)
    }

    func testLockoutWinsOverExpiryInTheStatusRow() {
        reachCodeEntry()
        send(.verifyFailed(.tooManyAttempts(retryAfter: 700), generation: submitCode()!))
        now = t0.addingTimeInterval(601)
        guard case .tooManyAttempts = model.statusRow(now: now) else { return XCTFail("\(String(describing: model.statusRow(now: now)))") }
        now = t0.addingTimeInterval(701)
        send(.tick)
        XCTAssertEqual(model.statusRow(now: now), .codeExpiredLocal)
    }

    // MARK: - Test 9: transient failures

    func testTransientVerifyFailuresChangeNothingButTheMessage() {
        let cases: [(AuthError, SignInStatus)] = [
            (.offline, .offline), (.timedOut, .timedOut), (.unavailable, .serviceDown), (.unreachable, .serviceDown),
            (.invalidResponse, .serviceDown), (.invalidEmail, .serviceDown), (.sendRateLimited(retryAfter: 60), .serviceDown),
        ]
        for (error, expected) in cases {
            setUp()
            reachCodeEntry()
            let sentAt = model.codeSentAt
            let resendAt = model.resendAvailableAt
            let gen = submitCode()!
            let effects = send(.verifyFailed(error, generation: gen))
            XCTAssertEqual(model.state, .codeEntry, "\(error)")
            XCTAssertEqual(model.status, expected, "\(error)")
            XCTAssertEqual(model.attempts, 0, "\(error)")
            XCTAssertEqual(model.digits, "123456", "\(error)")
            XCTAssertEqual(model.codeSentAt, sentAt, "\(error)")
            XCTAssertEqual(model.resendAvailableAt, resendAt, "\(error)")
            XCTAssertNil(model.lockedUntil, "\(error)")
            XCTAssertEqual(announcements(effects).count, 1, "\(error)")
        }
    }

    func testEditingTheDigitsClearsATransportOrRejectedMessageButNotALockoutOrExpiry() {
        reachCodeEntry()
        send(.verifyFailed(.timedOut, generation: submitCode()!))
        send(.codeEdited("12345"))
        XCTAssertNil(model.status)

        send(.verifyFailed(.codeRejected, generation: submitCode("123456")!))
        XCTAssertEqual(model.status, .codeRejected)
        send(.codeEdited("1"))
        XCTAssertNil(model.status)

        now = t0.addingTimeInterval(601)
        send(.tick)
        send(.codeEdited("123456"))
        XCTAssertEqual(model.status, .codeExpiredLocal)
    }

    func testACancelledRequestReturnsToTheIdleStepWithNoMessage() {
        send(.emailEdited(address))
        send(.sendFailed(.cancelled, generation: requestedGeneration(send(.submitEmail))!))
        XCTAssertEqual(model.state, .emailEntry)
        XCTAssertNil(model.statusRow(now: now))

        reachCodeEntry()
        send(.verifyFailed(.cancelled, generation: submitCode()!))
        XCTAssertEqual(model.state, .codeEntry)
        XCTAssertNil(model.status)
        XCTAssertEqual(model.attempts, 0)
    }

    // MARK: - Test 10: resend

    func testResendIsGuardedByTheCooldown() {
        reachCodeEntry()
        XCTAssertFalse(model.canResend(now: now))
        XCTAssertEqual(send(.resendTapped), [])
        XCTAssertEqual(model.state, .codeEntry)
        XCTAssertEqual(model.captionCooldownUntil(now: now), t0.addingTimeInterval(60))

        now = t0.addingTimeInterval(59)
        XCTAssertEqual(send(.resendTapped), [])
        now = t0.addingTimeInterval(60)
        XCTAssertNil(model.captionCooldownUntil(now: now))
        XCTAssertTrue(model.canResend(now: now))
        XCTAssertEqual(requestCount(send(.resendTapped)), 1)
    }

    func testResendSuccessStartsAFreshCodeTimerAndCooldown() {
        reachCodeEntry()
        send(.codeEdited("123456"))
        now = t0.addingTimeInterval(700)
        let gen = requestedGeneration(send(.resendTapped))!
        advance(2)
        send(.sendSucceeded(generation: gen))
        XCTAssertEqual(model.codeSentAt, t0.addingTimeInterval(700))
        XCTAssertEqual(model.resendAvailableAt, t0.addingTimeInterval(762))
        XCTAssertFalse(model.isCodeExpired(now: now))
        XCTAssertNil(model.status)
        XCTAssertEqual(model.digits, "")
    }

    func testResendRateLimitedKeepsTheOldCodeAndShowsTheCooldown() {
        reachCodeEntry()
        send(.codeEdited("123456"))
        now = t0.addingTimeInterval(61)
        let sentAt = model.codeSentAt
        let gen = requestedGeneration(send(.resendTapped))!
        send(.sendFailed(.sendRateLimited(retryAfter: 45), generation: gen))
        XCTAssertEqual(model.state, .codeEntry)
        XCTAssertEqual(model.resendAvailableAt, now.addingTimeInterval(45))
        XCTAssertEqual(model.captionCooldownUntil(now: now), now.addingTimeInterval(45))
        XCTAssertEqual(model.codeSentAt, sentAt)
        XCTAssertEqual(model.digits, "123456")
        XCTAssertNil(model.status)
        XCTAssertTrue(model.canSubmitCode(now: now), "the old code may still be valid")
    }

    func testAFailedResendStartsNoCooldownAndKeepsTheTimers() {
        reachCodeEntry()
        now = t0.addingTimeInterval(61)
        let resendAt = model.resendAvailableAt
        let sentAt = model.codeSentAt
        let gen = requestedGeneration(send(.resendTapped))!
        send(.sendFailed(.offline, generation: gen))
        XCTAssertEqual(model.state, .codeEntry)
        XCTAssertEqual(model.status, .offline)
        XCTAssertEqual(model.resendAvailableAt, resendAt, "no new cooldown from a failure")
        XCTAssertEqual(model.codeSentAt, sentAt)
        XCTAssertTrue(model.canResend(now: now), "the user can try again")
    }

    func testResendKeepsALockoutMessageButDropsAnOldTransportMessage() {
        reachCodeEntry()
        send(.verifyFailed(.tooManyAttempts(retryAfter: 700), generation: submitCode()!))
        now = t0.addingTimeInterval(61)                       // cooldown over, lockout not
        XCTAssertTrue(model.canResend(now: now))
        _ = send(.resendTapped)
        XCTAssertEqual(model.status, .tooManyAttempts(until: t0.addingTimeInterval(700)))
        send(.sendFailed(.offline, generation: model.generation))
        XCTAssertEqual(model.status, .offline, "a failed resend shows its own error")

        setUp()
        reachCodeEntry()
        send(.verifyFailed(.timedOut, generation: submitCode()!))
        now = t0.addingTimeInterval(61)
        _ = send(.resendTapped)
        XCTAssertNil(model.status, "an old transport message does not survive a resend")
    }

    func testResendReadyIsAnnouncedOnce() {
        reachCodeEntry()
        now = t0.addingTimeInterval(59)
        XCTAssertEqual(announcements(send(.tick)), [])
        now = t0.addingTimeInterval(60)
        XCTAssertEqual(announcements(send(.tick)), [SignInCopy.resendReady])
        advance(1)
        XCTAssertEqual(announcements(send(.tick)), [])
    }

    // MARK: - Test 11: rate-limited send on step 1

    func testRateLimitedSendShowsTheCooldownForThatAddressOnly() {
        send(.emailEdited(address))
        let gen = requestedGeneration(send(.submitEmail))!
        let effects = send(.sendFailed(.sendRateLimited(retryAfter: 45), generation: gen))
        XCTAssertEqual(model.state, .emailEntry)
        XCTAssertEqual(model.statusRow(now: now), .resendCooldown(until: t0.addingTimeInterval(45)))
        XCTAssertFalse(model.canSendCode(now: now))
        XCTAssertTrue(model.canOfferHaveCode(now: now))
        XCTAssertEqual(send(.submitEmail), [], "Send is disabled for this address")
        XCTAssertEqual(announcements(effects).count, 1)

        // Same address, different case: still limited.
        send(.emailEdited("SAM@example.com"))
        XCTAssertFalse(model.canSendCode(now: now))
        XCTAssertTrue(model.canOfferHaveCode(now: now))

        // A different address is not.
        send(.emailEdited("kim@example.com"))
        XCTAssertTrue(model.canSendCode(now: now))
        XCTAssertFalse(model.canOfferHaveCode(now: now))
        XCTAssertNil(model.statusRow(now: now))
        XCTAssertEqual(requestCount(send(.submitEmail)), 1)
    }

    func testTheCooldownNoteEndsWhenTheTimerDoes() {
        send(.emailEdited(address))
        send(.sendFailed(.sendRateLimited(retryAfter: 30), generation: requestedGeneration(send(.submitEmail))!))
        now = t0.addingTimeInterval(29)
        XCTAssertNotNil(model.statusRow(now: now))
        now = t0.addingTimeInterval(30)
        XCTAssertNil(model.statusRow(now: now))
        XCTAssertTrue(model.canSendCode(now: now))
        XCTAssertFalse(model.canOfferHaveCode(now: now))
    }

    func testIAlreadyHaveACodeEntersCodeEntry() {
        send(.emailEdited(address))
        send(.sendFailed(.tooManyAttempts(retryAfter: 45), generation: requestedGeneration(send(.submitEmail))!))
        let effects = send(.haveCodeTapped)
        XCTAssertEqual(model.state, .codeEntry)
        XCTAssertEqual(model.codeSentAt, now, "the send time is unknown: the server stays the authority")
        XCTAssertEqual(model.resendAvailableAt, t0.addingTimeInterval(45), "the cooldown is kept")
        XCTAssertEqual(model.digits, "")
        XCTAssertTrue(effects.contains(.focus(.code(selectAll: false))))
        XCTAssertNotNil(submitCode())
    }

    func testIAlreadyHaveACodeDoesNothingWithoutACooldown() {
        send(.emailEdited(address))
        XCTAssertEqual(send(.haveCodeTapped), [])
        XCTAssertEqual(model.state, .emailEntry)
    }

    func testAFailedSendOnTheEmailStepShowsTheErrorAndReturnsFocus() {
        send(.emailEdited(address))
        let effects = send(.sendFailed(.timedOut, generation: requestedGeneration(send(.submitEmail))!))
        XCTAssertEqual(model.statusRow(now: now), .timedOut)
        XCTAssertTrue(effects.contains(.focus(.email(selectAll: false))))
        XCTAssertNil(model.resendAvailableAt)
        XCTAssertTrue(model.canSendCode(now: now))
    }

    // MARK: - Test 12: change email

    func testChangeEmailKeepsTheCooldownForTheOldAddress() {
        reachCodeEntry()
        send(.codeEdited("123456"))
        for _ in 0..<2 { send(.verifyFailed(.codeRejected, generation: submitCode()!)) }
        let effects = send(.changeEmailTapped)
        XCTAssertEqual(model.state, .emailEntry)
        XCTAssertEqual(model.email, address, "pre-filled")
        XCTAssertTrue(effects.contains(.focus(.email(selectAll: true))))
        XCTAssertEqual(model.digits, "")
        XCTAssertEqual(model.attempts, 0)
        XCTAssertNil(model.lockedUntil)
        XCTAssertNil(model.status)

        // Sending to the same address inside the cooldown does not send a second email.
        XCTAssertFalse(model.canSendCode(now: now))
        XCTAssertEqual(send(.submitEmail), [])
        XCTAssertTrue(model.canOfferHaveCode(now: now))

        send(.emailEdited("kim@example.com"))
        XCTAssertTrue(model.canSendCode(now: now))
        XCTAssertEqual(requestCount(send(.submitEmail)), 1)
    }

    func testChangeEmailIsIgnoredWhileVerifying() {
        reachCodeEntry()
        _ = submitCode()
        XCTAssertEqual(send(.changeEmailTapped), [])
        XCTAssertEqual(model.state, .verifying)
    }

    // MARK: - Test 13: saving

    func testSuccessGoesThroughSavingToSignedIn() {
        reachCodeEntry()
        let gen = submitCode("123456")!
        let saving = send(.verifySucceeded(session, generation: gen))
        XCTAssertEqual(model.state, .saving)
        XCTAssertEqual(saving, [.storeSession(session)])

        let done = send(.saveSucceeded)
        XCTAssertEqual(model.state, .signedIn)
        XCTAssertEqual(model.signedInEmail, "sam@example.com")
        XCTAssertNil(model.pendingSession)
        XCTAssertEqual(model.digits, "")
        XCTAssertEqual(done, [
            .clearPasteboardIfItHoldsTheCode("123456"), .stopTimers, .focus(.done), .announce(SignInCopy.signedIn, .high),
        ])
    }

    func testTheSignedInScreenShowsTheAddressTheServerReports() {
        reachCodeEntry(email: "SAM@Example.com")
        let other = AuthSession(accessToken: "a", refreshToken: "r", expiresAt: t0, email: "sam@example.com")
        send(.verifySucceeded(other, generation: submitCode()!))
        send(.saveSucceeded)
        XCTAssertEqual(model.signedInEmail, "sam@example.com")
    }

    func testAKeychainFailureKeepsTheSessionForARetryWithoutANewCode() {
        reachCodeEntry()
        send(.verifySucceeded(session, generation: submitCode()!))
        let failed = send(.saveFailed)
        XCTAssertEqual(model.state, .saveFailed)
        XCTAssertEqual(model.pendingSession, session)
        XCTAssertEqual(failed, [.announce(SignInCopy.storageFailed, .high), .focus(.retry)])
        XCTAssertNotEqual(model.state, .signedIn, "the user is not signed in")

        // Retry fails again: same screen, no new announcement, still not signed in.
        XCTAssertEqual(send(.retrySaveTapped), [.storeSession(session)])
        XCTAssertEqual(model.state, .saving)
        XCTAssertEqual(send(.saveFailed), [])
        XCTAssertEqual(model.state, .saveFailed)

        // Retry works.
        send(.retrySaveTapped)
        let done = send(.saveSucceeded)
        XCTAssertEqual(model.state, .signedIn)
        XCTAssertTrue(done.contains(.clearPasteboardIfItHoldsTheCode("123456")))
        XCTAssertNil(model.pendingSession)
    }

    func testClosingTheFailureScreenLogsTheUnsavedSessionOutAndDropsIt() {
        reachCodeEntry()
        send(.verifySucceeded(session, generation: submitCode()!))
        send(.saveFailed)
        let effects = send(.closeRequested)
        XCTAssertEqual(effects, [.logoutBestEffort(session), .stopTimers, .closeWindow])
        XCTAssertEqual(model.state, .closed)
        XCTAssertNil(model.pendingSession)
    }

    func testRetryIsIgnoredOutsideTheFailureScreen() {
        reachCodeEntry()
        XCTAssertEqual(send(.retrySaveTapped), [])
        XCTAssertEqual(model.state, .codeEntry)
    }

    // MARK: - Test 14: closing

    func testALateSuccessAfterClosingIsNeverStored() {
        reachCodeEntry()
        let gen = submitCode()!
        let closing = send(.closeRequested)
        XCTAssertEqual(closing, [.stopTimers, .closeWindow])
        XCTAssertEqual(model.state, .closed)
        XCTAssertEqual(send(.verifySucceeded(session, generation: gen)), [])
        XCTAssertEqual(model.state, .closed)
        XCTAssertNil(model.pendingSession)
    }

    func testClosingDropsEverythingTheUserEntered() {
        reachCodeEntry()
        send(.codeEdited("123456"))
        send(.closeRequested)
        XCTAssertEqual(model.email, "")
        XCTAssertEqual(model.digits, "")
        XCTAssertEqual(model.attempts, 0)
        XCTAssertNil(model.codeSentAt)
        XCTAssertNil(model.resendAvailableAt)
        XCTAssertNil(model.lockedUntil)
    }

    func testCloseFromEveryStepClosesAndStopsTimers() {
        // Email, sending, code, verifying, signed in.
        var steps: [() -> Void] = []
        steps.append({})
        steps.append({ self.send(.emailEdited(self.address)); self.send(.submitEmail) })
        steps.append({ self.reachCodeEntry() })
        steps.append({ self.reachCodeEntry(); _ = self.submitCode() })
        steps.append({
            self.reachCodeEntry()
            self.send(.verifySucceeded(self.session, generation: self.submitCode()!))
            self.send(.saveSucceeded)
        })
        for step in steps {
            setUp()
            step()
            let effects = send(.closeRequested)
            XCTAssertEqual(model.state, .closed)
            XCTAssertTrue(effects.contains(.stopTimers))
            XCTAssertTrue(effects.contains(.closeWindow))
            XCTAssertEqual(send(.submitEmail), [], "closed ignores everything")
            XCTAssertEqual(send(.closeRequested), [], "closing twice does nothing")
        }
    }

    func testAStaleResultIsDropped() {
        send(.emailEdited(address))
        let first = requestedGeneration(send(.submitEmail))!
        send(.sendFailed(.offline, generation: first))
        let second = requestedGeneration(send(.submitEmail))!
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(send(.sendSucceeded(generation: first)), [])
        XCTAssertEqual(model.state, .sendingCode(.email))
        XCTAssertFalse(send(.sendSucceeded(generation: second)).isEmpty)
    }

    func testAStaleVerifyResultIsDropped() {
        reachCodeEntry()
        let gen = submitCode()!
        XCTAssertEqual(send(.verifyFailed(.codeRejected, generation: gen + 1)), [])
        XCTAssertEqual(send(.verifySucceeded(session, generation: gen - 1)), [])
        XCTAssertEqual(model.state, .verifying)
    }

    func testTheFieldsAreReadOnlyWhileBusy() {
        send(.emailEdited(address))
        send(.submitEmail)
        XCTAssertEqual(send(.emailEdited("other@example.com")), [])
        XCTAssertEqual(model.email, address)
        send(.sendSucceeded(generation: model.generation))
        _ = submitCode()
        send(.codeEdited("999999"))
        XCTAssertEqual(model.digits, "123456")
    }

    // MARK: - Test 15: mapping

    func testEveryAuthErrorMapsOnSendAndOnVerify() {
        let errors: [AuthError] = [
            .invalidEmail, .codeRejected, .tooManyAttempts(retryAfter: 45), .sendRateLimited(retryAfter: 45), .offline,
            .timedOut, .cancelled, .unreachable, .unavailable, .invalidResponse, .sessionRevoked, .storageFailed,
        ]
        // No `default`: a new case fails to compile here until the list above has it.
        for error in errors {
            switch error {
            case .invalidEmail, .codeRejected, .tooManyAttempts, .sendRateLimited, .offline, .timedOut, .cancelled,
                 .unreachable, .unavailable, .invalidResponse, .sessionRevoked, .storageFailed: break
            }
        }
        for error in errors {
            for phase in [SignInPhase.send, .verify] {
                let status = SignInStatus(error, phase: phase, now: t0)
                if error == .cancelled { XCTAssertNil(status) } else { XCTAssertNotNil(status, "\(error) \(phase)") }
            }
        }
        XCTAssertEqual(SignInStatus(.invalidEmail, phase: .send, now: t0), .invalidEmail)
        XCTAssertEqual(SignInStatus(.invalidEmail, phase: .verify, now: t0), .serviceDown)
        XCTAssertEqual(SignInStatus(.codeRejected, phase: .send, now: t0), .serviceDown)
        XCTAssertEqual(SignInStatus(.codeRejected, phase: .verify, now: t0), .codeRejected)
        XCTAssertEqual(SignInStatus(.sendRateLimited(retryAfter: 45), phase: .send, now: t0), .resendCooldown(until: t0.addingTimeInterval(45)))
        XCTAssertEqual(SignInStatus(.sendRateLimited(retryAfter: 45), phase: .verify, now: t0), .serviceDown)
        XCTAssertEqual(SignInStatus(.tooManyAttempts(retryAfter: 45), phase: .send, now: t0), .resendCooldown(until: t0.addingTimeInterval(45)))
        XCTAssertEqual(SignInStatus(.tooManyAttempts(retryAfter: 45), phase: .verify, now: t0), .tooManyAttempts(until: t0.addingTimeInterval(45)))
    }

    func testEveryStatusHasCopy() {
        let statuses: [SignInStatus] = [
            .invalidEmail, .codeRejected, .codeExpiredLocal, .tooManyAttempts(until: t0.addingTimeInterval(30)),
            .resendCooldown(until: t0.addingTimeInterval(30)), .offline, .timedOut, .serviceDown,
        ]
        for status in statuses { XCTAssertFalse(SignInCopy.text(for: status, now: t0).isEmpty) }
        XCTAssertEqual(SignInCopy.text(for: .tooManyAttempts(until: t0.addingTimeInterval(30)), now: t0), SignInCopy.tooManyAttempts(waitSeconds: 30))
        XCTAssertEqual(SignInCopy.text(for: .resendCooldown(until: t0.addingTimeInterval(0.2)), now: t0), SignInCopy.resendCooldown(waitSeconds: 1))
    }

    // MARK: - Pasteboard matching

    func testPasteboardTextMatchesOnlyTheEnteredCode() {
        XCTAssertTrue(SignInModel.pasteboardText("123456", holdsCode: "123456"))
        XCTAssertTrue(SignInModel.pasteboardText(" 123 456\n", holdsCode: "123456"))
        XCTAssertTrue(SignInModel.pasteboardText("123-456", holdsCode: "123456"))
        XCTAssertFalse(SignInModel.pasteboardText("654321", holdsCode: "123456"))
        XCTAssertFalse(SignInModel.pasteboardText("your code is 123456", holdsCode: "123456"))
        XCTAssertFalse(SignInModel.pasteboardText("1234567", holdsCode: "123456"))
        XCTAssertFalse(SignInModel.pasteboardText("", holdsCode: ""))
    }
}
