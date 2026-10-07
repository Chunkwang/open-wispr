import Foundation

/// What the status bar is showing, reduced to what the sequencer needs to know.
enum DictationPhase: Equatable {
    case idle
    case recording
    case transcribing
    case rewriting
    /// Downloading, waiting for a permission, a notice or an error.
    case other
}

/// Everything the sequencer touches outside itself. `AppDelegate` supplies the
/// real one; tests supply a fake with a manual clock. `@MainActor` makes the
/// "main thread only" contract this doc comment used to merely assert into
/// something the compiler enforces at every call site.
@MainActor
protocol DictationEnvironment: AnyObject {
    /// Monotonic seconds.
    func now() -> TimeInterval
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
    func frontmostProcessID() -> Int32?
    /// True while the dictation hotkey is held or a recording is in progress.
    func isRecordingActive() -> Bool

    /// Puts `text` at the cursor (clipboard plus synthetic Cmd+V).
    func insert(_ text: String)
    /// Puts `text` on the clipboard and sends no keystroke.
    func copyToPasteboard(_ text: String)
    /// `nil` clears it (see `deliver`'s secure branch): there is nothing safe to
    /// show on "Copy Last Dictation" once that text has turned out to belong to a
    /// secure field.
    func setLastTranscription(_ raw: String?)

    var phase: DictationPhase { get }
    func showRewriting()
    func showIdle()
    func showNotice(_ message: String)
    func refreshMenu()
}

/// Decides when, and whether, each finished dictation is pasted. A rewrite can
/// take up to its 6 s deadline, so by the time a result arrives the user may have
/// switched apps, started another dictation, or be holding the hotkey. The rules:
///
/// - Each dictation is inserted exactly once, and never as empty text.
/// - In order: dictation N is inserted only after N-1 has been inserted. A
///   dictation that never reports back is given up on after `maxWait` and its raw
///   transcript is inserted in its place, so nothing waits behind it forever.
/// - Never while a recording is active or the hotkey is held: it waits, but at
///   most `maxDeferral`; after that the text goes on the clipboard instead, so it
///   is never held only in memory indefinitely.
/// - Never two inserts inside one clipboard-restore window: the second waits.
/// - If the frontmost app is no longer the one that was frontmost when the
///   transcript was ready, nothing is pasted: the text goes on the clipboard and
///   the user is told.
/// - If the focused context is secure (a secure field, or secure keyboard input
///   system-wide), nothing is pasted, regardless of recording or focus state:
///   the text goes on the clipboard and the user is told. This takes priority
///   over every other notice below.
/// - Whenever text ends somewhere other than the cursor, or a fallback needs
///   explaining, the user is told. If a newer recording or another notice owns the
///   status bar, the notice is held and shown when the bar is next idle.
/// - On quit, the raw text of anything still pending goes on the clipboard.
/// - `lastTranscription` is set to the RAW text when the transcript is ready,
///   before any wait, and never changes to the rewrite. If the outcome turns out
///   to be secure, it is cleared back to nil at delivery time: "Copy Last
///   Dictation" must never be able to re-expose a secure field's text after the
///   fact.
///
/// A dictation that needed no waiting (rewrite not attempted, no earlier
/// dictation pending) skips the deferral and focus checks entirely and is
/// inserted at once, exactly as before rewrite existed.
///
/// `@MainActor`: every mutable property here (`nextID`, `ready`, `openTickets`,
/// `lastTranscriptionOwner`, ...) used to be guarded only by a doc-comment
/// convention that every call happens on the main thread, with nothing
/// enforcing it. A stress test firing concurrent `begin()`/`finish()` calls
/// from a background queue reproduced real memory corruption (unsynchronized
/// `Dictionary` mutation). `@MainActor` turns that convention into a
/// compile-time guarantee instead of a lock, which was the deliberate choice
/// over adding an internal `NSLock`: a future caller mistake now fails to
/// build instead of silently serializing (or, worse, not serializing) around
/// a violation nobody notices.
@MainActor
final class DictationSequencer {
    struct Ticket: Equatable {
        let id: Int
        let raw: String
        let frontmostAtStart: Int32?
    }

