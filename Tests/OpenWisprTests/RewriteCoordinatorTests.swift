import XCTest
import Network
@testable import OpenWisprLib

/// Records the timeout it was asked to wait, so a test can prove the coordinator
/// waits for the monitor's first update.
private final class FakeReachability: NetworkReachability {
    let online: Bool
    private let lock = NSLock()
    private var _timeouts: [TimeInterval] = []

    init(online: Bool) { self.online = online }

    var timeouts: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return _timeouts
    }

    private func note(_ timeout: TimeInterval) {
        lock.lock(); _timeouts.append(timeout); lock.unlock()
    }

    func isOnline(waitingUpTo timeout: TimeInterval) async -> Bool {
        note(timeout)
        return online
    }
}

/// Counts what the coordinator touches so tests can assert that a closed gate
/// creates no network object and makes no reachability or rewrite call. The
/// rewrite closure runs on another thread, so every counter is lock-guarded.
private final class Probe {
    private let lock = NSLock()
    private var _gateCalls = 0
    private var _reachabilityCreated = 0
    private var _rewriterCreated = 0
    private var _rewriteCalls = 0
    private var _willRewriteCalls = 0
    private var _completions: [RewriteOutcome] = []
    private var _timeouts: [TimeInterval] = []
    private var _tokenReads = 0

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var gateCalls: Int { locked { _gateCalls } }
    var reachabilityCreated: Int { locked { _reachabilityCreated } }
    var rewriterCreated: Int { locked { _rewriterCreated } }
    var rewriteCalls: Int { locked { _rewriteCalls } }
    var willRewriteCalls: Int { locked { _willRewriteCalls } }
    var completions: [RewriteOutcome] { locked { _completions } }
    var timeouts: [TimeInterval] { locked { _timeouts } }
    var tokenReads: Int { locked { _tokenReads } }

    func noteGate() { locked { _gateCalls += 1 } }
    func noteReachability() { locked { _reachabilityCreated += 1 } }
    func noteRewriter() { locked { _rewriterCreated += 1 } }
    func noteRewrite() { locked { _rewriteCalls += 1 } }
    func noteWillRewrite() { locked { _willRewriteCalls += 1 } }
    func noteCompletion(_ outcome: RewriteOutcome) { locked { _completions.append(outcome) } }
    func noteTimeout(_ t: TimeInterval) { locked { _timeouts.append(t) } }
    func noteTokenRead() { locked { _tokenReads += 1 } }
    func resetCompletions() { locked { _completions = [] } }
}

