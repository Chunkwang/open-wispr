import Foundation

/// Reads and writes the one Keychain item that holds the signed-in `AuthSession`.
///
/// Signed out means exactly one thing: the item does not exist (or holds bytes
/// that can never be a session). A Keychain that cannot be read right now (a
/// locked screen, a dismissed access prompt) is an error, surfaced to the caller,
/// and nothing is deleted because of it: the session may be perfectly good.
struct SessionStore: Sendable {
    /// Keychain account of the session. The service is `Keychain.service`.
    static let account = "session"

    /// The account the DEBUG-only paste-a-token menu shortcut used before
    /// sign-in existed. It held a bare token, not a session, and is deleted, not
    /// migrated.
    static let legacyAccount = "session-token"

    private let keychain: KeychainStoring

    init(keychain: KeychainStoring = SystemKeychain()) {
        self.keychain = keychain
    }

    /// `.success(nil)` means signed out. Bytes that do not decode to a session
    /// (a partial write, a format from another build) are deleted and also count
    /// as signed out, so a corrupt item cannot wedge sign-in.
    func load() -> Result<AuthSession?, KeychainError> {
        let data: Data?
        do {
            data = try keychain.read(account: SessionStore.account)
        } catch let error as KeychainError {
            return .failure(error)
        } catch {
            return .failure(KeychainError(status: errSecInternalError))
        }
        guard let data = data else { return .success(nil) }
        guard let session = try? JSONDecoder().decode(AuthSession.self, from: data),
              !session.accessToken.isEmpty
        else {
            try? keychain.delete(account: SessionStore.account)
            return .success(nil)
        }
        return .success(session)
    }

    func save(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        try keychain.write(data, account: SessionStore.account)
    }

    /// Removes the session. Clearing what is not there succeeds. A failure is
    /// returned, not swallowed: sign-out must know whether the token is really gone.
    @discardableResult
    func clear() -> Result<Void, KeychainError> {
        do {
            try keychain.delete(account: SessionStore.account)
            return .success(())
        } catch let error as KeychainError {
            return .failure(error)
        } catch {
            return .failure(KeychainError(status: errSecInternalError))
        }
    }

    /// True only when a usable session is stored. A Keychain that cannot be read
    /// counts as "no token available right now" (the caller inserts raw text), not
    /// as a reason to change anything.
    var isSignedIn: Bool {
        if case .success(let session) = load(), session != nil { return true }
        return false
    }

    /// Deletes the pre-sign-in dev token item. Best effort: it is only clutter.
    func deleteLegacyItem() {
        try? keychain.delete(account: SessionStore.legacyAccount)
    }
}
