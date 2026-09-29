import XCTest
@testable import OpenWisprLib

/// Covers `GET /v1/me`, `POST /v1/billing/checkout`, `POST /v1/billing/portal`
/// against the contract in backend/proxy/README.md, using the same
/// `StubURLProtocol` `RewritePipelineTests` uses, so no test touches the network.
final class BillingClientTests: XCTestCase {
    private let baseURL = URL(string: "https://proxy.test")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        StubURLProtocol.requestCount = 0
    }

    private func makeClient(token: String? = "test-token", timeout: TimeInterval = 5) -> BillingClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return BillingClient(
            session: RewritePipeline.makeSession(configuration: config, timeout: timeout),
            baseURL: baseURL,
            timeout: timeout,
            tokenProvider: { token }
        )
    }

    private func meBody(tier: String, remaining: Int) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tier": tier, "remainingThisMonth": remaining])
    }

    private func urlBody(_ urlString: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["url": urlString])
    }

    // MARK: - fetchMe

    func testFetchMeParsesFreeTier() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.meBody(tier: "free", remaining: 3000)) }
        let client = makeClient()
        let result = fetch(client)
        XCTAssertEqual(result, .success(TierInfo(tier: .free, remainingThisMonth: 3000)))
    }

    func testFetchMeParsesProTier() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.meBody(tier: "pro", remaining: 2999)) }
        let result = fetch(makeClient())
        XCTAssertEqual(result, .success(TierInfo(tier: .pro, remainingThisMonth: 2999)))
    }

    func testFetchMeSendsBearerTokenAndGET() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.meBody(tier: "free", remaining: 10)) }
        _ = fetch(makeClient(token: "abc123"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer abc123")
        XCTAssertTrue(StubURLProtocol.lastRequest?.url?.path.hasSuffix("v1/me") ?? false)
    }

    func testFetchMeNoTokenIsNotAuthenticatedWithoutARequest() {
        let result = fetch(makeClient(token: nil))
        XCTAssertEqual(result, .failure(.notAuthenticated))
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testFetchMeUnauthorized() {
        StubURLProtocol.handler = { _ in .init(status: 401, body: Data()) }
        XCTAssertEqual(fetch(makeClient()), .failure(.unauthorized))
    }

    func testFetchMeRateLimited() {
        StubURLProtocol.handler = { _ in .init(status: 429, body: Data()) }
        XCTAssertEqual(fetch(makeClient()), .failure(.rateLimited))
    }

    func testFetchMeServiceUnavailable() {
        for status in [500, 503] {
            StubURLProtocol.handler = { _ in .init(status: status, body: Data()) }
            XCTAssertEqual(fetch(makeClient()), .failure(.unavailable), "status \(status)")
        }
    }

    func testFetchMeInvalidJSONIsInvalidResponse() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data("not json".utf8)) }
        XCTAssertEqual(fetch(makeClient()), .failure(.invalidResponse))
    }

    func testFetchMeUnknownTierStringIsInvalidResponse() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.meBody(tier: "enterprise", remaining: 1)) }
        XCTAssertEqual(fetch(makeClient()), .failure(.invalidResponse))
    }

    func testFetchMeOffline() {
        StubURLProtocol.handler = { _ in .init(error: URLError(.notConnectedToInternet)) }
        XCTAssertEqual(fetch(makeClient()), .failure(.offline))
    }

    // MARK: - checkout

    func testCheckoutReturnsURL() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.urlBody("https://checkout.stripe.com/c/pay/cs_123")) }
        let result = checkout(makeClient())
        XCTAssertEqual(result, .success(URL(string: "https://checkout.stripe.com/c/pay/cs_123")!))
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertTrue(StubURLProtocol.lastRequest?.url?.path.hasSuffix("v1/billing/checkout") ?? false)
    }

    func testCheckoutAlreadyPro() {
        StubURLProtocol.handler = { _ in .init(status: 409, body: Data()) }
        XCTAssertEqual(checkout(makeClient()), .failure(.alreadyPro))
    }

    func testCheckoutProviderFailed() {
        StubURLProtocol.handler = { _ in .init(status: 502, body: Data()) }
        XCTAssertEqual(checkout(makeClient()), .failure(.providerFailed))
    }

    /// A non-https URL must never be handed to the caller to open: a compromised
    /// or misconfigured proxy answering 200 must not be able to make this app
    /// open an arbitrary custom-scheme or `file://` URL.
    func testCheckoutRejectsNonHTTPSURL() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.urlBody("file:///etc/passwd")) }
        XCTAssertEqual(checkout(makeClient()), .failure(.invalidResponse))
    }

    func testCheckoutRejectsCustomSchemeURL() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.urlBody("myapp://do-something-else")) }
        XCTAssertEqual(checkout(makeClient()), .failure(.invalidResponse))
    }

    /// The scheme check alone would let a compromised or misconfigured proxy
    /// send this app to any `https://` URL — including a convincing page made
    /// up to look like Stripe. Only Stripe's own hosted-checkout host is safe
    /// to open with no indication to the user that it isn't really Stripe.
    func testCheckoutRejectsNonStripeHTTPSURL() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.urlBody("https://stripe-checkout.example.com/cs_123")) }
        XCTAssertEqual(checkout(makeClient()), .failure(.invalidResponse))
    }

    /// Host confusion between the two Stripe products: a checkout response
    /// pointing at the *portal's* real host is still not the checkout host, so
    /// it must be rejected too, not waved through because it's "still Stripe".
    func testCheckoutRejectsBillingPortalHost() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.urlBody("https://billing.stripe.com/p_123")) }
        XCTAssertEqual(checkout(makeClient()), .failure(.invalidResponse))
    }

    /// Off loopback, https is required even on a would-be-legitimate host: a
    /// real Stripe hostname served over plain http is still not safe (no TLS,
    /// so nothing guarantees it actually came from Stripe) and must be
    /// rejected exactly like any other non-https URL.
    func testCheckoutRejectsPlainHTTPOnRealStripeHost() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.urlBody("http://checkout.stripe.com/cs_123")) }
        XCTAssertEqual(checkout(makeClient()), .failure(.invalidResponse))
    }

    /// `scripts/mock-stripe.mjs` (local dev, and `BillingCoordinator` run
    /// against the real `BillingClient`) serves plain `http://127.0.0.1:<port>`
    /// checkout/portal URLs — those must still work, not just the unit tests'
    /// stubbed fixtures. Loopback is trusted by definition, same reasoning as
    /// `RewritePipeline.isLoopbackHost`'s own http-on-loopback override.
    func testCheckoutAcceptsLoopbackHTTPURL() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.urlBody("http://127.0.0.1:54323/checkout/cs_123")) }
        XCTAssertEqual(checkout(makeClient()), .success(URL(string: "http://127.0.0.1:54323/checkout/cs_123")!))
    }

    func testCheckoutAcceptsLoopbackLocalhostURL() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.urlBody("http://localhost:54323/checkout/cs_123")) }
        XCTAssertEqual(checkout(makeClient()), .success(URL(string: "http://localhost:54323/checkout/cs_123")!))
    }

    // MARK: - portal

    func testPortalReturnsURL() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.urlBody("https://billing.stripe.com/session/p_123")) }
        let result = portal(makeClient())
        XCTAssertEqual(result, .success(URL(string: "https://billing.stripe.com/session/p_123")!))
        XCTAssertTrue(StubURLProtocol.lastRequest?.url?.path.hasSuffix("v1/billing/portal") ?? false)
    }

    /// Same phishing scenario as checkout, on the portal route.
    func testPortalRejectsNonStripeHTTPSURL() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.urlBody("https://stripe-billing.example.com/p_123")) }
        XCTAssertEqual(portal(makeClient()), .failure(.invalidResponse))
    }

    /// Same host-confusion check, the other direction: a portal response
    /// pointing at the checkout host is rejected too.
    func testPortalRejectsCheckoutHost() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.urlBody("https://checkout.stripe.com/cs_123")) }
        XCTAssertEqual(portal(makeClient()), .failure(.invalidResponse))
    }

    /// Same mock-stripe loopback case as checkout, on the portal route.
    func testPortalAcceptsLoopbackHTTPURL() {
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.urlBody("http://127.0.0.1:54323/portal/p_123")) }
        XCTAssertEqual(portal(makeClient()), .success(URL(string: "http://127.0.0.1:54323/portal/p_123")!))
    }

    func testPortalNoCustomer() {
        StubURLProtocol.handler = { _ in .init(status: 404, body: Data()) }
        XCTAssertEqual(portal(makeClient()), .failure(.noCustomer))
    }

    /// 404 means something different on each route: `.me`/`.checkout` have no
    /// defined 404, so it must not be silently reinterpreted as `.noCustomer`.
    func testCheckout404IsNotMisreadAsNoCustomer() {
        StubURLProtocol.handler = { _ in .init(status: 404, body: Data()) }
        XCTAssertEqual(checkout(makeClient()), .failure(.unexpectedStatus(404)))
    }

    /// 409 similarly means "already Pro" only on checkout.
    func testPortal409IsNotMisreadAsAlreadyPro() {
        StubURLProtocol.handler = { _ in .init(status: 409, body: Data()) }
        XCTAssertEqual(portal(makeClient()), .failure(.unexpectedStatus(409)))
    }

    // MARK: - helpers

    private func fetch(_ client: BillingClient) -> Result<TierInfo, BillingError> {
        let done = expectation(description: "fetchMe completes")
        var result: Result<TierInfo, BillingError>?
        Task { result = await client.fetchMe(); done.fulfill() }
        wait(for: [done], timeout: 5)
        return result ?? .failure(.invalidResponse)
    }

    private func checkout(_ client: BillingClient) -> Result<URL, BillingError> {
        let done = expectation(description: "startCheckout completes")
        var result: Result<URL, BillingError>?
        Task { result = await client.startCheckout(); done.fulfill() }
        wait(for: [done], timeout: 5)
        return result ?? .failure(.invalidResponse)
    }

    private func portal(_ client: BillingClient) -> Result<URL, BillingError> {
        let done = expectation(description: "startPortal completes")
        var result: Result<URL, BillingError>?
        Task { result = await client.startPortal(); done.fulfill() }
        wait(for: [done], timeout: 5)
        return result ?? .failure(.invalidResponse)
    }
}