    /// Longest an attempted rewrite may hold up the queue. The request's own
    /// deadline is 6 s; this covers the wait for the network check on top.
    static let maxWait: TimeInterval = 8
    /// Gap between two inserts: the clipboard-restore delay plus a margin, so one
    /// paste's restore never overlaps the next paste.
    static let minInsertGap: TimeInterval = TextInserter.defaultRestoreDelay + 0.1
    static let retryInterval: TimeInterval = 0.25
    /// Longest a finished dictation waits for a recording to end before it is put
    /// on the clipboard instead of pasted.
    static let maxDeferral: TimeInterval = 30
    static let noticePollInterval: TimeInterval = 0.5
    /// Longest a held notice waits for an idle status bar (never while recording).
    static let maxNoticeHold: TimeInterval = 30

    private struct Entry {
        let ticket: Ticket
        let outcome: RewriteOutcome
        /// Subject to the deferral and focus rules.
        let guarded: Bool
    }

    private let env: DictationEnvironment
    private var nextID = 0
    private var nextToInsert = 0
    private var ready: [Int: Entry] = [:]
    private var lastInsertAt: TimeInterval?
    private var retryScheduled = false
    private var openTickets: [Int: Ticket] = [:]
    private var deferredSince: TimeInterval?
    private var heldNotices: [String] = []
    private var heldSince: TimeInterval?
    private var noticePollScheduled = false
    /// The ticket whose raw text `lastTranscription` currently shows, if any.
    /// Needed because a later dictation can `begin()` (and so overwrite
    /// `lastTranscription`) before an earlier, still-pending one is `deliver`ed;
    /// without tracking this, scrubbing a secure outcome's text (see `deliver`)
    /// could wipe out a newer, non-secure dictation's legitimate text instead.
    private var lastTranscriptionOwner: Int?

    init(environment: DictationEnvironment) {
        self.env = environment
    }

    /// Dictations issued but not yet inserted.
    var pendingCount: Int { nextID - nextToInsert }

    /// Call when a non-empty transcript is ready. Records the raw text for "Copy
    /// Last Dictation" and the frontmost app at this moment.
    func begin(raw: String) -> Ticket {
        let ticket = Ticket(id: nextID, raw: raw, frontmostAtStart: env.frontmostProcessID())
        nextID += 1
        openTickets[ticket.id] = ticket
        env.setLastTranscription(raw)
        lastTranscriptionOwner = ticket.id
        return ticket
    }

    /// Call when a rewrite request is about to start. Shows the rewriting state
    /// unless something newer already owns the status bar, and starts the
    /// give-up timer.
    func willRewrite(_ ticket: Ticket) {
        if env.phase == .transcribing { env.showRewriting() }
        env.schedule(after: DictationSequencer.maxWait) { [weak self] in
            self?.giveUp(on: ticket)
        }
    }

    /// Reports the result for `ticket`. Only the first report counts.
    func finish(_ ticket: Ticket, outcome: RewriteOutcome) {
        guard ticket.id >= nextToInsert, ready[ticket.id] == nil else { return }
        let guarded = outcome.attempted || outcome.secure || ticket.id != nextToInsert
        ready[ticket.id] = Entry(ticket: ticket, outcome: outcome, guarded: guarded)
        drain()
    }

    private func giveUp(on ticket: Ticket) {
        finish(ticket, outcome: RewriteOutcome(
            text: ticket.raw,
            notice: RewriteError.timedOut.userNotice,
            rewritten: false,
            attempted: true
        ))
    }

