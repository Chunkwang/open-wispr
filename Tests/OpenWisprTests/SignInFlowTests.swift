import XCTest
@testable import OpenWisprLib

/// Scripted auth layer: results come from closures, and a verify can be held
/// until the test releases it, to simulate a slow network.
private final class FakeAuth: SignInAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _saved: [AuthSession] = []
    private var _loggedOut: [AuthSession] = []
    private var verifyWaiter: CheckedContinuation<Void, Never>?

    var sendResult: Result<Void, AuthError> = .success(())
    var verifyResult: Result<AuthSession, AuthError> = .failure(.codeRejected)
    var saveResult: Result<Void, AuthError> = .success(())
    var holdVerify = false

    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    var saved: [AuthSession] { lock.lock(); defer { lock.unlock() }; return _saved }
    var loggedOut: [AuthSession] { lock.lock(); defer { lock.unlock() }; return _loggedOut }
    private func note(_ line: String) { lock.lock(); _log.append(line); lock.unlock() }

    func requestCode(email: String) async -> Result<Void, AuthError> {
        note("send")
        return sendResult
    }

    func verifyWithoutSaving(email: String, code: String) async -> Result<AuthSession, AuthError> {
        note("verify")
        if holdVerify { await withCheckedContinuation { c in lock.lock(); verifyWaiter = c; lock.unlock() } }
        return verifyResult
    }

    func releaseVerify() {
        lock.lock(); let waiter = verifyWaiter; verifyWaiter = nil; lock.unlock()
        waiter?.resume()
    }

    var isHoldingVerify: Bool { lock.lock(); defer { lock.unlock() }; return verifyWaiter != nil }

    func save(_ session: AuthSession) -> Result<Void, AuthError> {
        note("save")
        lock.lock(); if case .success = saveResult { _saved.append(session) }; lock.unlock()
        return saveResult
    }

    func logoutUnsaved(_ session: AuthSession) {
        note("logout")
        lock.lock(); _loggedOut.append(session); lock.unlock()
    }
}

private final class FakePasteboard: SignInPasteboard {
    var text: String?
    var clears = 0
    func currentString() -> String? { text }
    func clear() { text = nil; clears += 1 }
}

