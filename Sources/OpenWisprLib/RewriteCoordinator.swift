import Foundation
import CoreGraphics

/// What to do with one finished transcript: the text to insert and an optional
/// one-shot notice to show. `text` is never empty for a non-empty transcript.
struct RewriteOutcome: Equatable {
    var text: String
    var notice: String?
    /// True when the text is the service's rewrite rather than the raw transcript.
    var rewritten: Bool
    /// True when the rewriting state was shown for this dictation (a request was
    /// about to be made), so the insertion step owns cleaning it up. False when
    /// nothing was sent and nothing was shown.
    var attempted: Bool = false
    /// True when the focused context was found to be secure (a secure field, or
    /// system-wide secure keyboard input) at the moment this dictation would have
    /// been inserted. `DictationSequencer` never pastes when this is true — a
    /// synthetic paste into a secure field can silently fail or behave
    /// unpredictably, with no way to tell whether it worked — and always treats
    /// the outcome as guarded regardless of `attempted`, so the same deferral and
    /// notice rules apply as to any other diverted insert.
    var secure: Bool = false
    /// Set only by `AskCoordinator`, when it captured a window-scoped
    /// screenshot to answer with: that window's on-screen frame, in AppKit/
    /// `NSScreen` coordinates (already converted from the Accessibility frame
    /// `ScreenCapturer` used — see `AXTreeWalker.axRectToScreenRect`). The
    /// model's `<box>` tags (`BoundingBoxParser`) are normalized 0-1000
    /// coordinates relative to whatever image was sent, so placing one back on
    /// screen needs this window's frame, not the display's. `nil` for every
    /// other coordinator and whenever Ask captured no screenshot.
    var capturedWindowFrame: CGRect? = nil
}

/// Decides, for one dictation, whether the transcript is rewritten, and turns
/// every result into text to insert. It owns no UI and does no insertion:
/// `DictationSequencer` decides when and whether the outcome is pasted.
///
/// The gate is consulted first and nothing else is touched when it says no: the
/// reachability monitor and the pipeline are created lazily, on the first
/// dictation that passes the gate, so a user with rewrite off has no network
/// object at all and gets exactly the pre-rewrite behaviour.
///
/// The rewrite mode is passed as a closure that `process` evaluates once, on
/// entry, on the calling thread (the main thread in the app). It is therefore
/// sampled at the moment the decision is made, not when the recording stopped, so
/// switching Rewrite off while Whisper is still running stops the send. This type
/// never holds config and never reads it from a background thread.
///
/// Concurrency: each call is independent and nothing is cancelled. The
/// pipeline's own 6 s deadline bounds every request.
final class RewriteCoordinator {
    typealias Rewriter = (String) async -> Result<String, RewriteError>

    /// The production request deadline. Asserted by a test.
    static let productionTimeout: TimeInterval = 6

    private let gate: (RewriteMode) -> Bool
    private let makeReachability: () -> NetworkReachability
    private let makeRewriter: () -> Rewriter
    private let lock = NSLock()
    private var reachability: NetworkReachability?
    private var rewriter: Rewriter?
    private var stoppedForSession = false

    /// - Parameters:
    ///   - gate: must be backed by `RewriteGate.shouldRewrite`, and nothing else.
    ///   - makeReachability: called at most once, only after the gate passes.
    ///   - makeRewriter: called at most once, only after the gate passes and the
    ///     device is online.
    init(
        gate: @escaping (RewriteMode) -> Bool,
        makeReachability: @escaping () -> NetworkReachability,
        makeRewriter: @escaping () -> Rewriter
    ) {
        self.gate = gate
        self.makeReachability = makeReachability
        self.makeRewriter = makeRewriter
    }

    /// Production wiring. Every input is injectable so tests can prove the gate
    /// honours mode, consent and token, and that the deadline is 6 s.
    static func production(
        consent: RewriteConsent = .shared,
        hasToken: @escaping () -> Bool = { SessionStore().isSignedIn },
        timeout: TimeInterval = RewriteCoordinator.productionTimeout,
        config: @escaping () -> Config? = { nil },
        makeReachability: @escaping () -> NetworkReachability = { PathMonitorReachability() },
        makeRewriter: @escaping (TimeInterval) -> Rewriter = { RewriteCoordinator.pipelineRewriter(timeout: $0) }
    ) -> RewriteCoordinator {
        RewriteCoordinator(
            gate: { mode in
                RewriteGate.shouldRewrite(mode: mode, consent: consent, hasToken: hasToken(), config: config())
            },
            makeReachability: makeReachability,
            makeRewriter: { makeRewriter(timeout) }
        )
    }

