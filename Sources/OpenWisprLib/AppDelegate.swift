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
    private var sleepWakeObservers: [NSObjectProtocol] = []
    var isReady = false
    public var lastTranscription: String?
    /// Owns the rewrite decision. Built on the main thread at launch (it creates
    /// no network object until a dictation passes the gate).
    private var rewriteCoordinator: RewriteCoordinator!
    /// Owns when, and whether, each finished dictation is pasted. Main thread only.
    private var sequencer: DictationSequencer!

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        recorder = AudioRecorder()
        rewriteCoordinator = RewriteCoordinator.production()
        sequencer = DictationSequencer(environment: AppDictationEnvironment(delegate: self))
        registerSleepWakeObservers()

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
                self.statusBar.updateDownloadProgress("Downloading \(self.config.modelSize) model...")
            }
            print("Downloading \(config.modelSize) model...")
            try ModelDownloader.download(modelSize: config.modelSize) { [weak self] percent in
                DispatchQueue.main.async {
                    let pct = Int(percent)
                    self?.statusBar.updateDownloadProgress("Downloading \(self?.config.modelSize ?? "") model... \(pct)%", percent: percent)
                }
            }
            DispatchQueue.main.async {
                self.statusBar.updateDownloadProgress(nil)
            }
        }

        if let modelPath = Transcriber.findModel(modelSize: config.modelSize) {
            let modelURL = URL(fileURLWithPath: modelPath)
            if !ModelDownloader.isValidGGMLFile(at: modelURL) {
                let msg = "Model file is corrupted. Re-download with: open-wispr download-model \(config.modelSize)"
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
                    self?.handleKeyDown()
                },
                onKeyUp: { [weak self] in
                    self?.handleKeyUp()
                }
            )
            hotkeyManagers.append(manager)
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
                onKeyDown: { [weak self] in self?.handleKeyDown() },
                onKeyUp: { [weak self] in self?.handleKeyUp() }
            )
            hotkeyManagers.append(manager)
        }

        if !wasDownloading && !Transcriber.modelExists(modelSize: config.modelSize) {
            statusBar.state = .downloading
            statusBar.updateDownloadProgress("Downloading \(config.modelSize) model...")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try ModelDownloader.download(modelSize: newConfig.modelSize) { percent in
                        DispatchQueue.main.async {
                            let pct = Int(percent)
                            self?.statusBar.updateDownloadProgress("Downloading \(newConfig.modelSize) model... \(pct)%", percent: percent)
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
            whisperPrompt: config.whisperPrompt
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
        statusBar.state = .recording
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
            statusBar.state = .idle
        }
    }

    private func handleRecordingStop() {
        guard let audioURL = recorder.stopRecording() else {
            RecordingCancellation.discardTrackedPartialRecording(&currentRecordingURL)
            statusBar.state = .idle
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
                let raw = try self.transcriber.transcribe(audioURL: audioURL)
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
                DispatchQueue.main.async {
                    let ticket = self.sequencer.begin(raw: text)
                    self.rewriteCoordinator.process(
                        transcript: text,
                        // Sampled here, on the main thread, immediately before the
                        // decision: not when recording stopped, before Whisper ran.
                        mode: { self.config.rewriteMode },
                        willRewrite: { self.sequencer.willRewrite(ticket) },
                        completion: { outcome in
                            // Synchronous (nothing sent) completions are already on
                            // the main thread and finish in the same turn.
                            if Thread.isMainThread {
                                self.sequencer.finish(ticket, outcome: outcome)
                            } else {
                                DispatchQueue.main.async {
                                    self.sequencer.finish(ticket, outcome: outcome)
                                }
                            }
                        }
                    )
                }
            } catch {
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

    func insert(_ text: String) { delegate.inserter.insert(text: text) }

    func copyToPasteboard(_ text: String) {
        // This replaces whatever the user had on the clipboard. The notice that
        // accompanies this path says the text is on the clipboard. Marking it as
        // concealed/transient is planned work (Task 5.5) and needs testing across
        // paste layouts, so it is deliberately not done here.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func setLastTranscription(_ raw: String) { delegate.lastTranscription = raw }

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
