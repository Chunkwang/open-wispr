import XCTest
@testable import OpenWisprLib

/// Covers Task 4.6 (fetch and cache the tier) and the `TierStore.refresh`
/// helper `AppDelegate` calls on launch and on every sign-in/out.
final class TierStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TierStore.shared.set(nil)
    }

    override func tearDown() {
        TierStore.shared.set(nil)
        super.tearDown()
    }

    func testInstanceStoreGetSet() {
        let store = TierStore()
        XCTAssertNil(store.current)
        store.set(TierInfo(tier: .pro, remainingThisMonth: 100))
        XCTAssertEqual(store.current, TierInfo(tier: .pro, remainingThisMonth: 100))
        store.set(nil)
        XCTAssertNil(store.current)
    }

    func testTwoInstancesAreIndependent() {
        let a = TierStore()
        let b = TierStore()
        a.set(TierInfo(tier: .pro, remainingThisMonth: 1))
        XCTAssertNil(b.current)
    }

    func testRefreshWhenSignedOutClearsWithoutAFetch() {
        TierStore.shared.set(TierInfo(tier: .pro, remainingThisMonth: 100))
        var fetchCalls = 0
        let done = expectation(description: "completion runs")
        TierStore.refresh(
            isSignedIn: { false },
            fetchMe: { fetchCalls += 1; return .success(TierInfo(tier: .free, remainingThisMonth: 1)) },
            completion: { done.fulfill() }
        )
        wait(for: [done], timeout: 2)
        XCTAssertNil(TierStore.shared.current)
        XCTAssertEqual(fetchCalls, 0, "signed out never needs to hit the network")
    }

    func testRefreshSuccessSetsCache() {
        let done = expectation(description: "completion runs")
        TierStore.refresh(
            isSignedIn: { true },
            fetchMe: { .success(TierInfo(tier: .pro, remainingThisMonth: 2500)) },
            completion: { done.fulfill() }
        )
        wait(for: [done], timeout: 2)
        XCTAssertEqual(TierStore.shared.current, TierInfo(tier: .pro, remainingThisMonth: 2500))
    }

    func testRefreshUnauthorizedClearsCache() {
        TierStore.shared.set(TierInfo(tier: .pro, remainingThisMonth: 2500))
        let done = expectation(description: "completion runs")
        TierStore.refresh(isSignedIn: { true }, fetchMe: { .failure(.unauthorized) }, completion: { done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertNil(TierStore.shared.current)
    }

    func testRefreshNotAuthenticatedClearsCache() {
        TierStore.shared.set(TierInfo(tier: .free, remainingThisMonth: 1))
        let done = expectation(description: "completion runs")
        TierStore.refresh(isSignedIn: { true }, fetchMe: { .failure(.notAuthenticated) }, completion: { done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertNil(TierStore.shared.current)
    }

    /// A transient failure (offline, rate-limited, 5xx...) must not hide a known
    /// Pro user's "Manage Subscription" item: the cache is left as it was.
    func testRefreshTransientFailureLeavesCacheUnchanged() {
        let known = TierInfo(tier: .pro, remainingThisMonth: 2500)
        TierStore.shared.set(known)
        let done = expectation(description: "completion runs")
        TierStore.refresh(isSignedIn: { true }, fetchMe: { .failure(.unreachable) }, completion: { done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(TierStore.shared.current, known)
    }

    func testRefreshCompletionAlwaysRunsOnMainThread() {
        let done = expectation(description: "completion runs")
        TierStore.refresh(
            isSignedIn: { true },
            fetchMe: { .success(TierInfo(tier: .free, remainingThisMonth: 1)) },
            completion: {
                XCTAssertTrue(Thread.isMainThread)
                done.fulfill()
            }
        )
        wait(for: [done], timeout: 2)
    }
}
