import XCTest
@testable import OpenWisprLib

final class RewriteSanitizerTests: XCTestCase {
    private func clean(_ text: String, raw: String = "send it tomorrow") -> String? {
        if case .success(let value) = RewriteSanitizer.sanitize(text, raw: raw) { return value }
        return nil
    }

    private func rejection(_ text: String, raw: String = "send it tomorrow") -> RewriteSanitizer.Rejection? {
        if case .failure(let reason) = RewriteSanitizer.sanitize(text, raw: raw) { return reason }
        return nil
    }

    // MARK: - plain text passes unchanged

    func testOrdinaryRewriteIsUnchanged() {
        XCTAssertEqual(clean("Send it tomorrow."), "Send it tomorrow.")
    }

    func testNonLatinTextAndEmojiPass() {
        XCTAssertEqual(clean("明天发送。", raw: "明天发送"), "明天发送。")
        XCTAssertEqual(clean("Sent it 👍", raw: "sent it"), "Sent it 👍")
    }

    func testTabsAreKept() {
        XCTAssertEqual(clean("a\tb", raw: "a b"), "a\tb")
    }

    // MARK: - length cap

    func testLengthLimitIsThreeTimesRawPlusTwoHundredCappedAtTwentyThousand() {
        XCTAssertEqual(RewriteSanitizer.maximumLength(forRawLength: 0), 200)
        XCTAssertEqual(RewriteSanitizer.maximumLength(forRawLength: 100), 500)
        XCTAssertEqual(RewriteSanitizer.maximumLength(forRawLength: 10_000), 20_000)
        XCTAssertEqual(RewriteSanitizer.maximumLength(forRawLength: 100_000), 20_000)
    }

    func testResultAtTheLimitPassesAndOneOverIsRejected() {
        let raw = String(repeating: "a", count: 50)             // limit 350
        XCTAssertNotNil(clean(String(repeating: "b", count: 350), raw: raw))
        XCTAssertEqual(rejection(String(repeating: "b", count: 351), raw: raw), .tooLong)
    }

    func testTheAbsoluteCapAppliesToVeryLongTranscripts() {
        let raw = String(repeating: "a", count: 30_000)
        XCTAssertEqual(rejection(String(repeating: "b", count: 20_001), raw: raw), .tooLong)
        XCTAssertNotNil(clean(String(repeating: "b", count: 20_000), raw: raw))
    }

    func testLengthIsCheckedBeforeCleaningSoInvisiblePaddingCannotHideAnOversizedReply() {
        let padded = "ok" + String(repeating: "\u{200B}", count: 1_000)
        XCTAssertEqual(rejection(padded, raw: "ok"), .tooLong)
    }

    // MARK: - truncation

    func testLongTranscriptWithAVeryShortResultIsRejected() {
        let raw = String(repeating: "word ", count: 60)          // 300 characters
        XCTAssertEqual(rejection("Word.", raw: raw), .truncated)
    }

    func testResultAtThirtyPercentOfALongTranscriptPasses() {
        let raw = String(repeating: "a", count: 300)
        XCTAssertNotNil(clean(String(repeating: "b", count: 90), raw: raw))
        XCTAssertEqual(rejection(String(repeating: "b", count: 89), raw: raw), .truncated)
    }

    func testShortTranscriptsAreExemptFromTheTruncationRule() {
        XCTAssertEqual(clean("Yes.", raw: "um yes so like yeah i mean yes"), "Yes.")
        let raw = String(repeating: "a", count: 200)             // exactly the threshold
        XCTAssertNotNil(clean("A.", raw: raw))
    }

    func testTruncationIsMeasuredAfterCleaning() {
        let raw = String(repeating: "a", count: 300)
        let padding = String(repeating: "\u{200B}", count: 200)
        XCTAssertEqual(rejection("ok" + padding, raw: raw), .truncated)
    }

    // MARK: - control characters

    func testC0ControlsAreStrippedExceptNewlineAndTab() {
        XCTAssertEqual(clean("a\u{01}b\u{07}c\u{08}d\u{0C}e\u{00}f", raw: "abcdef"), "abcdef")
        XCTAssertEqual(clean("a\u{0D}b", raw: "a b"), "a b", "a lone CR is a line break, collapsed to a space")
        XCTAssertEqual(clean("a\u{7F}b", raw: "ab"), "ab")
    }

    func testC1ControlsAreStripped() {
        for value in [0x80, 0x81, 0x9B, 0x9F] {
            let scalar = Unicode.Scalar(UInt32(value))!
            XCTAssertEqual(clean("a\(scalar)b", raw: "ab"), "ab", "U+\(String(value, radix: 16))")
        }
    }