    private func drain() {
        while let entry = ready[nextToInsert] {
            var forceClipboard = false
            if entry.guarded {
                if env.isRecordingActive() {
                    let since = deferredSince ?? env.now()
                    deferredSince = since
                    if env.now() - since < DictationSequencer.maxDeferral {
                        scheduleRetry(after: DictationSequencer.retryInterval)
                        return
                    }
                    forceClipboard = true
                } else {
                    deferredSince = nil
                }
                if let last = lastInsertAt {
                    let remaining = last + DictationSequencer.minInsertGap - env.now()
                    if remaining > 0 {
                        scheduleRetry(after: remaining)
                        return
                    }
                }
            }
            ready[nextToInsert] = nil
            openTickets[nextToInsert] = nil
            nextToInsert += 1
            deferredSince = nil
            deliver(entry, forceClipboard: forceClipboard)
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        guard !retryScheduled else { return }
        retryScheduled = true
        env.schedule(after: delay) { [weak self] in
            guard let self = self else { return }
            self.retryScheduled = false
            self.drain()
        }
    }

    private func deliver(_ entry: Entry, forceClipboard: Bool) {
        let ticket = entry.ticket
        // Never insert empty text: fall back to the raw transcript.
        let text = entry.outcome.text.isEmpty ? ticket.raw : entry.outcome.text
        var notice = entry.outcome.notice

        if entry.outcome.secure {
            // Never attempted, regardless of recording state or focus: there is
            // no point simulating a paste that likely won't work, and might
            // behave unpredictably, in a security-sensitive context.
            if !text.isEmpty { env.copyToPasteboard(text) }
            // `secureStatusUnknown` means Accessibility couldn't even be asked
            // (see `SecureInputCheck.cannotDetermine`): "couldn't check" is a
            // different claim from "checked, and it's secure," so it gets its
            // own notice rather than the default below.
            notice = entry.outcome.secureStatusUnknown
                ? DictationNotice.cannotDetermineSecureInput
                : DictationNotice.secureInput
            // `begin()` already set `lastTranscription` to this raw text before
            // the secure determination was known. Scrub it now so "Copy Last
            // Dictation" (StatusBarController) cannot re-expose a secure field's
            // text later, indefinitely, with no indication of where it came from.
            // Only when nothing newer has already overwritten it first (see
            // `lastTranscriptionOwner`'s doc comment) — otherwise this would wipe
            // out a later, non-secure dictation's legitimate text.
            if lastTranscriptionOwner == ticket.id {
                env.setLastTranscription(nil)
                lastTranscriptionOwner = nil
            }
        } else if forceClipboard {
            if !text.isEmpty { env.copyToPasteboard(text) }
            notice = DictationNotice.stillRecording
        } else if entry.guarded && env.frontmostProcessID() != ticket.frontmostAtStart {
            if !text.isEmpty { env.copyToPasteboard(text) }
            notice = DictationNotice.switchedApps
        } else if !text.isEmpty {
            env.insert(text)
        }
        lastInsertAt = env.now()

        if !entry.guarded {
            env.showIdle()
            if let notice = notice { env.showNotice(notice) }
        } else if let notice = notice {
            surface(notice)
        } else if (env.phase == .rewriting || env.phase == .transcribing) && pendingCount == 0 {
            env.showIdle()
        }
        env.refreshMenu()
    }

    // MARK: - notices

    /// Shows `notice` now if the status bar is free to take it. If a newer
    /// recording or another message owns the bar, it is held and shown when the
    /// bar is next idle, so the user is always told where their text went.
    private func surface(_ notice: String) {
        switch env.phase {
        case .idle, .rewriting, .transcribing:
            env.showNotice(notice)
        case .recording, .other:
            if heldNotices.isEmpty { heldSince = env.now() }
            heldNotices.append(notice)
            scheduleNoticePoll()
        }
    }

    private func scheduleNoticePoll() {
        guard !noticePollScheduled else { return }
        noticePollScheduled = true
        env.schedule(after: DictationSequencer.noticePollInterval) { [weak self] in
            guard let self = self else { return }
            self.noticePollScheduled = false
            self.showHeldNoticeIfPossible()
        }
    }

    private func showHeldNoticeIfPossible() {
        guard !heldNotices.isEmpty else { return }
        let waited = env.now() - (heldSince ?? env.now())
        let phase = env.phase
        // Never over a live recording; otherwise, after a long wait, take the bar.
        if phase == .idle || (waited >= DictationSequencer.maxNoticeHold && phase != .recording) {
            env.showNotice(heldNotices.removeFirst())
            heldSince = env.now()
        }
        if !heldNotices.isEmpty { scheduleNoticePoll() }
    }

    // MARK: - quitting

    /// Call from `applicationWillTerminate`. Puts the raw text of every dictation
    /// that has not been inserted yet on the clipboard (oldest first, blank line
    /// between), so quitting mid-rewrite or mid-deferral does not lose it. Does
    /// nothing, and leaves the clipboard alone, when nothing is pending. Nothing is
    /// written to disk.
    func flushPendingOnTerminate() {
        let pending = openTickets.keys.sorted().compactMap { openTickets[$0]?.raw }.filter { !$0.isEmpty }
        guard !pending.isEmpty else { return }
        env.copyToPasteboard(pending.joined(separator: "\n\n"))
    }
}