@MainActor
final class SignInFlowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let address = "sam@example.com"
    private let session = AuthSession(
        accessToken: "access-value", refreshToken: "refresh-value",
        expiresAt: Date(timeIntervalSince1970: 1_790_003_600), email: "sam@example.com"
    )

    private var auth = FakeAuth()
    private var pasteboard = FakePasteboard()
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var insertInFlight = false
    private var announced: [String] = []
    private var timersStopped = 0
    private var windowClosed = 0
    private var sessionChanges = 0

    override func setUp() {
        super.setUp()
        auth = FakeAuth()
        pasteboard = FakePasteboard()
        clock = t0
        insertInFlight = false
        announced = []
        timersStopped = 0
        windowClosed = 0
        sessionChanges = 0
    }

    private func makeFlow() -> SignInFlow {
        SignInFlow(
            auth: auth,
            clock: { [unowned self] in self.clock },
            pasteboard: pasteboard,
            isDictationInsertInFlight: { [unowned self] in self.insertInFlight },
            announcer: { [unowned self] text, _ in self.announced.append(text) },
            stopTimers: { [unowned self] in self.timersStopped += 1 },
            closeWindow: { [unowned self] in self.windowClosed += 1 },
            sessionDidChange: { [unowned self] in self.sessionChanges += 1 }
        )
    }

    private func reachCodeEntry(_ flow: SignInFlow) async {
        flow.send(.emailEdited(address))
        flow.send(.submitEmail)
        await flow.settle()
        XCTAssertEqual(flow.model.state, .codeEntry)
    }

    private func submit(_ flow: SignInFlow, code: String = "123456") {
        flow.send(.codeEdited(code))
        flow.send(.submitCode)
    }

    // MARK: - happy path

    func testSignInFromEmailToDoneThroughTheAuthLayer() async {
        auth.verifyResult = .success(session)
        let flow = makeFlow()
        await reachCodeEntry(flow)
        XCTAssertEqual(auth.log, ["send"])
        XCTAssertEqual(announced, [SignInCopy.codeSentTo(address)])

        submit(flow)
        XCTAssertEqual(flow.model.state, .verifying)
        await flow.settle()
        XCTAssertEqual(flow.model.state, .signedIn)
        XCTAssertEqual(auth.log, ["send", "verify", "save"])
        XCTAssertEqual(auth.saved, [session])
        XCTAssertEqual(announced.last, SignInCopy.signedIn)
        XCTAssertEqual(timersStopped, 1)
        XCTAssertEqual(flow.focusRequest?.focus, .done)
        XCTAssertTrue(auth.loggedOut.isEmpty)
        XCTAssertEqual(sessionChanges, 1, "the menu is told once, when the session is really saved")

        flow.send(.closeRequested)
        XCTAssertEqual(windowClosed, 1)
        XCTAssertTrue(auth.loggedOut.isEmpty, "a saved session is never logged out by closing the window")
    }

    func testAFailedSendShowsTheErrorAndSendsNothingElse() async {
        auth.sendResult = .failure(.offline)
        let flow = makeFlow()
        flow.send(.emailEdited(address))
        flow.send(.submitEmail)
        await flow.settle()
        XCTAssertEqual(flow.model.state, .emailEntry)
        XCTAssertEqual(flow.model.statusRow(now: flow.now), .offline)
    }

    func testTheClockIsInjected() async {
        let flow = makeFlow()
        await reachCodeEntry(flow)
        clock = t0.addingTimeInterval(601)
        submit(flow)
        XCTAssertEqual(flow.model.state, .codeEntry)
        XCTAssertFalse(auth.log.contains("verify"), "an expired code never reaches the server")
        XCTAssertEqual(flow.model.status, .codeExpiredLocal)
    }

    func testTickRedrawsAndRunsTheModelsTimers() async {
        let flow = makeFlow()
        await reachCodeEntry(flow)
        let before = flow.tickCount
        clock = t0.addingTimeInterval(60)
        flow.tick()
        XCTAssertEqual(flow.tickCount, before + 1)
        XCTAssertTrue(announced.contains(SignInCopy.resendReady))
    }

    func testRepeatedFocusRequestsAreDistinct() async {
        auth.verifyResult = .failure(.codeRejected)
        let flow = makeFlow()
        await reachCodeEntry(flow)
        submit(flow)
        await flow.settle()
        let first = flow.focusRequest
        XCTAssertEqual(first?.focus, .code(selectAll: true))
        submit(flow)
        await flow.settle()
        XCTAssertEqual(flow.focusRequest?.focus, .code(selectAll: true))
        XCTAssertNotEqual(flow.focusRequest?.id, first?.id)
    }

    // MARK: - pasteboard

    func testThePasteboardIsClearedAfterSuccessWhenItHoldsTheCode() async {
        auth.verifyResult = .success(session)
        pasteboard.text = "123456"
        let flow = makeFlow()
        await reachCodeEntry(flow)
        submit(flow)
        await flow.settle()
        XCTAssertEqual(pasteboard.clears, 1)
        XCTAssertNil(pasteboard.text)
    }

    func testThePasteboardIsClearedWhenItHoldsTheCodeWithASpace() async {
        auth.verifyResult = .success(session)
        pasteboard.text = "123 456"
        let flow = makeFlow()
        await reachCodeEntry(flow)
        submit(flow, code: "123 456")
        await flow.settle()
        XCTAssertEqual(pasteboard.clears, 1)
    }

    func testThePasteboardIsLeftAloneWhenItHoldsSomethingElse() async {
        auth.verifyResult = .success(session)
        pasteboard.text = "a shopping list"
        let flow = makeFlow()
        await reachCodeEntry(flow)
        submit(flow)
        await flow.settle()
        XCTAssertEqual(flow.model.state, .signedIn)
        XCTAssertEqual(pasteboard.clears, 0)
        XCTAssertEqual(pasteboard.text, "a shopping list")
    }

    func testThePasteboardIsNeverTouchedWhileADictationInsertIsInFlight() async {
        auth.verifyResult = .success(session)
        pasteboard.text = "123456"
        insertInFlight = true
        let flow = makeFlow()
        await reachCodeEntry(flow)
        submit(flow)
        await flow.settle()
        XCTAssertEqual(pasteboard.clears, 0)
        XCTAssertEqual(pasteboard.text, "123456")
    }

    func testThePasteboardIsLeftAloneWhenTheCodeWasWrong() async {
        auth.verifyResult = .failure(.codeRejected)
        pasteboard.text = "123456"
        let flow = makeFlow()
        await reachCodeEntry(flow)
        submit(flow)
        await flow.settle()
        XCTAssertEqual(pasteboard.clears, 0)
    }

    // MARK: - storage failure

    func testAKeychainFailureIsNotSignedInAndCanBeRetriedWithoutANewCode() async {
        auth.verifyResult = .success(session)
        auth.saveResult = .failure(.storageFailed)
        pasteboard.text = "123456"
        let flow = makeFlow()
        await reachCodeEntry(flow)
        submit(flow)
        await flow.settle()
        XCTAssertEqual(flow.model.state, .saveFailed)
        XCTAssertEqual(flow.model.pendingSession, session)
        XCTAssertEqual(announced.last, SignInCopy.storageFailed)
        XCTAssertEqual(pasteboard.clears, 0, "not signed in yet")
        XCTAssertEqual(sessionChanges, 0, "nothing saved, so the menu is not told")
        XCTAssertEqual(flow.focusRequest?.focus, .retry)

        // Still failing: same screen.
        flow.send(.retrySaveTapped)
        XCTAssertEqual(flow.model.state, .saveFailed)

        // The Keychain is unlocked: the retry saves the same session.
        auth.saveResult = .success(())
        flow.send(.retrySaveTapped)
        XCTAssertEqual(flow.model.state, .signedIn)
        XCTAssertEqual(auth.saved, [session])
        XCTAssertEqual(auth.log.filter { $0 == "verify" }.count, 1, "no second code was needed")
        XCTAssertEqual(auth.log.filter { $0 == "send" }.count, 1)
        XCTAssertEqual(pasteboard.clears, 1)
        XCTAssertEqual(sessionChanges, 1)
        XCTAssertTrue(auth.loggedOut.isEmpty)
    }

    func testClosingTheFailureScreenEndsTheUnsavedServerSession() async {
        auth.verifyResult = .success(session)
        auth.saveResult = .failure(.storageFailed)
        let flow = makeFlow()
        await reachCodeEntry(flow)
        submit(flow)
        await flow.settle()
        flow.send(.closeRequested)
        XCTAssertEqual(auth.loggedOut, [session])
        XCTAssertEqual(windowClosed, 1)
        XCTAssertNil(flow.model.pendingSession)
    }

    // MARK: - closing while a request is in flight

    func testASessionThatArrivesAfterTheWindowClosedIsLoggedOutAndNeverSaved() async {
        auth.verifyResult = .success(session)
        auth.holdVerify = true
        let flow = makeFlow()
        await reachCodeEntry(flow)
        submit(flow)
        while !auth.isHoldingVerify { await Task.yield() }
        flow.send(.closeRequested)
        XCTAssertEqual(flow.model.state, .closed)

        auth.releaseVerify()
        await flow.settle()
        XCTAssertEqual(flow.model.state, .closed)
        XCTAssertFalse(auth.log.contains("save"), "never stored")
        XCTAssertEqual(auth.loggedOut, [session], "and not left alive on the server")
        XCTAssertEqual(pasteboard.clears, 0)
    }

    func testALateFailureAfterClosingChangesNothing() async {
        auth.verifyResult = .failure(.codeRejected)
        auth.holdVerify = true
        let flow = makeFlow()
        await reachCodeEntry(flow)
        submit(flow)
        while !auth.isHoldingVerify { await Task.yield() }
        flow.send(.closeRequested)
        auth.releaseVerify()
        await flow.settle()
        XCTAssertEqual(flow.model.state, .closed)
        XCTAssertEqual(flow.model.attempts, 0)
        XCTAssertTrue(auth.loggedOut.isEmpty)
    }

    // MARK: - Return

    func testReturnPressesThePrimaryButtonOfTheCurrentScreen() async {
        auth.verifyResult = .success(session)
        let flow = makeFlow()

        flow.submitPrimary()                                   // empty email: nothing happens
        XCTAssertFalse(auth.log.contains("send"))
        flow.send(.emailEdited(address))
        flow.submitPrimary()                                   // Send code
        await flow.settle()
        XCTAssertEqual(flow.model.state, .codeEntry)

        flow.send(.codeEdited("12345"))
        flow.submitPrimary()                                   // five digits: nothing happens
        XCTAssertFalse(auth.log.contains("verify"))
        flow.send(.codeEdited("123456"))
        flow.submitPrimary()                                   // Sign in
        await flow.settle()
        XCTAssertEqual(flow.model.state, .signedIn)

        flow.submitPrimary()                                   // Done
        XCTAssertEqual(flow.model.state, .closed)
        XCTAssertEqual(windowClosed, 1)
    }

    func testReturnOnAnExpiredCodeSendsANewOne() async {
        let flow = makeFlow()
        await reachCodeEntry(flow)
        clock = t0.addingTimeInterval(700)
        flow.send(.codeEdited("123456"))
        flow.submitPrimary()
        XCTAssertEqual(flow.model.state, .sendingCode(.resend))
        await flow.settle()
        XCTAssertEqual(auth.log.filter { $0 == "send" }.count, 2)
        XCTAssertFalse(auth.log.contains("verify"))
    }

    func testReturnOnTheFailureScreenRetriesTheSave() async {
        auth.verifyResult = .success(session)
        auth.saveResult = .failure(.storageFailed)
        let flow = makeFlow()
        await reachCodeEntry(flow)
        submit(flow)
        await flow.settle()
        auth.saveResult = .success(())
        flow.submitPrimary()
        XCTAssertEqual(flow.model.state, .signedIn)
    }
}
