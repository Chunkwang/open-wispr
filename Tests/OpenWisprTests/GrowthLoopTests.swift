import XCTest
@testable import OpenWisprLib

/// Unit tests for Stage 7 Growth Loop (Task 7.1 & Task 7.2):
/// In-memory before/after pair storage & formatted snippet generation.
final class GrowthLoopTests: XCTestCase {

    func testFormatBeforeAfterSnippet() {
        let raw = "um yeah so hello world"
        let rewritten = "Hello world."

        let formatted = Copy.formatBeforeAfter(raw: raw, rewritten: rewritten)

        XCTAssertTrue(formatted.contains("Raw:"))
        XCTAssertTrue(formatted.contains("um yeah so hello world"))
        XCTAssertTrue(formatted.contains("Rewritten:"))
        XCTAssertTrue(formatted.contains("Hello world."))
    }

    func testCopyBeforeAfterMenuTitlesConformToVoiceGuide() {
        let titles = [Copy.menuCopyBeforeAfter, Copy.menuCopiedBeforeAfter]
        for title in titles {
            let lower = title.lowercased()
            for banned in CopyLint.banned {
                XCTAssertFalse(lower.contains(banned), "Title contains banned word '\(banned)': \(title)")
            }
            XCTAssertFalse(title.contains("!"), "Title contains exclamation mark: \(title)")
        }
    }
}
