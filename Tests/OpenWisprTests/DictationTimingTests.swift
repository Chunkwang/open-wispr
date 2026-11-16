import XCTest
@testable import OpenWisprLib

final class DictationTimingTests: XCTestCase {

    func testNewTokenIsNonEmpty() {
        XCTAssertFalse(DictationTiming.newToken().isEmpty)
    }

    func testNewTokenIsNotConstant() {
        // Not a strict uniqueness guarantee, just a smoke check that this
        // isn't a hardcoded string.
        let a = DictationTiming.newToken()
        let b = DictationTiming.newToken()
        XCTAssertNotEqual(a, b)
    }

    func testMarkDoesNotThrowOrCrashForEveryStageWithARealToken() {
        let token = DictationTiming.newToken()
        for stage: DictationTiming.Stage in [.keyDown, .frameGrab, .asrStart, .asrDone, .cleanupDone, .pasteDone] {
            DictationTiming.mark(token, stage)
        }
    }

    func testMarkDoesNotThrowOrCrashForNilToken() {
        // `token` is nil whenever a call site has nothing to correlate with
        // yet (e.g. TextInserter.insert's default). Must still just log.
        DictationTiming.mark(nil, .pasteDone)
    }

    func testMarkDoesNotThrowOrCrashForEmptyStringToken() {
        DictationTiming.mark("", .asrStart)
    }

    func testMarkDoesNotThrowOrCrashWithDetail() {
        DictationTiming.mark("abc123", .asrDone, detail: "ok")
        DictationTiming.mark("abc123", .asrDone, detail: "error")
        DictationTiming.mark("abc123", .asrDone, detail: "")
    }

    func testMarkUsesInjectedClockWithoutCrashing() {
        DictationTiming.mark("abc123", .keyDown, now: { 0 })
        DictationTiming.mark("abc123", .keyDown, now: { .infinity })
        DictationTiming.mark("abc123", .keyDown, now: { .nan })
    }
}