    /// The only place a `RewritePipeline` is constructed (a test enforces this).
    ///
    /// Preference order when more than one on-device option is enabled: on-device
    /// Apple Intelligence (`FoundationModelsPipeline`) first — it costs 0 extra app
    /// size and needs 0 separate install, unlike Ollama, which needs a server the
    /// user runs themselves — then Ollama (`LocalLLMPipeline`), then the cloud
    /// pipeline, then (outside this function, in `RewriteCoordinator.outcome`) the
    /// raw transcript on total failure. `onDeviceAIEnabled` alone is not enough:
    /// `FoundationModelsPipeline.isAvailable` must also be true, so a Mac where
    /// Apple Intelligence is off falls through to Ollama or the cloud pipeline
    /// instead of silently failing.
    static func pipelineRewriter(timeout: TimeInterval) -> Rewriter {
        let config = Config.load()
        if config.onDeviceAIEnabled?.value == true, FoundationModelsPipeline.isAvailable {
            return { await FoundationModelsPipeline.rewrite(transcript: $0, timeout: timeout) }
        }
        if config.localLLMEnabled?.value == true,
           let url = LocalLLMPipeline.validatedURL(from: config.localLLMURL) {
            let model = config.localLLMModel ?? LocalLLMPipeline.defaultModel
            let localPipeline = LocalLLMPipeline(baseURL: url, model: model, timeout: timeout)
            return { await localPipeline.rewrite(transcript: $0) }
        }
        let pipeline = RewritePipeline(timeout: timeout)
        return { await pipeline.rewrite(transcript: $0) }
    }

    /// Forget a session-long stop (see `process`). Call when the user turns
    /// rewrite off or on.
    func resetSession() {
        lock.lock()
        stoppedForSession = false
        lock.unlock()
    }

    /// Calls `completion` exactly once. It runs synchronously, on the calling
    /// thread, when nothing is sent (gate closed, blank transcript, stopped for
    /// the session), and on a background thread when a request was attempted.
    /// `willRewrite` runs first, on the calling thread, only when a request is
    /// about to be made.
    ///
    /// After the service answers "sign in" (401) or "not Pro" (402), it will answer
    /// the same to every later transcript, so the rest of the session inserts raw
    /// text without sending anything and without repeating the notice.
    func process(
        transcript: String,
        mode currentMode: () -> RewriteMode,
        willRewrite: () -> Void,
        completion: @escaping (RewriteOutcome) -> Void
    ) {
        let mode = currentMode()
        let raw = RewriteOutcome(text: transcript, notice: nil, rewritten: false)

        if mode == .off { resetSession() }

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              gate(mode)
        else {
            completion(raw)
            return
        }

        guard !isStoppedForSession else {
            completion(raw)
            return
        }

        let reachability = resolvedReachability()
        willRewrite()
        Task {
            guard await reachability.isOnline(waitingUpTo: ReachabilityWait.firstUpdateTimeout) else {
                completion(RewriteOutcome(
                    text: transcript, notice: RewriteError.offline.userNotice, rewritten: false, attempted: true
                ))
                return
            }
            let result = await self.resolvedRewriter()(transcript)
            self.noteResult(result)
            completion(RewriteCoordinator.outcome(for: result, raw: transcript))
        }
    }

    /// Only a rewrite that passes `RewriteSanitizer` replaces the transcript.
    /// Anything else, including a blank or hostile "success", falls back to the
    /// raw text.
    static func outcome(for result: Result<String, RewriteError>, raw: String) -> RewriteOutcome {
        switch result {
        case .success(let text):
            switch RewriteSanitizer.sanitize(text, raw: raw) {
            case .success(let clean):
                return RewriteOutcome(text: clean, notice: nil, rewritten: true, attempted: true)
            case .failure:
                return RewriteOutcome(text: raw, notice: RewriteError.invalidResponse.userNotice, rewritten: false, attempted: true)
            }
        case .failure(let error):
            return RewriteOutcome(text: raw, notice: error.userNotice, rewritten: false, attempted: true)
        }
    }

    private var isStoppedForSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedForSession
    }

    private func noteResult(_ result: Result<String, RewriteError>) {
        guard case .failure(let error) = result, error == .requiresPro || error == .unauthorized else { return }
        lock.lock()
        stoppedForSession = true
        lock.unlock()
    }

    private func resolvedReachability() -> NetworkReachability {
        lock.lock()
        defer { lock.unlock() }
        if let existing = reachability { return existing }
        let created = makeReachability()
        reachability = created
        return created
    }

    private func resolvedRewriter() -> Rewriter {
        lock.lock()
        defer { lock.unlock() }
        if let existing = rewriter { return existing }
        let created = makeRewriter()
        rewriter = created
        return created
    }

    /// The outcome for plain dictation when the dictate hotkey's own secure-input
    /// check (`checkSecureInput`, called before `process` from `AppDelegate`)
    /// found the focused context secure. Mirrors `EditCoordinator` and
    /// `AskCoordinator`'s own pre-network bailouts (see their `process` methods):
    /// the raw transcript is returned untouched, `attempted` is false because
    /// nothing is sent, and `secure` is true so `DictationSequencer` never pastes
    /// it. `nil` when the context is not secure, meaning the caller should go
    /// ahead and call `process` normally.
    ///
    /// This exists so the AppDelegate call site cannot repeat the bug this fixed:
    /// calling `process` first and only gating the paste afterwards would still
    /// send the transcript to the network from a secure field.
    static func secureDictateOutcome(for status: SecureInputCheck, transcript: String) -> RewriteOutcome? {
        guard status != .notSecure else { return nil }
        return RewriteOutcome(text: transcript, notice: nil, rewritten: false, attempted: false, secure: true)
    }
}
