import AppKit

class MenuItemTarget: NSObject {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

/// Whether an "Upgrade to Pro" attempt is currently in flight, so a repeat
/// click on the menu item while one is already running is a no-op instead of
/// starting a second, overlapping two-minute poll loop (each of which burns
/// quota from the shared "billing" and "me" buckets for nothing). Plain state,
/// no AppKit or Keychain dependency, so it can be unit tested directly instead
/// of through a full `StatusBarController` (which pulls in the real Keychain
/// via `SessionStore` as soon as `buildMenu()` runs).
final class UpgradeAttemptGuard {
    private var inProgress = false

    /// Marks an attempt in progress and returns `true`, unless one already
    /// was — in which case nothing changes and this returns `false`.
    func begin() -> Bool {
        guard !inProgress else { return false }
        inProgress = true
        return true
    }

    /// Clears the in-flight state, whether the attempt succeeded or failed.
    /// Safe to call even if no attempt is in progress.
    func end() {
        inProgress = false
    }
}

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var animationFrames: [NSImage] = []
    private var downloadProgress: String?
    private var downloadPercent: Double = 0
    private var copiedFeedback = false
    private var copiedBeforeAfterFeedback = false
    private var noticeGeneration = 0
    private var menuItemTargets: [MenuItemTarget] = []
    private var stateMenuItem: NSMenuItem?
    // The two sign-in items live for the whole life of the menu, so they can be
    // refreshed when it opens without changing its structure.
    private var signInItem: NSMenuItem?
    private var signOutItem: NSMenuItem?
    private var signInTarget: MenuItemTarget?
    private var signOutTarget: MenuItemTarget?
    // Same reasoning as the sign-in items above: these live for the life of the
    // menu so `applyBillingMenu` can show/hide them without a full rebuild when
    // the tier changes while the menu is open (Tasks 4.7/4.8).
    private var upgradeItem: NSMenuItem?
    private var manageSubscriptionItem: NSMenuItem?
    private var upgradeTarget: MenuItemTarget?
    private var manageSubscriptionTarget: MenuItemTarget?
    // Guards against a few rapid/accidental clicks on "Upgrade to Pro" starting
    // several overlapping two-minute poll loops (each burning "billing" and "me"
    // quota for no reason). Plain state with no AppKit or Keychain dependency
    // (unlike this class itself, which pulls in the real Keychain through
    // `SessionStore` as soon as `buildMenu()` runs), so its begin/end behavior
    // is tested directly in `UpgradeAttemptGuardTests` instead of through a
    // full `StatusBarController`.
    private let upgradeGuard = UpgradeAttemptGuard()

    var reprocessHandler: ((URL) -> Void)?
    var onConfigChange: ((Config) -> Void)?

    enum State {
        case idle
        case recording
        case transcribing
        case rewriting
        case downloading
        case waitingForPermission
        case copiedToClipboard
        /// One-shot message that is not a failure of the app, for example a
        /// rewrite that fell back to the raw transcript. Cleared by `showNotice`.
        case notice(String)
        case error(String)
    }

    var state: State = .idle {
        didSet { updateIcon() }
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = StatusBarController.drawLogo(active: false)
            button.image?.isTemplate = true
        }

        // A saved sign-in changes the menu at once, while the window is still open.
        Task { @MainActor [weak self] in
            SignInWindowController.shared.sessionDidChange = { self?.buildMenu() }
        }

