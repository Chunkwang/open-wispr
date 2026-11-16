import Foundation

/// Why a sign-in step did not succeed. `AuthService` never throws: every failure
/// is one of these, chosen from the HTTP status and Supabase's `error_code`,
/// never from message text.
///
/// `errorDescription` is fixed diagnostic text for logs. It never contains an
/// email address, a code or a token. User-facing wording is chosen from the brand
/// voice guide in one place (`SignInCopy`, Day 4 part 2).
public enum AuthError: LocalizedError, Equatable, Sendable {
    /// The email address was refused as malformed.
    case invalidEmail
    /// The code was refused. Wrong, expired and already-used codes look the same
    /// to the server, so they look the same here.
    case codeRejected
    /// Too many verify attempts. Wait `retryAfter` seconds.
    case tooManyAttempts(retryAfter: TimeInterval)
    /// Too many codes requested for this address. Wait `retryAfter` seconds.
    case sendRateLimited(retryAfter: TimeInterval)
    /// The device has no network connection.
    case offline
    /// The request did not finish in time.
    case timedOut
    /// The caller cancelled. Not a service problem: show no notice.
    case cancelled
    /// The service could not be reached for any other network reason.
    case unreachable
    /// 5xx from the service.
    case unavailable
    /// The service answered with something this client cannot use: a success with
    /// an unusable body, or a status it has no meaning for.
    case invalidResponse
    /// The refresh token was rejected; the session is over (Day 5).
    case sessionRevoked
    /// Signed in, but the session could not be saved to the Keychain.
    case storageFailed

    /// Used when the server gives no (or an unusable) `Retry-After`.
    public static let defaultRetryAfter: TimeInterval = 60

    public var errorDescription: String? {
        switch self {
        case .invalidEmail: return "Email address refused."
        case .codeRejected: return "Code refused."
        case .tooManyAttempts: return "Too many attempts."
        case .sendRateLimited: return "Too many codes requested."
        case .offline: return "No network connection."
        case .timedOut: return "Sign-in request timed out."
        case .cancelled: return "Sign-in request cancelled."
        case .unreachable: return "Sign-in service unreachable."
        case .unavailable: return "Sign-in service unavailable (5xx)."
        case .invalidResponse: return "Unusable response from sign-in service."
        case .sessionRevoked: return "Session ended."
        case .storageFailed: return "Could not save the session."
        }
    }
}
