import XCTest
import Security
@testable import OpenWisprLib

private struct AlwaysOnline: NetworkReachability {
    func isOnline(waitingUpTo timeout: TimeInterval) async -> Bool { true }
}

/// Lock-guarded record of what happened, in order, across threads.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [String] = []
    func note(_ event: String) { lock.lock(); _list.append(event); lock.unlock() }
    var list: [String] { lock.lock(); defer { lock.unlock() }; return _list }
}

final class AuthCoordinatorTests: XCTestCase {
    private let email = "person@example.com"
    private let session = AuthSession(
        accessToken: "stored-access", refreshToken: "stored-refresh",
        expiresAt: Date(timeIntervalSince1970: 1_790_003_600), email: "person@example.com"
    )

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        StubURLProtocol.requestCount = 0
    }

    private func makeService(logoutCap: TimeInterval = 3) -> AuthService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AuthService(
            session: RewritePipeline.makeSession(configuration: config, timeout: 5),
            baseURL: URL(string: "https://auth.test")!, anonKey: "sb_publishable_test", logoutCap: logoutCap
        )
    }

    private func makeCoordinator(
        _ fake: InMemoryKeychain, _ events: Events = Events(), logoutCap: TimeInterval = 3
    ) -> AuthCoordinator {
        AuthCoordinator(
            service: makeService(logoutCap: logoutCap),
            store: SessionStore(keychain: fake),
            didChangeSession: { events.note("reset") }
        )
    }

    private func sessionReply() -> StubURLProtocol.Reply {
        let object: [String: Any] = [
            "access_token": "new-access", "token_type": "bearer", "expires_in": 3600, "expires_at": 1_790_003_600,
            "refresh_token": "new-refresh", "user": ["id": "u", "aud": "authenticated", "role": "authenticated", "email": email],
        ]
        return .init(body: try! JSONSerialization.data(withJSONObject: object))
    }

    // MARK: - sign-in

    func testVerifySavesTheSessionThenResets() async throws {
        let fake = InMemoryKeychain()
        let events = Events()
        StubURLProtocol.handler = { _ in self.sessionReply() }
        let signedIn = try await makeCoordinator(fake, events).verifyCode(email: email, code: "123456").get()

        XCTAssertEqual(signedIn.accessToken, "new-access")
        XCTAssertEqual(try SessionStore(keychain: fake).load().get(), signedIn)
        XCTAssertEqual(events.list, ["reset"])
    }

    func testAFailedVerifySavesNothingAndDoesNotReset() async {
        let fake = InMemoryKeychain()
        let events = Events()
        StubURLProtocol.handler = { _ in .init(status: 403, body: Data(#"{"code":403,"error_code":"otp_expired","msg":"x"}"#.utf8)) }
        let result = await makeCoordinator(fake, events).verifyCode(email: email, code: "000000")
        guard case .failure(.codeRejected) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(fake.operations, [])
        XCTAssertEqual(events.list, [])
    }

    func testAKeychainThatRefusesTheSaveIsStorageFailed() async {
        let fake = InMemoryKeychain()
        fake.writeStatus = errSecInteractionNotAllowed
        let events = Events()
        StubURLProtocol.handler = { _ in self.sessionReply() }
        let result = await makeCoordinator(fake, events).verifyCode(email: email, code: "123456")
        guard case .failure(.storageFailed) = result else { return XCTFail("\(result)") }
        XCTAssertNil(fake.stored(account: "session"))
        XCTAssertEqual(events.list, [], "not signed in, so nothing to reset")
    }

    func testRequestCodeStoresNothingAndDoesNotReset() async {
        let fake = InMemoryKeychain()
        let events = Events()
        StubURLProtocol.handler = { _ in .init(body: Data("{}".utf8)) }
        if case .failure(let error) = await makeCoordinator(fake, events).requestCode(email: email) { XCTFail("\(error)") }
        XCTAssertEqual(fake.operations, [])
        XCTAssertEqual(events.list, [])
    }

    // MARK: - sign-out

    func testSignOutClearsTheKeychainBeforeTheServerIsToldAndResetsBeforeToo() async throws {
        let fake = InMemoryKeychain()
        try SessionStore(keychain: fake).save(session)
        let events = Events()
        StubURLProtocol.handler = { request in
            // At the moment the logout request is made, the local session is
            // already gone and the rewrite stop already lifted.
            events.note(fake.stored(account: "session") == nil ? "keychain-empty" : "keychain-STILL-FULL")
            events.note("request:\(request.url?.path ?? "")")
            return .init(status: 204)
        }
        let result = makeCoordinator(fake, events).signOut()
        await result.serverLogout?.value

        XCTAssertEqual(events.list, ["reset", "keychain-empty", "request:/auth/v1/logout"])
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer stored-access")
        guard case .success = result.local else { return XCTFail("\(result.local)") }
        XCTAssertNil(fake.stored(account: "session"))
    }

    func testSignOutReturnsBeforeTheServerAnswers() async throws {
        let fake = InMemoryKeychain()
        try SessionStore(keychain: fake).save(session)
        StubURLProtocol.handler = { _ in .init(stall: true) }
        let started = Date()
        let result = makeCoordinator(fake, logoutCap: 0.3).signOut()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "the local part never waits for the network")
        XCTAssertNil(fake.stored(account: "session"))
        await result.serverLogout?.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testSignOutStaysSignedOutWhateverTheServerSays() async throws {
        let replies: [StubURLProtocol.Reply] = [.init(status: 401), .init(status: 500), .init(error: URLError(.notConnectedToInternet))]
        for reply in replies {
            let fake = InMemoryKeychain()
            try SessionStore(keychain: fake).save(session)
            StubURLProtocol.handler = { _ in reply }
            let result = makeCoordinator(fake).signOut()
            await result.serverLogout?.value
            guard case .success = result.local else { return XCTFail("\(result.local)") }
            XCTAssertFalse(SessionStore(keychain: fake).isSignedIn)
        }
    }

    func testSignOutWithNoSessionSendsNothingButStillResets() {
        let fake = InMemoryKeychain()
        let events = Events()
        StubURLProtocol.handler = { _ in .init(status: 204) }
        let result = makeCoordinator(fake, events).signOut()
        XCTAssertNil(result.serverLogout)
        guard case .success = result.local else { return XCTFail("\(result.local)") }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
        XCTAssertEqual(events.list, ["reset"])
    }

    func testSignOutWhenTheKeychainRefusesToDeleteReportsItButStillRevokesOnTheServer() async throws {
        let fake = InMemoryKeychain()
        try SessionStore(keychain: fake).save(session)
        fake.deleteStatus = errSecInteractionNotAllowed
        StubURLProtocol.handler = { _ in .init(status: 204) }
        let result = makeCoordinator(fake).signOut()
        await result.serverLogout?.value
        guard case .failure(.storageFailed) = result.local else { return XCTFail("\(result.local)") }
        XCTAssertNotNil(fake.stored(account: "session"), "the token really is still there, and the result says so")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testSignOutWhenTheKeychainCannotBeReadStillTriesToClearAndSendsNothing() {
        let fake = InMemoryKeychain()
        fake.readStatus = errSecInteractionNotAllowed
        StubURLProtocol.handler = { _ in .init(status: 204) }
        let result = makeCoordinator(fake).signOut()
        XCTAssertNil(result.serverLogout, "no token to send")
        XCTAssertTrue(fake.operations.contains("delete:session"))
    }

    // MARK: - the rewrite stop is lifted for real

    /// One dictation through a real `RewriteCoordinator`; returns whether a
    /// request was attempted.
    private func attempted(_ coordinator: RewriteCoordinator) -> Bool {
        let done = expectation(description: "completion")
        var outcome: RewriteOutcome?
        coordinator.process(
            transcript: "hello there", mode: { .auto }, willRewrite: {},
            completion: { outcome = $0; done.fulfill() }
        )
        wait(for: [done], timeout: 5)
        return outcome?.attempted ?? false
    }

    private func stoppedRewriteCoordinator() -> RewriteCoordinator {
        let coordinator = RewriteCoordinator(
            gate: { _ in true },
            makeReachability: { AlwaysOnline() },
            makeRewriter: { { _ in .failure(.unauthorized) } }
        )
        XCTAssertTrue(attempted(coordinator), "first dictation is sent and answered 401")
        XCTAssertFalse(attempted(coordinator), "the rest of the session is stopped")
        return coordinator
    }

    func testSigningInLiftsTheSessionLongStop() async throws {
        let rewrite = stoppedRewriteCoordinator()
        let auth = AuthCoordinator(
            service: makeService(), store: SessionStore(keychain: InMemoryKeychain()),
            didChangeSession: { rewrite.resetSession() }
        )
        StubURLProtocol.handler = { _ in self.sessionReply() }
        _ = try await auth.verifyCode(email: email, code: "123456").get()
        XCTAssertTrue(attempted(rewrite))
    }

    func testSigningOutLiftsTheSessionLongStopToo() async throws {
        let rewrite = stoppedRewriteCoordinator()
        let fake = InMemoryKeychain()
        try SessionStore(keychain: fake).save(session)
        let auth = AuthCoordinator(
            service: makeService(), store: SessionStore(keychain: fake),
            didChangeSession: { rewrite.resetSession() }
        )
        StubURLProtocol.handler = { _ in .init(status: 204) }
        await auth.signOut().serverLogout?.value
        XCTAssertTrue(attempted(rewrite))
    }

    // MARK: - verify and save as two steps (the sign-in window retries the save)

    func testVerifyWithoutSavingReturnsTheSessionAndTouchesNothing() async throws {
        let fake = InMemoryKeychain()
        let events = Events()
        StubURLProtocol.handler = { _ in self.sessionReply() }
        let verified = try await makeCoordinator(fake, events).verifyWithoutSaving(email: email, code: "123456").get()
        XCTAssertEqual(verified.accessToken, "new-access")
        XCTAssertEqual(fake.operations, [])
        XCTAssertEqual(events.list, [])
    }

    func testSaveStoresTheSessionThenResets() throws {
        let fake = InMemoryKeychain()
        let events = Events()
        guard case .success = makeCoordinator(fake, events).save(session) else { return XCTFail() }
        XCTAssertEqual(try SessionStore(keychain: fake).load().get(), session)
        XCTAssertEqual(events.list, ["reset"])
    }

    func testAFailedSaveCanBeRetriedWithTheSameSessionAndOnlyThenResets() throws {
        let fake = InMemoryKeychain()
        let events = Events()
        let coordinator = makeCoordinator(fake, events)
        fake.writeStatus = errSecInteractionNotAllowed
        guard case .failure(.storageFailed) = coordinator.save(session) else { return XCTFail() }
        XCTAssertEqual(events.list, [], "not signed in, so nothing to reset")
        XCTAssertFalse(SessionStore(keychain: fake).isSignedIn)

        fake.writeStatus = nil
        guard case .success = coordinator.save(session) else { return XCTFail() }
        XCTAssertEqual(try SessionStore(keychain: fake).load().get(), session)
        XCTAssertEqual(events.list, ["reset"])
    }

    func testDiscardingAnUnsavedSessionLogsItOutWithItsOwnTokenAndStoresNothing() async {
        let fake = InMemoryKeychain()
        StubURLProtocol.handler = { _ in .init(status: 204) }
        await makeCoordinator(fake).discardUnsaved(session).value
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/auth/v1/logout")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer stored-access")
        XCTAssertEqual(fake.operations, [])
    }
}
