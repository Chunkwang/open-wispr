import Foundation

/// The user's recorded agreement to send transcript text to the rewrite service.
///
/// This lives in UserDefaults, deliberately NOT in `config.json`: that file is a
/// plain settings file anything running as the user can edit, so a value there
/// proves nothing about what the user was shown. The stored value is the version
/// of the disclosure the user accepted. Bumping `currentDisclosureVersion` when
/// the disclosure text changes makes every earlier acceptance stop counting.
///
/// `recordAcceptance()` is called only from the disclosure sheet's "Accept"
/// button (`RewriteDisclosureSheet.swift`, Task 5.1); nothing else in the app
/// may call it. `RewriteGateTests` scans the sources and fails if any other
/// call exists outside a `#if DEBUG` region.
public struct RewriteConsent {
    /// Version of the disclosure text the user must have accepted.
    public static let currentDisclosureVersion = 1

    static let defaultsKey = "rewriteDisclosureVersionAccepted"

    public static let shared = RewriteConsent()

    private let defaults: UserDefaults

    /// `defaults` is injectable so tests use a throwaway suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True only when the stored value is a plain integer equal to the current
    /// disclosure version. A missing key, an older or newer version, a string, a
    /// boolean or any other type all count as "no consent".
    public var hasConsent: Bool {
        guard let number = defaults.object(forKey: RewriteConsent.defaultsKey) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number)
        else { return false }
        return number.intValue == RewriteConsent.currentDisclosureVersion
    }

    /// Withdrawing consent only ever reduces what is sent, so it is not gated.
    public func revoke() {
        defaults.removeObject(forKey: RewriteConsent.defaultsKey)
    }

    /// Records the user's acceptance of the current disclosure version.
    /// Called only from the disclosure sheet's Accept button.
    public func recordAcceptance() {
        defaults.set(RewriteConsent.currentDisclosureVersion, forKey: RewriteConsent.defaultsKey)
    }
}

/// The single decision point for whether a transcript may leave the device.
/// `RewriteCoordinator` consults nothing else, and `AppDelegate` reaches the
/// network only through the coordinator. Every condition must hold. `hasToken` is
/// evaluated only if the checks before it passed, so a user with rewrite off
/// triggers no Keychain read.
public enum RewriteGate {
    public static func shouldRewrite(
        mode: RewriteMode,
        consent: RewriteConsent,
        hasToken: @autoclosure () -> Bool,
        config: Config? = nil
    ) -> Bool {
        guard mode == .auto else { return false }
        guard consent.hasConsent else { return false }
        if let config = config {
            // Preferred first: costs 0 extra app size and needs 0 separate
            // install, unlike the Ollama bypass below. Only a genuine bypass when
            // the on-device model is actually usable right now — an enabled flag
            // on a Mac where Apple Intelligence is off must fall through to the
            // next check, not silently open the gate.
            if config.onDeviceAIEnabled?.value == true, FoundationModelsPipeline.isAvailable {
                return true
            }
            if config.localLLMEnabled?.value == true,
               LocalLLMPipeline.validatedURL(from: config.localLLMURL) != nil {
                return true
            }
        }
        return hasToken()
    }

    /// One-line menu status derived from the same inputs as the gate.
    public static func statusLine(
        mode: RewriteMode,
        consent: RewriteConsent,
        hasToken: @autoclosure () -> Bool
    ) -> String {
        guard mode == .auto else { return "Rewrite: off" }
        guard hasToken() else { return "Rewrite: needs sign-in" }
        guard consent.hasConsent else { return "Rewrite: needs your consent" }
        return "Rewrite: on"
    }
}
