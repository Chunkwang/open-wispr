import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController!
    var hotkeyManagers: [HotkeyManager] = []
    var recorder: AudioRecorder!
    var transcriber: Transcriber!
    var inserter: TextInserter!
    var config: Config!
    var recordingLifecycle = RecordingLifecycle()
    var currentRecordingURL: URL?
    /// Correlation id for the latency timing log (DictationTiming.swift), set
    /// fresh at each `handleRecordingStart`. Debug-only, local console output;
    /// never the dictated text. Best-effort: if a second dictation starts
    /// before the first one has pasted (the sequencer allows this — see
    /// `DictationSequencer`'s queue), the first one's `paste_done` line can
    /// end up stamped with the newer token. Acceptable for a timing log, not
    /// for anything that must be exact.
    fileprivate var currentDictationToken: String?
    private var sleepWakeObservers: [NSObjectProtocol] = []
    var isReady = false
    public var lastTranscription: String?
    /// Owns the rewrite decision. Built on the main thread at launch (it creates
    /// no network object until a dictation passes the gate).
    private var rewriteCoordinator: RewriteCoordinator!
    private var editCoordinator: EditCoordinator!
    private var askCoordinator: AskCoordinator!
    
    enum RecordingMode { case dictate, edit, context }
    private var currentRecordingMode: RecordingMode = .dictate
    
    private var editHotkeyManager: HotkeyManager?
    private var askHotkeyManager: HotkeyManager?

    /// Sign-in hooks for the sign-in window and menu. Signing in or out lifts the
    /// rewrite coordinator's session-long stop. Main thread only.
    private(set) var authCoordinator: AuthCoordinator!
    /// Owns when, and whether, each finished dictation is pasted. Main thread only.
    private var sequencer: DictationSequencer!
    /// The most recent (raw, rewritten) dictation pair in memory (Task 7.1).
    /// Never written to disk; dropped when the app quits.
    private(set) var lastRewritePair: (raw: String, rewritten: String)?
    /// True while a finished dictation is waiting to be pasted or being pasted.
    /// The sign-in window checks it before touching the pasteboard. `@MainActor`
    /// because `DictationSequencer.pendingCount` now is: both of this property's
    /// callers (`SignInWindowController`, `SignInFlow`) are themselves
    /// `@MainActor`, so this adds no new thread requirement for them.
    @MainActor
    var isDictationInsertInFlight: Bool { (sequencer?.pendingCount ?? 0) > 0 }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        recorder = AudioRecorder()
        // `config` is nil until `setupInner()` loads it (it runs after this, on a
        // background queue), and these coordinators are not used before then, so
        // the closures below just read whatever is current at call time. Without
        // a real config, the gates never see `agentLayerEnabled` or
        // `localLLMEnabled`, silently disabling both no matter what config.json says.
        rewriteCoordinator = RewriteCoordinator.production(config: { [weak self] in self?.config })
        editCoordinator = EditCoordinator.production(config: { [weak self] in self?.config })
        askCoordinator = AskCoordinator.production(config: { [weak self] in self?.config })
        let rewriteCoordinator = self.rewriteCoordinator!
        let editCoordinator = self.editCoordinator!
        let askCoordinator = self.askCoordinator!
        // Captured as a local `let`, same as the coordinators above, so this
        // `@Sendable` closure never captures `self` (an NSObject, not Sendable).
        let statusBarForSessionChange = self.statusBar!
        authCoordinator = AuthCoordinator(didChangeSession: {
            rewriteCoordinator.resetSession()
            editCoordinator.resetSession()
            askCoordinator.resetSession()
            // Task 4.6: a sign-in needs the new user's tier, and a sign-out must
            // not leave a stale Pro (or Free) badge showing.
            TierStore.refresh(completion: { statusBarForSessionChange.buildMenu() })
        })
        // Task 4.6: also fetch at launch, for a user who was already signed in
        // from a previous run.
        TierStore.refresh(completion: { [weak self] in self?.statusBar.buildMenu() })
        sequencer = DictationSequencer(environment: AppDictationEnvironment(delegate: self))
        registerSleepWakeObservers()
        UpdaterController.shared.start()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setup()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Nothing is written to disk. If a dictation is still waiting, its raw text
        // goes on the clipboard so quitting does not lose it.
        sequencer?.flushPendingOnTerminate()
        unregisterSleepWakeObservers()
    }

    private func setup() {
        do {
            try setupInner()
        } catch {
            print("Fatal setup error: \(error.localizedDescription)")
        }
    }

    private func setupInner() throws {
        let isFirstRun = !FileManager.default.fileExists(atPath: Config.configFile.path)
        #if DEBUG
        // Only DEBUG builds ever stored the pre-sign-in dev token.
        SessionStore().deleteLegacyItem()
        #endif
        config = Config.load()
        inserter = TextInserter()
        migrateAudioDeviceUIDIfNeeded()
        recorder.preferredDeviceID = AudioDeviceManager.resolveConfiguredDeviceID(
            uid: config.audioInputDeviceUID,
            legacyID: config.audioInputDeviceID
        )
        if Config.effectiveMaxRecordings(config.maxRecordings) == 0 {
            RecordingStore.deleteAllRecordings()
        }
        transcriber = makeTranscriber(for: config)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusBar.reprocessHandler = { [weak self] url in
                self?.reprocess(audioURL: url)
            }
            self.statusBar.onConfigChange = { [weak self] newConfig in
                self?.applyConfigChange(newConfig)
            }
            self.statusBar.buildMenu()
        }

        if Transcriber.findWhisperBinary() == nil {
            print("Error: whisper-cpp not found. Install it with: brew install whisper-cpp")
            return
        }

        if isFirstRun {
            let semaphore = DispatchSemaphore(value: 0)
            OnboardingWindowController.presentIfFirstRun {
                semaphore.signal()
            }
            semaphore.wait()
        }

        if Permissions.didUpgrade() {
            print("Accessibility: upgrade detected, resetting permissions...")
            Permissions.resetAccessibility()
            Thread.sleep(forTimeInterval: 1)
        }

        if !AXIsProcessTrusted() {
            DispatchQueue.main.async {
                self.statusBar.state = .waitingForPermission
                self.statusBar.buildMenu()
            }
        }

        Permissions.ensureMicrophone()

        if !AXIsProcessTrusted() {
            print("Accessibility: not granted")
            Permissions.promptAccessibility()
            Permissions.openAccessibilitySettings()
            print("Waiting for Accessibility permission...")
            while !AXIsProcessTrusted() {
                Thread.sleep(forTimeInterval: 0.5)
            }
            print("Accessibility: granted")
        } else {
            print("Accessibility: granted")
        }

        if !Transcriber.modelExists(modelSize: config.modelSize) {
            DispatchQueue.main.async {
                self.statusBar.state = .downloading
                self.statusBar.updateDownloadProgress(Copy.downloadingModel(self.config.modelSize, percent: 0))
            }
            print("Downloading \(config.modelSize) model...")
            try ModelDownloader.download(modelSize: config.modelSize) { [weak self] percent in
                DispatchQueue.main.async {
                    let pct = Int(percent)
                    self?.statusBar.updateDownloadProgress(Copy.downloadingModel(self?.config.modelSize ?? "", percent: pct), percent: percent)
                }
            }
            DispatchQueue.main.async {
                self.statusBar.updateDownloadProgress(nil)
            }
        }

        if let modelPath = Transcriber.findModel(modelSize: config.modelSize) {
            let modelURL = URL(fileURLWithPath: modelPath)
            if !ModelDownloader.isValidGGMLFile(at: modelURL) {
                let msg = Copy.modelFileCorrupted(config.modelSize)
                print("Error: \(msg)")
                DispatchQueue.main.async {
                    self.statusBar.state = .error(msg)
                    self.statusBar.buildMenu()
                }
                return
            }
        }

        recorder.prewarm()

        DispatchQueue.main.async { [weak self] in
            self?.startListening()
        }
    }

    private func startListening() {
        for m in hotkeyManagers { m.stop() }
        hotkeyManagers = []
        for hk in config.hotkeys {
            let manager = HotkeyManager(
                keyCode: hk.keyCode,
                modifiers: hk.modifierFlags
            )
            manager.start(
                onKeyDown: { [weak self] in
                    self?.currentRecordingMode = .dictate
                    self?.handleKeyDown()
                },
                onKeyUp: { [weak self] in
                    self?.handleKeyUp()
                }
            )
            hotkeyManagers.append(manager)
        }
        
        editHotkeyManager?.stop()
        editHotkeyManager = nil
        if let hk = config.editHotkey {
            let manager = HotkeyManager(
                keyCode: hk.keyCode,
                modifiers: hk.modifierFlags
            )
            manager.start(
                onKeyDown: { [weak self] in
                    self?.currentRecordingMode = .edit
                    self?.handleKeyDown()
                },
                onKeyUp: { [weak self] in
                    self?.handleKeyUp()
                }
            )
            editHotkeyManager = manager
        }
        
        askHotkeyManager?.stop()
        askHotkeyManager = nil
        // Explicit opt-in only: enabling the agent-layer flag must not, by
        // itself, start listening for a bare-modifier hotkey nobody chose.
        // The founder sets `askHotkey` in config.json to turn this on.
        if let hk = config.askHotkey {
            let manager = HotkeyManager(
                keyCode: hk.keyCode,
                modifiers: hk.modifierFlags
            )
            manager.start(
                onKeyDown: { [weak self] in
                    self?.currentRecordingMode = .context
                    self?.handleKeyDown()
                },
                onKeyUp: { [weak self] in
                    self?.handleKeyUp()
                }
            )
            askHotkeyManager = manager
        }

        isReady = true
        statusBar.state = .idle
        statusBar.buildMenu()

        let hotkeyDesc = config.hotkeySummary()
        print("open-wispr v\(OpenWispr.version)")
        print("Hotkey: \(hotkeyDesc)")
        print("Model: \(config.modelSize)")
        print("Ready.")
    }

    public func reloadConfig() {
        let newConfig = Config.load()
        applyConfigChange(newConfig)
    }

    /// Configs written by older versions store only the numeric AudioDeviceID,
    /// which is not stable across reboots or device replugs. If that ID still
    /// refers to a device, persist its UID so the selection survives.
    private func migrateAudioDeviceUIDIfNeeded() {
        guard config.audioInputDeviceUID == nil,
              let legacyID = config.audioInputDeviceID,
              let uid = AudioDeviceManager.getDeviceUID(deviceID: legacyID) else { return }
        config.audioInputDeviceUID = uid
        try? config.save()
    }

    func applyConfigChange(_ newConfig: Config) {
        guard isReady else { return }
        let wasDownloading: Bool
        if case .downloading = statusBar.state { wasDownloading = true } else { wasDownloading = false }
        let newDeviceID = AudioDeviceManager.resolveConfiguredDeviceID(
            uid: newConfig.audioInputDeviceUID,
            legacyID: newConfig.audioInputDeviceID
        )
        let deviceChanged = recorder.preferredDeviceID != newDeviceID
        if newConfig.rewriteMode != config.rewriteMode {
            // A session-long stop after a sign-in or Pro answer ends when the user
            // turns rewrite off or on.
            rewriteCoordinator.resetSession()
            editCoordinator.resetSession()
            askCoordinator.resetSession()
        }
        config = newConfig
        recorder.preferredDeviceID = newDeviceID
        if deviceChanged {
            recorder.reload()
        }
        transcriber = makeTranscriber(for: config)
        inserter = TextInserter()

        for m in hotkeyManagers { m.stop() }
        hotkeyManagers = []
        for hk in config.hotkeys {
            let manager = HotkeyManager(
                keyCode: hk.keyCode,
                modifiers: hk.modifierFlags
            )
            manager.start(
                onKeyDown: { [weak self] in 
                    self?.currentRecordingMode = .dictate
                    self?.handleKeyDown() 
                },
                onKeyUp: { [weak self] in self?.handleKeyUp() }
            )
            hotkeyManagers.append(manager)
        }
        
        editHotkeyManager?.stop()
        editHotkeyManager = nil
        if let hk = config.editHotkey {
            let manager = HotkeyManager(
                keyCode: hk.keyCode,
                modifiers: hk.modifierFlags
            )
            manager.start(
                onKeyDown: { [weak self] in
                    self?.currentRecordingMode = .edit
                    self?.handleKeyDown()
                },
                onKeyUp: { [weak self] in
                    self?.handleKeyUp()
                }
            )
            editHotkeyManager = manager
        }
        
        askHotkeyManager?.stop()
        askHotkeyManager = nil
        // Explicit opt-in only: enabling the agent-layer flag must not, by
        // itself, start listening for a bare-modifier hotkey nobody chose.
        // The founder sets `askHotkey` in config.json to turn this on.
        if let hk = config.askHotkey {
            let manager = HotkeyManager(
                keyCode: hk.keyCode,
                modifiers: hk.modifierFlags
            )
            manager.start(
                onKeyDown: { [weak self] in
                    self?.currentRecordingMode = .context
                    self?.handleKeyDown()
                },
                onKeyUp: { [weak self] in
                    self?.handleKeyUp()
                }
            )
            askHotkeyManager = manager
        }

        if !wasDownloading && !Transcriber.modelExists(modelSize: config.modelSize) {
            statusBar.state = .downloading
            statusBar.updateDownloadProgress(Copy.downloadingModel(config.modelSize, percent: 0))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try ModelDownloader.download(modelSize: newConfig.modelSize) { percent in
                        DispatchQueue.main.async {
                            let pct = Int(percent)
                            self?.statusBar.updateDownloadProgress(Copy.downloadingModel(newConfig.modelSize, percent: pct), percent: percent)
                        }
                    }
                    DispatchQueue.main.async {
                        self?.statusBar.state = .idle
                        self?.statusBar.updateDownloadProgress(nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        print("Error downloading model: \(error.localizedDescription)")
                        self?.statusBar.state = .idle
                        self?.statusBar.updateDownloadProgress(nil)
                    }
                }
            }
        }

        statusBar.buildMenu()

        let hotkeyDesc = config.hotkeySummary()
        print("Config updated: lang=\(config.language) model=\(config.modelSize) hotkey=\(hotkeyDesc)")
    }

    private func makeTranscriber(for config: Config) -> Transcriber {
        let transcriber = Transcriber(
            modelSize: config.modelSize,
            language: config.language,
            whisperPrompt: config.whisperPrompt,
            translateToEnglish: config.translateToEnglish?.value ?? false
        )
        transcriber.spokenPunctuation = config.spokenPunctuation?.value ?? false
        return transcriber
    }

    private func handleKeyDown() {
        guard isReady else { return }

        let isToggle = config.toggleMode?.value ?? false

        switch recordingLifecycle.keyDown(toggleMode: isToggle) {
        case .startRecording:
            handleRecordingStart()
        case .stopRecording:
            handleRecordingStop()
        case .none, .cancelRecording, .prepareRecorder:
            break
        }
    }

    private func handleKeyUp() {
        guard isReady else { return }

        let isToggle = config.toggleMode?.value ?? false

        if recordingLifecycle.keyUp(toggleMode: isToggle) == .stopRecording {
            handleRecordingStop()
        }
    }

    private func handleRecordingStart() {
        let token = DictationTiming.newToken()
        currentDictationToken = token
        DictationTiming.mark(token, .keyDown)

        statusBar.state = .recording
        if currentRecordingMode == .context {
            DispatchQueue.main.async { AskOverlayController.shared.show(state: .listening) }
        }
        do {
            let outputURL: URL
            if Config.effectiveMaxRecordings(config.maxRecordings) == 0 {
                outputURL = RecordingStore.tempRecordingURL()
            } else {
                outputURL = RecordingStore.newRecordingURL()
            }
            try recorder.startRecording(to: outputURL)
            currentRecordingURL = outputURL
        } catch {
            print("Error: \(error.localizedDescription)")
            recordingLifecycle.recordingStartFailed()
            currentRecordingURL = nil
            if currentRecordingMode == .context {
                DispatchQueue.main.async { AskOverlayController.shared.hide() }
            }
            // Previously fell straight back to .idle here with only a console
            // print -- invisible to a real user, who would just see the
            // hotkey appear to do nothing (e.g. after revoking Microphone
            // access in System Settings mid-session). showNotice surfaces it
            // the same way every other user-facing failure in this file does.
            statusBar.showNotice(Copy.recordingFailedToStart)
        }
    }

    private func handleRecordingStop() {
        // Captured now (not re-read later) so every closure below, including
        // the completion handlers that fire well after this call returns,
        // logs against the token for THIS attempt even if a later dictation
        // has since overwritten `currentDictationToken`.
        let token = currentDictationToken
        guard let audioURL = recorder.stopRecording() else {
            RecordingCancellation.discardTrackedPartialRecording(&currentRecordingURL)
            statusBar.state = .idle
            if currentRecordingMode == .context {
                DispatchQueue.main.async { AskOverlayController.shared.hide() }
            }
            return
        }

        currentRecordingURL = nil
        statusBar.state = .transcribing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let maxRecordings = Config.effectiveMaxRecordings(self.config.maxRecordings)
            defer {
                if maxRecordings == 0 {
                    try? FileManager.default.removeItem(at: audioURL)
                }
            }
            do {
                DictationTiming.mark(token, .asrStart)
                let raw = try self.transcriber.transcribe(audioURL: audioURL)
                DictationTiming.mark(token, .asrDone, detail: "ok")
                let text = (self.config.spokenPunctuation?.value ?? false) ? TextPostProcessor.process(raw) : raw
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                guard !text.isEmpty else {
                    DispatchQueue.main.async {
                        self.statusBar.state = .idle
                        self.statusBar.buildMenu()
                    }
                    return
                }
                // Back on the main thread: the sequencer records the raw text and the
                // frontmost app now, before any rewrite wait. The coordinator
                // consults RewriteGate; nothing here decides whether text may leave
                // the device. It calls `completion` exactly once.
                let mode = self.currentRecordingMode
                DispatchQueue.main.async {
                    if mode == .context {
                        // Routing (Edit vs. Ask) needs to know whether there is a
                        // selection, which needs a read — but that read must not
                        // happen for its own sake. `agentLayerActive` mirrors the
                        // first two checks EditGate/AskGate apply before consent
                        // or sign-in are even considered (ContextConsent.swift):
                        // if either is false, both coordinators' own `gate(mode)`
                        // bounces this to the raw transcript with no read at all,
                        // so there is nothing to look at yet. When it is true,
                        // exactly one Accessibility read happens here, and that
                        // same snapshot — not a second, independent read — is
                        // handed to whichever coordinator gets chosen below.
                        let agentLayerActive = self.config.isAgentLayerEnabled && self.config.rewriteMode == .auto
                        // `@MainActor`: this task calls `self.sequencer.begin`/
                        // `.finish` (both main-actor-isolated now) and touches
                        // `statusBar`/`AskOverlayController` after the `await`
                        // below. Without this annotation the task's isolation is
                        // inferred from its creation context, which happens to be
                        // `@MainActor`-recognised today (nested in
                        // `DispatchQueue.main.async`) but that is an inference,
                        // not a guarantee; spelling it out is what actually pins
                        // the resumption to the main thread regardless of how the
                        // enclosing closure is reached.
                        Task { @MainActor in
                            let snapshot = agentLayerActive
                                ? await DefaultAccessibilityContextReader.system().readSnapshot()
                                : nil
                            let hasSelection = snapshot?.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

                            if hasSelection {
                                self.statusBar.state = .idle
                                self.statusBar.buildMenu()
                                let ticket = self.sequencer.begin(raw: text)
                                self.editCoordinator.process(
                                    instruction: text,
                                    mode: { self.config.rewriteMode },
                                    willEdit: {},
                                    prefetchedSnapshot: snapshot,
                                    completion: { outcome in
                                        DictationTiming.mark(token, .cleanupDone, detail: "edit")
                                        DispatchQueue.main.async {
                                            if outcome.rewritten {
                                                self.lastRewritePair = (raw: text, rewritten: outcome.text)
                                                self.statusBar.buildMenu()
                                            }
                                            self.sequencer.finish(ticket, outcome: outcome)
                                        }
                                    }
                                )
                            } else {
                                self.statusBar.state = .idle
                                self.statusBar.buildMenu()

                                let trimmedInstruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmedInstruction.isEmpty {
                                    let hotkeyDesc = self.config.askHotkey.map {
                                        KeyCodes.describe(keyCode: $0.keyCode, modifiers: $0.modifiers)
                                    } ?? Copy.contextHotkeyFallbackName
                                    AskOverlayController.shared.show(state: .error(Copy.askNoSpeechDetected(hotkeyDesc)))
                                    return
                                }

                                self.askCoordinator.process(
                                    instruction: trimmedInstruction,
                                    mode: { self.config.rewriteMode },
                                    willAsk: {
                                        DispatchQueue.main.async { AskOverlayController.shared.show(state: .processing) }
                                    },
                                    prefetchedSnapshot: snapshot,
                                    completion: { outcome in
                                        DictationTiming.mark(token, .cleanupDone, detail: "ask")
                                        DispatchQueue.main.async {
                                            if let notice = outcome.notice, !outcome.rewritten {
                                                AskOverlayController.shared.show(state: .error(notice))
                                            } else {
                                                AskOverlayController.shared.show(state: .answered(outcome.text), windowFrame: outcome.capturedWindowFrame)
                                            }
                                        }
                                    }
                                )
                            }
                        }
                        return
                    }

                    let ticket = self.sequencer.begin(raw: text)
                    let completionHandler: (RewriteOutcome) -> Void = { outcome in
                        DictationTiming.mark(token, .cleanupDone, detail: mode == .dictate ? "dictate" : "edit")
                        let updateBlock = {
                            if outcome.rewritten {
                                self.lastRewritePair = (raw: text, rewritten: outcome.text)
                                self.statusBar.buildMenu()
                            }
                            self.sequencer.finish(ticket, outcome: outcome)
                        }
                        if Thread.isMainThread {
                            updateBlock()
                        } else {
                            DispatchQueue.main.async(execute: updateBlock)
                        }
                    }
                    
                    if mode == .dictate {
                        // Plain dictation has no other reason to read Accessibility
                        // (unlike Edit/Ask, which already read a full snapshot and
                        // already refuse a secure field or secure keyboard input
                        // before sending anything over the network). This check is
                        // the narrow one: it only ever asks "is it secure", never
                        // "what does it say", and skips both the rewrite call and
                        // the paste attempt entirely when it is — nothing is sent
                        // to the network from a secure field, and a synthetic paste
                        // into one can silently fail or behave unpredictably, with
                        // no way to tell the user whether it worked.
                        DefaultAccessibilityContextReader.system().checkSecureInput { status in
                            DispatchQueue.main.async {
                                // Bail out BEFORE touching the network when the context is
                                // secure, exactly like Edit/Ask's own pre-network bailouts
                                // (EditCoordinator.process, AskCoordinator.process). Calling
                                // `rewriteCoordinator.process` first and only gating the paste
                                // afterwards would still send the raw transcript to the cloud
                                // rewrite pipeline from a password field.
                                if let secureOutcome = RewriteCoordinator.secureDictateOutcome(for: status, transcript: text) {
                                    completionHandler(secureOutcome)
                                    return
                                }
                                self.rewriteCoordinator.process(
                                    transcript: text,
                                    mode: { self.config.rewriteMode },
                                    willRewrite: { self.sequencer.willRewrite(ticket) },
                                    completion: completionHandler
                                )
                            }
                        }
                    } else if mode == .edit {
                        self.editCoordinator.process(
                            instruction: text,
                            mode: { self.config.rewriteMode },
                            willEdit: { self.sequencer.willRewrite(ticket) },
                            completion: completionHandler
                        )
                    }
                }
            } catch {
                DictationTiming.mark(token, .asrDone, detail: "error")
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                DispatchQueue.main.async {
                    print("Error: \(error.localizedDescription)")
                    self.statusBar.state = .error(error.localizedDescription)
                    self.statusBar.buildMenu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if case .error = self.statusBar.state {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    }
                }
            }
        }
    }

    func handleSystemWillSleep() {
        guard recordingLifecycle.systemWillSleep() == .cancelRecording else { return }

        recorder.teardown()
        RecordingCancellation.discardTrackedPartialRecording(&currentRecordingURL)
        resetRecordingStatusToIdleIfNeeded()
    }

    func handleSystemDidWake() {
        guard recordingLifecycle.systemDidWake(isReady: isReady) == .prepareRecorder else { return }

        recorder.preferredDeviceID = AudioDeviceManager.resolveConfiguredDeviceID(
            uid: config.audioInputDeviceUID,
            legacyID: config.audioInputDeviceID
        )
        recorder.reload()
    }

    private func registerSleepWakeObservers() {
        guard sleepWakeObservers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        sleepWakeObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleSystemWillSleep()
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleSystemDidWake()
            },
        ]
    }

    private func unregisterSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepWakeObservers {
            center.removeObserver(observer)
        }
        sleepWakeObservers = []
    }

    private func resetRecordingStatusToIdleIfNeeded() {
        guard case .recording = statusBar.state else { return }
        statusBar.state = .idle
        statusBar.buildMenu()
    }

    public func reprocess(audioURL: URL) {
        guard case .idle = statusBar.state else { return }

        statusBar.state = .transcribing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let raw = try self.transcriber.transcribe(audioURL: audioURL)
                let text = (self.config.spokenPunctuation?.value ?? false) ? TextPostProcessor.process(raw) : raw
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        self.lastTranscription = text
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self.statusBar.state = .copiedToClipboard
                        self.statusBar.buildMenu()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    } else {
                        self.statusBar.state = .idle
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("Reprocess error: \(error.localizedDescription)")
                    self.statusBar.state = .idle
                }
            }
        }
    }
}


