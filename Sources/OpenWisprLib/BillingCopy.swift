import Foundation

/// Every user-facing string for "Upgrade to Pro" and "Manage subscription"
/// (Tasks 4.7/4.8). Wording follows `brand-voice-tone-guide.md`: calm, specific,
/// no apology, no exclamation marks, two sentences at most.
///
/// `BillingCopyTests` lints every string with the same rules
/// `RewriteNoticeTests`/`SignInCopyTests` use.
enum BillingCopy {
    // MARK: - Menu items

    static let menuUpgrade = "Upgrade to Pro…"
    static let menuManageSubscription = "Manage Subscription…"

    // MARK: - Upgrade flow

    /// Shown the moment "Upgrade to Pro…" is chosen, before Checkout opens.
    /// Verbatim from `brand-voice-tone-guide.md`'s "Upgrade prompt (Free → Pro)"
    /// sample — do not edit this string without checking that doc first.
    static let upgradePrompt = "Rewrite cleans up filler words and punctuation automatically. It costs us a small amount per use, which is why it's the one thing we charge for — everything else stays free."

    /// Shown once the post-checkout poll sees the tier flip to Pro.
    static let upgradeComplete = "You're on Pro now. Rewrite is available."

    // MARK: - Error mapping

    static let signedOutNotice = "You're signed out. Sign in to manage billing."
    static let alreadyProNotice = "You're already on Pro."
    static let noCustomerNotice = "No subscription found yet. Upgrade to Pro to start one."
    static let rateLimitedNotice = "You've made too many billing requests. Try again in a few minutes."
    static let offlineNotice = "You're offline, and billing needs a connection. Try again once you're back online."
    static let timedOutNotice = "The billing service didn't answer in time. Try again."
    static let unreachableNotice = "Couldn't reach the billing service. Try again in a few minutes."
    static let invalidResponseNotice = "The billing service sent back something unusable. Try again."

    /// `nil` means show nothing: the caller cancelled, which is not a failure.
    /// One switch, no `default`, so a new `BillingError` case does not compile
    /// until someone chooses its wording (same discipline as
    /// `RewriteError.userNotice`).
    static func notice(for error: BillingError) -> String? {
        switch error {
        case .cancelled:
            return nil
        case .notAuthenticated, .unauthorized:
            return signedOutNotice
        case .alreadyPro:
            return alreadyProNotice
        case .noCustomer:
            return noCustomerNotice
        case .rateLimited:
            return rateLimitedNotice
        case .offline:
            return offlineNotice
        case .timedOut:
            return timedOutNotice
        case .unreachable, .unavailable, .providerFailed:
            return unreachableNotice
        case .unexpectedStatus, .invalidResponse:
            return invalidResponseNotice
        }
    }
}
