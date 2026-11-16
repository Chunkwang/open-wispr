import XCTest
@testable import OpenWisprLib

/// Manual clock and scheduler plus a log of everything the sequencer does, so
/// each rule can be tested without AppKit. `@MainActor` because
/// `DictationEnvironment` is now: XCTest runs these tests on the main thread
/// already, so this only makes that fact visible to the type checker.
@MainActor
private final class FakeEnvironment: DictationEnvironment {
    var time: TimeInterval = 100
    var frontmost: Int32? = 1
    var recording = false
    var currentPhase: DictationPhase = .transcribing

    var inserted: [String] = []
    var copied: [String] = []
    var notices: [String] = []
    var lastTranscription: String?
    var rewritingShown = 0
    var idleShown = 0
    var menuRefreshes = 0
    var frontmostQueries = 0
    private var timers: [(due: TimeInterval, work: () -> Void)] = []

    var scheduledCount: Int { timers.count }

    func now() -> TimeInterval { time }
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        timers.append((time + delay, work))
    }
    func frontmostProcessID() -> Int32? { frontmostQueries += 1; return frontmost }
    func isRecordingActive() -> Bool { recording }
    func insert(_ text: String) { inserted.append(text) }
    func copyToPasteboard(_ text: String) { copied.append(text) }
    func setLastTranscription(_ raw: String?) { lastTranscription = raw }
    var phase: DictationPhase { currentPhase }
    func showRewriting() { rewritingShown += 1; currentPhase = .rewriting }
    func showIdle() { idleShown += 1; currentPhase = .idle }
    func showNotice(_ message: String) { notices.append(message); currentPhase = .other }
    func refreshMenu() { menuRefreshes += 1 }

    /// Moves the clock forward, running due timers in due order.
    func advance(by seconds: TimeInterval) {
        let target = time + seconds
        while true {
            let due = timers.enumerated().filter { $0.element.due <= target }
            guard let next = due.min(by: { $0.element.due < $1.element.due }) else { break }
            let work = timers.remove(at: next.offset).work
            time = max(time, next.element.due)
            work()
        }
        time = target
    }
}

@MainActor
final class DictationSequencerTests: XCTestCase {
    private func rewritten(_ text: String, notice: String? = nil) -> RewriteOutcome {
        RewriteOutcome(text: text, notice: notice, rewritten: true, attempted: true)
    }

    private func fallback(_ raw: String, notice: String? = nil) -> RewriteOutcome {
        RewriteOutcome(text: raw, notice: notice, rewritten: false, attempted: true)
    }

    private func passthrough(_ raw: String, notice: String? = nil) -> RewriteOutcome {
        RewriteOutcome(text: raw, notice: notice, rewritten: false, attempted: false)
    }

    private func secure(_ text: String) -> RewriteOutcome {
        RewriteOutcome(text: text, notice: nil, rewritten: false, attempted: false, secure: true)
    }

    /// Finding 2 of the Day 3 hardening pass: `secure` outcomes where
    /// Accessibility couldn't even be asked (`SecureInputCheck.cannotDetermine`)
    /// get a distinct notice from an ordinary `secure` outcome -- see
    /// `testCannotDetermineOutcomeShowsItsOwnNoticeNotSecureInput` below.
    private func cannotDetermineSecure(_ text: String) -> RewriteOutcome {
        RewriteOutcome(text: text, notice: nil, rewritten: false, attempted: false, secure: true, secureStatusUnknown: true)
    }

    // MARK: - main-actor isolation (Day 3 hardening pass)

