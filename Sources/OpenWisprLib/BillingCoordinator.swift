import Foundation

/// Drives "Upgrade to Pro" and "Manage subscription" (Tasks 4.7/4.8). Owns no UI
/// and no AppKit dependency: `StatusBarController` supplies `openURL` (which
/// dispatches to `NSWorkspace.shared.open` on the main thread) and turns the
/// results into notices and a menu rebuild. Every dependency here is a plain
/// closure so tests can drive the whole checkout-then-poll sequence with a fake
/// clock and a fake network, in well under the real two minutes.
final class BillingCoordinator {
    /// How long to keep polling `GET /v1/me` after Checkout opens, per the plan
    /// ("poll `/v1/me` for up to two minutes after return").
    static let pollDuration: TimeInterval = 120
    /// Interval between polls: frequent enough that the menu updates within a
    /// few seconds of the webhook landing, far below `/v1/me`'s 60/min limit.
    static let pollInterval: TimeInterval = 5

    private let fetchMe: () async -> Result<TierInfo, BillingError>
    private let startCheckoutCall: () async -> Result<URL, BillingError>
    private let startPortalCall: () async -> Result<URL, BillingError>
    private let sleep: (TimeInterval) async -> Void
    private let now: () -> Date
    private let pollDuration: TimeInterval
    private let pollInterval: TimeInterval

    init(
        fetchMe: @escaping () async -> Result<TierInfo, BillingError>,
        startCheckout: @escaping () async -> Result<URL, BillingError>,
        startPortal: @escaping () async -> Result<URL, BillingError>,
        sleep: @escaping (TimeInterval) async -> Void = BillingCoordinator.defaultSleep,
        now: @escaping () -> Date = Date.init,
        pollDuration: TimeInterval = BillingCoordinator.pollDuration,
        pollInterval: TimeInterval = BillingCoordinator.pollInterval
    ) {
        self.fetchMe = fetchMe
        self.startCheckoutCall = startCheckout
        self.startPortalCall = startPortal
        self.sleep = sleep
        self.now = now
        self.pollDuration = pollDuration
        self.pollInterval = pollInterval
    }

    /// Production wiring: a fresh `BillingClient` per call (billing actions are
    /// infrequent button presses, not a hot path, so there is nothing worth
    /// caching the way `RewriteCoordinator` caches its pipeline).
    static func production() -> BillingCoordinator {
        let client = BillingClient()
        return BillingCoordinator(
            fetchMe: { await client.fetchMe() },
            startCheckout: { await client.startCheckout() },
            startPortal: { await client.startPortal() }
        )
    }

    private static func defaultSleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Starts a Checkout Session and, only if that succeeds, opens it and polls.
    /// `openURL` is called exactly once, only on success. `onTierUpdate` is called
    /// after every poll that got a usable answer (even a still-Free one), so the
    /// caller can refresh its cache and the menu while polling continues; it is
    /// never called after a poll failure (offline, rate-limited, etc. are treated
    /// as "try again next tick", not reported).
    ///
    /// Returns once Checkout has been opened, whether or not the poll ever saw
    /// Pro: `.success` means "checkout started", not "now on Pro" — the caller
    /// reads the last `onTierUpdate` (or the cache it wrote) to know which.
    @discardableResult
    func upgrade(
        openURL: @escaping (URL) -> Void,
        onTierUpdate: @escaping (TierInfo) -> Void
    ) async -> Result<Void, BillingError> {
        switch await startCheckoutCall() {
        case .failure(let error):
            return .failure(error)
        case .success(let url):
            openURL(url)
            await poll(onTierUpdate: onTierUpdate)
            return .success(())
        }
    }

    /// Stops as soon as `onTierUpdate` sees Pro, or once `pollDuration` elapses.
    private func poll(onTierUpdate: @escaping (TierInfo) -> Void) async {
        let deadline = now().addingTimeInterval(pollDuration)
        while now() < deadline {
            await sleep(pollInterval)
            guard case .success(let info) = await fetchMe() else { continue }
            onTierUpdate(info)
            if info.tier == .pro { return }
        }
    }

    /// Starts a portal Session and opens it. `openURL` is called exactly once,
    /// only on success.
    @discardableResult
    func manageSubscription(openURL: @escaping (URL) -> Void) async -> Result<Void, BillingError> {
        switch await startPortalCall() {
        case .success(let url):
            openURL(url)
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }
}
