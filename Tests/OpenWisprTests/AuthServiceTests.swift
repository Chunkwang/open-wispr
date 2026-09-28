import XCTest
@testable import OpenWisprLib

/// AuthService against URLProtocol stubs that answer with exactly the JSON in
/// docs/auth-design.md section 2 (the mock Supabase contract).
final class AuthServiceTests: XCTestCase {
    private let baseURL = URL(string: "https://auth.test")!
    private let anonKey = "sb_publishable_test_key"
    private let email = "person@example.com"
    private let code = "482913"

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        StubURLProtocol.requestCount = 0
    }

    private func makeService(
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) },
        logoutCap: TimeInterval = 3
    ) -> AuthService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AuthService(
            session: RewritePipeline.makeSession(configuration: config, timeout: 5),
            baseURL: baseURL, anonKey: anonKey, now: now, logoutCap: logoutCap
        )
    }

    // MARK: - fixtures (section 2 shapes)

    private func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func gotrueError(_ status: Int, _ errorCode: String, headers: [String: String] = [:]) -> StubURLProtocol.Reply {
        .init(status: status, body: data(["code": status, "error_code": errorCode, "msg": "text that must never be matched"]), headers: headers)
    }

    private func sessionReply(expiresAt: Any? = 1_790_003_600, expiresIn: Any? = 3600, userEmail: String? = "person@example.com") -> StubURLProtocol.Reply {
        var object: [String: Any] = [
            "access_token": "header.payload.signature",
            "token_type": "bearer",
            "refresh_token": "abcdefghijkl",
            "user": ["id": "0b0e1f5e-1111-4222-8333-444455556666", "aud": "authenticated", "role": "authenticated"]
                .merging(userEmail.map { ["email": $0] } ?? [:]) { a, _ in a },
        ]
        if let expiresAt = expiresAt { object["expires_at"] = expiresAt }
        if let expiresIn = expiresIn { object["expires_in"] = expiresIn }
        return .init(body: data(object))
    }

    private func requestCode(_ email: String? = nil) async -> Result<Void, AuthError> {
        await makeService().requestCode(email: email ?? self.email)
    }

    private func verify(_ code: String? = nil) async -> Result<AuthSession, AuthError> {
        await makeService().verifyCode(email: email, code: code ?? self.code)
    }

    private func assertFails<T>(_ result: Result<T, AuthError>, _ expected: AuthError, file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success: XCTFail("expected \(expected), got success", file: file, line: line)
        case .failure(let error): XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    private func bodyObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(StubURLProtocol.lastBody)) as? [String: Any])
    }

    // MARK: - requestCode: request shape

    func testRequestCodeShape() async throws {
        StubURLProtocol.handler = { _ in .init(body: Data("{}".utf8)) }
        _ = try await requestCode().get()

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/auth/v1/otp")
        XCTAssertEqual(request.url?.host, "auth.test")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), anonKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try bodyObject()
        XCTAssertEqual(Set(body.keys), ["email", "create_user"])
        XCTAssertEqual(body["email"] as? String, email)
        XCTAssertEqual(body["create_user"] as? Bool, true)
    }

    func testTheEmailIsNeverInTheURL() async throws {
        StubURLProtocol.handler = { _ in .init(body: Data("{}".utf8)) }
        _ = await requestCode("a+b@example.com")
        let url = try XCTUnwrap(StubURLProtocol.lastRequest?.url).absoluteString.removingPercentEncoding ?? ""
        XCTAssertFalse(url.contains("a+b"))
        XCTAssertFalse(url.contains("example.com"))
        XCTAssertFalse(url.contains("@"))
    }

    func testTheEmailIsTrimmedBeforeSending() async throws {
        StubURLProtocol.handler = { _ in .init(body: Data("{}".utf8)) }
        _ = await requestCode("  person@example.com \n")
        XCTAssertEqual(try bodyObject()["email"] as? String, "person@example.com")
    }

    func testABlankEmailSendsNothing() async {
        StubURLProtocol.handler = { _ in .init(body: Data("{}".utf8)) }
        assertFails(await requestCode("   "), .invalidEmail)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    // MARK: - requestCode: outcomes

    func testRequestCodeSuccess() async throws {
        StubURLProtocol.handler = { _ in .init(body: Data("{}".utf8)) }
        if case .failure(let error) = await requestCode() { XCTFail("\(error)") }
    }

    func testRequestCodeSuccessNeedsNoParseableBody() async {
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data()) }
        if case .failure(let error) = await requestCode() { XCTFail("\(error)") }
    }

    func testInvalidEmailIs400ValidationFailed() async {
        StubURLProtocol.handler = { _ in self.gotrueError(400, "validation_failed") }
        assertFails(await requestCode(), .invalidEmail)
    }

    func testInvalidEmailIs422ValidationFailedAndEmailAddressInvalid() async {
        StubURLProtocol.handler = { _ in self.gotrueError(422, "validation_failed") }
        assertFails(await requestCode(), .invalidEmail)
        StubURLProtocol.handler = { _ in self.gotrueError(400, "email_address_invalid") }
        assertFails(await requestCode(), .invalidEmail)
    }

    func testSendRateLimitedReadsRetryAfter() async {
        StubURLProtocol.handler = { _ in self.gotrueError(429, "over_email_send_rate_limit", headers: ["Retry-After": "42"]) }
        assertFails(await requestCode(), .sendRateLimited(retryAfter: 42))
    }

    func testSendRateLimitedWithoutRetryAfterDefaultsToSixtySeconds() async {
        StubURLProtocol.handler = { _ in self.gotrueError(429, "over_email_send_rate_limit") }
        assertFails(await requestCode(), .sendRateLimited(retryAfter: 60))
    }

    func testRequestCodeWithARequestRateLimitCodeIsTooManyAttempts() async {
        StubURLProtocol.handler = { _ in self.gotrueError(429, "over_request_rate_limit") }
        assertFails(await requestCode(), .tooManyAttempts(retryAfter: 60))
    }

    func testAn429WithNoKnownCodeFollowsTheRoute() async {
        StubURLProtocol.handler = { _ in .init(status: 429, body: Data("{}".utf8), headers: ["Retry-After": "7"]) }
        assertFails(await requestCode(), .sendRateLimited(retryAfter: 7))
        assertFails(await verify(), .tooManyAttempts(retryAfter: 7))
    }

    // MARK: - verifyCode: request shape

    func testVerifyShape() async throws {
        StubURLProtocol.handler = { _ in self.sessionReply() }
        _ = try await verify().get()

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/auth/v1/verify")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), anonKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try bodyObject()
        XCTAssertEqual(Set(body.keys), ["type", "email", "token"])
        XCTAssertEqual(body["type"] as? String, "email")
        XCTAssertEqual(body["email"] as? String, email)
        XCTAssertEqual(body["token"] as? String, code)
    }

    func testNeitherTheEmailNorTheCodeIsEverInAnyURL() async throws {
        var urls: [String] = []
        StubURLProtocol.handler = { request in
            urls.append(request.url!.absoluteString)
            return self.sessionReply()
        }
        let service = makeService()
        _ = await service.requestCode(email: email)
        let session = try await service.verifyCode(email: email, code: code).get()
        await service.signOut(session)
        XCTAssertEqual(urls.count, 3)
        for url in urls {
            XCTAssertFalse(url.contains(code), url)
            XCTAssertFalse(url.contains("example.com"), url)
            XCTAssertFalse(url.contains("person"), url)
            XCTAssertFalse(url.contains("header.payload.signature"), "the token is a header, not a URL part")
        }
    }

    func testBlankCodeSendsNothing() async {
        StubURLProtocol.handler = { _ in self.sessionReply() }
        assertFails(await verify(""), .codeRejected)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    // MARK: - verifyCode: success

    func testVerifySuccessBuildsTheSession() async throws {
        StubURLProtocol.handler = { _ in self.sessionReply() }
        let session = try await verify().get()
        XCTAssertEqual(session.accessToken, "header.payload.signature")
        XCTAssertEqual(session.refreshToken, "abcdefghijkl")
        XCTAssertEqual(session.expiresAt, Date(timeIntervalSince1970: 1_790_003_600))
        XCTAssertEqual(session.email, "person@example.com")
    }

    func testExpiresAtWinsOverExpiresIn() async throws {
        StubURLProtocol.handler = { _ in self.sessionReply(expiresAt: 1_790_000_100, expiresIn: 3600) }
        let got = try await verify().get()
        XCTAssertEqual(got.expiresAt, Date(timeIntervalSince1970: 1_790_000_100))
    }

    func testExpiresInIsUsedWithTheInjectedClockWhenExpiresAtIsMissing() async throws {
        StubURLProtocol.handler = { _ in self.sessionReply(expiresAt: nil, expiresIn: 3600) }
        let got = try await verify().get()
        XCTAssertEqual(got.expiresAt, Date(timeIntervalSince1970: 1_790_003_600))
    }

    func testTheRequestedEmailIsUsedWhenTheReplyHasNone() async throws {
        StubURLProtocol.handler = { _ in self.sessionReply(userEmail: nil) }
        let got = try await verify().get()
        XCTAssertEqual(got.email, email)
    }

    // MARK: - verifyCode: failures

    func testWrongOrExpiredCodeIs403OtpExpired() async {
        StubURLProtocol.handler = { _ in self.gotrueError(403, "otp_expired") }
        assertFails(await verify(), .codeRejected)
    }

    func testWrongCodeIsNeverReportedAsARateLimit() async {
        StubURLProtocol.handler = { _ in self.gotrueError(403, "otp_expired") }
        let result = await verify()
        if case .failure(.sendRateLimited) = result { XCTFail("wrong code must not look like a send limit") }
        if case .failure(.tooManyAttempts) = result { XCTFail("a single wrong code is not a lockout") }
    }

    func testMalformedCodeIs400And422ValidationFailed() async {
        for status in [400, 422] {
            StubURLProtocol.handler = { _ in self.gotrueError(status, "validation_failed") }
            assertFails(await verify(), .codeRejected)
        }
    }

    func testTooManyAttemptsIs429OverRequestRateLimit() async {
        StubURLProtocol.handler = { _ in self.gotrueError(429, "over_request_rate_limit") }
        assertFails(await verify(), .tooManyAttempts(retryAfter: 60))
        StubURLProtocol.handler = { _ in self.gotrueError(429, "over_request_rate_limit", headers: ["Retry-After": "30"]) }
        assertFails(await verify(), .tooManyAttempts(retryAfter: 30))
    }

    func testAVerifyWithTheSendLimitCodeIsStillASendLimit() async {
        StubURLProtocol.handler = { _ in self.gotrueError(429, "over_email_send_rate_limit", headers: ["Retry-After": "12"]) }
        assertFails(await verify(), .sendRateLimited(retryAfter: 12))
    }

    func test5xxIsUnavailableOnEveryRoute() async {
        for status in [500, 502, 503, 504] {
            StubURLProtocol.handler = { _ in .init(status: status, body: Data("<html>bad gateway</html>".utf8)) }
            assertFails(await requestCode(), .unavailable)
            assertFails(await verify(), .unavailable)
        }
    }

    func testA5xxWithAnyBodyIsStillUnavailable() async {
        StubURLProtocol.handler = { _ in self.gotrueError(503, "validation_failed") }
        assertFails(await requestCode(), .unavailable)
    }

    func testTheMissingAPIKeyAnswerIsAnUnusableResponse() async {
        StubURLProtocol.handler = { _ in .init(status: 401, body: self.data(["message": "No API key found in request"])) }
        assertFails(await requestCode(), .invalidResponse)
        assertFails(await verify(), .invalidResponse)
    }

    func testARedirectIsNotFollowedAndIsUnusable() async {
        StubURLProtocol.handler = { _ in .init(status: 302, body: Data(), headers: ["Location": "https://evil.test/"]) }
        assertFails(await requestCode(), .invalidResponse)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    // MARK: - classification never matches message text

    func testOtherShapesAreTolerated() async {
        // OAuth-style: the code is in `error`.
        StubURLProtocol.handler = { _ in .init(status: 400, body: self.data(["error": "validation_failed", "error_description": "anything"])) }
        assertFails(await requestCode(), .invalidEmail)
        // Only free text: nothing to classify on.
        StubURLProtocol.handler = { _ in .init(status: 400, body: self.data(["message": "Unable to validate email address: invalid format"])) }
        assertFails(await requestCode(), .invalidResponse)
        StubURLProtocol.handler = { _ in .init(status: 403, body: self.data(["error_description": "Token has expired or is invalid"])) }
        assertFails(await verify(), .invalidResponse)
        // Non-JSON, arrays, wrong types.
        for junk in ["", "not json", "[]", #"{"error_code": 5}"#, #"{"error": {"nested": true}}"#] {
            StubURLProtocol.handler = { _ in .init(status: 400, body: Data(junk.utf8)) }
            assertFails(await requestCode(), .invalidResponse)
        }
    }

    func testMessageTextNeverDecidesTheOutcome() async {
        // The text talks about rate limits; the code says validation.
        StubURLProtocol.handler = { _ in
            .init(status: 400, body: self.data(["error_code": "validation_failed", "msg": "over_email_send_rate_limit otp_expired"]))
        }
        assertFails(await requestCode(), .invalidEmail)
        assertFails(await verify(), .codeRejected)
    }

    func testAnUnknownLimiterFollowsTheRouteNotTheMessageText() async {
        StubURLProtocol.handler = { _ in .init(status: 429, body: self.data(["msg": "email rate limit exceeded"])) }
        assertFails(await verify(), .tooManyAttempts(retryAfter: 60))
        StubURLProtocol.handler = { _ in .init(status: 400, body: self.data(["msg": "email rate limit exceeded"])) }
        assertFails(await verify(), .invalidResponse)
    }

    func testErrorCodeWinsOverError() {
        let body = data(["error_code": "otp_expired", "error": "validation_failed"])
        XCTAssertEqual(AuthService.errorCode(in: body), "otp_expired")
    }

    // MARK: - Retry-After parsing

    func testRetryAfterParsing() {
        XCTAssertEqual(AuthService.retryAfter(from: "45"), 45)
        XCTAssertEqual(AuthService.retryAfter(from: " 45 "), 45)
        XCTAssertEqual(AuthService.retryAfter(from: "1"), 1)
        XCTAssertEqual(AuthService.retryAfter(from: "99999"), 3600)
        for unusable in [nil, "", "0", "-5", "abc", "1.5", "Wed, 21 Oct 2026 07:28:00 GMT"] {
            XCTAssertNil(AuthService.retryAfter(from: unusable), unusable ?? "nil")
        }
    }

    func testAnUnusableRetryAfterHeaderFallsBackToSixty() async {
        for header in ["0", "-1", "soon", "Wed, 21 Oct 2026 07:28:00 GMT"] {
            StubURLProtocol.handler = { _ in self.gotrueError(429, "over_email_send_rate_limit", headers: ["Retry-After": header]) }
            assertFails(await requestCode(), .sendRateLimited(retryAfter: 60))
        }
    }

    func testRetryAfterHeaderNameIsCaseInsensitive() async {
        StubURLProtocol.handler = { _ in self.gotrueError(429, "over_email_send_rate_limit", headers: ["retry-after": "9"]) }
        assertFails(await requestCode(), .sendRateLimited(retryAfter: 9))
    }

    // MARK: - unusable success bodies

    func testA2xxWithoutAUsableSessionIsInvalidResponse() async {
        let bodies: [Data] = [
            Data(),
            Data("not json".utf8),
            Data("{}".utf8),
            Data("[]".utf8),
            data(["access_token": "", "refresh_token": "r", "expires_at": 1_790_003_600]),
            data(["access_token": "a", "refresh_token": "", "expires_at": 1_790_003_600]),
            data(["access_token": "a", "expires_at": 1_790_003_600]),
            data(["access_token": "a", "refresh_token": "r"]),
            data(["access_token": "a", "refresh_token": "r", "expires_at": 0, "expires_in": 0]),
            data(["access_token": 5, "refresh_token": "r", "expires_at": 1_790_003_600]),
            data(["error_code": "otp_expired"]),
        ]
        for body in bodies {
            StubURLProtocol.handler = { _ in .init(body: body) }
            assertFails(await verify(), .invalidResponse)
        }
    }

    func testAnOversizedBodyIsInvalidResponse() async {
        StubURLProtocol.handler = { _ in .init(body: Data(repeating: 0x20, count: AuthService.maxResponseBytes + 1)) }
        assertFails(await verify(), .invalidResponse)
        StubURLProtocol.handler = { _ in .init(status: 400, body: Data(repeating: 0x20, count: AuthService.maxResponseBytes + 1)) }
        assertFails(await requestCode(), .invalidResponse)
    }

    // MARK: - network errors

    func testNetworkErrorMapping() async {
        let cases: [(Error, AuthError)] = [
            (URLError(.timedOut), .timedOut),
            (URLError(.notConnectedToInternet), .offline),
            (URLError(.dataNotAllowed), .offline),
            (URLError(.internationalRoamingOff), .offline),
            (URLError(.cancelled), .cancelled),
            (URLError(.cannotFindHost), .unreachable),
            (URLError(.cannotConnectToHost), .unreachable),
            (URLError(.secureConnectionFailed), .unreachable),
        ]
        for (error, expected) in cases {
            StubURLProtocol.handler = { _ in .init(error: error) }
            assertFails(await requestCode(), expected)
            assertFails(await verify(), expected)
        }
    }

    func testNonURLErrorsAndSwiftCancellationMapLikeTheRewritePipeline() {
        struct Other: Error {}
        XCTAssertEqual(AuthService.classify(networkError: Other()), .unreachable)
        XCTAssertEqual(AuthService.classify(networkError: CancellationError()), .cancelled)
    }

    func testCancellingTheCallingTaskReturnsCancelled() async {
        StubURLProtocol.handler = { _ in .init(stall: true) }
        let service = makeService()
        let email = self.email
        let task = Task { await service.requestCode(email: email) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        assertFails(await task.value, .cancelled)
    }

    // MARK: - signOut

    private let session = AuthSession(
        accessToken: "access-token-for-logout", refreshToken: "refresh", expiresAt: Date(timeIntervalSince1970: 1_790_003_600),
        email: "person@example.com"
    )

    func testSignOutShape() async throws {
        StubURLProtocol.handler = { _ in .init(status: 204) }
        await makeService().signOut(session)

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/auth/v1/logout")
        XCTAssertEqual(request.url?.query, "scope=local")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token-for-logout")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), anonKey)
        XCTAssertFalse(request.url?.absoluteString.contains("person") ?? true)
        XCTAssertFalse(request.url?.absoluteString.contains("access-token") ?? true)
        XCTAssertTrue((StubURLProtocol.lastBody ?? Data()).isEmpty)
    }

    func testSignOutIgnoresEveryOutcome() async {
        let replies: [StubURLProtocol.Reply] = [
            .init(status: 401, body: data(["code": 401, "error_code": "bad_jwt", "msg": "x"])),
            .init(status: 500),
            .init(status: 429),
            .init(error: URLError(.notConnectedToInternet)),
            .init(error: URLError(.timedOut)),
        ]
        for reply in replies {
            StubURLProtocol.handler = { _ in reply }
            await makeService().signOut(session)   // returns; nothing to assert but no crash or hang
            XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/auth/v1/logout")
        }
    }

    func testSignOutIsCappedWhenTheServerNeverAnswers() async {
        StubURLProtocol.handler = { _ in .init(stall: true) }
        let started = Date()
        await makeService(logoutCap: 0.3).signOut(session)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 2.5, "must not wait for the 5 s session deadline")
        XCTAssertGreaterThanOrEqual(elapsed, 0.25)
    }

    func testSignOutIsCappedEvenWhenTheServerKeepsTricklingBytes() async {
        // Bytes keep arriving, so the request's own idle timeout never fires: only
        // the cap can end this one.
        StubURLProtocol.handler = { _ in .init(trickleSeconds: 4) }
        let started = Date()
        await makeService(logoutCap: 0.3).signOut(session)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTheProductionCapIsThreeSeconds() {
        XCTAssertEqual(AuthService.logoutCap, 3)
    }

    // MARK: - nothing sensitive in errors

    func testErrorTextsNeverHoldTheEmailOrTheCode() async {
        StubURLProtocol.handler = { _ in self.gotrueError(403, "otp_expired") }
        let result = await verify()
        let text = "\(result) \(String(describing: result))"
        XCTAssertFalse(text.contains(email))
        XCTAssertFalse(text.contains(code))
        for error in [AuthError.invalidEmail, .codeRejected, .tooManyAttempts(retryAfter: 30), .sendRateLimited(retryAfter: 30), .offline, .timedOut, .cancelled, .unreachable, .unavailable, .invalidResponse, .sessionRevoked, .storageFailed] {
            let description = try? XCTUnwrap(error.errorDescription)
            XCTAssertFalse(description?.isEmpty ?? true, "\(error)")
            XCTAssertFalse(description?.contains("@") ?? false)
            XCTAssertFalse(description?.contains("30") ?? false, "descriptions are fixed text, no interpolated values")
        }
    }
}