        buildMenu()
    }

    @objc private func copyLastTranscription() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate,
              let text = delegate.lastTranscription else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedFeedback = true
        buildMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copiedFeedback = false
            self?.buildMenu()
        }
    }

    @objc func copyLastBeforeAfter() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate,
              let pair = delegate.lastRewritePair else { return }
        let formatted = Copy.formatBeforeAfter(raw: pair.raw, rewritten: pair.rewritten)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(formatted, forType: .string)
        copiedBeforeAfterFeedback = true
        buildMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copiedBeforeAfterFeedback = false
            self?.buildMenu()
        }
    }

    /// Shows `message` in the menu and icon for `seconds`, then returns to idle,
    /// unless something else has taken over the status bar in the meantime.
    func showNotice(_ message: String, for seconds: TimeInterval = 5) {
        noticeGeneration += 1
        let generation = noticeGeneration
        state = .notice(message)
        buildMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.noticeGeneration == generation,
                  case .notice = self.state else { return }
            self.state = .idle
            self.buildMenu()
        }
    }

    func updateDownloadProgress(_ text: String?, percent: Double = 0) {
        downloadProgress = text
        downloadPercent = percent
        if case .downloading = state {
            setIcon(StatusBarController.drawDownloadProgress(downloadPercent))
        }
        if let text = text, let item = stateMenuItem {
            let config = Config.load()
            let hotkeyDesc = config.hotkeySummary()
            item.title = "\(text) (hotkey: \(hotkeyDesc))"
        } else {
            buildMenu()
        }
    }

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    func buildMenu() {
        menuItemTargets = []

        let config = Config.load()
        let hotkeyDesc = config.hotkeySummary()

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "\(ProductInfo.displayName) v\(OpenWispr.version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        let stateLabel: String
        if let progress = downloadProgress {
            stateLabel = progress
        } else {
            switch state {
            case .idle: stateLabel = "Ready"
            case .recording: stateLabel = "Recording..."
            case .transcribing: stateLabel = "Transcribing..."
            case .rewriting: stateLabel = "Rewriting..."
            case .downloading: stateLabel = "Downloading model..."
            case .waitingForPermission: stateLabel = "Waiting for Accessibility permission..."
            case .copiedToClipboard: stateLabel = "Copied to clipboard"
            case .notice(let message): stateLabel = message
            case .error(let message): stateLabel = "Error: \(message)"
            }
        }
        if case .waitingForPermission = state {
            let target = MenuItemTarget {
                Permissions.openAccessibilitySettings()
            }
            menuItemTargets.append(target)
            let stateItem = NSMenuItem(title: "Grant Accessibility Permission...", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            stateItem.target = target
            menu.addItem(stateItem)
            stateMenuItem = stateItem
        } else {
            let stateItem = NSMenuItem(title: "\(stateLabel) (hotkey: \(hotkeyDesc))", action: nil, keyEquivalent: "")
            stateItem.isEnabled = false
            menu.addItem(stateItem)
            stateMenuItem = stateItem
        }

        menu.addItem(NSMenuItem.separator())

        let currentLang = config.language
        let langName = Config.supportedLanguages.first(where: { $0.code == currentLang })?.name ?? currentLang
        let langItem = NSMenuItem(title: "Language: \(langName)", action: nil, keyEquivalent: "")
        let langSubmenu = NSMenu()

        for (index, lang) in Config.supportedLanguages.enumerated() {
            if index == 1 {
                langSubmenu.addItem(NSMenuItem.separator())
            }
            let target = MenuItemTarget { [weak self] in
                var cfg = Config.load()
                cfg.language = lang.code
                if lang.code != "en" && cfg.modelSize.hasSuffix(".en") {
                    let base = String(cfg.modelSize.dropLast(3))
                    if Config.supportedModels.contains(base) {
                        cfg.modelSize = base
                    }
                } else if lang.code == "en" && !cfg.modelSize.hasSuffix(".en") {
                    let enVariant = cfg.modelSize + ".en"
                    if Config.supportedModels.contains(enVariant) {
                        cfg.modelSize = enVariant
                    }
                }
                try? cfg.save()
                self?.onConfigChange?(cfg)
            }
            self.menuItemTargets.append(target)
            let item = NSMenuItem(title: lang.name, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            if lang.code == currentLang {
                item.state = .on
            }
            langSubmenu.addItem(item)
        }

        langItem.submenu = langSubmenu
        menu.addItem(langItem)

        let translateTarget = MenuItemTarget { [weak self] in
            var cfg = Config.load()
            let current = cfg.translateToEnglish?.value ?? false
            cfg.translateToEnglish = FlexBool(!current)
            try? cfg.save()
            self?.onConfigChange?(cfg)
        }
        menuItemTargets.append(translateTarget)
        let translateItem = NSMenuItem(title: "Translate Foreign Speech to English", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
        translateItem.target = translateTarget
        translateItem.state = (config.translateToEnglish?.value ?? false) ? .on : .off
        menu.addItem(translateItem)

        let modelItem = NSMenuItem(title: "Model: \(config.modelSize)", action: nil, keyEquivalent: "")
        let modelSubmenu = NSMenu()

        let englishModels = Config.supportedModels.filter { Config.isEnglishOnlyModel($0) }
        let multilingualModels = Config.supportedModels.filter { !Config.isEnglishOnlyModel($0) }

        let engHeader = NSMenuItem(title: "English", action: nil, keyEquivalent: "")
        engHeader.isEnabled = false
        modelSubmenu.addItem(engHeader)

        for model in englishModels {
            let target = MenuItemTarget { [weak self] in
                var cfg = Config.load()
                cfg.modelSize = model
                if cfg.language != "en" {
                    cfg.language = "en"
                }
                try? cfg.save()
                self?.onConfigChange?(cfg)
            }
            self.menuItemTargets.append(target)
            let item = NSMenuItem(title: "  \(model)", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            if model == config.modelSize {
                item.state = .on
            }
            modelSubmenu.addItem(item)
        }

        modelSubmenu.addItem(NSMenuItem.separator())

        let multiHeader = NSMenuItem(title: "Multilingual", action: nil, keyEquivalent: "")
        multiHeader.isEnabled = false
        modelSubmenu.addItem(multiHeader)

        for model in multilingualModels {
            let target = MenuItemTarget { [weak self] in
                var cfg = Config.load()
                cfg.modelSize = model
                try? cfg.save()
                self?.onConfigChange?(cfg)
            }
            self.menuItemTargets.append(target)
            let item = NSMenuItem(title: "  \(model)", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            if model == config.modelSize {
                item.state = .on
            }
            modelSubmenu.addItem(item)
        }

        modelItem.submenu = modelSubmenu
        menu.addItem(modelItem)

        let devices = AudioDeviceManager.listInputDevices()
        let selectedDevice = devices.first(where: { device in
            if let uid = config.audioInputDeviceUID { return device.uid == uid }
            if let id = config.audioInputDeviceID { return device.id == id }
            return false
        })
        let currentDeviceName = selectedDevice?.name ?? "System Default"
        let audioItem = NSMenuItem(title: "Audio Input: \(currentDeviceName)", action: nil, keyEquivalent: "")
        let audioSubmenu = NSMenu()
        audioSubmenu.autoenablesItems = false

        let defaultTarget = MenuItemTarget { [weak self] in
            var cfg = Config.load()
            cfg.audioInputDeviceID = nil
            cfg.audioInputDeviceUID = nil
            try? cfg.save()
            self?.onConfigChange?(cfg)
        }
        menuItemTargets.append(defaultTarget)
        let defaultItem = NSMenuItem(title: "System Default", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
        defaultItem.target = defaultTarget
        if config.audioInputDeviceID == nil && config.audioInputDeviceUID == nil {
            defaultItem.state = .on
        }
        audioSubmenu.addItem(defaultItem)

        if !devices.isEmpty {
            audioSubmenu.addItem(NSMenuItem.separator())
        }

        for device in devices {
            let target = MenuItemTarget { [weak self] in
                var cfg = Config.load()
                cfg.audioInputDeviceID = device.id
                cfg.audioInputDeviceUID = device.uid
                try? cfg.save()
                self?.onConfigChange?(cfg)
            }
            menuItemTargets.append(target)
            let item = NSMenuItem(title: device.name, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            item.target = target
            if selectedDevice?.id == device.id { item.state = .on }
            audioSubmenu.addItem(item)
        }

        audioItem.submenu = audioSubmenu
        menu.addItem(audioItem)

        menu.addItem(NSMenuItem.separator())

        let toggleTarget = MenuItemTarget { [weak self] in
            var cfg = Config.load()
            let current = cfg.toggleMode?.value ?? false
            cfg.toggleMode = FlexBool(!current)
            try? cfg.save()
            self?.onConfigChange?(cfg)
        }
        menuItemTargets.append(toggleTarget)
        let toggleItem = NSMenuItem(title: "Toggle Mode", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
        toggleItem.target = toggleTarget
        toggleItem.state = (config.toggleMode?.value ?? false) ? .on : .off
        menu.addItem(toggleItem)


        // Rewrite toggle — shows disclosure sheet if consent not yet granted
        let rewriteTarget = MenuItemTarget { [weak self] in
            var cfg = Config.load()
            if cfg.rewriteMode == .auto {
                // Turning off — always allowed
                cfg.rewriteMode = .off
                try? cfg.save()
                self?.onConfigChange?(cfg)
            } else {
                // Turning on — show disclosure sheet if consent not yet granted
                if RewriteConsent.shared.hasConsent {
                    cfg.rewriteMode = .auto
                    try? cfg.save()
                    self?.onConfigChange?(cfg)
                } else {
                    RewriteDisclosureWindowController.present { accepted in
                        if accepted {
                            var cfg2 = Config.load()
                            cfg2.rewriteMode = .auto
                            try? cfg2.save()
                            DispatchQueue.main.async {
                                self?.onConfigChange?(cfg2)
                            }
                        } else {
                            DispatchQueue.main.async {
                                self?.buildMenu()
                            }
                        }
                    }
                }
            }
        }
        menuItemTargets.append(rewriteTarget)
        let rewriteItem = NSMenuItem(title: "Rewrite", action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
        rewriteItem.target = rewriteTarget
        rewriteItem.state = config.rewriteMode == .auto ? .on : .off
        menu.addItem(rewriteItem)

        let rewriteStatusItem = NSMenuItem(
            title: RewriteGate.statusLine(
                mode: config.rewriteMode,
                consent: .shared,
                hasToken: SessionStore().isSignedIn
            ),
            action: nil,
            keyEquivalent: ""
        )
        rewriteStatusItem.isEnabled = false
        menu.addItem(rewriteStatusItem)

        // On-device Apple Intelligence (Foundation Models), Phase 1: DEBUG-only so
        // the founder can try it today ahead of a real settings toggle. Never
        // compiled into a release build — the whole block is `#if DEBUG`, so
        // nothing here (the toggle, its title string, or the status line) reaches
        // a release binary at all (verified: `strings` on `swift build -c release`
        // output finds none of it).
        #if DEBUG
        let onDeviceTarget = MenuItemTarget { [weak self] in
            var cfg = Config.load()
            let next = !(cfg.onDeviceAIEnabled?.value ?? false)
            cfg.onDeviceAIEnabled = FlexBool(next)
            try? cfg.save()
            self?.onConfigChange?(cfg)
            self?.buildMenu()
        }
        menuItemTargets.append(onDeviceTarget)
        let onDeviceItem = NSMenuItem(
            title: "[DEBUG] On-Device AI (Apple Intelligence)",
            action: #selector(MenuItemTarget.invoke),
            keyEquivalent: ""
        )
        onDeviceItem.target = onDeviceTarget
        onDeviceItem.state = (config.onDeviceAIEnabled?.value ?? false) ? .on : .off
        menu.addItem(onDeviceItem)

        let onDeviceReason = FoundationModelsPipeline.unavailableReason
        let onDeviceStatusText: String
        if config.onDeviceAIEnabled?.value != true {
            onDeviceStatusText = "[DEBUG] On-Device AI: off"
        } else if let onDeviceReason {
            onDeviceStatusText = "[DEBUG] On-Device AI: unavailable (\(onDeviceReason))"
        } else {
            onDeviceStatusText = "[DEBUG] On-Device AI: on"
        }
        let onDeviceStatusItem = NSMenuItem(title: onDeviceStatusText, action: nil, keyEquivalent: "")
        onDeviceStatusItem.isEnabled = false
        menu.addItem(onDeviceStatusItem)
        #endif

        // Revoke rewrite consent (always available if consent was granted)
        let rewriteConsentGranted = RewriteConsent.shared.hasConsent
        if rewriteConsentGranted {
            let revokeTarget = MenuItemTarget { [weak self] in
                RewriteConsent.shared.revoke()
                self?.buildMenu()
            }
            menuItemTargets.append(revokeTarget)
            let revokeItem = NSMenuItem(
                title: "Revoke rewrite consent",
                action: #selector(MenuItemTarget.invoke),
                keyEquivalent: ""
            )
            revokeItem.target = revokeTarget
            menu.addItem(revokeItem)
        }

        // Context consent (Edit & Ask features)
        let contextConsentGranted = ContextConsent.shared.hasTextConsent
        let contextConsentTarget = MenuItemTarget { [weak self] in
            if contextConsentGranted {
                ContextConsent.shared.revokeTextConsent()
                ContextConsent.shared.revokeImageConsent()
                self?.buildMenu()
            } else {
                ContextConsentWindowController.present { accepted in
                    DispatchQueue.main.async {
                        self?.buildMenu()
                    }
                }
            }
        }
        menuItemTargets.append(contextConsentTarget)
        let contextConsentItem = NSMenuItem(
            title: contextConsentGranted ? "Revoke context consent" : "Enable screen context…",
            action: #selector(MenuItemTarget.invoke),
            keyEquivalent: ""
        )
        contextConsentItem.target = contextConsentTarget
        menu.addItem(contextConsentItem)

        // Sign-in (docs/design/sign-in.md, section 9): "Sign in…", or a disabled
        // "Signed in as <email>" plus "Sign out". Both items always exist; which
        // one shows, and how, is decided by `applySignInMenu` on every rebuild and
        // whenever the menu opens.
        let signInTarget = MenuItemTarget {
            Task { @MainActor in SignInWindowController.shared.show() }
        }
        let signOutTarget = MenuItemTarget { [weak self] in self?.signOutFromMenu() }
        self.signInTarget = signInTarget
        self.signOutTarget = signOutTarget
        let signInItem = NSMenuItem(title: SignInCopy.menuSignIn, action: nil, keyEquivalent: "")
        let signOutItem = NSMenuItem(title: SignInCopy.menuSignOut, action: nil, keyEquivalent: "")
        self.signInItem = signInItem
        self.signOutItem = signOutItem
        menu.addItem(signInItem)
        menu.addItem(signOutItem)

        // "Upgrade to Pro" / "Manage Subscription" (Tasks 4.7/4.8): both items
        // always exist, like the sign-in pair above; `applyBillingMenu` decides
        // which (if either) shows, from the current sign-in state and
        // `TierStore`. Kept as one visibility switch rather than two independent
        // items so the two can never both show at once.
        let upgradeTarget = MenuItemTarget { [weak self] in self?.startUpgrade() }
        let manageSubscriptionTarget = MenuItemTarget { [weak self] in self?.startManageSubscription() }
        self.upgradeTarget = upgradeTarget
        self.manageSubscriptionTarget = manageSubscriptionTarget
        let upgradeItem = NSMenuItem(title: BillingCopy.menuUpgrade, action: nil, keyEquivalent: "")
        let manageSubscriptionItem = NSMenuItem(title: BillingCopy.menuManageSubscription, action: nil, keyEquivalent: "")
        self.upgradeItem = upgradeItem
        self.manageSubscriptionItem = manageSubscriptionItem
        menu.addItem(upgradeItem)
        menu.addItem(manageSubscriptionItem)

        menu.delegate = self
        applySignInMenu()
        applyBillingMenu()

        // Task 7.6: Invite someone referral menu item
        if SessionStore().isSignedIn {
            let inviteTarget = MenuItemTarget { [weak self] in
                let inviteUrl = "https://openwispr.com/invite"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(inviteUrl, forType: .string)
                self?.showNotice(Copy.referralCopiedLink, for: 3)
            }
            menuItemTargets.append(inviteTarget)
            let inviteItem = NSMenuItem(title: Copy.referralMenuInvite, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
            inviteItem.target = inviteTarget
            menu.addItem(inviteItem)
        }

        menu.addItem(NSMenuItem.separator())

        let lastText = (NSApplication.shared.delegate as? AppDelegate)?.lastTranscription
        let copyTitle = copiedFeedback ? "Copied!" : Copy.menuCopyLast
        let copyItem = NSMenuItem(title: copyTitle, action: lastText != nil && !copiedFeedback ? #selector(copyLastTranscription) : nil, keyEquivalent: "c")
        copyItem.target = self
        if lastText == nil || copiedFeedback { copyItem.isEnabled = copiedFeedback }
        menu.addItem(copyItem)

        // Task 7.2: Copy before/after snippet menu item
        let lastPair = (NSApplication.shared.delegate as? AppDelegate)?.lastRewritePair
        let copyBeforeAfterTitle = copiedBeforeAfterFeedback ? Copy.menuCopiedBeforeAfter : Copy.menuCopyBeforeAfter
        let copyBeforeAfterItem = NSMenuItem(
            title: copyBeforeAfterTitle,
            action: lastPair != nil && !copiedBeforeAfterFeedback ? #selector(copyLastBeforeAfter) : nil,
            keyEquivalent: ""
        )
        copyBeforeAfterItem.target = self
        if lastPair == nil || copiedBeforeAfterFeedback { copyBeforeAfterItem.isEnabled = copiedBeforeAfterFeedback }
        menu.addItem(copyBeforeAfterItem)

        if Config.effectiveMaxRecordings(config.maxRecordings) > 0 {
            let recordings = RecordingStore.listRecordings()
            let reprocessItem = NSMenuItem(title: "Recent Recordings", action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            if recordings.isEmpty {
                let emptyItem = NSMenuItem(title: "No recordings", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                submenu.addItem(emptyItem)
            } else {
                for (index, recording) in recordings.enumerated() {
                    let dateStr = StatusBarController.displayDateFormatter.string(from: recording.date)
                    let label = "\(dateStr) (\(index + 1))"
                    let target = MenuItemTarget { [weak self] in
                        self?.reprocessHandler?(recording.url)
                    }
                    menuItemTargets.append(target)
                    let item = NSMenuItem(title: label, action: #selector(MenuItemTarget.invoke), keyEquivalent: "")
                    item.target = target
                    submenu.addItem(item)
                }
            }

            reprocessItem.submenu = submenu
            menu.addItem(reprocessItem)
        }

        menu.addItem(NSMenuItem.separator())

        let reloadItem = NSMenuItem(title: "Reload Configuration", action: #selector(reloadConfiguration), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let openItem = NSMenuItem(title: "Open Configuration", action: #selector(openConfiguration), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: Copy.menuQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func checkForUpdates() {
        UpdaterController.shared.checkForUpdates()
    }

    @objc private func reloadConfiguration() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
        delegate.reloadConfig()
    }

    @objc private func openConfiguration() {
        let configFile = Config.configFile
        if !FileManager.default.fileExists(atPath: configFile.path) {
            let config = Config.defaultConfig
            try? config.save()
        }
        NSWorkspace.shared.open(configFile)
    }

    private func updateIcon() {
        stopAnimation()

        switch state {
        case .idle:
            setIcon(StatusBarController.drawLogo(active: false))
        case .recording:
            startRecordingAnimation()
        case .transcribing, .rewriting:
            startTranscribingAnimation()
        case .downloading:
            startDownloadingAnimation()
        case .waitingForPermission:
            setIcon(StatusBarController.drawLockIcon())
        case .copiedToClipboard:
            setIcon(StatusBarController.drawCheckmarkIcon())
        case .notice, .error:
            setIcon(StatusBarController.drawWarningIcon())
        }
    }

    // MARK: - Recording animation: wave

    private static let waveFrameCount = 30

    private static func prerenderWaveFrames() -> [NSImage] {
        let count = waveFrameCount
        let baseHeights: [CGFloat] = [4, 8, 12, 8, 4]
        let minScale: CGFloat = 0.3
        let phaseOffsets: [Double] = [0.0, 0.15, 0.3, 0.45, 0.6]

        return (0..<count).map { frame in
            let t = Double(frame) / Double(count)

            let size = NSSize(width: 18, height: 18)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()

                let barWidth: CGFloat = 2.0
                let gap: CGFloat = 2.5
                let radius: CGFloat = 1.5
                let centerX = rect.midX
                let centerY = rect.midY

                let totalWidth = CGFloat(baseHeights.count) * barWidth + CGFloat(baseHeights.count - 1) * gap
                let startX = centerX - totalWidth / 2

                for (i, baseHeight) in baseHeights.enumerated() {
                    let phase = t - phaseOffsets[i]
                    let scale = minScale + (1.0 - minScale) * CGFloat((sin(phase * 2.0 * .pi) + 1.0) / 2.0)
                    let height = baseHeight * scale
                    let x = startX + CGFloat(i) * (barWidth + gap)
                    let y = centerY - height / 2
                    let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                    NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()
                }
                return true
            }
            image.isTemplate = true
            return image
        }
    }

    private func startRecordingAnimation() {
        animationFrame = 0
        animationFrames = StatusBarController.prerenderWaveFrames()
        setIcon(animationFrames[0])

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.animationFrame = (self.animationFrame + 1) % StatusBarController.waveFrameCount
            self.setIcon(self.animationFrames[self.animationFrame])
        }
    }

    // MARK: - Transcribing animation: smooth wave dots

    private static let transcribeFrameCount = 30

    private static func prerenderTranscribeFrames() -> [NSImage] {
        let count = transcribeFrameCount
        let maxBounce: CGFloat = 3.0
        return (0..<count).map { frame in
            let t = Double(frame) / Double(count)

            let size = NSSize(width: 18, height: 18)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()

                let dotSize: CGFloat = 3
                let gap: CGFloat = 3.0
                let centerY = rect.midY - dotSize / 2
                let totalWidth = 3 * dotSize + 2 * gap
                let startX = rect.midX - totalWidth / 2

                for i in 0..<3 {
                    let phase = t - Double(i) * 0.15
                    let bounce = maxBounce * CGFloat(max(0, sin(phase * 2.0 * .pi)))
                    let x = startX + CGFloat(i) * (dotSize + gap)
                    let y = centerY + bounce
                    let dotRect = NSRect(x: x, y: y, width: dotSize, height: dotSize)
                    NSBezierPath(ovalIn: dotRect).fill()
                }
                return true
            }
            image.isTemplate = true
            return image
        }
    }

    private func startTranscribingAnimation() {
        animationFrame = 0
        animationFrames = StatusBarController.prerenderTranscribeFrames()
        setIcon(animationFrames[0])

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.animationFrame = (self.animationFrame + 1) % StatusBarController.transcribeFrameCount
            self.setIcon(self.animationFrames[self.animationFrame])
        }
    }

    // MARK: - Downloading: progress ring

    private static let downloadPulseFrameCount = 30

    private static func prerenderDownloadPulseFrames() -> [NSImage] {
        let count = downloadPulseFrameCount
        return (0..<count).map { frame in
            let t = Double(frame) / Double(count)
            let alpha = CGFloat(0.4 + 0.6 * (sin(t * 2.0 * .pi) + 1.0) / 2.0)
            return drawDownloadProgress(0, pulseAlpha: alpha)
        }
    }

    private func startDownloadingAnimation() {
        animationFrame = 0
        animationFrames = StatusBarController.prerenderDownloadPulseFrames()
        setIcon(animationFrames[0])

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.downloadPercent > 0 {
                self.setIcon(StatusBarController.drawDownloadProgress(self.downloadPercent))
            } else {
                self.animationFrame = (self.animationFrame + 1) % StatusBarController.downloadPulseFrameCount
                self.setIcon(self.animationFrames[self.animationFrame])
            }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrames = []
    }

    private func setIcon(_ image: NSImage) {
        DispatchQueue.main.async {
            if let button = self.statusItem.button {
                button.image = image
                button.image?.isTemplate = true
            }
        }
    }

    // MARK: - Custom drawn icons

    static func drawLogo(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()

            let barWidth: CGFloat = 2.0
            let gap: CGFloat = 2.5
            let radius: CGFloat = 1.5
            let centerX = rect.midX
            let centerY = rect.midY

            let heights: [CGFloat] = [4, 8, 12, 8, 4]
            let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            let startX = centerX - totalWidth / 2

            for (i, height) in heights.enumerated() {
                let x = startX + CGFloat(i) * (barWidth + gap)
                let y = centerY - height / 2
                let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func drawDownloadProgress(_ percent: Double, pulseAlpha: CGFloat = 1.0) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.5
            let lineWidth: CGFloat = 1.8

            NSColor.black.withAlphaComponent(0.25 * pulseAlpha).setStroke()
            let bgCircle = NSBezierPath()
            bgCircle.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            bgCircle.lineWidth = lineWidth
            bgCircle.stroke()

            if percent > 0 {
                NSColor.black.setStroke()
                let progressArc = NSBezierPath()
                let startAngle: CGFloat = 90
                let endAngle = startAngle - CGFloat(percent / 100.0) * 360.0
                progressArc.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
                progressArc.lineWidth = lineWidth
                progressArc.lineCapStyle = .round
                progressArc.stroke()
            }

            NSColor.black.withAlphaComponent(pulseAlpha).setStroke()
            NSColor.black.withAlphaComponent(pulseAlpha).setFill()
            let arrowPath = NSBezierPath()
            arrowPath.move(to: NSPoint(x: center.x, y: center.y + 3))
            arrowPath.line(to: NSPoint(x: center.x, y: center.y - 3))
            arrowPath.lineWidth = 1.5
            arrowPath.lineCapStyle = .round
            arrowPath.stroke()

            let headPath = NSBezierPath()
            headPath.move(to: NSPoint(x: center.x - 2.5, y: center.y - 0.5))
            headPath.line(to: NSPoint(x: center.x, y: center.y - 3.5))
            headPath.line(to: NSPoint(x: center.x + 2.5, y: center.y - 0.5))
            headPath.lineWidth = 1.5
            headPath.lineCapStyle = .round
            headPath.lineJoinStyle = .round
            headPath.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    static func drawLockIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let centerX = rect.midX

            let bodyRect = NSRect(x: centerX - 4, y: 2, width: 8, height: 7)
            NSBezierPath(roundedRect: bodyRect, xRadius: 1.5, yRadius: 1.5).fill()

            let shacklePath = NSBezierPath()
            shacklePath.move(to: NSPoint(x: centerX - 2.5, y: 9))
            shacklePath.curve(to: NSPoint(x: centerX + 2.5, y: 9),
                              controlPoint1: NSPoint(x: centerX - 2.5, y: 15),
                              controlPoint2: NSPoint(x: centerX + 2.5, y: 15))
            shacklePath.lineWidth = 1.8
            shacklePath.lineCapStyle = .round
            shacklePath.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    static func drawCheckmarkIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()

            let centerX = rect.midX
            let centerY = rect.midY

            let path = NSBezierPath()
            path.move(to: NSPoint(x: centerX - 5, y: centerY + 1))
            path.line(to: NSPoint(x: centerX - 2, y: centerY - 3))
            path.line(to: NSPoint(x: centerX + 5, y: centerY + 4))
            path.lineWidth = 2.0
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    static func drawWarningIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let centerX = rect.midX

            // Triangle outline
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: centerX, y: 16))
            triangle.line(to: NSPoint(x: centerX - 7, y: 3))
            triangle.line(to: NSPoint(x: centerX + 7, y: 3))
            triangle.close()
            triangle.lineWidth = 1.5
            triangle.lineJoinStyle = .round
            triangle.stroke()

            // Exclamation mark
            let stemRect = NSRect(x: centerX - 0.75, y: 7, width: 1.5, height: 5)
            NSBezierPath(roundedRect: stemRect, xRadius: 0.75, yRadius: 0.75).fill()
            let dotRect = NSRect(x: centerX - 1, y: 4.5, width: 2, height: 2)
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        image.isTemplate = true
        return image
    }
}

extension StatusBarController: NSMenuDelegate {
    /// Re-reads the session every time the menu opens, so a Keychain that was
    /// locked at the last rebuild, or a sign-in from another launch, shows up.
    /// Also re-applies the billing items: the two-minute upgrade poll can flip
    /// `TierStore` while the menu exists, and this is what makes that show up
    /// without waiting for some unrelated rebuild.
    func menuNeedsUpdate(_ menu: NSMenu) {
        applySignInMenu()
        applyBillingMenu()
    }

    /// Shows "Upgrade to Pro…" for a signed-in Free user, "Manage Subscription…"
    /// for a signed-in Pro user, and neither otherwise (signed out, a Keychain
    /// that cannot be read right now, or a tier not yet fetched since launch —
    /// Task 4.6's cache is `nil` in all three cases, and the menu must not guess).
    func applyBillingMenu() {
        guard let upgradeItem = upgradeItem, let manageSubscriptionItem = manageSubscriptionItem,
              let upgradeTarget = upgradeTarget, let manageSubscriptionTarget = manageSubscriptionTarget
        else { return }

        func enable(_ item: NSMenuItem, _ target: MenuItemTarget) {
            item.target = target
            item.action = #selector(MenuItemTarget.invoke)
            item.isHidden = false
        }
        func hide(_ item: NSMenuItem) {
            item.target = nil
            item.action = nil
            item.isHidden = true
        }

        guard case .signedIn = SignInMenuState(SessionStore().load()) else {
            hide(upgradeItem)
            hide(manageSubscriptionItem)
            return
        }
        switch TierStore.shared.current?.tier {
        case .free:
            enable(upgradeItem, upgradeTarget)
            hide(manageSubscriptionItem)
        case .pro:
            hide(upgradeItem)
            enable(manageSubscriptionItem, manageSubscriptionTarget)
        case nil:
            hide(upgradeItem)
            hide(manageSubscriptionItem)
        }
    }

    /// Starts a Checkout Session, opens it in the default browser, then polls
    /// `GET /v1/me` for up to two minutes so the menu flips to Pro without a
    /// restart (Task 4.7). The prompt shows at once, independent of how long the
    /// checkout call itself takes.
    ///
    /// A repeat click while one attempt is already running is a no-op: without
    /// this, a few rapid or accidental clicks would each start their own
    /// checkout-then-poll sequence, all consuming from the same "billing" and
    /// "me" quota buckets for nothing.
    func startUpgrade() {
        guard upgradeGuard.begin() else { return }
        showNotice(BillingCopy.upgradePrompt, for: 6)
        Task { [weak self] in
            let result = await BillingCoordinator.production().upgrade(
                openURL: { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } },
                onTierUpdate: { info in
                    DispatchQueue.main.async {
                        TierStore.shared.set(info)
                        self?.buildMenu()
                    }
                }
            )
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.upgradeGuard.end()
                switch result {
                case .success:
                    // The poll may have ended without ever seeing Pro (checkout
                    // abandoned, or Stripe's webhook still in flight past the
                    // two-minute window) — no notice then, per "no nagging"; the
                    // menu already reflects whatever `TierStore` last learned.
                    if TierStore.shared.current?.tier == .pro {
                        self.showNotice(BillingCopy.upgradeComplete)
                    }
                case .failure(let error):
                    if let notice = BillingCopy.notice(for: error) {
                        self.showNotice(notice)
                    }
                }
            }
        }
    }

    /// Starts a billing portal Session and opens it for a Pro user (Task 4.8).
    /// `.noCustomer` (checkout was never completed) is a real edge case per
    /// backend/proxy/README.md, not a crash: it gets the same plain notice as
    /// every other billing failure.
    func startManageSubscription() {
        Task { [weak self] in
            let result = await BillingCoordinator.production().manageSubscription(
                openURL: { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            )
            if case .failure(let error) = result {
                DispatchQueue.main.async {
                    if let notice = BillingCopy.notice(for: error) {
                        self?.showNotice(notice)
                    }
                }
            }
        }
    }

    func applySignInMenu() {
        guard let signInItem = signInItem, let signOutItem = signOutItem,
              let signInTarget = signInTarget, let signOutTarget = signOutTarget else { return }

        func enable(_ item: NSMenuItem, _ target: MenuItemTarget) {
            item.target = target
            item.action = #selector(MenuItemTarget.invoke)
        }
        func disable(_ item: NSMenuItem) {
            item.target = nil
            item.action = nil
        }

        signInItem.toolTip = nil
        switch SignInMenuState(SessionStore().load()) {
        case .signedOut:
            signInItem.title = SignInCopy.menuSignIn
            enable(signInItem, signInTarget)
            signOutItem.isHidden = true
        case .signedIn(let email):
            signInItem.title = SignInCopy.menuSignedInAs(email)
            signInItem.toolTip = email
            disable(signInItem)
            signOutItem.isHidden = false
            enable(signOutItem, signOutTarget)
        case .unavailable:
            // The Keychain cannot be read right now: do not claim signed out.
            signInItem.title = SignInCopy.menuSignInUnavailable
            disable(signInItem)
            signOutItem.isHidden = true
        }
    }

    /// Signs out, then says what really happened. The token is gone only if the
    /// local clear worked; if it did not, the menu still shows the user as signed
    /// in and the notice says so.
    func signOutFromMenu() {
        guard let coordinator = (NSApp.delegate as? AppDelegate)?.authCoordinator else { return }
        let feedback = SignOutFeedback(local: coordinator.signOut().local)
        showNotice(feedback.notice)
        if let announcement = feedback.announcement {
            SignInAnnouncer.post(announcement, priority: .medium)
        }
    }
}