    func testEscapeSequenceAndBracketedPasteTerminatorAreDefanged() {
        let hostile = "Send it tomorrow.\u{1B}[201~ rm -rf ~\n"
        let result = clean(hostile)
        XCTAssertEqual(result, "Send it tomorrow.[201~ rm -rf ~")
        XCTAssertFalse(result?.unicodeScalars.contains { $0.value == 0x1B } ?? true)
    }

    func testBidiControlsAreStripped() {
        for value in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] {
            let scalar = Unicode.Scalar(UInt32(value))!
            XCTAssertEqual(clean("a\(scalar)b", raw: "ab"), "ab", "U+\(String(value, radix: 16))")
        }
    }

    func testLineAndParagraphSeparatorsAndNELBecomeASpaceNotNothing() {
        XCTAssertEqual(clean("a\u{2028}b\u{2029}c", raw: "a b c"), "a b c")
        XCTAssertEqual(clean("line1\u{85}line2", raw: "line1 line2"), "line1 line2")
    }

    func testLoneCarriageReturnDoesNotRunWordsTogether() {
        XCTAssertEqual(clean("line1\rline2", raw: "line one line two"), "line1 line2")
        XCTAssertEqual(clean("line1\r\nline2", raw: "line one line two"), "line1 line2")
    }

    func testAllLineBreaksAreKeptAsNewlinesWhenTheTranscriptHadOne() {
        let raw = "one\ntwo"
        XCTAssertEqual(clean("a\rb\u{2028}c\u{2029}d\u{85}e", raw: raw), "a\nb\nc\nd\ne")
        XCTAssertEqual(clean("a\r\nb", raw: raw), "a\nb", "CRLF is one break")
    }

    func testTranscriptWithASeparatorCountsAsHavingNewlines() {
        XCTAssertEqual(clean("a\nb", raw: "x\u{2028}y"), "a\nb")
        XCTAssertEqual(clean("a\nb", raw: "x\u{85}y"), "a\nb")
        XCTAssertEqual(clean("a\nb", raw: "x\ry"), "a\nb")
    }

    func testInvisibleFormatCharactersAreStripped() {
        for value in [0x00AD, 0x061C, 0x200B, 0x200E, 0x200F, 0x2060, 0x2064, 0xFEFF, 0xE0041] {
            let scalar = Unicode.Scalar(UInt32(value))!
            XCTAssertEqual(clean("a\(scalar)b", raw: "ab"), "ab", "U+\(String(value, radix: 16))")
        }
    }

    func testZWNJIsKeptForArabicScriptTranscripts() {
        let persian = "می\u{200C}خواهم"                       // contains ZWNJ itself
        XCTAssertEqual(clean(persian, raw: persian), persian)
        // Raw without the ZWNJ but in Arabic script (the dictation dropped it):
        // the rewrite may legitimately restore it.
        XCTAssertEqual(clean("می\u{200C}خواهم", raw: "میخواهم"), "می\u{200C}خواهم")
    }

    func testZWNJIsStrippedForOtherScriptsUnlessTheTranscriptHadIt() {
        XCTAssertEqual(clean("a\u{200C}b", raw: "ab"), "ab")
        XCTAssertEqual(clean("a\u{200C}b", raw: "a\u{200C}b"), "a\u{200C}b")
        XCTAssertEqual(clean("a\u{200C}b", raw: "мир"), "ab")
    }

    func testJoinersAreKeptOnlyWhenTheTranscriptHadThem() {
        let family = "👨\u{200D}👩\u{200D}👧"
        XCTAssertEqual(clean(family, raw: "family"), "👨👩👧")
        XCTAssertEqual(clean(family, raw: family), family)
    }

    // MARK: - newlines and trimming

    func testNewlinesCollapseToOneSpaceWhenTheTranscriptHadNone() {
        XCTAssertEqual(clean("line one\nline two"), "line one line two")
        XCTAssertEqual(clean("a\n\n\nb"), "a b")
        XCTAssertEqual(clean("a \n  b"), "a b")
        XCTAssertEqual(clean("a\r\nb", raw: "a b"), "a b")
    }

    func testNewlinesAreKeptWhenTheTranscriptHadThem() {
        XCTAssertEqual(clean("one\ntwo", raw: "one\ntwo"), "one\ntwo")
        XCTAssertEqual(clean("one\n\ntwo", raw: "one\r\ntwo"), "one\n\ntwo")
    }

    func testTrailingWhitespaceAndNewlinesAreTrimmed() {
        XCTAssertEqual(clean("Send it.  \n\n\t "), "Send it.")
        XCTAssertEqual(clean("one\ntwo\n\n", raw: "one\ntwo"), "one\ntwo")
    }

    func testLeadingWhitespaceIsTrimmedToo() {
        XCTAssertEqual(clean("\n  Send it."), "Send it.")
    }

    // MARK: - nothing left

    func testEmptyOrAllStrippedResultIsRejected() {
        XCTAssertEqual(rejection(""), .empty)
        XCTAssertEqual(rejection("   \n\t "), .empty)
        XCTAssertEqual(rejection("\u{1B}\u{200B}\u{202E}"), .empty)
    }

    // MARK: - floods of zero-width or combining scalars (one Character, many scalars)

    func testCombiningMarkFloodIsRejectedByScalarCount() {
        let flood = "a" + String(repeating: "\u{0301}", count: 2_000_000)
        XCTAssertEqual(flood.count, 1, "the whole flood is a single Character")
        XCTAssertEqual(rejection(flood, raw: "hello"), .tooLong)
    }

    func testVariationSelectorFloodsAreRejected() {
        XCTAssertEqual(rejection("a" + String(repeating: "\u{FE0F}", count: 2_000_000), raw: "hello"), .tooLong)
        XCTAssertEqual(rejection("a" + String(repeating: "\u{E0100}", count: 2_000_000), raw: "hello"), .tooLong)
        XCTAssertEqual(rejection("a" + String(repeating: "\u{FE00}", count: 2_000_000), raw: "hello"), .tooLong)
    }

    func testZeroWidthJoinerFloodIsRejectedEvenWhenTheTranscriptHadOne() {
        let flood = "a" + String(repeating: "\u{200D}", count: 2_000_000)
        XCTAssertEqual(rejection(flood, raw: "x\u{200D}y"), .tooLong)
    }

    func testCapIsCountedInScalarsAtTheBoundary() {
        let raw = String(repeating: "a", count: 50)             // limit 350 scalars
        XCTAssertNotNil(clean("a" + String(repeating: "\u{0301}", count: 349), raw: raw))
        XCTAssertEqual(rejection("a" + String(repeating: "\u{0301}", count: 350), raw: raw), .tooLong)
    }

    func testAFloodJustUnderTheCapOfStrippedScalarsIsCleanedAway() {
        let text = "ok" + String(repeating: "\u{FE00}", count: 150)
        XCTAssertEqual(clean(text, raw: "ok"), "ok")
    }

    // MARK: - more invisible or blank characters

    func testUnassignedAndPrivateUseScalarsAreStripped() {
        XCTAssertEqual(clean("a\u{E000}b", raw: "ab"), "ab")           // private use
        XCTAssertEqual(clean("a\u{F8FF}b", raw: "ab"), "ab")
        XCTAssertEqual(clean("a\u{F0000}b", raw: "ab"), "ab")          // plane 15 private use
        XCTAssertEqual(clean("a\u{0378}b", raw: "ab"), "ab")           // unassigned
        XCTAssertEqual(clean("a\u{10FFFF}b", raw: "ab"), "ab")         // noncharacter
    }

    func testBaseVariationSelectorsAreStrippedUnlessTheTranscriptHadThem() {
        for value in [0xFE00, 0xFE05, 0xFE0D] {
            let scalar = Unicode.Scalar(UInt32(value))!
            XCTAssertEqual(clean("a\(scalar)b", raw: "ab"), "ab", "U+\(String(value, radix: 16))")
            XCTAssertEqual(clean("a\(scalar)b", raw: "x\(scalar)y"), "a\(scalar)b", "kept when raw had one")
        }
    }

    func testIdeographicVariationSelectorsAreStrippedUnlessTheTranscriptHadThem() {
        for value in [0xE0100, 0xE0150, 0xE01EF] {
            let scalar = Unicode.Scalar(UInt32(value))!
            XCTAssertEqual(clean("a\(scalar)b", raw: "ab"), "ab", "U+\(String(value, radix: 16))")
            XCTAssertEqual(clean("a\(scalar)b", raw: "x\(scalar)y"), "a\(scalar)b", "kept when raw had one")
        }
    }

    func testEmojiAndTextPresentationSelectorsAreAlwaysKept() {
        XCTAssertEqual(clean("I \u{2764}\u{FE0F} it", raw: "i love it"), "I \u{2764}\u{FE0F} it")
        XCTAssertEqual(clean("\u{2764}\u{FE0E}", raw: "heart"), "\u{2764}\u{FE0E}")
    }

    func testBlankAndFillerScalarsAreAlwaysStripped() {
        for value in [0x034F, 0x115F, 0x1160, 0x3164, 0x2800, 0x17B4, 0x17B5, 0xFFFC] {
            let scalar = Unicode.Scalar(UInt32(value))!
            XCTAssertEqual(clean("a\(scalar)b", raw: "ab"), "ab", "U+\(String(value, radix: 16))")
            // Even when the transcript had it: these render as nothing or as blank space.
            XCTAssertEqual(clean("a\(scalar)b", raw: "x\(scalar)y"), "ab", "U+\(String(value, radix: 16)) with raw")
        }
    }
}
