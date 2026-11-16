import Foundation

/// In-memory cache of the signed-in user's billing tier, from `GET /v1/me`
/// (Task 4.6). Deliberately not persisted anywhere (not `config.json`, not
/// `UserDefaults`, not Keychain): on relaunch the menu shows no tier-specific
/// item until the next fetch, so a stale "Pro" can never survive past what the
/// server actually says right now.
///
/// `nil` means "not known right now" — signed out, not yet fetched since
/// launch, or the last fetch failed — and callers must not guess a tier they
/// have not been told: `StatusBarController` shows neither "Upgrade to Pro" nor
/// "Manage Subscription" while this is `nil`.
final class TierStore: @unchecked Sendable {
    static let shared = TierStore()

    private let lock = NSLock()
    private var _current: TierInfo?

    /// Not private: tests build their own instance instead of touching the
    /// process-wide `shared` cache.
    init() {}

    var current: TierInfo? {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    func set(_ info: TierInfo?) {
        lock.lock()
        _current = info
        lock.unlock()
    }
}

extension TierStore {
    /// Fetches `GET /v1/me` and updates `shared`'s cache. Signed out clears the
    /// cache immediately, with no network call. A successful fetch replaces the
    /// cache; any other failure (offline, timed out, rate-limited, 5xx) leaves the
    /// last known tier as is, EXCEPT `.unauthorized`/`.notAuthenticated`, which
    /// clears it the same as being signed out — a network blip must not hide a
    /// known Pro user's "Manage Subscription" item, but a rejected token really
    /// does mean "not known".
    ///
    /// `completion` always runs, once, on the main thread, whether or not
    /// anything changed, so callers can rebuild the menu unconditionally
    /// (`StatusBarController.buildMenu()` is cheap and idempotent).
    ///
    /// `isSignedIn` and `fetchMe` are injectable so tests never touch the real
    /// Keychain or network; production callers take the defaults.
    static func refresh(
        isSignedIn: () -> Bool = { SessionStore().isSignedIn },
        fetchMe: @escaping () async -> Result<TierInfo, BillingError> = { await BillingClient().fetchMe() },
        completion: @escaping () -> Void = {}
    ) {
        guard isSignedIn() else {
            shared.set(nil)
            DispatchQueue.main.async(execute: completion)
            return
        }
        Task {
            switch await fetchMe() {
            case .success(let info):
                shared.set(info)
            case .failure(.unauthorized), .failure(.notAuthenticated):
                shared.set(nil)
            case .failure:
                break
            }
            DispatchQueue.main.async(execute: completion)
        }
    }
}
