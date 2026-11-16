import XCTest
import Security
@testable import OpenWisprLib

final class AuthSessionTests: XCTestCase {
    private let expiry = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(expiresAt: Date? = nil) -> AuthSession {
        AuthSession(
            accessToken: "access-token-VALUE",
            refreshToken: "refresh-token-VALUE",
            expiresAt: expiresAt ?? expiry,
            email: "person@example.com"
        )
    }

    // MARK: - redaction

    func testEveryDescriptionIsRedacted() {
        let s = session()
        var dumped = ""
        dump(s, to: &dumped)
        let outputs = [
            "\(s)", String(describing: s), String(reflecting: s), s.description, s.debugDescription,
            "\(Result<AuthSession, AuthError>.success(s))", dumped,
        ]
        for text in outputs {
            XCTAssertFalse(text.contains("access-token"), text)
            XCTAssertFalse(text.contains("refresh-token"), text)
            XCTAssertFalse(text.contains("person@example.com"), text)
            XCTAssertFalse(text.contains("VALUE"), text)
        }
    }

    // MARK: - encoding

    func testEncodesExpiryAsEpochSeconds() throws {
        let data = try JSONEncoder().encode(session())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["expiresAt"] as? Double, 1_790_000_000)
        XCTAssertEqual(Set(object.keys), ["accessToken", "refreshToken", "expiresAt", "email"])
    }

    func testRoundTripsIncludingFractionalSeconds() throws {
        let original = session(expiresAt: Date(timeIntervalSince1970: 1_790_000_000.25))
        let decoded = try JSONDecoder().decode(AuthSession.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testMissingFieldsDoNotDecode() {
        let json = Data(#"{"accessToken":"a","refreshToken":"r","email":"e"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AuthSession.self, from: json))
    }

    // MARK: - needsRefresh boundaries

    func testNeedsRefreshBoundaries() {
        let s = session()
        XCTAssertFalse(s.needsRefresh(now: expiry.addingTimeInterval(-61)))
        XCTAssertTrue(s.needsRefresh(now: expiry.addingTimeInterval(-60)), "exactly 60 s left counts")
        XCTAssertTrue(s.needsRefresh(now: expiry.addingTimeInterval(-59)))
        XCTAssertTrue(s.needsRefresh(now: expiry))
        XCTAssertTrue(s.needsRefresh(now: expiry.addingTimeInterval(1)), "already expired")
    }

    func testNeedsRefreshHonoursALeewayArgument() {
        let s = session()
        XCTAssertFalse(s.needsRefresh(now: expiry.addingTimeInterval(-11), leeway: 10))
        XCTAssertTrue(s.needsRefresh(now: expiry.addingTimeInterval(-10), leeway: 10))
        XCTAssertTrue(s.needsRefresh(now: expiry.addingTimeInterval(-3599), leeway: 3600))
    }

    func testDefaultLeewayIsSixtySeconds() {
        let s = session()
        XCTAssertFalse(s.needsRefresh(now: expiry.addingTimeInterval(-61)))
        XCTAssertTrue(s.needsRefresh(now: expiry.addingTimeInterval(-60)))
    }
}

final class SessionStoreTests: XCTestCase {
    private let session = AuthSession(
        accessToken: "access-1", refreshToken: "refresh-1",
        expiresAt: Date(timeIntervalSince1970: 1_790_000_000), email: "person@example.com"
    )

    override func setUp() {
        super.setUp()
        // Only the refreshingKeychainToken tests below touch the network, but
        // StubURLProtocol's state is static, so it is reset for every test here
        // the same way AuthServiceTests and AuthCoordinatorTests do.
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        StubURLProtocol.requestCount = 0
    }

    private func store(_ fake: InMemoryKeychain) -> SessionStore { SessionStore(keychain: fake) }

    private func authService(baseURL: URL = URL(string: "https://auth.test")!) -> AuthService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AuthService(
            session: RewritePipeline.makeSession(configuration: config, timeout: 5),
            baseURL: baseURL, anonKey: "sb_publishable_test"
        )
    }

    // MARK: - one item

    func testTheSessionLivesInOneItemNamedSession() throws {
        let fake = InMemoryKeychain()
        try store(fake).save(session)
        XCTAssertEqual(SessionStore.account, "session")
        XCTAssertNotNil(fake.stored(account: "session"))
        XCTAssertEqual(fake.operations, ["write:session"])
    }

    func testRoundTrip() throws {
        let fake = InMemoryKeychain()
        let store = store(fake)
        XCTAssertEqual(try store.load().get(), nil)
        XCTAssertFalse(store.isSignedIn)
        try store.save(session)
        XCTAssertEqual(try store.load().get(), session)
        XCTAssertTrue(store.isSignedIn)
    }

    func testSaveReplacesThePreviousSession() throws {
        let fake = InMemoryKeychain()
        let store = store(fake)
        try store.save(session)
        var newer = session
        newer.accessToken = "access-2"
        try store.save(newer)
        XCTAssertEqual(try store.load().get(), newer)
    }

    func testSaveSurfacesAKeychainFailure() {
        let fake = InMemoryKeychain()
        fake.writeStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store(fake).save(session)) {
            XCTAssertEqual($0 as? KeychainError, KeychainError(status: errSecInteractionNotAllowed))
        }
    }

    // MARK: - clear

    func testClearSignsOutAndIsIdempotent() throws {
        let fake = InMemoryKeychain()
        let store = store(fake)
        try store.save(session)
        XCTAssertNoThrow(try store.clear().get())
        XCTAssertNoThrow(try store.clear().get())
        XCTAssertEqual(try store.load().get(), nil)
        XCTAssertFalse(store.isSignedIn)
    }

    func testClearReportsAFailureAndKeepsTheItem() throws {
        let fake = InMemoryKeychain()
        let store = store(fake)
        try store.save(session)
        fake.deleteStatus = errSecInteractionNotAllowed
        guard case .failure(let error) = store.clear() else { return XCTFail("expected a failure") }
        XCTAssertEqual(error, KeychainError(status: errSecInteractionNotAllowed))
        XCTAssertNotNil(fake.stored(account: "session"))
    }

    // MARK: - undecodable data

    func testUndecodableJSONIsDeletedAndTreatedAsSignedOut() throws {
        for garbage in ["not json", "{}", "[]", #"{"accessToken":"a"}"#, "", #"{"accessToken":"a","refreshToken":"r","expiresAt":"soon","email":"e"}"#] {
            let fake = InMemoryKeychain()
            fake.put(Data(garbage.utf8), account: "session")
            XCTAssertEqual(try store(fake).load().get(), nil, garbage)
            XCTAssertNil(fake.stored(account: "session"), "corrupt item removed: \(garbage)")
        }
    }

    func testABlankAccessTokenIsNotASession() throws {
        let fake = InMemoryKeychain()
        var blank = session
        blank.accessToken = ""
        fake.put(try JSONEncoder().encode(blank), account: "session")
        XCTAssertEqual(try store(fake).load().get(), nil)
        XCTAssertNil(fake.stored(account: "session"))
    }

    func testUndecodableDataIsDeletedEvenIfTheDeleteFails() throws {
        let fake = InMemoryKeychain()
        fake.put(Data("junk".utf8), account: "session")
        fake.deleteStatus = errSecInteractionNotAllowed
        XCTAssertEqual(try store(fake).load().get(), nil)
    }

    // MARK: - a Keychain that cannot be read is not "signed out"

    func testANonNotFoundReadErrorIsSurfacedAndDeletesNothing() throws {
        let fake = InMemoryKeychain()
        try store(fake).save(session)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, -1] {
            fake.readStatus = status
            let result = store(fake).load()
            XCTAssertEqual(result, .failure(KeychainError(status: status)), "status \(status)")
            XCTAssertFalse(fake.operations.contains { $0.hasPrefix("delete") }, "status \(status)")
            XCTAssertNotNil(fake.stored(account: "session"), "the session survives")
        }
    }

    func testIsSignedInIsFalseWhenTheKeychainCannotBeReadButNothingIsChanged() throws {
        let fake = InMemoryKeychain()
        try store(fake).save(session)
        fake.readStatus = errSecInteractionNotAllowed
        XCTAssertFalse(store(fake).isSignedIn)
        XCTAssertNotNil(fake.stored(account: "session"))
        fake.readStatus = nil
        XCTAssertTrue(store(fake).isSignedIn)
    }

    // MARK: - legacy dev token

    func testTheLegacyDevTokenItemIsDeletedAndTheSessionIsLeftAlone() throws {
        let fake = InMemoryKeychain()
        fake.put(Data("old-dev-token".utf8), account: "session-token")
        try store(fake).save(session)
        store(fake).deleteLegacyItem()
        XCTAssertNil(fake.stored(account: "session-token"))
        XCTAssertNotNil(fake.stored(account: "session"))
        XCTAssertEqual(SessionStore.legacyAccount, "session-token")
    }

    func testDeletingTheLegacyItemNeverThrowsWhenItFails() {
        let fake = InMemoryKeychain()
        fake.deleteStatus = errSecInteractionNotAllowed
        store(fake).deleteLegacyItem()
    }

    // MARK: - the pipeline reads the same item

    func testThePipelineTokenIsTheStoredAccessTokenAsIs() throws {
        let fake = InMemoryKeychain()
        XCTAssertNil(RewritePipeline.keychainToken(store: store(fake)))
        var expired = session
        expired.expiresAt = Date(timeIntervalSince1970: 1)
        try store(fake).save(expired)
        XCTAssertEqual(RewritePipeline.keychainToken(store: store(fake)), "access-1", "no refresh on Day 4")
    }

    func testThePipelineTokenIsNilWhenTheKeychainCannotBeRead() throws {
        let fake = InMemoryKeychain()
        try store(fake).save(session)
        fake.readStatus = errSecInteractionNotAllowed
        XCTAssertNil(RewritePipeline.keychainToken(store: store(fake)))
    }

    // MARK: - refreshingKeychainToken (Task 3.5): the pipeline refreshes first

    private func refreshReply(
        accessToken: String = "new-access", refreshToken: String = "new-refresh", expiresAt: TimeInterval = 1_790_003_600
    ) -> StubURLProtocol.Reply {
        let object: [String: Any] = [
            "access_token": accessToken, "refresh_token": refreshToken, "expires_at": expiresAt,
            "user": ["email": "person@example.com"],
        ]
        return .init(body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func revokedReply(_ errorCode: String = "refresh_token_not_found") -> StubURLProtocol.Reply {
        .init(status: 400, body: try! JSONSerialization.data(withJSONObject: ["code": 400, "error_code": errorCode, "msg": "x"]))
    }

    func testATokenThatDoesNotNeedRefreshingIsReturnedAsIsAndNothingIsSent() async throws {
        let fake = InMemoryKeychain()
        var fresh = session
        fresh.expiresAt = Date(timeIntervalSince1970: 1_790_000_000 + 3600)
        try store(fake).save(fresh)
        let now = { Date(timeIntervalSince1970: 1_790_000_000) }

        let token = await RewritePipeline.refreshingKeychainToken(store: store(fake), service: authService(), now: now)
        XCTAssertEqual(token, "access-1")
        XCTAssertEqual(StubURLProtocol.requestCount, 0, "not near expiry: refreshing this would be a wasted network call")
    }

    func testAnExpiredTokenRefreshesOnceAndSucceeds() async throws {
        let fake = InMemoryKeychain()
        var expiring = session
        expiring.expiresAt = Date(timeIntervalSince1970: 1_790_000_000)
        try store(fake).save(expiring)
        StubURLProtocol.handler = { _ in self.refreshReply() }
        let now = { Date(timeIntervalSince1970: 1_790_000_000) }

        let token = await RewritePipeline.refreshingKeychainToken(store: store(fake), service: authService(), now: now)
        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "exactly one refresh")

        let saved = try store(fake).load().get()
        XCTAssertEqual(saved?.accessToken, "new-access")
        XCTAssertEqual(saved?.refreshToken, "new-refresh", "the rotated refresh token must be saved, not the old one")
        XCTAssertEqual(saved?.expiresAt, Date(timeIntervalSince1970: 1_790_003_600))
    }

    func testARevokedRefreshTokenLandsInTheSignedOutState() async throws {
        let fake = InMemoryKeychain()
        var expiring = session
        expiring.expiresAt = Date(timeIntervalSince1970: 1_790_000_000)
        try store(fake).save(expiring)
        StubURLProtocol.handler = { _ in self.revokedReply() }
        let now = { Date(timeIntervalSince1970: 1_790_000_000) }

        let token = await RewritePipeline.refreshingKeychainToken(store: store(fake), service: authService(), now: now)
        XCTAssertNil(token)
        XCTAssertNil(fake.stored(account: "session"), "a genuinely dead refresh token clears the stored session")
        XCTAssertFalse(store(fake).isSignedIn)
    }

    func testAReusedRefreshTokenAlsoLandsInTheSignedOutState() async throws {
        let fake = InMemoryKeychain()
        var expiring = session
        expiring.expiresAt = Date(timeIntervalSince1970: 1_790_000_000)
        try store(fake).save(expiring)
        StubURLProtocol.handler = { _ in self.revokedReply("refresh_token_already_used") }
        let now = { Date(timeIntervalSince1970: 1_790_000_000) }

        let token = await RewritePipeline.refreshingKeychainToken(store: store(fake), service: authService(), now: now)
        XCTAssertNil(token)
        XCTAssertFalse(store(fake).isSignedIn)
    }

    /// The plan says "if refresh fails, mark signed out", but signing a user out
    /// over a network blip (rather than a genuinely dead refresh token) would be
    /// wrong, and the design doc (docs/auth-design.md, Day 5) says so explicitly:
    /// keep the session and use the old token, retrying on the next call.
    func testATransientRefreshFailureKeepsTheOldSessionAndReturnsTheOldToken() async throws {
        let fake = InMemoryKeychain()
        var expiring = session
        expiring.expiresAt = Date(timeIntervalSince1970: 1_790_000_000)
        try store(fake).save(expiring)
        StubURLProtocol.handler = { _ in .init(error: URLError(.notConnectedToInternet)) }
        let now = { Date(timeIntervalSince1970: 1_790_000_000) }

        let token = await RewritePipeline.refreshingKeychainToken(store: store(fake), service: authService(), now: now)
        XCTAssertEqual(token, "access-1", "a network blip must not sign the user out")
        XCTAssertEqual(try store(fake).load().get(), expiring)
    }

    func testA5xxDuringRefreshAlsoKeepsTheOldSession() async throws {
        let fake = InMemoryKeychain()
        var expiring = session
        expiring.expiresAt = Date(timeIntervalSince1970: 1_790_000_000)
        try store(fake).save(expiring)
        StubURLProtocol.handler = { _ in .init(status: 503) }
        let now = { Date(timeIntervalSince1970: 1_790_000_000) }

        let token = await RewritePipeline.refreshingKeychainToken(store: store(fake), service: authService(), now: now)
        XCTAssertEqual(token, "access-1")
        XCTAssertTrue(store(fake).isSignedIn)
    }

    func testRefreshingTokenIsNilWhenAlreadySignedOutAndSendsNothing() async {
        let fake = InMemoryKeychain()
        let token = await RewritePipeline.refreshingKeychainToken(store: store(fake), service: authService())
        XCTAssertNil(token)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }
}
