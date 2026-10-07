import Foundation

/// The 5 event names v1 is allowed to report — a closed set, not a free-form
/// string, so a future caller cannot add a 6th event (or a payload disguised as
/// one) without a compiler error here.
enum AnalyticsEvent: String {
    case dictationCompleted = "dictation_completed"
    case rewriteInvoked = "rewrite_invoked"
    case subscriptionTierChanged = "subscription_tier_changed"
    case beforeAfterShared = "before_after_shared"
    case referralSent = "referral_sent"
}

/// Sends anonymous event counters to `POST /v1/events` when opt-in diagnostics is enabled.
///
/// Rules (Task 7.7):
///  - Off by default (`analyticsOptIn` must be explicitly `true`).
///  - If disabled, zero network calls are made.
///  - Carries only the 5 allowed v1 event names, enforced by `AnalyticsEvent`
///    being the only type `send` accepts.
///  - Contains no user identifier, token, IP, or dictation payload.
struct AnalyticsReporter {
    static var endpoint: URL {
        let base = ProcessInfo.processInfo.environment["OPENWISPR_PROXY_URL"] ?? "http://127.0.0.1:8787"
        return URL(string: "\(base)/v1/events")!
    }

    static func send(_ event: AnalyticsEvent, configProvider: () -> Config = { Config.load() }) {
        let config = configProvider()
        // Off by default: require explicit opt-in
        guard config.analyticsOptIn?.value == true else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["event": event.rawValue])

        URLSession.shared.dataTask(with: request).resume()
    }
}