final class RewriteCoordinatorTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RewriteCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeCoordinator(
        probe: Probe,
        gateOpen: Bool,
        online: Bool = true,
        result: Result<String, RewriteError> = .success("Send it tomorrow.")
    ) -> RewriteCoordinator {
        RewriteCoordinator(
            gate: { mode in probe.noteGate(); return gateOpen && mode == .auto },
            makeReachability: { probe.noteReachability(); return FakeReachability(online: online) },
            makeRewriter: {
                probe.noteRewriter()
                return { _ in probe.noteRewrite(); return result }
            }
        )
    }

    /// Runs one dictation and waits for its completion. Lets a short grace period
    /// pass afterwards so a second, wrongly delivered completion would be counted.
    @discardableResult
    private func run(
        _ coordinator: RewriteCoordinator,
        _ probe: Probe,
        transcript: String = "um so like send it tomorrow",
        mode: RewriteMode = .auto
    ) -> RewriteOutcome? {
        let before = probe.completions.count
        let done = expectation(description: "completion")
        coordinator.process(
            transcript: transcript,
            mode: { mode },
            willRewrite: { probe.noteWillRewrite() },
            completion: { outcome in
                probe.noteCompletion(outcome)
                // Fulfil once only: a second delivery is caught by the count checks
                // instead of aborting the run on an over-fulfilled expectation.
                if probe.completions.count == before + 1 { done.fulfill() }
            }
        )
        wait(for: [done], timeout: 5)
        Thread.sleep(forTimeInterval: 0.15)
        return probe.completions.last
    }

    private func awaited<T>(_ body: @escaping () async -> T) -> T? {
        let done = expectation(description: "async body")
        var result: T?
        Task {
            result = await body()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }

    // MARK: - gate closed: nothing else happens

    func testClosedGateInsertsRawAndTouchesNothingElse() {
        let probe = Probe()
        let outcome = run(makeCoordinator(probe: probe, gateOpen: false), probe)
        XCTAssertEqual(outcome, RewriteOutcome(text: "um so like send it tomorrow", notice: nil, rewritten: false, attempted: false))
        XCTAssertEqual(probe.gateCalls, 1)
        XCTAssertEqual(probe.reachabilityCreated, 0)
        XCTAssertEqual(probe.rewriterCreated, 0)
        XCTAssertEqual(probe.rewriteCalls, 0)
        XCTAssertEqual(probe.willRewriteCalls, 0)
        XCTAssertEqual(probe.completions.count, 1)
    }

    func testClosedGateCompletesSynchronously() {
        let probe = Probe()
        let coordinator = makeCoordinator(probe: probe, gateOpen: false)
        var delivered = false
        coordinator.process(transcript: "hello", mode: { .auto }, willRewrite: {}, completion: { _ in delivered = true })
        XCTAssertTrue(delivered)
    }

    func testGateReceivesTheModeThatWasPassedIn() {
        var seen: [RewriteMode] = []
        let coordinator = RewriteCoordinator(
            gate: { mode in seen.append(mode); return false },
            makeReachability: { FakeReachability(online: true) },
            makeRewriter: { { _ in .success("x") } }
        )
        coordinator.process(transcript: "a", mode: { .auto }, willRewrite: {}, completion: { _ in })
        coordinator.process(transcript: "b", mode: { .off }, willRewrite: {}, completion: { _ in })
        XCTAssertEqual(seen, [.auto, .off])
    }

    func testBlankTranscriptNeverConsultsTheGateOrTheNetwork() {
        let probe = Probe()
        let outcome = run(makeCoordinator(probe: probe, gateOpen: true), probe, transcript: "  \n ")
        XCTAssertEqual(outcome?.text, "  \n ")
        XCTAssertEqual(outcome?.attempted, false)
        XCTAssertEqual(probe.gateCalls, 0)
        XCTAssertEqual(probe.reachabilityCreated, 0)
        XCTAssertEqual(probe.rewriteCalls, 0)
    }

    // MARK: - gate open

    func testSuccessInsertsTheRewrite() {
        let probe = Probe()
        let outcome = run(makeCoordinator(probe: probe, gateOpen: true), probe)
        XCTAssertEqual(outcome, RewriteOutcome(text: "Send it tomorrow.", notice: nil, rewritten: true, attempted: true))
        XCTAssertEqual(probe.willRewriteCalls, 1)
        XCTAssertEqual(probe.rewriteCalls, 1)
        XCTAssertEqual(probe.completions.count, 1)
    }

    func testEveryFailureInsertsTheRawTranscriptWithItsNotice() {
        let errors: [RewriteError] = [
            .notAuthenticated, .unauthorized, .requiresPro, .rateLimited, .tooLong, .offline,
            .timedOut, .cancelled, .unreachable, .unavailable, .unexpectedStatus(418), .invalidResponse,
        ]
        for error in errors {
            let probe = Probe()
            let outcome = run(makeCoordinator(probe: probe, gateOpen: true, result: .failure(error)), probe)
            XCTAssertEqual(outcome?.text, "um so like send it tomorrow", "\(error)")
            XCTAssertEqual(outcome?.notice, error.userNotice, "\(error)")
            XCTAssertEqual(outcome?.rewritten, false, "\(error)")
            XCTAssertEqual(outcome?.attempted, true, "\(error)")
            XCTAssertEqual(probe.completions.count, 1, "\(error)")
        }
    }

    func testCancelledFallsBackToRawWithNoNotice() {
        let probe = Probe()
        let outcome = run(makeCoordinator(probe: probe, gateOpen: true, result: .failure(.cancelled)), probe)
        XCTAssertEqual(outcome?.text, "um so like send it tomorrow")
        XCTAssertNil(outcome?.notice)
    }

    func testBlankSuccessFallsBackToRawNeverInsertsEmpty() {
        for blank in ["", "   ", "\n"] {
            let probe = Probe()
            let outcome = run(makeCoordinator(probe: probe, gateOpen: true, result: .success(blank)), probe)
            XCTAssertEqual(outcome?.text, "um so like send it tomorrow")
            XCTAssertEqual(outcome?.rewritten, false)
            XCTAssertEqual(outcome?.notice, RewriteError.invalidResponse.userNotice)
        }
    }

    func testOutcomeTextIsNeverEmptyForANonEmptyTranscript() {
        let results: [Result<String, RewriteError>] = [
            .success(""), .success(" "), .success("ok"), .failure(.timedOut), .failure(.cancelled),
        ]
        for result in results {
            XCTAssertFalse(RewriteCoordinator.outcome(for: result, raw: "raw").text.isEmpty)
        }
    }

    // MARK: - the reply is sanitized before it can be inserted

    func testHostileSuccessIsCleanedBeforeInsertion() {
        let hostile = "Send it tomorrow.\u{1B}[201~ rm -rf ~\n"
        let outcome = RewriteCoordinator.outcome(for: .success(hostile), raw: "send it tomorrow")
        XCTAssertEqual(outcome.text, "Send it tomorrow.[201~ rm -rf ~")
        XCTAssertFalse(outcome.text.unicodeScalars.contains { $0.value < 0x20 })
        XCTAssertTrue(outcome.rewritten)
        XCTAssertNil(outcome.notice)
    }

    func testRejectedSuccessFallsBackToRawWithTheUnusableNotice() {
        let raw = "send it tomorrow"
        let oversized = String(repeating: "a", count: 5_000)
        let outcome = RewriteCoordinator.outcome(for: .success(oversized), raw: raw)
        XCTAssertEqual(outcome.text, raw)
        XCTAssertFalse(outcome.rewritten)
        XCTAssertEqual(outcome.notice, RewriteError.invalidResponse.userNotice)
        XCTAssertTrue(outcome.attempted)
    }

    // MARK: - offline short-circuit

    func testOfflineSkipsTheRequestAndInsertsRaw() {
        let probe = Probe()
        let outcome = run(makeCoordinator(probe: probe, gateOpen: true, online: false), probe)
        XCTAssertEqual(outcome?.text, "um so like send it tomorrow")
        XCTAssertEqual(outcome?.notice, RewriteError.offline.userNotice)
        XCTAssertEqual(outcome?.attempted, true)
        XCTAssertEqual(probe.reachabilityCreated, 1)
        XCTAssertEqual(probe.rewriterCreated, 0)
        XCTAssertEqual(probe.rewriteCalls, 0)
        XCTAssertEqual(probe.completions.count, 1)
    }

    func testFirstDictationWaitsForTheMonitorsFirstUpdate() {
        let reachability = FakeReachability(online: true)
        let coordinator = RewriteCoordinator(
            gate: { _ in true },
            makeReachability: { reachability },
            makeRewriter: { { _ in .success("Ok.") } }
        )
        let done = expectation(description: "completion")
        coordinator.process(transcript: "ok", mode: { .auto }, willRewrite: {}, completion: { _ in done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(reachability.timeouts, [ReachabilityWait.firstUpdateTimeout])
        XCTAssertEqual(ReachabilityWait.firstUpdateTimeout, 0.3)
    }

    // MARK: - reachability mapping and the first-update wait

    func testOnlyAnUnsatisfiedPathIsOffline() {
        XCTAssertTrue(PathMonitorReachability.isOnline(status: .satisfied))
        XCTAssertTrue(PathMonitorReachability.isOnline(status: .requiresConnection))
        XCTAssertFalse(PathMonitorReachability.isOnline(status: .unsatisfied))
    }

    func testUnknownPathCountsAsOnline() {
        XCTAssertTrue(PathMonitorReachability.isOnline(status: nil))
    }

    func testWaitPicksUpAStatusThatArrivesDuringTheWait() {
        var reads = 0
        var sleeps = 0
        let online = awaited {
            await ReachabilityWait.resolve(
                status: { reads += 1; return reads <= 3 ? nil : .unsatisfied },
                timeout: 0.3,
                sleep: { _ in sleeps += 1 }
            )
        }
        XCTAssertEqual(online, false)
        XCTAssertEqual(sleeps, 3)
    }

    func testWaitDoesNotSleepWhenTheStatusIsAlreadyKnown() {
        var sleeps = 0
        let online = awaited {
            await ReachabilityWait.resolve(status: { .unsatisfied }, timeout: 0.3, sleep: { _ in sleeps += 1 })
        }
        XCTAssertEqual(online, false)
        XCTAssertEqual(sleeps, 0)
    }

    func testWaitGivesUpAfterTheTimeoutAndCountsUnknownAsOnline() {
        var sleeps = 0
        let online = awaited {
            await ReachabilityWait.resolve(status: { nil }, timeout: 0.3, sleep: { _ in sleeps += 1 })
        }
        XCTAssertEqual(online, true)
        XCTAssertTrue(sleeps >= 14 && sleeps <= 16, "slept \(sleeps) times")
    }

    // MARK: - laziness and reuse

    func testReachabilityAndRewriterAreCreatedOnceAcrossDictations() {
        let probe = Probe()
        let coordinator = makeCoordinator(probe: probe, gateOpen: true)
        run(coordinator, probe)
        run(coordinator, probe)
        XCTAssertEqual(probe.reachabilityCreated, 1)
        XCTAssertEqual(probe.rewriterCreated, 1)
        XCTAssertEqual(probe.rewriteCalls, 2)
    }

    func testTheGateIsConsultedForEveryDictation() {
        let probe = Probe()
        let coordinator = makeCoordinator(probe: probe, gateOpen: false)
        run(coordinator, probe)
        run(coordinator, probe)
        XCTAssertEqual(probe.gateCalls, 2)
    }

    // MARK: - overlapping dictations

    func testTwoPendingRewritesEachDeliverExactlyOnce() {
        let probe = Probe()
        let coordinator = makeCoordinator(probe: probe, gateOpen: true)
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        var delivered: [String] = []
        let lock = NSLock()
        // Each delivery fulfils the next expectation, so a third (duplicate)
        // delivery shows up in `delivered` instead of aborting the run.
        let expectations = [first, second]
        func record(_ outcome: RewriteOutcome) {
            lock.lock()
            delivered.append(outcome.text)
            let position = delivered.count - 1
            lock.unlock()
            if position < expectations.count { expectations[position].fulfill() }
        }
        coordinator.process(transcript: "one", mode: { .auto }, willRewrite: {}, completion: { record($0) })
        coordinator.process(transcript: "two", mode: { .auto }, willRewrite: {}, completion: { record($0) })
        wait(for: [first, second], timeout: 5)
        Thread.sleep(forTimeInterval: 0.15)
        lock.lock(); let count = delivered.count; lock.unlock()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(probe.rewriteCalls, 2)
    }

    // MARK: - no repeat uploads after a sign-in or Pro answer

    func testProRequiredStopsRewritesForTheSessionAndNoticeShowsOnce() {
        let probe = Probe()
        let coordinator = makeCoordinator(probe: probe, gateOpen: true, result: .failure(.requiresPro))
        let first = run(coordinator, probe)
        XCTAssertEqual(first?.notice, RewriteError.requiresPro.userNotice)
        XCTAssertEqual(probe.rewriteCalls, 1)

        let second = run(coordinator, probe)
        let third = run(coordinator, probe)
        for later in [second, third] {
            XCTAssertEqual(later?.text, "um so like send it tomorrow")
            XCTAssertNil(later?.notice)
            XCTAssertEqual(later?.attempted, false)
            XCTAssertEqual(later?.rewritten, false)
        }
        XCTAssertEqual(probe.rewriteCalls, 1, "no further upload")
        XCTAssertEqual(probe.willRewriteCalls, 1)
    }

    func testUnauthorizedStopsRewritesForTheSession() {
        let probe = Probe()
        let coordinator = makeCoordinator(probe: probe, gateOpen: true, result: .failure(.unauthorized))
        XCTAssertEqual(run(coordinator, probe)?.notice, RewriteError.unauthorized.userNotice)
        XCTAssertNil(run(coordinator, probe)?.notice)
        XCTAssertEqual(probe.rewriteCalls, 1)
    }

    func testOtherFailuresDoNotStopTheSession() {
        for error in [RewriteError.timedOut, .unreachable, .unavailable, .rateLimited, .tooLong, .invalidResponse, .cancelled] {
            let probe = Probe()
            let coordinator = makeCoordinator(probe: probe, gateOpen: true, result: .failure(error))
            run(coordinator, probe)
            run(coordinator, probe)
            XCTAssertEqual(probe.rewriteCalls, 2, "\(error)")
        }
    }

    func testResetSessionAllowsRewritesAgain() {
        let probe = Probe()
        let coordinator = makeCoordinator(probe: probe, gateOpen: true, result: .failure(.requiresPro))
        run(coordinator, probe)
        run(coordinator, probe)
        XCTAssertEqual(probe.rewriteCalls, 1)
        coordinator.resetSession()
        XCTAssertEqual(run(coordinator, probe)?.notice, RewriteError.requiresPro.userNotice)
        XCTAssertEqual(probe.rewriteCalls, 2)
    }

    func testTurningRewriteOffResetsTheSessionStop() {
        let probe = Probe()
        let coordinator = makeCoordinator(probe: probe, gateOpen: true, result: .failure(.unauthorized))
        run(coordinator, probe)
        run(coordinator, probe)
        XCTAssertEqual(probe.rewriteCalls, 1)
        coordinator.process(transcript: "x", mode: { .off }, willRewrite: {}, completion: { _ in })
        run(coordinator, probe)
        XCTAssertEqual(probe.rewriteCalls, 2)
    }

    // MARK: - production wiring: mode AND consent AND token, and the deadline

    private func productionCoordinator(
        probe: Probe,
        consented: Bool,
        hasToken: Bool,
        timeout: TimeInterval? = nil
    ) -> RewriteCoordinator {
        defaults.removeObject(forKey: RewriteConsent.defaultsKey)
        if consented { defaults.set(RewriteConsent.currentDisclosureVersion, forKey: RewriteConsent.defaultsKey) }
        let consent = RewriteConsent(defaults: defaults)
        let reachability: () -> NetworkReachability = { FakeReachability(online: true) }
        let rewriter: (TimeInterval) -> RewriteCoordinator.Rewriter = { t in
            probe.noteTimeout(t)
            return { _ in probe.noteRewrite(); return .success("Send it tomorrow.") }
        }
        let token: () -> Bool = { probe.noteTokenRead(); return hasToken }
        if let timeout = timeout {
            return RewriteCoordinator.production(
                consent: consent, hasToken: token, timeout: timeout,
                makeReachability: reachability, makeRewriter: rewriter
            )
        }
        return RewriteCoordinator.production(
            consent: consent, hasToken: token, makeReachability: reachability, makeRewriter: rewriter
        )
    }

    func testProductionGateOpensOnlyForModeAndConsentAndToken() {
        for mode in [RewriteMode.off, .auto] {
            for consented in [false, true] {
                for hasToken in [false, true] {
                    let probe = Probe()
                    let coordinator = productionCoordinator(probe: probe, consented: consented, hasToken: hasToken)
                    let outcome = run(coordinator, probe, mode: mode)
                    let expectOpen = mode == .auto && consented && hasToken
                    XCTAssertEqual(outcome?.attempted, expectOpen, "mode=\(mode) consent=\(consented) token=\(hasToken)")
                    XCTAssertEqual(probe.rewriteCalls, expectOpen ? 1 : 0, "mode=\(mode) consent=\(consented) token=\(hasToken)")
                    XCTAssertEqual(outcome?.text, expectOpen ? "Send it tomorrow." : "um so like send it tomorrow")
                }
            }
        }
    }

    func testProductionNeverReadsTheTokenWhenModeIsOffOrConsentIsMissing() {
        let off = Probe()
        run(productionCoordinator(probe: off, consented: true, hasToken: true), off, mode: .off)
        XCTAssertEqual(off.tokenReads, 0)
        let noConsent = Probe()
        run(productionCoordinator(probe: noConsent, consented: false, hasToken: true), noConsent, mode: .auto)
        XCTAssertEqual(noConsent.tokenReads, 0)
    }

    func testProductionTimeoutIsSixSeconds() {
        XCTAssertEqual(RewriteCoordinator.productionTimeout, 6)
        let probe = Probe()
        run(productionCoordinator(probe: probe, consented: true, hasToken: true), probe)
        XCTAssertEqual(probe.timeouts, [6])
    }

    func testProductionPassesAnInjectedTimeoutThrough() {
        let probe = Probe()
        run(productionCoordinator(probe: probe, consented: true, hasToken: true, timeout: 2), probe)
        XCTAssertEqual(probe.timeouts, [2])
    }

    func testThePipelinesOwnDefaultDeadlineIsSixSeconds() {
        XCTAssertEqual(RewritePipeline().timeout, 6)
    }

    // MARK: - nothing else can build a pipeline

    func testRewritePipelineIsOnlyConstructedByTheCoordinator() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if line.contains("RewritePipeline(") && file.lastPathComponent != "RewriteCoordinator.swift" {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertTrue(scanned > 10, "expected to scan the Sources tree, scanned \(scanned) files")
        XCTAssertEqual(offenders, [])
    }

    // MARK: - the mode is sampled when the decision is made

    func testModeIsEvaluatedOnEntryNotWhenTheRecordingStopped() {
        let probe = Probe()
        let coordinator = makeCoordinator(probe: probe, gateOpen: true)
        // The user had Rewrite on when they released the key...
        var current = RewriteMode.auto
        let sampled: () -> RewriteMode = { current }
        XCTAssertEqual(sampled(), .auto)
        // ...and switched it off while Whisper was still running.
        current = .off
        var outcome: RewriteOutcome?
        coordinator.process(transcript: "hello", mode: sampled, willRewrite: { probe.noteWillRewrite() }, completion: { outcome = $0 })
        XCTAssertEqual(outcome?.attempted, false)
        XCTAssertEqual(outcome?.text, "hello")
        XCTAssertEqual(probe.willRewriteCalls, 0)
        XCTAssertEqual(probe.rewriteCalls, 0)
        XCTAssertEqual(probe.reachabilityCreated, 0)
    }

    func testModeClosureIsCalledExactlyOnceAndBeforeProcessReturns() {
        var calls = 0
        let coordinator = RewriteCoordinator(
            gate: { _ in false },
            makeReachability: { FakeReachability(online: true) },
            makeRewriter: { { _ in .success("x") } }
        )
        coordinator.process(transcript: "hello", mode: { calls += 1; return .auto }, willRewrite: {}, completion: { _ in })
        XCTAssertEqual(calls, 1)
    }

    // MARK: - secureDictateOutcome: the pre-network bailout for plain dictation
    //
    // AppDelegate's dictate branch must call this BEFORE `process`, never after,
    // so a secure field's transcript is never sent to rewrite in the first
    // place (not just kept from being pasted). These tests pin the pure
    // decision so that contract cannot regress silently.

    func testSecureDictateOutcomeIsNilWhenNotSecureSoTheCallerProceedsToProcess() {
        XCTAssertNil(RewriteCoordinator.secureDictateOutcome(for: .notSecure, transcript: "hello"))
    }

    func testSecureDictateOutcomeForASecureFieldNeverAttemptsAndIsMarkedSecure() {
        let outcome = RewriteCoordinator.secureDictateOutcome(for: .secureField, transcript: "my password is hunter2")
        XCTAssertEqual(outcome, RewriteOutcome(
            text: "my password is hunter2", notice: nil, rewritten: false, attempted: false, secure: true
        ))
    }

    func testSecureDictateOutcomeForSecureEventInputNeverAttemptsAndIsMarkedSecure() {
        let outcome = RewriteCoordinator.secureDictateOutcome(for: .secureEventInput, transcript: "sudo password")
        XCTAssertEqual(outcome, RewriteOutcome(
            text: "sudo password", notice: nil, rewritten: false, attempted: false, secure: true
        ))
    }

    /// Finding 2 of the Day 3 hardening pass (security-engineer): Accessibility
    /// being off (including revoked mid-session) must bail out exactly like a
    /// confirmed secure field -- never paste, never send -- but is marked
    /// `secureStatusUnknown` so `DictationSequencer` can show a notice that
    /// says "couldn't check" rather than claiming secure input was confirmed.
    func testSecureDictateOutcomeForCannotDetermineNeverAttemptsIsMarkedSecureAndUnknown() {
        let outcome = RewriteCoordinator.secureDictateOutcome(for: .cannotDetermine, transcript: "my password is hunter2")
        XCTAssertEqual(outcome, RewriteOutcome(
            text: "my password is hunter2", notice: nil, rewritten: false, attempted: false, secure: true,
            secureStatusUnknown: true
        ))
    }

    /// The bug this fixed: calling `process` first and only gating the paste on
    /// `secure` afterwards still sends the transcript to the network. Proving
    /// `secureDictateOutcome` is non-nil for every non-`.notSecure` status, and
    /// that the AppDelegate call site returns immediately on a non-nil result
    /// without ever constructing a `process` call, is what keeps that from
    /// coming back. (The call-site wiring itself is exercised by hand: no fake
    /// `RewriteCoordinator` exists to intercept `process`, and adding one only
    /// to prove a `return` statement runs would not catch more than this does.)
    func testEveryNonNotSecureStatusProducesABailoutOutcome() {
        for status: SecureInputCheck in [.secureField, .secureEventInput, .cannotDetermine] {
            XCTAssertNotNil(RewriteCoordinator.secureDictateOutcome(for: status, transcript: "x"))
        }
    }

    func testTheProductionGateSeesTheModeAtProcessTime() {
        let probe = Probe()
        let coordinator = productionCoordinator(probe: probe, consented: true, hasToken: true)
        var current = RewriteMode.auto
        current = .off
        let done = expectation(description: "completion")
        coordinator.process(transcript: "um yes", mode: { current }, willRewrite: {}, completion: { _ in done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(probe.rewriteCalls, 0)
        XCTAssertEqual(probe.tokenReads, 0)
    }
}

