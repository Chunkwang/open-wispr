import XCTest
@testable import OpenWisprLib

/// A clock the coordinator's injected `sleep`/`now` drive together, so a test
/// exercising the two-minute poll window runs in well under a second instead of
/// two real minutes.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 0)) { current = start }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

/// Covers Tasks 4.7 ("Upgrade to Pro") and 4.8 ("Manage subscription"): the
/// checkout-then-poll sequence and the portal call, entirely against injected
/// fakes — no test touches the network or waits on a real clock.
final class BillingCoordinatorTests: XCTestCase {
    private let checkoutURL = URL(string: "https://stripe.test/checkout/cs_1")!
    private let portalURL = URL(string: "https://stripe.test/portal/p_1")!

    private func makeCoordinator(
        fetchMe: @escaping () async -> Result<TierInfo, BillingError> = { fatalError("fetchMe not expected") },
        startCheckout: @escaping () async -> Result<URL, BillingError> = { fatalError("startCheckout not expected") },
        startPortal: @escaping () async -> Result<URL, BillingError> = { fatalError("startPortal not expected") },
        clock: FakeClock,
        pollDuration: TimeInterval = 20,
        pollInterval: TimeInterval = 5
    ) -> BillingCoordinator {
        BillingCoordinator(
            fetchMe: fetchMe,
            startCheckout: startCheckout,
            startPortal: startPortal,
            sleep: { seconds in clock.advance(seconds) },
            now: { clock.now() },
            pollDuration: pollDuration,
            pollInterval: pollInterval
        )
    }

    private func run<T>(_ work: @escaping () async -> T) -> T {
        let done = expectation(description: "async work completes")
        var result: T!
        Task { result = await work(); done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }

    private func assertFailure(_ result: Result<Void, BillingError>, _ expected: BillingError, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else { return XCTFail("expected .failure, got \(result)", file: file, line: line) }
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    private func assertSuccess(_ result: Result<Void, BillingError>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .success = result else { return XCTFail("expected .success, got \(result)", file: file, line: line) }
    }

    // MARK: - upgrade: checkout failure

    func testUpgradeCheckoutFailureNeverOpensOrPolls() {
        let clock = FakeClock()
        var openedURLs: [URL] = []
        var fetchCalls = 0
        let coordinator = makeCoordinator(
            fetchMe: { fetchCalls += 1; return .success(TierInfo(tier: .free, remainingThisMonth: 10)) },
            startCheckout: { .failure(.alreadyPro) },
            clock: clock
        )
        let result = run { await coordinator.upgrade(openURL: { openedURLs.append($0) }, onTierUpdate: { _ in }) }
        assertFailure(result, .alreadyPro)
        XCTAssertTrue(openedURLs.isEmpty, "checkout failed, so nothing should ever open a browser tab")
        XCTAssertEqual(fetchCalls, 0, "checkout failed, so no poll should ever start")
    }

    // MARK: - upgrade: checkout success, tier flips to Pro before the window ends

    func testUpgradeOpensURLAndStopsPollingAsSoonAsPro() {
        let clock = FakeClock()
        var openedURLs: [URL] = []
        var updates: [TierInfo] = []
        var fetchCalls = 0
        let coordinator = makeCoordinator(
            fetchMe: {
                fetchCalls += 1
                if fetchCalls < 3 { return .success(TierInfo(tier: .free, remainingThisMonth: 10)) }
                return .success(TierInfo(tier: .pro, remainingThisMonth: 3000))
            },
            startCheckout: { .success(self.checkoutURL) },
            clock: clock,
            pollDuration: 120,
            pollInterval: 5
        )
        let result = run {
            await coordinator.upgrade(openURL: { openedURLs.append($0) }, onTierUpdate: { updates.append($0) })
        }
        assertSuccess(result)
        XCTAssertEqual(openedURLs, [checkoutURL])
        XCTAssertEqual(fetchCalls, 3, "stops polling the instant it sees Pro, not at the full window")
        XCTAssertEqual(updates.map(\.tier), [.free, .free, .pro])
    }

    // MARK: - upgrade: tier never flips, poll stops at the deadline

    func testUpgradeStopsPollingAtTheDeadlineIfNeverPro() {
        let clock = FakeClock()
        var fetchCalls = 0
        let coordinator = makeCoordinator(
            fetchMe: { fetchCalls += 1; return .success(TierInfo(tier: .free, remainingThisMonth: 10)) },
            startCheckout: { .success(self.checkoutURL) },
            clock: clock,
            pollDuration: 20,
            pollInterval: 5
        )
        let result = run { await coordinator.upgrade(openURL: { _ in }, onTierUpdate: { _ in }) }
        assertSuccess(result)
        XCTAssertEqual(fetchCalls, 4, "20s window / 5s interval = 4 polls, then it gives up for this session")
    }

    // MARK: - upgrade: a failed poll is skipped, not reported, and polling continues

    func testUpgradePollFailureIsSkippedNotReportedAndPollingContinues() {
        let clock = FakeClock()
        var updates: [TierInfo] = []
        var fetchCalls = 0
        let coordinator = makeCoordinator(
            fetchMe: {
                fetchCalls += 1
                if fetchCalls == 1 { return .failure(.unreachable) }
                return .success(TierInfo(tier: .pro, remainingThisMonth: 3000))
            },
            startCheckout: { .success(self.checkoutURL) },
            clock: clock,
            pollDuration: 120,
            pollInterval: 5
        )
        _ = run { await coordinator.upgrade(openURL: { _ in }, onTierUpdate: { updates.append($0) }) }
        XCTAssertEqual(fetchCalls, 2, "a failed poll does not stop the loop")
        XCTAssertEqual(updates.count, 1, "only the successful poll is reported")
        XCTAssertEqual(updates.first?.tier, .pro)
    }

    // MARK: - manage subscription

    func testManageSubscriptionOpensPortalURL() {
        let clock = FakeClock()
        var openedURLs: [URL] = []
        let coordinator = makeCoordinator(startPortal: { .success(self.portalURL) }, clock: clock)
        let result = run { await coordinator.manageSubscription(openURL: { openedURLs.append($0) }) }
        assertSuccess(result)
        XCTAssertEqual(openedURLs, [portalURL])
    }

    func testManageSubscriptionNoCustomerNeverOpensAnything() {
        let clock = FakeClock()
        var openedURLs: [URL] = []
        let coordinator = makeCoordinator(startPortal: { .failure(.noCustomer) }, clock: clock)
        let result = run { await coordinator.manageSubscription(openURL: { openedURLs.append($0) }) }
        assertFailure(result, .noCustomer)
        XCTAssertTrue(openedURLs.isEmpty)
    }
}
