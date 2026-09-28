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

    private func store(_ fake: InMemoryKeychain) -> SessionStore { SessionStore(keychain: fake) }

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
}
