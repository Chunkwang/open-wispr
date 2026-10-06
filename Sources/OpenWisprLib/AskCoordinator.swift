import Foundation
import CoreGraphics
import AppKit

final class AskCoordinator {
    typealias Asker = (String, String?, String?, Data?, String?) async -> Result<String, RewriteError>

    private let gate: (RewriteMode) -> Bool
    private let makeReachability: () -> NetworkReachability
    private let makeAsker: () -> Asker
    private let contextReader: AccessibilityContextReader
    /// How the frontmost app is read, both at t0 and in the TOCTOU re-check
    /// right before `AXTreeWalker.walkFrontmostWindow` (finding 2). Injectable so
    /// a test can simulate the frontmost app changing mid-request without a real
    /// window switch; production reads `NSWorkspace.shared` for real.
    private let frontmostApp: () -> FrontmostAppInfo?
    private let lock = NSLock()
    private var reachability: NetworkReachability?
    private var asker: Asker?
    private var stoppedForSession = false

    init(
        gate: @escaping (RewriteMode) -> Bool,
        makeReachability: @escaping () -> NetworkReachability,
        makeAsker: @escaping () -> Asker,
        contextReader: AccessibilityContextReader = DefaultAccessibilityContextReader.system(),
        frontmostApp: @escaping () -> FrontmostAppInfo? = { NSWorkspace.shared.frontmostApplication.map(FrontmostAppInfo.init) }
    ) {
        self.gate = gate
        self.makeReachability = makeReachability
        self.makeAsker = makeAsker
        self.contextReader = contextReader
        self.frontmostApp = frontmostApp
    }

    static func production(
        consent: ContextConsent = .shared,
        hasToken: @escaping () -> Bool = { SessionStore().isSignedIn },
        timeout: TimeInterval = 90,
        config: @escaping () -> Config? = { nil },
        makeReachability: @escaping () -> NetworkReachability = { PathMonitorReachability() },
        makeAsker: @escaping (TimeInterval) -> Asker = { AskCoordinator.pipelineAsker(timeout: $0) },
        contextReader: AccessibilityContextReader = DefaultAccessibilityContextReader.system()
    ) -> AskCoordinator {
        AskCoordinator(
            gate: { mode in
                AskGate.shouldAsk(mode: mode, consent: consent, hasToken: hasToken(), config: config())
            },
            makeReachability: makeReachability,
            makeAsker: { makeAsker(timeout) },
            contextReader: contextReader
        )
    }

