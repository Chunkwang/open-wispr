import Foundation

/// Where sign-in requests go and which PUBLIC key identifies this app to them.
///
/// Auth calls go straight to Supabase, not through our proxy. The client holds
/// only the project URL and the public anon (publishable) key, never the
/// service-role key, an `sb_secret_*` key or the JWT secret. A test asserts that
/// the shipped key is neither, and `isPublicKey` refuses either as an override.
enum AuthConfig {
    /// `.invalid` is reserved (RFC 2606) and never resolves, so until the Supabase
    /// project exists (Day 16) a build cannot send an email address to a hostname
    /// someone else could register.
    static let defaultURL = URL(string: "https://auth.invalid")!

    /// Placeholder until Day 16. Deliberately not a JWT and not a secret-key shape.
    static let defaultAnonKey = "sb_publishable_placeholder_replace_on_day_16"

    /// Environment overrides exist for local development only and are honoured in
    /// DEBUG builds. In a release build anything that could set the environment
    /// could otherwise send the email address and codes to a host of its choosing.
    static let url: URL = {
        resolveURL(override: ProcessInfo.processInfo.environment["OPENWISPR_AUTH_URL"], allowOverride: allowOverride)
    }()

    static let anonKey: String = {
        resolveAnonKey(override: ProcessInfo.processInfo.environment["OPENWISPR_AUTH_ANON_KEY"], allowOverride: allowOverride)
    }()

    private static var allowOverride: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Same rules as the proxy URL: https, or plain http to loopback only.
    static func resolveURL(override: String?, allowOverride: Bool) -> URL {
        RewritePipeline.resolveBaseURL(override: override, allowOverride: allowOverride, default: defaultURL)
    }

    /// A DEBUG override that is not a plausible PUBLIC key falls back to the default.
    static func resolveAnonKey(override: String?, allowOverride: Bool) -> String {
        guard allowOverride, let override = override else { return defaultAnonKey }
        let key = override.trimmingCharacters(in: .whitespacesAndNewlines)
        return isPublicKey(key) ? key : defaultAnonKey
    }

    /// False for anything that must never be in the client: empty, not header-safe,
    /// an `sb_secret_*` key, or a JWT whose `role` is `service_role`. It cannot
    /// prove a key is public, only refuse the known secret shapes.
    static func isPublicKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.count <= 2048 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard key.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        if key.lowercased().hasPrefix("sb_secret_") { return false }
        return jwtRole(of: key) != "service_role"
    }

    /// The `role` claim of a JWT-shaped string, without verifying anything.
    static func jwtRole(of token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["role"] as? String
    }
}
