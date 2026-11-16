import Foundation

/// The signed-in user's billing tier, from `GET /v1/me` (backend/proxy/README.md).
enum Tier: String, Codable, Equatable, Sendable {
    case free
    case pro
}

/// One snapshot of `GET /v1/me`: the tier and the live rewrite quota remaining
/// this month. Cached in memory by `TierStore`; never written to disk or to
/// `config.json` (Task 4.6).
struct TierInfo: Equatable, Sendable {
    let tier: Tier
    let remainingThisMonth: Int
}

/// Why a billing call (`GET /v1/me`, `POST /v1/billing/checkout`,
/// `POST /v1/billing/portal`) did not produce a result. Mirrors `RewriteError`'s
/// shape, but for the billing endpoints' own status codes (backend/proxy/README.md),
/// which differ from `/v1/rewrite`'s: no 402 (these routes are reachable by Free
/// users on purpose), but a 409 "already Pro" on checkout and a 404 "no Stripe
/// customer yet" on portal that `/v1/rewrite` has no equivalent of.
enum BillingError: LocalizedError, Equatable, Sendable {
    /// No session token stored; nothing was sent.
    case notAuthenticated
    /// 401: the token was rejected (expired or revoked).
    case unauthorized
    /// 409 from checkout: the caller is already Pro, no Stripe call was made.
    case alreadyPro
    /// 404 from portal: no `stripe_customer_id` on file yet (checkout was never
    /// completed for this user).
    case noCustomer
    /// 429: the shared per-user "billing" or "me" quota bucket is exhausted.
    case rateLimited
    /// The device has no network connection.
    case offline
    /// The request did not finish in time.
    case timedOut
    /// The caller cancelled (for example the app is quitting). Not a service
    /// problem: show no notice.
    case cancelled
    /// The service could not be reached for any other network reason.
    case unreachable
    /// 5xx other than 502 (`misconfigured`, `service_unavailable`).
    case unavailable
    /// 502 `checkout_failed` / `portal_failed`: Stripe itself rejected the call.
    case providerFailed
    /// Any other unexpected HTTP status.
    case unexpectedStatus(Int)
    /// A success status with a body we cannot use (bad JSON or an unusable URL).
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in."
        case .unauthorized: return "Session rejected (401)."
        case .alreadyPro: return "Already Pro (409)."
        case .noCustomer: return "No Stripe customer on file (404)."
        case .rateLimited: return "Billing quota reached (429)."
        case .offline: return "No network connection."
        case .timedOut: return "Billing request timed out."
        case .cancelled: return "Billing request cancelled."
        case .unreachable: return "Billing service unreachable."
        case .unavailable: return "Billing service unavailable (5xx)."
        case .providerFailed: return "Stripe rejected the request (502)."
        case .unexpectedStatus(let code): return "Unexpected response (\(code))."
        case .invalidResponse: return "Unusable response from billing service."
        }
    }
}

/// `GET /v1/me`, `POST /v1/billing/checkout`, `POST /v1/billing/portal`
/// (TRD Section 3.3 / backend/proxy/README.md). Sends nothing but the bearer
/// token: no transcript, no card details ever touch this client — Stripe's own
/// hosted Checkout and portal pages collect payment information, never this app.
///
/// Internal on purpose, same reasoning as `RewritePipeline`: `BillingCoordinator`
/// is the only place that calls it in production, so UI code never talks to the
/// proxy directly.
final class BillingClient {
    /// A billing reply is a URL or a tiny tier object, a few hundred bytes.
    /// Anything past this is not one, and is rejected before it is decoded.
    static let maxResponseBytes = 64 * 1024

    private let session: URLSession
    private let baseURL: URL
    private let timeout: TimeInterval
    private let tokenProvider: () async -> String?

    /// Production configuration: Keychain token (refreshed if needed, same as
    /// `RewritePipeline`), default proxy URL, ephemeral session.
    convenience init(timeout: TimeInterval = 10) {
        self.init(
            session: RewritePipeline.makeSession(configuration: .ephemeral, timeout: timeout),
            baseURL: RewritePipeline.proxyBaseURL,
            timeout: timeout,
            tokenProvider: { await RewritePipeline.refreshingKeychainToken() }
        )
    }

    /// `tokenProvider` and `session` are injectable so tests never touch the real
    /// Keychain or network.
    init(
        session: URLSession,
        baseURL: URL,
        timeout: TimeInterval = 10,
        tokenProvider: @escaping () async -> String?
    ) {
        self.session = session
        self.baseURL = baseURL
        self.timeout = timeout
        self.tokenProvider = tokenProvider
    }

