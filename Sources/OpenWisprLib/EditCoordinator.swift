import Foundation

final class EditCoordinator {
    typealias Editor = (String, String, String?) async -> Result<String, RewriteError>

    private let gate: (RewriteMode) -> Bool
    private let makeReachability: () -> NetworkReachability
    private let makeEditor: () -> Editor
    private let contextReader: AccessibilityContextReader
    private let lock = NSLock()
    private var reachability: NetworkReachability?
    private var editor: Editor?
    private var stoppedForSession = false

    init(
        gate: @escaping (RewriteMode) -> Bool,
        makeReachability: @escaping () -> NetworkReachability,
        makeEditor: @escaping () -> Editor,
        contextReader: AccessibilityContextReader = DefaultAccessibilityContextReader.system()
    ) {
        self.gate = gate
        self.makeReachability = makeReachability
        self.makeEditor = makeEditor
        self.contextReader = contextReader
    }

    static func production(
        consent: ContextConsent = .shared,
        hasToken: @escaping () -> Bool = { SessionStore().isSignedIn },
        timeout: TimeInterval = RewriteCoordinator.productionTimeout,
        config: @escaping () -> Config? = { nil },
        makeReachability: @escaping () -> NetworkReachability = { PathMonitorReachability() },
        makeEditor: @escaping (TimeInterval) -> Editor = { EditCoordinator.pipelineEditor(timeout: $0) },
        contextReader: AccessibilityContextReader = DefaultAccessibilityContextReader.system()
    ) -> EditCoordinator {
        EditCoordinator(
            gate: { mode in
                EditGate.shouldEdit(mode: mode, consent: consent, hasToken: hasToken(), config: config())
            },
            makeReachability: makeReachability,
            makeEditor: { makeEditor(timeout) },
            contextReader: contextReader
        )
    }

    static func pipelineEditor(timeout: TimeInterval) -> Editor {
        let config = Config.load()
        if config.localLLMEnabled?.value == true,
           let url = LocalLLMPipeline.validatedURL(from: config.localLLMURL) {
            let model = config.localLLMModel ?? LocalLLMPipeline.defaultModel
            let localPipeline = LocalLLMPipeline(baseURL: url, model: model, timeout: timeout)
            return { instruction, contextText, contextTitle in
                await localPipeline.edit(instruction: instruction, contextText: contextText, contextTitle: contextTitle)
            }
        }
        let pipeline = EditPipeline(timeout: timeout)
        return { instruction, text, title in
            await pipeline.edit(instruction: instruction, contextText: text, contextTitle: title)
        }
    }

    func resetSession() {
        lock.lock()
        stoppedForSession = false
        lock.unlock()
    }

    /// - Parameter prefetchedSnapshot: A snapshot the caller already obtained
    ///   *after* its own equivalent of this gate passed (the merged Context
    ///   hotkey reads once to decide Edit-vs-Ask routing, then hands that same
    ///   read in here instead of triggering a second Accessibility walk).
    ///   `nil` (the default, and what the standalone Edit hotkey passes) makes
    ///   this read for itself, after the gate below, exactly as before.
    func process(
        instruction: String,
        mode currentMode: () -> RewriteMode,
        willEdit: @escaping () -> Void,
        prefetchedSnapshot: ContextSnapshot? = nil,
        completion: @escaping (RewriteOutcome) -> Void
    ) {
        let mode = currentMode()
        let raw = RewriteOutcome(text: instruction, notice: nil, rewritten: false)

        if mode == .off { resetSession() }

        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
        let reader = self.contextReader

        Task {
            let snapshot: ContextSnapshot
            if let prefetchedSnapshot {
                snapshot = prefetchedSnapshot
            } else {
                snapshot = await reader.readSnapshot()
            }

            if snapshot.status == .excludedApp {
                completion(RewriteOutcome(text: instruction, notice: "Edit is disabled for this app to protect your privacy.", rewritten: false, attempted: true))
                return
            }

            // `secure: true` is what actually matters here: production hands this
            // outcome to `DictationSequencer.finish` exactly like plain dictation
            // (AppDelegate.swift), and `deliver()` checks `outcome.secure` first,
            // before anything else, copying to the clipboard and never calling
            // `env.insert`. Without it this outcome would flow through as an
            // ordinary "rewrite not attempted" result and get pasted raw into the
            // secure field it was just refused for. The `notice` string below is
            // only ever shown as written when `secure` is false; once it is true,
            // `deliver()` overwrites it with `DictationNotice.secureInput`, which
            // is accurate here (the text does end up on the clipboard), so it is
            // left as-is rather than duplicated.
            if snapshot.status == .secureField {
                completion(RewriteOutcome(text: instruction, notice: "Cannot use Edit in a secure field.", rewritten: false, attempted: true, secure: true))
                return
            }

            if snapshot.status == .secureEventInput {
                completion(RewriteOutcome(text: instruction, notice: "Cannot use Edit while secure keyboard input is on.", rewritten: false, attempted: true, secure: true))
                return
            }

            if let appName = snapshot.appName, DefaultExcludedApps.matchesByName(appName) {
                completion(RewriteOutcome(text: instruction, notice: "Edit is disabled for \(appName) to protect your privacy.", rewritten: false, attempted: true))
                return
            }

            guard let contextText = snapshot.selectedText else {
                completion(raw)
                return
            }

            // Best-effort only (see InjectionDetector's documentation): the real
            // protection is server-side prompt isolation in editPrompt.ts. This
            // just avoids sending the crudest attempts and tells the user why
            // nothing happened, instead of silently proceeding or silently
            // dropping the dictation.
            if InjectionDetector.containsInjection(text: contextText)
                || (snapshot.windowTitle.map(InjectionDetector.containsInjection) ?? false) {
                completion(RewriteOutcome(text: instruction, notice: "Selected text rejected due to unsafe instructions.", rewritten: false, attempted: true))
                return
            }

            // Must hop back to main to fire `willEdit` as it interacts with UI/Sequencer.
            DispatchQueue.main.async {
                willEdit()
            }

            guard await reachability.isOnline(waitingUpTo: ReachabilityWait.firstUpdateTimeout) else {
                completion(RewriteOutcome(
                    text: instruction, notice: RewriteError.offline.userNotice, rewritten: false, attempted: true
                ))
                return
            }
            
            let result = await self.resolvedEditor()(instruction, contextText, snapshot.windowTitle)
            self.noteResult(result)
            completion(RewriteCoordinator.outcome(for: result, raw: instruction))
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

    private func resolvedEditor() -> Editor {
        lock.lock()
        defer { lock.unlock() }
        if let existing = editor { return existing }
        let created = makeEditor()
        editor = created
        return created
    }
}