    /// `DictationSequencer` and `DictationEnvironment` used to be guarded only
    /// by a doc comment ("all calls happen on the main thread"), with nothing
    /// enforcing it. A stress test that fired 500 concurrent `begin()`/
    /// `finish()` calls at one instance from an unsynchronized background
    /// queue reliably reproduced memory corruption (SIGSEGV, SIGABRT,
    /// `NSInvalidArgumentException` on tagged-pointer objects -- the usual
    /// signatures of two threads mutating the same `Dictionary` at once).
    /// That test was the right way to *find* the bug, but the wrong thing to
    /// leave in a permanent suite: a regression would crash the whole test
    /// process instead of reporting one clean failure, and could take other,
    /// unrelated tests down with it depending on run order.
    ///
    /// Both types are now `@MainActor`, which turns that doc comment into a
    /// compile-time guarantee: a call to either from off the main actor
    /// fails to build (see the attempt below, kept for reference, commented
    /// out because it must not compile):
    ///
    ///     DispatchQueue.global().sync { seq.begin(raw: "x") }
    ///     // error: call to main actor-isolated instance method 'begin(raw:)'
    ///     // in a synchronous nonisolated context
    ///
    /// There is no way to exercise that failure from inside a passing test
    /// (a test that fails to compile fails the whole build, not just itself),
    /// so this test instead proves the guarantee is real rather than
    /// decorative: it checks that running on the main actor actually means
    /// running on the main thread, then drives one real `begin`/`finish`
    /// round trip through the sequencer to tie that assertion to an actual
    /// call path instead of asserting something unrelated.
    func testDictationSequencerCallsReallyRunOnTheMainThread() {
        MainActor.assertIsolated("DictationSequencer must only ever be touched from the main actor")
        XCTAssertTrue(Thread.isMainThread, "the main actor's executor must be the main thread")

        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let ticket = seq.begin(raw: "main-actor-check")
        seq.finish(ticket, outcome: passthrough("main-actor-check"))
        XCTAssertEqual(env.inserted, ["main-actor-check"])
    }

    // MARK: - rewrite not attempted: exactly the pre-rewrite behaviour

    func testPassthroughInsertsAtOnceWithNoTimersOrFocusCheck() {
        let env = FakeEnvironment()
        env.recording = true                 // would defer a guarded ticket
        let seq = DictationSequencer(environment: env)
        let ticket = seq.begin(raw: "hello")
        env.frontmost = 99                   // would divert a guarded ticket
        seq.finish(ticket, outcome: passthrough("hello"))
        XCTAssertEqual(env.inserted, ["hello"])
        XCTAssertEqual(env.copied, [])
        XCTAssertEqual(env.idleShown, 1)
        XCTAssertEqual(env.scheduledCount, 0)
        XCTAssertEqual(env.notices, [])
        XCTAssertEqual(env.menuRefreshes, 1)
    }

    func testPassthroughIdlesUnconditionallyLikeBefore() {
        let env = FakeEnvironment()
        env.currentPhase = .recording
        let seq = DictationSequencer(environment: env)
        seq.finish(seq.begin(raw: "hello"), outcome: passthrough("hello"))
        XCTAssertEqual(env.idleShown, 1)
    }

