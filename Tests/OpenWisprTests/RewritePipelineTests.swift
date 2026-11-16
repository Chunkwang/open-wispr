import XCTest
@testable import OpenWisprLib

/// URLProtocol stub: the pipeline runs against a real URLSession, but every
/// request is answered (or failed) by `handler`, so no test touches the network.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var body: Data = Data()
        /// Response headers, e.g. `Retry-After`.
        var headers: [String: String] = [:]
        var error: Error?
        /// Never answers, to exercise the total-deadline and cancellation paths.
        var stall = false
        /// Answers 200 at once, then keeps dribbling bytes for `trickleSeconds`.
        /// Idle-time timeouts never fire because data keeps arriving; only a total
        /// (resource) deadline can end this.
        var trickleSeconds: TimeInterval = 0
    }

    /// Set per test. Tests in a class run serially, so a static is safe.
    static var handler: ((URLRequest) -> Reply)?
    static var lastRequest: URLRequest?
    static var lastBody: Data?
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.requestCount += 1
        StubURLProtocol.lastRequest = request
        StubURLProtocol.lastBody = StubURLProtocol.readBody(of: request)

        let reply = StubURLProtocol.handler?(request) ?? Reply(status: 500)
        if reply.stall { return }
        if reply.trickleSeconds > 0 {
            let head = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: head, cacheStoragePolicy: .notAllowed)
            trickle(until: Date().addingTimeInterval(reply.trickleSeconds))
            return
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private var stopped = false

    override func stopLoading() { stopped = true }

    private func trickle(until end: Date) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, !self.stopped else { return }
            if Date() >= end {
                self.client?.urlProtocolDidFinishLoading(self)
            } else {
                self.client?.urlProtocol(self, didLoad: Data(" ".utf8))
                self.trickle(until: end)
            }
        }
    }

    /// URLSession hands the body to a URLProtocol as a stream, not httpBody.
    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class RewritePipelineTests: XCTestCase {
    private let baseURL = URL(string: "https://proxy.test")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        StubURLProtocol.requestCount = 0
    }

    private func makePipeline(token: String? = "test-token", timeout: TimeInterval = 5) -> RewritePipeline {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return RewritePipeline(
            session: RewritePipeline.makeSession(configuration: config, timeout: timeout),
            baseURL: baseURL,
            timeout: timeout,
            tokenProvider: { token }
        )
    }

    /// Bridges the async API into a synchronous test.
    private func rewrite(_ pipeline: RewritePipeline, _ text: String = "um so like send it tomorrow") -> Result<String, RewriteError> {
        let done = expectation(description: "rewrite completes")
        var result: Result<String, RewriteError>?
        Task {
            result = await pipeline.rewrite(transcript: text)
            done.fulfill()
        }
        wait(for: [done], timeout: 8)
        return result ?? .failure(.invalidResponse)
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func assertFails(_ result: Result<String, RewriteError>, with expected: RewriteError, file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success(let text):
            XCTFail("expected \(expected), got success: \(text)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    // MARK: - success

    func testSuccessReturnsRewrittenText() {
        StubURLProtocol.handler = { _ in .init(body: self.json(["rewritten": "Send it tomorrow."])) }
        XCTAssertEqual(try rewrite(makePipeline()).get(), "Send it tomorrow.")
    }

    func testRequestShapeCarriesTokenAndOnlyTheTranscript() throws {
        StubURLProtocol.handler = { _ in .init(body: self.json(["rewritten": "ok"])) }
        _ = rewrite(makePipeline(token: "abc123"), "hello there")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://proxy.test/v1/rewrite")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        // Trust property (PRD): text only, nothing else, ever leaves the device.
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["transcript"])
        XCTAssertEqual(object["transcript"] as? String, "hello there")
    }

    // MARK: - no token

    func testNoTokenFailsWithoutSendingAnything() {
        StubURLProtocol.handler = { _ in .init(body: self.json(["rewritten": "should not happen"])) }
        assertFails(rewrite(makePipeline(token: nil)), with: .notAuthenticated)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    // MARK: - HTTP status mapping

    func testStatus401IsUnauthorized() {
        StubURLProtocol.handler = { _ in .init(status: 401) }
        assertFails(rewrite(makePipeline()), with: .unauthorized)
    }

    func testStatus402RequiresPro() {
        StubURLProtocol.handler = { _ in .init(status: 402) }
        assertFails(rewrite(makePipeline()), with: .requiresPro)
    }

    func testStatus413IsTooLong() {
        StubURLProtocol.handler = { _ in .init(status: 413) }
        assertFails(rewrite(makePipeline()), with: .tooLong)
    }

    func testStatus429IsRateLimited() {
        StubURLProtocol.handler = { _ in .init(status: 429) }
        assertFails(rewrite(makePipeline()), with: .rateLimited)
    }

    func testStatus500And502AreUnavailable() {
        for status in [500, 502, 503] {
            StubURLProtocol.handler = { _ in .init(status: status) }
            assertFails(rewrite(makePipeline()), with: .unavailable)
        }
    }

    func testOtherStatusKeepsTheCode() {
        StubURLProtocol.handler = { _ in .init(status: 400) }
        assertFails(rewrite(makePipeline()), with: .unexpectedStatus(400))
    }

    func testAny2xxWithAValidBodyIsSuccess() {
        for status in [200, 201, 203] {
            StubURLProtocol.handler = { _ in .init(status: status, body: self.json(["rewritten": "ok"])) }
            XCTAssertEqual(try rewrite(makePipeline()).get(), "ok", "status \(status)")
        }
    }

    func test204WithNoBodyIsInvalidResponse() {
        StubURLProtocol.handler = { _ in .init(status: 204) }
        assertFails(rewrite(makePipeline()), with: .invalidResponse)
    }

    // MARK: - network errors

    func testTimeoutIsTimedOut() {
        StubURLProtocol.handler = { _ in .init(error: URLError(.timedOut)) }
        assertFails(rewrite(makePipeline()), with: .timedOut)
    }

    func testNoInternetIsOffline() {
        StubURLProtocol.handler = { _ in .init(error: URLError(.notConnectedToInternet)) }
        assertFails(rewrite(makePipeline()), with: .offline)
    }

    func testOtherNetworkErrorIsUnreachable() {
        StubURLProtocol.handler = { _ in .init(error: URLError(.cannotConnectToHost)) }
        assertFails(rewrite(makePipeline()), with: .unreachable)
    }

    func testURLErrorCancelledIsCancelledNotUnreachable() {
        StubURLProtocol.handler = { _ in .init(error: URLError(.cancelled)) }
        assertFails(rewrite(makePipeline()), with: .cancelled)
    }

    func testSwiftCancellationErrorIsCancelled() {
        XCTAssertEqual(RewritePipeline.classify(networkError: CancellationError()), .cancelled)
    }

    // MARK: - deadline and cancellation

    /// The pipeline owns the deadline: a service that never answers must
    /// produce exactly one .timedOut soon after `timeout`, not hang.
    func testStalledServiceHitsTheTotalDeadline() {
        StubURLProtocol.handler = { _ in .init(stall: true) }
        let started = Date()
        assertFails(rewrite(makePipeline(timeout: 0.4)), with: .timedOut)
        XCTAssertTrue(Date().timeIntervalSince(started) < 4, "deadline took too long")
    }

    /// Proves the deadline is total, not idle time: bytes keep arriving, so only
    /// the resource timeout can stop this.
    func testSlowTrickleStillHitsTheTotalDeadline() {
        StubURLProtocol.handler = { _ in .init(trickleSeconds: 5) }
        let started = Date()
        assertFails(rewrite(makePipeline(timeout: 0.5)), with: .timedOut)
        XCTAssertTrue(Date().timeIntervalSince(started) < 3, "deadline did not cap a slow response")
    }

    func testCancellingTheCallingTaskReturnsCancelled() {
        StubURLProtocol.handler = { _ in .init(stall: true) }
        let pipeline = makePipeline(timeout: 5)
        let done = expectation(description: "cancelled call returns")
        var result: Result<String, RewriteError>?
        let task = Task {
            result = await pipeline.rewrite(transcript: "x")
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)  // let the request start
        task.cancel()
        wait(for: [done], timeout: 4)
        assertFails(result ?? .failure(.invalidResponse), with: .cancelled)
    }

    func testNonURLErrorIsUnreachable() {
        struct Odd: Error {}
        XCTAssertEqual(RewritePipeline.classify(networkError: Odd()), .unreachable)
    }

    // MARK: - malformed success responses

    func testBodyOver256KBIsInvalidResponseBeforeDecoding() {
        let padding = String(repeating: "a", count: 300 * 1024)
        StubURLProtocol.handler = { _ in .init(body: self.json(["rewritten": padding])) }
        assertFails(rewrite(makePipeline()), with: .invalidResponse)
    }

    func testBodyJustUnderTheCapStillDecodes() {
        let text = String(repeating: "a", count: 200 * 1024)
        StubURLProtocol.handler = { _ in .init(body: self.json(["rewritten": text])) }
        XCTAssertEqual(try rewrite(makePipeline()).get(), text)
    }

    func testInterpretRejectsAnOversizedBodyWithoutDecodingIt() {
        let big = Data(repeating: 0x20, count: RewritePipeline.maxResponseBytes + 1)
        XCTAssertEqual(RewritePipeline.maxResponseBytes, 256 * 1024)
        switch RewritePipeline.interpret(status: 200, body: big) {
        case .success: XCTFail("expected invalidResponse")
        case .failure(let error): XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testMalformedJSONIsInvalidResponse() {
        StubURLProtocol.handler = { _ in .init(body: Data("not json".utf8)) }
        assertFails(rewrite(makePipeline()), with: .invalidResponse)
    }

    func testMissingFieldIsInvalidResponse() {
        StubURLProtocol.handler = { _ in .init(body: self.json(["something": "else"])) }
        assertFails(rewrite(makePipeline()), with: .invalidResponse)
    }

    func testEmptyBodyIsInvalidResponse() {
        StubURLProtocol.handler = { _ in .init(body: Data()) }
        assertFails(rewrite(makePipeline()), with: .invalidResponse)
    }

    /// The caller inserts whatever comes back; empty text would erase the user's dictation.
    func testEmptyOrBlankRewrittenTextIsInvalidResponse() {
        for blank in ["", "   ", "\n\t"] {
            StubURLProtocol.handler = { _ in .init(body: self.json(["rewritten": blank])) }
            assertFails(rewrite(makePipeline()), with: .invalidResponse)
        }
    }

    func testErrorBodyOnSuccessStatusIsInvalidResponse() {
        StubURLProtocol.handler = { _ in .init(body: self.json(["error": "rewrite failed"])) }
        assertFails(rewrite(makePipeline()), with: .invalidResponse)
    }

    // MARK: - redirects and session hardening

    func testRedirectResponseIsNotFollowedAndIsReportedAsUnexpectedStatus() {
        StubURLProtocol.handler = { _ in .init(status: 302) }
        assertFails(rewrite(makePipeline()), with: .unexpectedStatus(302))
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testRedirectDelegateRefusesToFollow() {
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://proxy.test")!)
        let response = HTTPURLResponse(url: baseURL, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var followed: URLRequest? = URLRequest(url: URL(string: "https://evil.test")!)
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://evil.test")!)) { followed = $0 }
        XCTAssertNil(followed)
    }

    /// The 302 test above passes even without the delegate (the stub returns the
    /// 302 as a plain response), so this pins the wiring itself.
    func testSessionsAreBuiltWithTheNoRedirectDelegate() {
        let session = RewritePipeline.makeSession(configuration: .ephemeral)
        XCTAssertTrue(session.delegate is NoRedirectDelegate)
    }

    func testProductionSessionKeepsNoCookiesOrCache() {
        let session = RewritePipeline.makeSession(configuration: .ephemeral)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
    }

    // MARK: - proxy URL override

    func testOverrideIsIgnoredWhenNotAllowed() {
        let url = RewritePipeline.resolveBaseURL(override: "https://evil.test", allowOverride: false)
        XCTAssertEqual(url, RewritePipeline.defaultProxyURL)
    }

    func testAllowedOverrideAcceptsHTTPSAndLoopbackHTTPOnly() {
        XCTAssertEqual(
            RewritePipeline.resolveBaseURL(override: "https://staging.example.com", allowOverride: true).absoluteString,
            "https://staging.example.com")
        XCTAssertEqual(
            RewritePipeline.resolveBaseURL(override: "http://127.0.0.1:8787", allowOverride: true).absoluteString,
            "http://127.0.0.1:8787")
        XCTAssertEqual(
            RewritePipeline.resolveBaseURL(override: "http://localhost:8787", allowOverride: true).absoluteString,
            "http://localhost:8787")
    }

    func testAllowedOverrideRejectsPlainHTTPToARemoteHostAndOtherSchemes() {
        for bad in ["http://evil.test", "ftp://evil.test", "file:///etc/passwd", "not a url", ""] {
            XCTAssertEqual(
                RewritePipeline.resolveBaseURL(override: bad, allowOverride: true),
                RewritePipeline.defaultProxyURL, bad)
        }
    }

    func testNoOverrideUsesTheDefault() {
        XCTAssertEqual(RewritePipeline.resolveBaseURL(override: nil, allowOverride: true), RewritePipeline.defaultProxyURL)
    }

    // MARK: - descriptions

    func testEveryErrorHasADescription() {
        let all: [RewriteError] = [
            .notAuthenticated, .unauthorized, .requiresPro, .rateLimited, .tooLong, .offline,
            .timedOut, .cancelled, .unreachable, .unavailable, .unexpectedStatus(418), .invalidResponse,
        ]
        for error in all {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }
}
