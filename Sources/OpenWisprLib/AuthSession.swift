import Foundation

/// The signed-in session: what Supabase issued at verify time. Stored as ONE
/// Keychain item (`SessionStore`) so the access token, refresh token and expiry
/// can never be out of step with each other, which refresh logic depends on.
///
/// Every description is redacted, so interpolating a session into a log line or
/// an error message cannot leak a token or the email address.
public struct AuthSession: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var email: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, email: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.email = email
    }

    /// True when the access token is expired or will be within `leeway` seconds.
    /// The boundary counts as needing a refresh.
    public func needsRefresh(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }

    public var description: String { "AuthSession(redacted)" }
    public var debugDescription: String { "AuthSession(redacted)" }
    /// `dump` and Xcode's variable view read this, not `description`.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    // Stored as epoch seconds (a plain number) so the format does not depend on
    // a date-encoding strategy.
    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, expiresAt, email
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        expiresAt = Date(timeIntervalSince1970: try container.decode(TimeInterval.self, forKey: .expiresAt))
        email = try container.decode(String.self, forKey: .email)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(refreshToken, forKey: .refreshToken)
        try container.encode(expiresAt.timeIntervalSince1970, forKey: .expiresAt)
        try container.encode(email, forKey: .email)
    }
}
