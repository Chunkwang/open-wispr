import Foundation

/// What the DEBUG sign-in menu items show (docs/design/sign-in.md, section 9),
/// decided from one read of the session store. A Keychain that cannot be read is
/// its own case, so the menu never claims the user is signed out when it merely
/// could not look.
enum SignInMenuState: Equatable {
    case signedOut
    case signedIn(email: String)
    case unavailable

    init(_ load: Result<AuthSession?, KeychainError>) {
        switch load {
        case .success(let session?): self = .signedIn(email: session.email)
        case .success(nil): self = .signedOut
        case .failure: self = .unavailable
        }
    }
}

/// What to tell the user after "Sign out". The token is gone only if the local
/// clear worked: a failed clear must never be reported as signed out.
struct SignOutFeedback: Equatable {
    /// Five-second menu notice.
    let notice: String
    /// Spoken announcement; nil when the user is still signed in.
    let announcement: String?
    let isSignedOut: Bool

    init(local: Result<Void, AuthError>) {
        switch local {
        case .success:
            notice = SignInCopy.signOutSignedOutNotice
            announcement = SignInCopy.signedOut
            isSignedOut = true
        case .failure:
            notice = SignInCopy.signOutFailed
            announcement = nil
            isSignedOut = false
        }
    }
}
