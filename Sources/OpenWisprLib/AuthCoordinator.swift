import Foundation

/// The sign-in hooks the sign-in window and menu call. It ties the three sign-in
/// pieces together in the order that matters and owns no UI:
///
/// - after a verified sign-in the session is saved, then the rewrite coordinator's
///   session-long stop is lifted (a stop set by an earlier 401 or "not Pro" answer
///   would otherwise outlive the new sign-in);
/// - sign-out clears the Keychain FIRST, then lifts the same stop, and only then
///   tells the server, so a slow or failed network can never leave the user
///   signed in locally.
final class AuthCoordinator: Sendable {
    /// Result of `signOut()`.
    struct SignOut {
        /// `.failure(.storageFailed)` when the Keychain refused to delete the
        /// session, so the token is still on this Mac and the UI must not claim
        /// the user is signed out.
        let local: Result<Void, AuthError>
        /// The best-effort server call (capped at `AuthService.logoutCap`).
        /// Nothing needs to await it; tests do. Nil when there was no session.
        let serverLogout: Task<Void, Never>?
    }

    private let service: AuthService
    private let store: SessionStore
    private let didChangeSession: @Sendable () -> Void

    /// - Parameter didChangeSession: called after every sign-in and sign-out. The
    ///   app passes `{ rewriteCoordinator.resetSession() }`.
    init(service: AuthService, store: SessionStore, didChangeSession: @escaping @Sendable () -> Void) {
        self.service = service
        self.store = store
        self.didChangeSession = didChangeSession
    }

    /// Production wiring for the app.
    convenience init(didChangeSession: @escaping @Sendable () -> Void) {
        self.init(service: AuthService(), store: SessionStore(), didChangeSession: didChangeSession)
    }

    func requestCode(email: String) async -> Result<Void, AuthError> {
        await service.requestCode(email: email)
    }

    /// Verifies the code and saves the session. `.storageFailed` means the code
    /// was good but the Keychain would not keep the session: the user is not
    /// signed in.
    func verifyCode(email: String, code: String) async -> Result<AuthSession, AuthError> {
        switch await verifyWithoutSaving(email: email, code: code) {
        case .failure(let error):
            return .failure(error)
        case .success(let session):
            switch save(session) {
            case .success: return .success(session)
            case .failure(let error): return .failure(error)
            }
        }
    }

    /// Verifies the code and hands the session back unsaved, so the sign-in
    /// window can keep it in memory and retry `save(_:)` after a Keychain failure
    /// without asking for a new code (the server has already consumed this one).
    func verifyWithoutSaving(email: String, code: String) async -> Result<AuthSession, AuthError> {
        await service.verifyCode(email: email, code: code)
    }

    /// Saves a verified session, then lifts the rewrite coordinator's stop.
    /// `.storageFailed` when the Keychain refuses; nothing has changed then.
    func save(_ session: AuthSession) -> Result<Void, AuthError> {
        do {
            try store.save(session)
        } catch {
            return .failure(.storageFailed)
        }
        didChangeSession()
        return .success(())
    }

    /// Best-effort server logout of a session that was verified but never saved
    /// (the window closed on the save-failure screen), so the server session is
    /// not orphaned. Capped at `AuthService.logoutCap`. Nothing needs to await it.
    @discardableResult
    func discardUnsaved(_ session: AuthSession) -> Task<Void, Never> {
        let service = self.service
        return Task { await service.signOut(session) }
    }

    /// Signs out. Local work is done, and reported, before this returns.
    @discardableResult
    func signOut() -> SignOut {
        // Read first: the access token is needed for the server call and is gone
        // once the item is cleared. A Keychain that cannot be read gives no token,
        // and the clear below still runs.
        var session: AuthSession?
        if case .success(let stored) = store.load() { session = stored }

        let local: Result<Void, AuthError>
        switch store.clear() {
        case .success: local = .success(())
        case .failure: local = .failure(.storageFailed)
        }
        didChangeSession()

        guard let session = session else { return SignOut(local: local, serverLogout: nil) }
        let service = self.service
        return SignOut(local: local, serverLogout: Task { await service.signOut(session) })
    }
}