/// Connects `DictationSequencer` to the real app: status bar, inserter, clipboard,
/// frontmost application and recording state. Main thread only.
final class AppDictationEnvironment: DictationEnvironment {
    private unowned let delegate: AppDelegate

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func frontmostProcessID() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func isRecordingActive() -> Bool { delegate.recordingLifecycle.isRecording }

    func insert(_ text: String) {
        // Best-effort correlation only (see `currentDictationToken`'s doc
        // comment): this reads whichever token is current when the paste
        // actually happens, which can be a newer dictation's token if one
        // started while this one was still waiting to be inserted.
        delegate.inserter.insert(text: text, token: delegate.currentDictationToken)
    }

    func copyToPasteboard(_ text: String) {
        // This replaces whatever the user had on the clipboard. The notice that
        // accompanies this path says the text is on the clipboard. Marking it as
        // concealed/transient is planned work (Task 5.5) and needs testing across
        // paste layouts, so it is deliberately not done here.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func setLastTranscription(_ raw: String?) { delegate.lastTranscription = raw }

    var phase: DictationPhase {
        switch delegate.statusBar.state {
        case .idle: return .idle
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .rewriting: return .rewriting
        default: return .other
        }
    }

    func showRewriting() { delegate.statusBar.state = .rewriting }
    func showIdle() { delegate.statusBar.state = .idle }
    func showNotice(_ message: String) { delegate.statusBar.showNotice(message) }
    func refreshMenu() { delegate.statusBar.buildMenu() }
}
