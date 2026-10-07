import Security
import XCTest
@testable import OpenWisprLib

final class SignInMenuStateTests: XCTestCase {
    private let session = AuthSession(
        accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_790_003_600), email: "sam@example.com"
    )

    func testSignedOutOffersSignIn() {
        XCTAssertEqual(SignInMenuState(.success(nil)), .signedOut)
    }

    func testSignedInShowsTheAddress() {
        XCTAssertEqual(SignInMenuState(.success(session)), .signedIn(email: "sam@example.com"))
    }

    func testAnUnreadableKeychainIsNotReportedAsSignedOut() {
        let state = SignInMenuState(.failure(KeychainError(status: errSecInteractionNotAllowed)))
        XCTAssertEqual(state, .unavailable)
        XCTAssertNotEqual(state, .signedOut)
    }

    func testTheStateFollowsTheRealStore() throws {
        let fake = InMemoryKeychain()
        let store = SessionStore(keychain: fake)
        XCTAssertEqual(SignInMenuState(store.load()), .signedOut)
        try store.save(session)
        XCTAssertEqual(SignInMenuState(store.load()), .signedIn(email: "sam@example.com"))
        fake.readStatus = errSecInteractionNotAllowed
        XCTAssertEqual(SignInMenuState(store.load()), .unavailable)
    }

    func testTheMenuTitlesAreTheSpecifiedOnes() {
        XCTAssertEqual(SignInCopy.menuSignIn, "Sign in\u{2026}")
        XCTAssertEqual(SignInCopy.menuSignOut, "Sign out")
        XCTAssertEqual(SignInCopy.menuSignInUnavailable, "Sign-in status unavailable")
        XCTAssertEqual(SignInCopy.menuSignedInAs("sam@example.com"), "Signed in as sam@example.com")
    }

    // MARK: - sign-out feedback

    func testACleanSignOutSaysSignedOut() {
        let feedback = SignOutFeedback(local: .success(()))
        XCTAssertTrue(feedback.isSignedOut)
        XCTAssertEqual(feedback.notice, SignInCopy.signOutSignedOutNotice)
        XCTAssertEqual(feedback.announcement, SignInCopy.signedOut)
    }

    func testAFailedLocalClearNeverClaimsSignedOut() {
        let feedback = SignOutFeedback(local: .failure(.storageFailed))
        XCTAssertFalse(feedback.isSignedOut)
        XCTAssertEqual(feedback.notice, SignInCopy.signOutFailed)
        XCTAssertNil(feedback.announcement, "nothing spoken that says signed out")
        XCTAssertTrue(feedback.notice.contains("still signed in"))
        XCTAssertFalse(feedback.notice.hasPrefix("Signed out"))
    }

    func testSignOutFeedbackFollowsARealCoordinatorClear() throws {
        let fake = InMemoryKeychain()
        try SessionStore(keychain: fake).save(session)
        fake.deleteStatus = errSecInteractionNotAllowed
        let coordinator = AuthCoordinator(service: AuthService(), store: SessionStore(keychain: fake), didChangeSession: {})
        let result = coordinator.signOut()
        result.serverLogout?.cancel()
        XCTAssertFalse(SignOutFeedback(local: result.local).isSignedOut)
        XCTAssertEqual(SignInMenuState(SessionStore(keychain: fake).load()), .signedIn(email: "sam@example.com"),
                       "the menu still says signed in, as the token is still there")
    }
}