    /// Never throws: every failure is a `BillingError`.
    func fetchMe() async -> Result<TierInfo, BillingError> {
        switch await send(path: "v1/me", method: "GET") {
        case .failure(let error):
            return .failure(error)
        case .success(let reply):
            guard (200..<300).contains(reply.status) else {
                return .failure(BillingClient.interpret(status: reply.status, route: .me))
            }
            guard reply.body.count <= BillingClient.maxResponseBytes,
                  let decoded = try? JSONDecoder().decode(MeResponseBody.self, from: reply.body),
                  let tier = Tier(rawValue: decoded.tier)
            else { return .failure(.invalidResponse) }
            return .success(TierInfo(tier: tier, remainingThisMonth: decoded.remainingThisMonth))
        }
    }

    /// Reachable by Free users on purpose: it's how they become Pro.
    func startCheckout() async -> Result<URL, BillingError> {
        await requestURL(path: "v1/billing/checkout", route: .checkout)
    }

    /// Pro users only in practice (`.noCustomer` if called before ever checking
    /// out), but the server is the one that enforces that, not this client.
    func startPortal() async -> Result<URL, BillingError> {
        await requestURL(path: "v1/billing/portal", route: .portal)
    }

    private func requestURL(path: String, route: Route) async -> Result<URL, BillingError> {
        switch await send(path: path, method: "POST") {
        case .failure(let error):
            return .failure(error)
        case .success(let reply):
            guard (200..<300).contains(reply.status) else {
                return .failure(BillingClient.interpret(status: reply.status, route: route))
            }
            guard reply.body.count <= BillingClient.maxResponseBytes,
                  let decoded = try? JSONDecoder().decode(URLResponseBody.self, from: reply.body),
                  let url = URL(string: decoded.url),
                  BillingClient.isSafeBillingURL(url, route: route)
            else { return .failure(.invalidResponse) }
            return .success(url)
        }
    }

    // MARK: - transport

    private struct Reply {
        let status: Int
        let body: Data
    }

    private enum Route { case me, checkout, portal }

    /// The one real Stripe host each route's URL must resolve to, off loopback.
    /// `.me` never reaches this (it returns a tier object, not a URL); `nil`
    /// there is just "no host can ever match", not a real case.
    private static func expectedHost(for route: Route) -> String? {
        switch route {
        case .checkout: return "checkout.stripe.com"
        case .portal: return "billing.stripe.com"
        case .me: return nil
        }
    }

    /// A checkout/portal URL is safe to hand to the caller (which opens it in
    /// the default browser with no further indication of where it goes) when:
    ///
    /// - it is on loopback — `scripts/mock-stripe.mjs` serves plain
    ///   `http://127.0.0.1:<port>/...` for local dev, and loopback is by
    ///   definition this machine, so any scheme/host there is fine, same as
    ///   `RewritePipeline.isLoopbackHost`'s own override handling; or
    /// - off loopback, it is `https` **and** on the one real Stripe host that
    ///   route actually resolves to (mirrored in
    ///   `backend/proxy/test/helpers.ts`, which models the real Stripe SDK
    ///   response shape) — https alone is not enough, since a compromised or
    ///   misconfigured proxy could otherwise answer 200 with any `https://`
    ///   URL at all, including a convincing phishing page, or the *other*
    ///   Stripe product's host (a checkout URL landing on the portal host, or
    ///   vice versa, is rejected too, not just an unrelated domain).
    ///
    /// Same loopback-vs-not shape as `hostGuard.ts`'s `isLoopbackHostname` on
    /// the backend: off loopback must be strict, on loopback is local dev and
    /// trusted by definition.
    private static func isSafeBillingURL(_ url: URL, route: Route) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if RewritePipeline.isLoopbackHost(host) { return true }
        return url.scheme?.lowercased() == "https" && host == expectedHost(for: route)
    }

    private func send(path: String, method: String) async -> Result<Reply, BillingError> {
        guard let token = await tokenProvider() else { return .failure(.notAuthenticated) }

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        do {
            // Streamed so an oversized body is abandoned as soon as it passes the
            // cap, instead of being buffered whole before anything looks at it.
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > BillingClient.maxResponseBytes { return .failure(.invalidResponse) }
            }
            return .success(Reply(status: http.statusCode, body: data))
        } catch {
            return .failure(BillingClient.classify(networkError: error))
        }
    }

    static func classify(networkError error: Error) -> BillingError {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .unreachable }
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        default:
            return .unreachable
        }
    }

    /// `route` matters only for the two status codes that mean different things on
    /// different endpoints (404 and 409); every other status maps the same way
    /// everywhere.
    private static func interpret(status: Int, route: Route) -> BillingError {
        switch status {
        case 401: return .unauthorized
        case 404: return route == .portal ? .noCustomer : .unexpectedStatus(status)
        case 409: return route == .checkout ? .alreadyPro : .unexpectedStatus(status)
        case 429: return .rateLimited
        case 502: return .providerFailed
        case 500..<600: return .unavailable
        default: return .unexpectedStatus(status)
        }
    }
}

private struct MeResponseBody: Decodable {
    let tier: String
    let remainingThisMonth: Int
}

private struct URLResponseBody: Decodable {
    let url: String
}
