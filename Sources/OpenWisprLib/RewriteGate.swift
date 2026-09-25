import Foundation

/// The user's recorded agreement to send transcript text to the rewrite service.
///
/// This lives in UserDefaults, deliberately NOT in `config.json`: that file is a
/// plain settings file anything running as the user can edit, so a value there
/// proves nothing about what the user was shown. The stored value is the version
/// of the disclosure the user accepted. Bumping `currentDisclosureVersion` when
/// the disclosure text changes makes every earlier acceptance stop counting.
///
/// Until the disclosure sheet exists (Task 5.1) nothing in the app is allowed to
/// record acceptance in a release build: `recordAcceptance()` is compiled only
/// under `#if DEBUG`, so a release binary contains no code that can set it.
/// `RewriteGateTests` scans the sources and fails if any call is left outside a
/// DEBUG region. Task 5.1 removes the guard and calls it from the sheet's
/// "Accept" button.
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

    #if DEBUG
    /// DEBUG builds only, until the disclosure sheet (Task 5.1) is the one place
    /// that calls this. Do not reference it outside a `#if DEBUG` region.
    public func recordAcceptance() {
        defaults.set(RewriteConsent.currentDisclosureVersion, forKey: RewriteConsent.defaultsKey)
    }
    #endif
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
        hasToken: @autoclosure () -> Bool
    ) -> Bool {
        guard mode == .auto else { return false }
        guard consent.hasConsent else { return false }
        return hasToken()
    }

    #if DEBUG
    /// One-line menu status derived from the same inputs as the gate. "on" is
    /// returned exactly when `shouldRewrite` would return true. Only the DEBUG
    /// menu shows it (the Rewrite menu is hidden from release builds until the
    /// disclosure sheet exists, Task 5.1), so it is compiled only there.
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
    #endif
}