    static func pipelineAsker(timeout: TimeInterval) -> Asker {
        let config = Config.load()
        if config.localLLMEnabled?.value == true {
            let url = URL(string: config.localLLMURL ?? "http://127.0.0.1:11434") ?? LocalLLMPipeline.defaultOllamaURL
            let model = config.localLLMModel ?? LocalLLMPipeline.defaultModel
            let localPipeline = LocalLLMPipeline(baseURL: url, model: model, timeout: timeout)
            return { instruction, text, title, image, uiTree in
                await localPipeline.ask(instruction: instruction, contextText: text, contextTitle: title)
            }
        }
        let pipeline = AskPipeline(timeout: timeout)
        return { instruction, text, title, image, uiTree in
            await pipeline.ask(instruction: instruction, contextText: text, contextTitle: title, jpegData: image, uiTree: uiTree)
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
    ///   `nil` (the default) makes this read for itself, after the gate below,
    ///   exactly as before. Either way, the TOCTOU re-check against the
    ///   frontmost app further down still runs before anything is sent.
    func process(
        instruction: String,
        mode currentMode: () -> RewriteMode,
        willAsk: @escaping () -> Void,
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
        let frontmostApp = self.frontmostApp
        // Captured now, at t0, alongside the snapshot read below, so the walk
        // that happens after the real-latency work further down (screen capture,
        // the reachability wait) can be refused if the frontmost app changed —
        // see the re-check right before `AXTreeWalker.walkFrontmostWindow` below.
        let frontmostAtStart = frontmostApp()

        Task {
            let snapshot: ContextSnapshot
            if let prefetchedSnapshot {
                snapshot = prefetchedSnapshot
            } else {
                snapshot = await reader.readSnapshot()
            }

            // `secure: true` mirrors the same flag on `EditCoordinator`'s bailouts
            // (see its comment): the field is part of `RewriteOutcome`'s contract
            // regardless of which coordinator fills it in, and must be set
            // whenever the context is secure even though Ask's only current
            // caller (AppDelegate's merged Context hotkey, no-selection branch)
            // hands this outcome straight to `AskOverlayController` rather than to
            // `DictationSequencer` — it never calls `env.insert` or
            // `copyToPasteboard` at all today, so nothing is pasted either way,
            // and the `notice` string below (unlike Edit's) is shown verbatim,
            // never overwritten by `deliver()`'s `DictationNotice.secureInput`.
            // It correctly says nothing about the clipboard, because nothing is
            // copied there on this path. If Ask is ever routed through the
            // sequencer instead, this flag is what will make that path safe too.
            if snapshot.status == .secureField {
                completion(RewriteOutcome(text: instruction, notice: "Cannot use Ask in a secure field.", rewritten: false, attempted: true, secure: true))
                return
            }

            if snapshot.status == .secureEventInput {
                completion(RewriteOutcome(text: instruction, notice: "Cannot use Ask while secure keyboard input is on.", rewritten: false, attempted: true, secure: true))
                return
            }

            if snapshot.status == .excludedApp {
                let appDesc = snapshot.bundleID ?? "this app"
                completion(RewriteOutcome(text: instruction, notice: "Ask is disabled for \(appDesc) to protect your privacy.", rewritten: false, attempted: true))
                return
            }

            // Also check by app name as a fallback for unknown bundle IDs
            if let appName = snapshot.appName, DefaultExcludedApps.matchesByName(appName) {
                completion(RewriteOutcome(text: instruction, notice: "Ask is disabled for \(appName) to protect your privacy.", rewritten: false, attempted: true))
                return
            }

            // Best-effort only (see InjectionDetector's documentation): the real
            // protection is server-side prompt isolation. This just avoids
            // sending the crudest attempts and tells the user why, instead of
            // silently proceeding or silently dropping the dictation.
            if let selected = snapshot.selectedText, InjectionDetector.containsInjection(text: selected) {
                completion(RewriteOutcome(text: instruction, notice: "Selected text rejected due to unsafe instructions.", rewritten: false, attempted: true))
                return
            }
            if let title = snapshot.windowTitle, InjectionDetector.containsInjection(text: title) {
                completion(RewriteOutcome(text: instruction, notice: "Window title rejected due to unsafe instructions.", rewritten: false, attempted: true))
                return
            }

            var processedImage: ProcessedImage? = nil
            // The window this screenshot is scoped to, in AppKit/NSScreen
            // coordinates, carried through to the final outcome so the
            // bounding-box overlay (the model's <box> tags are normalized
            // 0-1000 against whatever image was sent) can place a box inside
            // this window rather than somewhere on the full display.
            var capturedWindowFrame: CGRect? = nil
            if #available(macOS 14.0, *), let pid = frontmostAtStart?.pid {
                // Read now, before the capture, so the window being rasterized
                // and the window this frame describes are the one the gate
                // above already checked — not whatever is frontmost later.
                let axWindowFrame = AXTreeWalker.frontmostWindowFrame(expectedPID: pid)
                if let capture = try? await ScreenCapturer.captureFrontmostWindow(pid: pid, windowFrame: axWindowFrame) {
                    processedImage = try? await ImageProcessor.process(cgImage: capture.image)
                    capturedWindowFrame = AXTreeWalker.axRectToScreenRect(capture.frame)
                }
            }

            DispatchQueue.main.async {
                willAsk()
            }

            guard await reachability.isOnline(waitingUpTo: ReachabilityWait.firstUpdateTimeout) else {
                completion(RewriteOutcome(
                    text: instruction, notice: RewriteError.offline.userNotice, rewritten: false, attempted: true
                ))
                return
            }

            // TOCTOU re-check: the screen capture and the reachability wait
            // above are real latency, during which the user can switch to a
            // different app — a banking app or a password manager, say. Nothing
            // above has re-verified the frontmost app since `snapshot` was read,
            // so the AX tree about to be walked could belong to a different,
            // possibly excluded, app. Re-verify right before walking it, and
            // pass the pid captured at t0 through so the walker's own check
            // (item 1) is not the only thing standing in the way.
            let frontmostNow = frontmostApp()
            guard !AskCoordinator.frontmostAppChanged(from: frontmostAtStart, to: frontmostNow) else {
                completion(RewriteOutcome(
                    text: instruction,
                    notice: "You switched apps while Ask was gathering context, so nothing was sent.",
                    rewritten: false, attempted: true
                ))
                return
            }

            var textToSend = snapshot.selectedText
            if textToSend == nil || textToSend!.isEmpty {
                textToSend = processedImage?.recognizedText
            }
            
            if let ocrText = processedImage?.recognizedText, InjectionDetector.containsInjection(text: ocrText) {
                completion(RewriteOutcome(text: instruction, notice: "Screen content rejected due to unsafe instructions.", rewritten: false, attempted: true))
                return
            }
            
            var uiTreeString: String? = nil
            var nodes: [AXElementNode] = []
            if #available(macOS 14.0, *), let expectedPID = frontmostAtStart?.pid {
                nodes = AXTreeWalker.walkFrontmostWindow(expectedPID: expectedPID)
                if !nodes.isEmpty {
                    uiTreeString = nodes.map { $0.stringRepresentation }.joined(separator: "\n")
                }
            }

            let result = await self.resolvedAsker()(instruction, textToSend, snapshot.windowTitle, processedImage?.jpegData, uiTreeString)
            self.noteResult(result)
            
            var finalResult = result
            if case .success(let answer) = result {
                if let regex = try? NSRegularExpression(pattern: "<pointer id=\"(\\d+)\"\\s*/?>", options: []),
                   let match = regex.firstMatch(in: answer, options: [], range: NSRange(location: 0, length: answer.utf16.count)),
                   let idRange = Range(match.range(at: 1), in: answer),
                   let id = Int(answer[idRange]) {
                    
                    if let targetNode = nodes.first(where: { $0.id == id }) {
                        DispatchQueue.main.async {
                            PointerOverlayController.shared.showPointer(at: targetNode.frame)
                        }
                    }
                    
                    let cleanedAnswer = answer.replacingOccurrences(of: regex.pattern, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                    finalResult = .success(cleanedAnswer)
                }
            }
            
            var outcome = RewriteCoordinator.outcome(for: finalResult, raw: instruction)
            outcome.capturedWindowFrame = capturedWindowFrame
            completion(outcome)
        }
    }

    /// True when `now` is not the same app as `start` (a different pid), or `now`
    /// is on the exclusion list — either means the AX tree about to be walked
    /// must not be. Pure and side-effect free, so a test can exercise the TOCTOU
    /// re-check (finding 2) with fabricated `FrontmostAppInfo` values instead of
    /// driving `process()` through a real screen capture.
    static func frontmostAppChanged(
        from start: FrontmostAppInfo?, to now: FrontmostAppInfo?, exclusions: ExcludedApps = ExcludedApps()
    ) -> Bool {
        if start?.pid != now?.pid { return true }
        if let bundleID = now?.bundleID,
           let cleaned = ContextText.identifier(bundleID, maxScalars: ContextSnapshot.maxBundleIDScalars),
           exclusions.reason(forBundleID: cleaned) != nil {
            return true
        }
        if let name = now?.localizedName, DefaultExcludedApps.matchesByName(name) { return true }
        return false
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

    private func resolvedAsker() -> Asker {
        lock.lock()
        defer { lock.unlock() }
        if let existing = asker { return existing }
        let created = makeAsker()
        asker = created
        return created
    }
}
