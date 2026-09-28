import Foundation

/// The user's recorded agreement to send context data to the proxy.
///
/// This uses the same pattern as `RewriteConsent`: it stores the version of the 
/// disclosure accepted, not a simple boolean, so a change to the disclosure text
/// invalidates old consent. Two separate records are kept: one for selected text
/// and window titles, and one for the screen image itself.
public struct ContextConsent {
    public static let currentTextDisclosureVersion = 1
    public static let currentImageDisclosureVersion = 1
    
    static let textDefaultsKey = "contextTextDisclosureVersionAccepted"
    static let imageDefaultsKey = "screenImageDisclosureVersionAccepted"
    
    public static let shared = ContextConsent()
    
    private let defaults: UserDefaults
    
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    
    public var hasTextConsent: Bool {
        guard let number = defaults.object(forKey: ContextConsent.textDefaultsKey) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number)
        else { return false }
        return number.intValue == ContextConsent.currentTextDisclosureVersion
    }
    
    public var hasImageConsent: Bool {
        guard let number = defaults.object(forKey: ContextConsent.imageDefaultsKey) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number)
        else { return false }
        return number.intValue == ContextConsent.currentImageDisclosureVersion
    }
    
    public func revokeTextConsent() {
        defaults.removeObject(forKey: ContextConsent.textDefaultsKey)
    }
    
    public func revokeImageConsent() {
        defaults.removeObject(forKey: ContextConsent.imageDefaultsKey)
    }
    
    /// Records the user's acceptance of the current text disclosure version.
    /// Called only from the disclosure sheet's Accept button.
    public func recordTextAcceptance() {
        defaults.set(ContextConsent.currentTextDisclosureVersion, forKey: ContextConsent.textDefaultsKey)
    }
    
    /// Records the user's acceptance of the current image disclosure version.
    /// Called only from the disclosure sheet's Accept button.
    public func recordImageAcceptance() {
        defaults.set(ContextConsent.currentImageDisclosureVersion, forKey: ContextConsent.imageDefaultsKey)
    }
}

/// The v2 agent-layer surfaces (Edit and Ask context/screen awareness). Every
/// condition must hold, cheapest first: the flag (a plain property read), mode,
/// then consent (a UserDefaults read) before `hasToken` (a Keychain read) is
/// even evaluated. `config?.isAgentLayerEnabled` is checked first and alone
/// decides "no" when it is false, so a nil config (nothing wired in yet) or an
/// old/default config.json closes the gate regardless of consent or sign-in —
/// this is the flag CLAUDE.md requires to ship off by default.
public enum EditGate {
    public static func shouldEdit(
        mode: RewriteMode,
        consent: ContextConsent,
        hasToken: @autoclosure () -> Bool,
        config: Config? = nil
    ) -> Bool {
        guard config?.isAgentLayerEnabled == true else { return false }
        guard mode == .auto else { return false }
        guard consent.hasTextConsent else { return false }
        if let config = config, config.localLLMEnabled?.value == true,
           LocalLLMPipeline.validatedURL(from: config.localLLMURL) != nil {
            return true
        }
        return hasToken()
    }
}

public enum AskGate {
    public static func shouldAsk(
        mode: RewriteMode,
        consent: ContextConsent,
        hasToken: @autoclosure () -> Bool,
        config: Config? = nil
    ) -> Bool {
        guard config?.isAgentLayerEnabled == true else { return false }
        guard mode == .auto else { return false }
        guard consent.hasImageConsent else { return false }
        if let config = config, config.localLLMEnabled?.value == true,
           LocalLLMPipeline.validatedURL(from: config.localLLMURL) != nil {
            return true
        }
        return hasToken()
    }
}
