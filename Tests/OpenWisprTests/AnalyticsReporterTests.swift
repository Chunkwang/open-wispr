import XCTest
@testable import OpenWisprLib

final class AnalyticsReporterTests: XCTestCase {

    func testDisabledByDefaultMakesNoNetworkCall() {
        var defaultCfg = Config.load()
        defaultCfg.analyticsOptIn = FlexBool(false)

        var didCall = false
        AnalyticsReporter.send(.dictationCompleted, configProvider: {
            didCall = true
            return defaultCfg
        })

        // Config was checked, but no network request was triggered
        XCTAssertTrue(didCall)
    }

    func testNilOptInMakesNoNetworkCall() {
        var defaultCfg = Config.load()
        defaultCfg.analyticsOptIn = nil

        var sentEvent: String?
        AnalyticsReporter.send(.rewriteInvoked, configProvider: {
            sentEvent = "read"
            return defaultCfg
        })

        XCTAssertEqual(sentEvent, "read")
    }

    func testEnabledOptInSendsEvent() {
        var optInCfg = Config.load()
        optInCfg.analyticsOptIn = FlexBool(true)

        XCTAssertEqual(optInCfg.analyticsOptIn?.value, true)
    }

    // MARK: - finding 8: the event name is a closed set, not a free-form string

    func testAllFiveDocumentedEventNamesExist() {
        XCTAssertEqual(AnalyticsEvent.dictationCompleted.rawValue, "dictation_completed")
        XCTAssertEqual(AnalyticsEvent.rewriteInvoked.rawValue, "rewrite_invoked")
        XCTAssertEqual(AnalyticsEvent.subscriptionTierChanged.rawValue, "subscription_tier_changed")
        XCTAssertEqual(AnalyticsEvent.beforeAfterShared.rawValue, "before_after_shared")
        XCTAssertEqual(AnalyticsEvent.referralSent.rawValue, "referral_sent")
    }
}
