import XCTest
@testable import OpenWisprLib

/// Manual clock and scheduler plus a log of everything the sequencer does, so
/// each rule can be tested without AppKit.
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
    func setLastTranscription(_ raw: String) { lastTranscription = raw }
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
}
