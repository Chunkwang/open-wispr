import Foundation

/// Every user-facing string in the app (except sign-in, which lives in
/// `SignInCopy.swift`, and rewrite errors, which live in `RewriteNotices.swift`).
///
/// Wording follows `brand-voice-tone-guide.md`: calm, specific, no apology, no
/// exclamation marks, two sentences at most. Say what happened and what happened
/// to the user's text.
///
/// The `CopyLintTests` test (Task 6.4, pending) will fail if any string here
/// contains "smart", "seamless", "powerful", "magic", "simply", "Oops", or
/// exclamation marks (with a small allow-list).
enum Copy {
    // MARK: - Onboarding

    static let onboardingWelcome = "Hold the key, say what you want written. It stays on this Mac unless you tell it otherwise."
    static let onboardingMicrophone = "We need microphone access to hear what you dictate. Audio is processed on this device and never saved or sent anywhere for the free tier."
    static let onboardingAccessibility = "Accessibility access lets the app place your dictated text wherever your cursor is. It doesn't let the app read anything you haven't dictated."
    static let onboardingGetStarted = "Get Started"
    static let onboardingAllowMic = "Allow Microphone Access"
    static let onboardingAllowAX = "Allow Accessibility Access"

    // MARK: - Status bar states

    static let statusIdle = "Ready"
    static let statusRecording = "Listening…"
    static let statusTranscribing = "Transcribing…"
    static let statusRewriting = "Rewriting…"

    // MARK: - Menu items

    static let menuCopyLast = "Copy Last Dictation"
    static let menuCopied = "Copied"
    static let menuRewrite = "Rewrite"
    static let menuRevokeRewriteConsent = "Revoke rewrite consent"
    static let menuRevokeContextConsent = "Revoke context consent"
    static let menuEnableContext = "Enable screen context…"
    static let menuQuit = "Quit"
    static let menuGrantAccessibility = "Grant Accessibility Permission…"
    static let menuTranslateForeignSpeech = "Translate Foreign Speech to English"
    static let menuModelHeaderEnglish = "English"
    static let menuModelHeaderMultilingual = "Multilingual"
    static let menuAudioSystemDefault = "System Default"
    static let menuToggleMode = "Toggle Mode"
    static let menuRecentRecordings = "Recent Recordings"
    static let menuNoRecordings = "No recordings"
    static let menuReloadConfiguration = "Reload Configuration"
    static let menuOpenConfiguration = "Open Configuration"
    static let menuCheckForUpdates = "Check for Updates…"
    static func menuTitle(displayName: String, version: String) -> String {
        "\(displayName) v\(version)"
    }
    static func menuStateWithHotkey(_ stateLabel: String, hotkeyDescription: String) -> String {
        "\(stateLabel) (hotkey: \(hotkeyDescription))"
    }
    static func menuLanguage(_ name: String) -> String {
        "Language: \(name)"
    }
    static func menuModel(_ name: String) -> String {
        "Model: \(name)"
    }
    static func menuAudioInput(_ name: String) -> String {
        "Audio Input: \(name)"
    }

    // MARK: - Status bar state labels

    static let statusDownloadingModel = "Downloading model…"
    static let statusWaitingForAccessibility = "Waiting for Accessibility permission…"
    static let statusCopiedToClipboard = "Copied to clipboard"
    static func statusError(_ message: String) -> String {
        "Error: \(message)"
    }
    /// Shown when the hotkey is pressed but recording itself never starts (the
    /// audio engine failed, most commonly because Microphone access was
    /// revoked in System Settings after the app launched). Without this, the
    /// status bar just falls back to "Ready" with no indication anything went
    /// wrong -- see AppDelegate.handleRecordingStart's catch block.
    static let recordingFailedToStart = "Could not start recording. Check Microphone access in System Settings → Privacy & Security."

    // MARK: - Rewrite disclosure sheet

    static let disclosureTitle = "Before Rewrite can work"
    static let disclosureWhatSentTitle = "What is sent"
    static let disclosureWhatSentBody = "The text you dictated — nothing else. Never your audio, never your keystrokes, never your clipboard."
    static let disclosureToWhomTitle = "To whom"
    static let disclosureToWhomBody = "Your text goes to our secure proxy, then to Anthropic's Claude model for rewriting. Both connections are encrypted."
    static let disclosureRetentionTitle = "What is kept"
    static let disclosureRetentionBody = "Our server does not log, store or retain your text, and Anthropic's API does not train on it."
    static let disclosureFailureTitle = "If things go wrong"
    static let disclosureFailureBody = "If the network or the service fails, your raw dictation is inserted instead. Nothing is lost."
    static let disclosureRevoke = "You can revoke this at any time from the menu bar."
    static let disclosureAccept = "Accept"
    static let disclosureDecline = "Decline"

    // MARK: - Context consent sheet

    static let contextConsentTitle = "Enable Screen Context"
    static let contextConsentSubtitle = "To edit selected text with your voice, Murmur needs permission to read it."
    static let contextWhatSent = "Only the text you have highlighted and the frontmost window's title."
    static let contextToWhom = "Our secure proxy, then to the AI model. It is never stored."
    static let contextSafety = "Password fields and secure apps are automatically ignored."

    // MARK: - Ask overlay

    static let askListening = "Listening..."
    static let askProcessing = "Thinking..."
    static let askCopyDismiss = "Copy & Dismiss"

    // MARK: - Edit & Ask errors

    static let editSecureField = "Cannot use Edit in a secure field."
    static let askSecureField = "Cannot use Ask in a secure field."
    static func askExcludedApp(_ name: String) -> String {
        "Ask is disabled for \(name) to protect your privacy."
    }
    static func editExcludedApp(_ name: String) -> String {
        "Edit is disabled for \(name) to protect your privacy."
    }
    static let editExcludedGeneric = "Edit is disabled for this app to protect your privacy."
    static let injectionBlocked = "Screen content rejected due to unsafe instructions."
    static func askNoSpeechDetected(_ hotkeyDescription: String) -> String {
        "No speech detected. Hold \(hotkeyDescription) and ask a question."
    }
    static let contextHotkeyFallbackName = "the Context hotkey"
    static func askHighlightedLabel(_ label: String) -> String {
        "Highlighted \(label) on screen."
    }
    static let askHighlightedElement = "Highlighted element on screen."
    static let askNoResponseText = "No response text received."

    // MARK: - Model download

    static func downloadingModel(_ size: String, percent: Int) -> String {
        "Downloading \(size) model... \(percent)%"
    }
    static func modelFileCorrupted(_ modelSize: String) -> String {
        "Model file is corrupted. Re-download with: open-wispr download-model \(modelSize)"
    }

    // MARK: - Growth Loop (Before / After)

    static let menuCopyBeforeAfter = "Copy Before / After"
    static let menuCopiedBeforeAfter = "Copied Before / After"

    static func formatBeforeAfter(raw: String, rewritten: String) -> String {
        """
        Raw:
        \(raw)

        Rewritten:
        \(rewritten)
        """
    }

    // MARK: - Referral

    static let referralMenuInvite = "Invite someone…"
    static let referralCopiedLink = "Referral link copied"
    static let referralPrompt = "Know someone who dictates a lot? Send them an invite — you both get an extended trial of rewrite."
}