    func testPassthroughShowsItsNoticeAfterIdle() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        seq.finish(seq.begin(raw: "hello"), outcome: passthrough("hello", notice: "n"))
        XCTAssertEqual(env.notices, ["n"])
        XCTAssertEqual(env.idleShown, 1)
    }

    // MARK: - lastTranscription is the raw text, set before any wait

    func testLastTranscriptionIsSetToRawAtBeginBeforeAnyRewriteReturns() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        _ = seq.begin(raw: "um so like send it")
        XCTAssertEqual(env.lastTranscription, "um so like send it")
        XCTAssertEqual(env.inserted, [])
    }

    func testLastTranscriptionStaysRawWhenARewriteIsInserted() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let ticket = seq.begin(raw: "um so like send it")
        seq.willRewrite(ticket)
        seq.finish(ticket, outcome: rewritten("Send it."))
        XCTAssertEqual(env.inserted, ["Send it."])
        XCTAssertEqual(env.lastTranscription, "um so like send it")
    }

    // MARK: - exactly once, never empty

    func testAnOutcomeIsInsertedExactlyOnceEvenIfReportedTwice() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let ticket = seq.begin(raw: "raw")
        seq.willRewrite(ticket)
        seq.finish(ticket, outcome: rewritten("Clean."))
        seq.finish(ticket, outcome: rewritten("Clean."))
        seq.finish(ticket, outcome: fallback("raw"))
        env.advance(by: 10)
        XCTAssertEqual(env.inserted, ["Clean."])
    }

    func testAnAttemptedRewriteWithEmptyTextInsertsTheRawTranscript() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let ticket = seq.begin(raw: "raw words")
        seq.willRewrite(ticket)
        seq.finish(ticket, outcome: RewriteOutcome(text: "", notice: nil, rewritten: true, attempted: true))
        XCTAssertEqual(env.inserted, ["raw words"])
    }

    func testNothingIsInsertedWhenBothTheOutcomeAndTheRawAreEmpty() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let ticket = seq.begin(raw: "")
        seq.willRewrite(ticket)
        seq.finish(ticket, outcome: RewriteOutcome(text: "", notice: nil, rewritten: false, attempted: true))
        XCTAssertEqual(env.inserted, [])
        XCTAssertEqual(env.copied, [])
    }

    // MARK: - ordering

    func testALaterDictationWaitsForAnEarlierPendingOne() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "first raw")
        seq.willRewrite(a)
        let b = seq.begin(raw: "second raw")
        seq.willRewrite(b)

        seq.finish(b, outcome: rewritten("Second."))
        XCTAssertEqual(env.inserted, [], "B must not be inserted before A")

        seq.finish(a, outcome: rewritten("First."))
        XCTAssertEqual(env.inserted, ["First."], "B waits out A's clipboard-restore window")
        env.advance(by: DictationSequencer.minInsertGap + 0.01)
        XCTAssertEqual(env.inserted, ["First.", "Second."])
    }

    func testAPassthroughDictationBehindAPendingRewriteWaitsToo() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "first raw")
        seq.willRewrite(a)
        let b = seq.begin(raw: "second raw")
        seq.finish(b, outcome: passthrough("second raw"))
        XCTAssertEqual(env.inserted, [])
        seq.finish(a, outcome: rewritten("First."))
        env.advance(by: 2)
        XCTAssertEqual(env.inserted, ["First.", "second raw"])
    }

    func testInOrderResultsKeepTheirOrder() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "a")
        seq.willRewrite(a)
        let b = seq.begin(raw: "b")
        seq.willRewrite(b)
        seq.finish(a, outcome: rewritten("A."))
        env.advance(by: 2)
        seq.finish(b, outcome: rewritten("B."))
        XCTAssertEqual(env.inserted, ["A.", "B."])
    }

    func testAnEarlierDictationThatNeverReturnsIsGivenUpOnAndItsRawTextInserted() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "first raw")
        seq.willRewrite(a)
        let b = seq.begin(raw: "second raw")
        seq.willRewrite(b)
        seq.finish(b, outcome: rewritten("Second."))
        XCTAssertEqual(env.inserted, [])

        env.advance(by: DictationSequencer.maxWait + 0.1)
        XCTAssertEqual(env.inserted.first, "first raw")
        env.advance(by: 3)
        XCTAssertEqual(env.inserted, ["first raw", "Second."])

        // A late answer for the abandoned dictation is ignored: it was inserted once.
        seq.finish(a, outcome: rewritten("First."))
        env.advance(by: 5)
        XCTAssertEqual(env.inserted, ["first raw", "Second."])
    }

    func testTwoInsertsNeverShareOneRestoreWindow() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "a")
        seq.willRewrite(a)
        seq.finish(a, outcome: rewritten("A."))
        let b = seq.begin(raw: "b")
        seq.willRewrite(b)
        seq.finish(b, outcome: rewritten("B."))
        XCTAssertEqual(env.inserted, ["A."])
        env.advance(by: DictationSequencer.minInsertGap - 0.2)
        XCTAssertEqual(env.inserted, ["A."], "still inside A's restore window")
        env.advance(by: 0.3)
        XCTAssertEqual(env.inserted, ["A.", "B."])
    }

    // MARK: - never paste while recording or the hotkey is held

    func testAGuardedInsertWaitsWhileRecordingAndGoesOnceReleased() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        env.recording = true
        seq.finish(a, outcome: rewritten("Clean."))
        XCTAssertEqual(env.inserted, [])
        env.advance(by: 3)
        XCTAssertEqual(env.inserted, [], "still held")
        env.recording = false
        env.advance(by: DictationSequencer.retryInterval + 0.01)
        XCTAssertEqual(env.inserted, ["Clean."])
        env.advance(by: 10)
        XCTAssertEqual(env.inserted, ["Clean."], "exactly once")
    }

    func testAFallbackInsertAlsoWaitsWhileRecording() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        env.recording = true
        seq.finish(a, outcome: fallback("raw", notice: "n"))
        XCTAssertEqual(env.inserted, [])
        env.recording = false
        env.advance(by: 1)
        XCTAssertEqual(env.inserted, ["raw"])
    }

    // MARK: - focus changed: no paste, text on the clipboard

    func testFocusChangeCopiesToTheClipboardAndDoesNotPaste() {
        let env = FakeEnvironment()
        env.frontmost = 10
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        env.frontmost = 20
        seq.finish(a, outcome: rewritten("Clean."))
        XCTAssertEqual(env.inserted, [])
        XCTAssertEqual(env.copied, ["Clean."])
        XCTAssertEqual(env.notices, [DictationNotice.switchedApps])
        XCTAssertEqual(env.lastTranscription, "raw")
    }

    func testFocusChangeAlsoDivertsARawFallbackAndReplacesItsNotice() {
        let env = FakeEnvironment()
        env.frontmost = 10
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        env.frontmost = 20
        seq.finish(a, outcome: fallback("raw", notice: RewriteError.timedOut.userNotice))
        XCTAssertEqual(env.copied, ["raw"])
        XCTAssertEqual(env.notices, [DictationNotice.switchedApps])
        XCTAssertEqual(env.inserted, [])
    }

    func testSameAppAfterTheWaitIsPasted() {
        let env = FakeEnvironment()
        env.frontmost = 10
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        seq.finish(a, outcome: rewritten("Clean."))
        XCTAssertEqual(env.inserted, ["Clean."])
        XCTAssertEqual(env.copied, [])
    }

    func testFocusIsComparedAtInsertionTimeAfterADeferral() {
        let env = FakeEnvironment()
        env.frontmost = 10
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        env.recording = true
        seq.finish(a, outcome: rewritten("Clean."))
        env.frontmost = 30                    // user moved on while holding the key
        env.recording = false
        env.advance(by: 1)
        XCTAssertEqual(env.inserted, [])
        XCTAssertEqual(env.copied, ["Clean."])
    }

    // MARK: - secure fields: never pasted, regardless of anything else

    func testSecureOutcomeIsNeverPastedEvenWhenNotGuardedByAnythingElse() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        // Same setup as testPassthroughInsertsAtOnceWithNoTimersOrFocusCheck: a
        // plain dictation with rewrite off is normally inserted at once, with no
        // deferral or focus check at all. A secure outcome must still never paste.
        let ticket = seq.begin(raw: "my password is hunter2")
        seq.finish(ticket, outcome: secure("my password is hunter2"))
        XCTAssertEqual(env.inserted, [])
        XCTAssertEqual(env.copied, ["my password is hunter2"])
        XCTAssertEqual(env.notices, [DictationNotice.secureInput])
    }

    /// Finding 2 of the Day 3 hardening pass (security-engineer): a `secure`
    /// outcome whose reason was "couldn't check" (Accessibility off, or
    /// revoked mid-session) must still never be pasted -- same as any other
    /// secure outcome -- but must show a notice that says so, not the
    /// "secure input is active" wording that claims a certainty this case
    /// does not have.
    func testCannotDetermineOutcomeShowsItsOwnNoticeNotSecureInput() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let ticket = seq.begin(raw: "my password is hunter2")
        seq.finish(ticket, outcome: cannotDetermineSecure("my password is hunter2"))
        XCTAssertEqual(env.inserted, [])
        XCTAssertEqual(env.copied, ["my password is hunter2"])
        XCTAssertEqual(env.notices, [DictationNotice.cannotDetermineSecureInput])
    }

    func testSecureOutcomeTakesPriorityOverTheStillRecordingNotice() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        env.recording = true
        seq.finish(a, outcome: secure("raw"))
        env.advance(by: DictationSequencer.maxDeferral + 1)
        XCTAssertEqual(env.inserted, [], "never pasted while recording either")
        XCTAssertEqual(env.copied, ["raw"])
        XCTAssertEqual(env.notices, [DictationNotice.secureInput], "secure wording wins over stillRecording")
    }

    func testSecureOutcomeTakesPriorityOverTheSwitchedAppsNotice() {
        let env = FakeEnvironment()
        env.frontmost = 10
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        env.frontmost = 20
        seq.finish(a, outcome: secure("raw"))
        XCTAssertEqual(env.inserted, [])
        XCTAssertEqual(env.copied, ["raw"])
        XCTAssertEqual(env.notices, [DictationNotice.secureInput], "secure wording wins over switchedApps")
    }

    func testSecureOutcomeWithEmptyTextCopiesNothing() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "")
        seq.finish(a, outcome: RewriteOutcome(text: "", notice: nil, rewritten: false, attempted: false, secure: true))
        XCTAssertEqual(env.inserted, [])
        XCTAssertEqual(env.copied, [])
        XCTAssertEqual(env.notices, [DictationNotice.secureInput])
    }

    func testSecureOutcomeIsHeldLikeAnyOtherNoticeWhileANewerRecordingOwnsTheBar() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        env.currentPhase = .recording
        seq.finish(a, outcome: secure("raw"))
        XCTAssertEqual(env.copied, ["raw"], "the clipboard copy still happens at once")
        XCTAssertEqual(env.notices, [], "but the notice waits for the bar to be free")
        XCTAssertEqual(env.currentPhase, .recording)
    }

    // MARK: - secure outcomes scrub lastTranscription (Copy Last Dictation)

    func testSecureOutcomeClearsLastTranscriptionSoItCannotBeCopiedLater() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let ticket = seq.begin(raw: "my password is hunter2")
        XCTAssertEqual(env.lastTranscription, "my password is hunter2", "begin() sets it, as always")
        seq.finish(ticket, outcome: secure("my password is hunter2"))
        XCTAssertNil(env.lastTranscription, "but a secure outcome scrubs it at delivery time")
    }

    func testSecureOutcomeDoesNotClearANewerDictationsLastTranscription() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        // A is secure but its rewrite is still pending when B begins (the user
        // started dictating again immediately): B's begin() overwrites
        // lastTranscription with its own raw text before A is ever delivered.
        let a = seq.begin(raw: "my password is hunter2")
        seq.willRewrite(a)
        let b = seq.begin(raw: "remind me to call mom")
        XCTAssertEqual(env.lastTranscription, "remind me to call mom")
        seq.finish(a, outcome: secure("my password is hunter2"))
        XCTAssertEqual(env.lastTranscription, "remind me to call mom", "A's scrub must not wipe B's legitimate text")
        seq.finish(b, outcome: passthrough("remind me to call mom"))
        XCTAssertEqual(env.lastTranscription, "remind me to call mom")
    }

    func testTheSecureInputNoticeFollowsTheVoiceGuide() {
        let text = DictationNotice.secureInput
        XCTAssertFalse(text.contains("!"))
        XCTAssertTrue(text.contains("clipboard"))
        XCTAssertEqual(text.components(separatedBy: ". ").count, 2)
        XCTAssertTrue(text.hasSuffix("."))
    }

    // MARK: - QA acceptance pass (Day 3 secure-field fix): additional probes
    // not covered by the scenarios above.

    /// Whatever notice the caller (Edit, a rewrite failure, etc.) attached to a
    /// secure outcome, `deliver()` must always show the generic secure-input
    /// notice instead, because that is what actually happened (clipboard, not
    /// whatever the caller's own string claims). Mirrors what
    /// `EditCoordinatorTests` proves indirectly through the real coordinator;
    /// this pins the same contract at the sequencer level with an invented
    /// custom notice so it is not tautological against one specific caller's
    /// wording.
    func testSecureOutcomeOverridesWhateverCustomNoticeTheCallerAttached() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.finish(a, outcome: RewriteOutcome(
            text: "raw", notice: "Cannot use Edit in a secure field.", rewritten: false, attempted: true, secure: true
        ))
        XCTAssertEqual(env.notices, [DictationNotice.secureInput], "the caller's own notice text must never surface for a secure outcome")
        XCTAssertEqual(env.copied, ["raw"])
        XCTAssertEqual(env.inserted, [])
    }

    /// Finding, not a crash: `deliver()` sets `lastInsertAt` unconditionally
    /// (line 212), even when the delivery was a clipboard-only secure copy with
    /// no synthetic Cmd+V and therefore no clipboard-restore window to protect.
    /// The result is that a guarded dictation queued right behind a secure one
    /// still waits out `minInsertGap` before its own (real) paste, even though
    /// nothing was actually pasted a moment ago. Documented here so the
    /// behavior is explicit and can be judged on purpose, not rediscovered as
    /// a mystery delay later.
    func testASecureDeliveryStillImposesTheOrdinaryInsertGapOnTheNextGuardedInsert() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "secret")
        seq.finish(a, outcome: secure("secret"))
        XCTAssertEqual(env.copied, ["secret"])

        let b = seq.begin(raw: "raw")
        seq.willRewrite(b)
        seq.finish(b, outcome: rewritten("Clean."))
        XCTAssertEqual(env.inserted, [], "B is held for minInsertGap purely because A set lastInsertAt, despite A never having pasted anything")
        env.advance(by: DictationSequencer.minInsertGap + 0.01)
        XCTAssertEqual(env.inserted, ["Clean."])
    }

    /// Regression check (angle 2): the new secure branch sits ahead of
    /// `forceClipboard`/switchedApps in `deliver()`'s if/else-if chain, but for
    /// a NON-secure outcome it must be a no-op — the still-recording and
    /// switched-apps diversions, and their relative priority over each other,
    /// must be byte-for-byte what they were before the secure check existed.
    /// Forces both conditions to apply at once (recording timed out AND the
    /// app changed) and confirms stillRecording still wins, exactly as the
    /// pre-existing if/else-if order dictates.
    func testNonSecureOutcomeStillReachesStillRecordingAheadOfSwitchedAppsUnaffectedByTheSecureCheck() {
        let env = FakeEnvironment()
        env.frontmost = 10
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        env.recording = true
        seq.finish(a, outcome: rewritten("Clean."))
        env.frontmost = 20 // app also switched while still recording
        env.advance(by: DictationSequencer.maxDeferral + 1)
        XCTAssertEqual(env.inserted, [])
        XCTAssertEqual(env.copied, ["Clean."])
        XCTAssertEqual(env.notices, [DictationNotice.stillRecording], "forceClipboard must still be checked, and win, ahead of switchedApps, same as before the secure branch was added")
    }

    // MARK: - status bar guards

    func testRewritingStateIsShownOnlyWhileTranscribing() {
        for phase in [DictationPhase.idle, .recording, .rewriting, .other] {
            let env = FakeEnvironment()
            env.currentPhase = phase
            let seq = DictationSequencer(environment: env)
            seq.willRewrite(seq.begin(raw: "raw"))
            XCTAssertEqual(env.rewritingShown, 0, "\(phase)")
        }
        let env = FakeEnvironment()
        env.currentPhase = .transcribing
        let seq = DictationSequencer(environment: env)
        seq.willRewrite(seq.begin(raw: "raw"))
        XCTAssertEqual(env.rewritingShown, 1)
    }

    func testStatusReturnsToIdleAfterASuccessfulRewrite() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        seq.finish(a, outcome: rewritten("Clean."))
        XCTAssertEqual(env.idleShown, 1)
        XCTAssertEqual(env.currentPhase, .idle)
    }

    func testANoticeIsShownOnlyIfTheStatusBarIsStillOurs() {
        let ours = FakeEnvironment()
        var seq = DictationSequencer(environment: ours)
        var a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        seq.finish(a, outcome: fallback("raw", notice: "n"))
        XCTAssertEqual(ours.notices, ["n"])

        let taken = FakeEnvironment()
        seq = DictationSequencer(environment: taken)
        a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        taken.currentPhase = .recording          // a newer recording owns the bar
        seq.finish(a, outcome: fallback("raw", notice: "n"))
        XCTAssertEqual(taken.notices, [])
        XCTAssertEqual(taken.idleShown, 0)
        XCTAssertEqual(taken.currentPhase, .recording)
        XCTAssertEqual(taken.inserted, ["raw"] , "the text is still inserted, once")
    }

    func testANewerRecordingKeepsItsStatusWhenAnEarlierRewriteFinishes() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        env.currentPhase = .recording
        seq.finish(a, outcome: rewritten("Clean."))
        XCTAssertEqual(env.idleShown, 0)
        XCTAssertEqual(env.currentPhase, .recording)
        XCTAssertEqual(env.menuRefreshes, 1)
    }

    func testStatusStaysRewritingWhileAnotherDictationIsStillPending() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "a")
        seq.willRewrite(a)
        let b = seq.begin(raw: "b")
        seq.willRewrite(b)
        seq.finish(a, outcome: rewritten("A."))
        XCTAssertEqual(env.idleShown, 0)
        XCTAssertEqual(env.currentPhase, .rewriting)
        env.advance(by: 2)
        seq.finish(b, outcome: rewritten("B."))
        XCTAssertEqual(env.idleShown, 1)
    }

    func testPendingCountTracksIssuedButNotInsertedDictations() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        XCTAssertEqual(seq.pendingCount, 0)
        let a = seq.begin(raw: "a")
        XCTAssertEqual(seq.pendingCount, 1)
        seq.finish(a, outcome: passthrough("a"))
        XCTAssertEqual(seq.pendingCount, 0)
    }

    // MARK: - the notice copy

    func testTheSwitchedAppsNoticeFollowsTheVoiceGuide() {
        let text = DictationNotice.switchedApps
        XCTAssertFalse(text.contains("!"))
        XCTAssertTrue(text.contains("clipboard"))
        XCTAssertEqual(text.components(separatedBy: ". ").count, 2)
        XCTAssertTrue(text.hasSuffix("."))
    }

    // MARK: - L1: a recording that never ends cannot hold text forever

    func testBeforeTheDeferralLimitTheTextIsHeldNotInsertedNorCopied() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        env.recording = true                       // stuck hotkey, lost key-up
        seq.finish(a, outcome: rewritten("Clean."))
        env.advance(by: DictationSequencer.maxDeferral - 1)
        XCTAssertEqual(env.inserted, [])
        XCTAssertEqual(env.copied, [])
        XCTAssertEqual(seq.pendingCount, 1, "still waiting")
    }

    func testPastTheDeferralLimitTheTextGoesToTheClipboardWithANoticeAndTheTicketCompletes() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        env.recording = true
        seq.finish(a, outcome: rewritten("Clean."))
        env.advance(by: DictationSequencer.maxDeferral + 1)
        XCTAssertEqual(env.inserted, [], "never pasted while recording")
        XCTAssertEqual(env.copied, ["Clean."])
        XCTAssertEqual(env.notices, [DictationNotice.stillRecording])
        XCTAssertEqual(seq.pendingCount, 0, "the ticket is done")
        env.advance(by: 120)
        XCTAssertEqual(env.copied, ["Clean."], "exactly once")
        XCTAssertEqual(env.inserted, [])
    }

    func testTheDeferralClockStartsWhenTheDeferralStartsNotAtFinish() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "a")
        seq.willRewrite(a)
        seq.finish(a, outcome: rewritten("A."))       // not recording: pasted at once
        let b = seq.begin(raw: "b")
        seq.willRewrite(b)
        env.advance(by: 5)
        env.recording = true
        seq.finish(b, outcome: rewritten("B."))
        env.advance(by: DictationSequencer.maxDeferral - 1)
        XCTAssertEqual(env.copied, [])
        env.advance(by: 2)
        XCTAssertEqual(env.copied, ["B."])
    }

    func testReleasingTheKeyBeforeTheLimitStillPastes() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw")
        seq.willRewrite(a)
        env.recording = true
        seq.finish(a, outcome: rewritten("Clean."))
        env.advance(by: 20)
        env.recording = false
        env.advance(by: 1)
        XCTAssertEqual(env.inserted, ["Clean."])
        XCTAssertEqual(env.copied, [])
    }

    func testTheStillRecordingNoticeFollowsTheVoiceGuide() {
        let text = DictationNotice.stillRecording
        XCTAssertFalse(text.contains("!"))
        XCTAssertTrue(text.contains("clipboard"))
        XCTAssertEqual(text.components(separatedBy: ". ").count, 2)
    }

    // MARK: - L4: quitting with text pending

    func testFlushOnTerminatePutsPendingRawTextOnTheClipboardOldestFirstAndPastesNothing() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "first raw")
        seq.willRewrite(a)
        let b = seq.begin(raw: "second raw")
        seq.willRewrite(b)
        seq.flushPendingOnTerminate()
        XCTAssertEqual(env.copied, ["first raw\n\nsecond raw"])
        XCTAssertEqual(env.inserted, [])
    }

    func testFlushOnTerminateUsesTheRawTextOfAFinishedButDeferredDictation() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "raw words")
        seq.willRewrite(a)
        env.recording = true
        seq.finish(a, outcome: rewritten("Clean."))   // deferred behind the held key
        seq.flushPendingOnTerminate()
        XCTAssertEqual(env.copied, ["raw words"])
        XCTAssertEqual(env.inserted, [])
    }

    func testFlushOnTerminateDoesNothingWhenNothingIsPending() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)
        seq.flushPendingOnTerminate()
        XCTAssertEqual(env.copied, [], "the clipboard is left alone")
        let a = seq.begin(raw: "raw")
        seq.finish(a, outcome: passthrough("raw"))
        seq.flushPendingOnTerminate()
        XCTAssertEqual(env.copied, [], "an inserted dictation is not pending")
        XCTAssertEqual(env.inserted, ["raw"])
    }

    func testFlushOnTerminateSkipsADictationAlreadyDivertedToTheClipboard() {
        let env = FakeEnvironment()
        env.frontmost = 10
        let seq = DictationSequencer(environment: env)
        let a = seq.begin(raw: "a raw")
        seq.willRewrite(a)
        env.frontmost = 20
        seq.finish(a, outcome: rewritten("A."))
        seq.flushPendingOnTerminate()
        XCTAssertEqual(env.copied, ["A."], "no second copy")
    }

    // MARK: - stress: rapid overlapping hotkey presses, not covered above by
    // any single pairwise test

    /// Simulates pressing the hotkey far faster than any real dictation could
    /// ever complete: 25 dictations are all `begin()`un before any of them
    /// `finish()`es, their rewrites land back in a shuffled (not FIFO) order,
    /// the frontmost app and the recording flag are both churned on every
    /// step (standing in for "switch app mid-recording, repeatedly"), and one
    /// dictation is deliberately never finished at all (stands in for a
    /// rewrite request that silently never calls back, as distinct from the
    /// already-covered timeout-driven give-up path). The existing tests each
    /// drive at most two or three tickets through one specific rule by hand;
    /// none hammers the queue with this many in-flight tickets at once or
    /// finishes them out of order at this scale. The invariant from
    /// DictationSequencer's own doc comment must still hold: every dictation
    /// is delivered (inserted XOR copied) exactly once, never lost, never
    /// duplicated, and the ones that do get inserted keep their ticket order
    /// relative to each other.
    func testManyOverlappingDictationsAllOutOfOrderAreEachDeliveredExactlyOnce() {
        let env = FakeEnvironment()
        let seq = DictationSequencer(environment: env)

        let count = 25
        var tickets: [DictationSequencer.Ticket] = []
        for i in 0..<count {
            env.frontmost = Int32(i % 3) // churn "frontmost app" on every begin()
            env.recording = (i % 2 == 0) // churn "still recording" too
            let ticket = seq.begin(raw: "raw-\(i)")
            tickets.append(ticket)
            seq.willRewrite(ticket)
        }
        XCTAssertEqual(seq.pendingCount, count)

        // Finish all but the last ticket, in a deliberately shuffled order
        // (reversed, then every other one) rather than FIFO, and keep
        // churning recording/frontmost state as each one lands.
        let finishOrder = Array(stride(from: count - 2, through: 0, by: -1))
        for i in finishOrder {
            env.recording = (i % 3 == 0)
            env.frontmost = Int32(i % 2)
            seq.finish(tickets[i], outcome: rewritten("REWRITTEN-\(i)"))
        }
        // Ticket count-1 is left to never finish at all -- let its own
        // give-up timer fire instead, same mechanism as the existing
        // "never returns" test but now with 24 other tickets also mid-flight
        // ahead of it in the queue rather than alone.
        env.recording = false
        env.advance(by: DictationSequencer.maxWait + 1)

        // Drain any still-pending retry timers (deferral/notice-hold loops)
        // until nothing is scheduled, so every ticket that CAN be delivered
        // has been.
        var guardIterations = 0
        while env.scheduledCount > 0 && guardIterations < 1000 {
            env.advance(by: max(DictationSequencer.minInsertGap, DictationSequencer.retryInterval))
            guardIterations += 1
        }
        XCTAssertLessThan(guardIterations, 1000, "drain loop never settled -- possible livelock")

        XCTAssertEqual(seq.pendingCount, 0, "every ticket must eventually be delivered, none left stuck")

        // Every one of the 25 raw dictations must appear exactly once across
        // both destinations, never in both, never in neither, never twice.
        let delivered = env.inserted + env.copied
        XCTAssertEqual(delivered.count, count, "each dictation must be delivered exactly once in total")
        XCTAssertEqual(Set(delivered).count, delivered.count, "no dictation was delivered more than once")
        for i in 0..<count {
            let expectedRaw = "raw-\(i)"
            let expectedRewritten = "REWRITTEN-\(i)"
            let matches = delivered.filter { $0 == expectedRaw || $0 == expectedRewritten }
            XCTAssertEqual(matches.count, 1, "ticket \(i) must be delivered exactly once; found \(matches.count)")
        }

        // Among whichever subset actually got pasted (as opposed to diverted
        // to the clipboard by a focus change or a still-recording guard),
        // ticket order must still be respected: DictationSequencer never
        // inserts ticket N+1 before ticket N.
        func ticketIndex(of delivered: String) -> Int? {
            if delivered.hasPrefix("raw-") { return Int(delivered.dropFirst(4)) }
            if delivered.hasPrefix("REWRITTEN-") { return Int(delivered.dropFirst(10)) }
            return nil
        }
        let insertedIndices = env.inserted.compactMap(ticketIndex)
        XCTAssertEqual(insertedIndices, insertedIndices.sorted(), "pasted dictations must stay in ticket order")
    }
}
