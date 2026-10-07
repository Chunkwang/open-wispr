import XCTest
@testable import OpenWisprLib

final class TranscriberTests: XCTestCase {

    func testArgumentsIncludeWhisperPromptAsSingleFollowingArgument() throws {
        let prompt = "  Use punctuation, keep product names like OpenWispr.  "
        let transcriber = Transcriber(
            modelSize: "base.en",
            language: "en",
            whisperPrompt: prompt
        )
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        let promptFlagIndex = try XCTUnwrap(args.firstIndex(of: "--prompt"))
        XCTAssertEqual(args[promptFlagIndex + 1], prompt)
        XCTAssertEqual(args.filter { $0 == prompt }.count, 1)
    }

    func testArgumentsOmitNilWhisperPrompt() {
        let transcriber = Transcriber(modelSize: "base.en", language: "en")
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        XCTAssertFalse(args.contains("--prompt"))
    }

    func testArgumentsOmitWhitespaceOnlyWhisperPrompt() {
        let transcriber = Transcriber(
            modelSize: "base.en",
            language: "en",
            whisperPrompt: " \n\t "
        )
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        XCTAssertFalse(args.contains("--prompt"))
    }

    func testArgumentsKeepSuppressRegexWhenSpokenPunctuationUsesPrompt() throws {
        let prompt = "Use punctuation and short sentences."
        let transcriber = Transcriber(
            modelSize: "base.en",
            language: "en",
            whisperPrompt: prompt
        )
        transcriber.spokenPunctuation = true

        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        let promptFlagIndex = try XCTUnwrap(args.firstIndex(of: "--prompt"))
        XCTAssertEqual(args[promptFlagIndex + 1], prompt)

        let suppressFlagIndex = try XCTUnwrap(args.firstIndex(of: "--suppress-regex"))
        XCTAssertEqual(args[suppressFlagIndex + 1], "[,\\.\\?!;:\\-—]")
    }

    func testBlankAudioMarker() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO]"), "")
    }

    func testBlankAudioWithWhitespace() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("  [BLANK_AUDIO]  "), "")
    }

    func testMultipleMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] [silence]"), "")
    }

    func testParenthesizedMarker() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("(BLANK_AUDIO)"), "")
    }

    func testNonSpeechEventMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[Music] [Applause]"), "")
    }

    func testMarkerMixedWithText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello [BLANK_AUDIO] world"), "hello world")
    }

    func testMarkerAtStartOfText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] hello"), "hello")
    }

    func testMarkerAtEndOfText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello [BLANK_AUDIO]"), "hello")
    }

    func testNormalTextUnchanged() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello world"), "hello world")
    }

    func testEmptyString() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(""), "")
    }

    func testUnknownBracketsPreserved() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("see [1] and (later)"), "see [1] and (later)")
    }

    func testKnownMarkerStrippedUnknownPreserved() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] see [1]"), "see [1]")
    }

    // MARK: - Expanded marker vocabulary / case-insensitivity

    func testBackgroundNoiseMarkerStripped() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[background noise]"), "")
    }

    func testCoughingMarkerStripped() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("(coughing)"), "")
    }

    func testTVMarkerStripped() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[TV]"), "")
    }

    func testDoorClosesMarkerStripped() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[door closes]"), "")
    }

    func testMixedCaseKnownMarkerStripped() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[Background Noise]"), "")
        XCTAssertEqual(Transcriber.stripWhisperMarkers("(Coughing)"), "")
    }

    func testUnknownBracketPhraseStillPreserved() {
        // Real-world whisper.cpp output we measured directly (base.en, silent audio
        // captured as low-level noise) that isn't in the fixed vocabulary — confirms
        // we don't silently over-broaden bracket matching.
        XCTAssertEqual(Transcriber.stripWhisperMarkers("(machinery whirring)"), "(machinery whirring)")
    }

    // MARK: - Bare unbracketed hallucinations (whisper's classic silence failure mode)
    //
    // "you", "thanks"/"thank you"(-family), and "bye"(-family) were removed from
    // hallucinationOnlyPhrases after a real acceptance pass on real whisper-cli output
    // confirmed they're plausible complete real dictations (e.g. a one-word chat
    // reply) and were being silently suppressed to empty text with zero user
    // feedback — indistinguishable from true silence. The tests below now assert the
    // opposite: these words survive as real output. Only unambiguous YouTube-outro/
    // caption-style phrases with no legitimate-dictation collision risk remain in the
    // filter.

    func testBareYouSurvivesAsRealDictation() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(" you"), "you")
    }

    func testBareThankYouSurvivesAsRealDictation() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(" Thank you."), "Thank you.")
    }

    func testBareThanksSurvivesAsRealDictation() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(" Thanks."), "Thanks.")
    }

    func testBareByeSurvivesAsRealDictation() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(" Bye."), "Bye.")
    }

    func testBareGoodbyeSurvivesAsRealDictation() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(" Goodbye."), "Goodbye.")
    }

    func testBareThanksForWatchingHallucinationStripped() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("Thanks for watching!"), "")
    }

    func testBareThankYouForWatchingHallucinationStripped() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(" Thank you for watching."), "")
    }

    func testBarePleaseSubscribeHallucinationStripped() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(" Please subscribe."), "")
    }

    func testBareSubscribeToMyChannelHallucinationStripped() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(" Subscribe to my channel."), "")
    }

    func testBareSeeYouNextTimeHallucinationStripped() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(" See you next time."), "")
    }

    func testPunctuationOnlyOutputStripped() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("."), "")
        XCTAssertEqual(Transcriber.stripWhisperMarkers("..."), "")
        XCTAssertEqual(Transcriber.stripWhisperMarkers("?!"), "")
    }

    func testHallucinationPhraseCaseInsensitive() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("PLEASE SUBSCRIBE."), "")
    }

    func testLegitimateSentenceContainingThankYouNotStripped() {
        // "thank you" appears inside a real, longer dictation — must survive.
        let real = "Please remember to send the quarterly report to finance before Friday, and thank you for reviewing the numbers carefully."
        XCTAssertEqual(Transcriber.stripWhisperMarkers(real), real)
    }

    func testLegitimateSentenceStartingWithThankYouNotStripped() {
        let real = "Thank you so much for helping me move the couch last weekend, it made a huge difference."
        XCTAssertEqual(Transcriber.stripWhisperMarkers(real), real)
    }

    func testLegitimateSentenceEndingInByeWordNotStripped() {
        let real = "I said goodbye to my coworkers before leaving for the airport."
        XCTAssertEqual(Transcriber.stripWhisperMarkers(real), real)
    }

    func testCombinedMarkerAndHallucinationHandledTogether() {
        // Bracket marker stripped first; remaining bare phrase then caught by the
        // hallucination filter.
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] thanks for watching"), "")
    }

    func testCombinedMarkerWithNowSurvivingBarePhraseKeepsText() {
        // "bye" is no longer in the hallucination list, so once the bracket marker is
        // stripped, the remaining real word must survive.
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] bye"), "bye")
    }

    // MARK: - Arguments include the decoder-level non-speech suppression flag

    func testArgumentsIncludeSuppressNonSpeechTokens() {
        let transcriber = Transcriber(modelSize: "base.en", language: "en")
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )
        XCTAssertTrue(args.contains("--suppress-nst"))
    }

    // MARK: - bundledBackendPath: GGML_BACKEND_PATH resolution (Task 8.2 follow-up)
    //
    // whisper.cpp dlopen()s its compute backend from a plugin file bundle-app.sh
    // embeds at Contents/Frameworks/ggml-backends/ inside the app. This must be
    // set only when that file actually exists -- an unbundled dev/test run (no
    // app bundle structure at all) must leave the environment untouched so
    // whisper-cli falls through to its own Homebrew-fallback resolution exactly
    // as it does today. Setting it to a path that doesn't exist is strictly worse
    // than not setting it, since ggml dlopen()s the value directly with no
    // fallback scan.

    func testBundledBackendPathReturnsPathWhenBackendFileExists() {
        let path = Transcriber.bundledBackendPath(
            bundlePath: "/Applications/Murmur.app",
            fileExists: { candidate in
                candidate == "/Applications/Murmur.app/Contents/Frameworks/ggml-backends/libggml-cpu-apple_m1.so"
            }
        )
        XCTAssertEqual(path, "/Applications/Murmur.app/Contents/Frameworks/ggml-backends/libggml-cpu-apple_m1.so")
    }

    func testBundledBackendPathReturnsNilWhenUnbundled() {
        // Simulates `scripts/dev.sh` / `swift test` / a bare `.build/release/open-wispr`
        // binary, where Bundle.main has no Contents/Frameworks structure at all.
        let path = Transcriber.bundledBackendPath(
            bundlePath: "/Users/dev/repo/.build/release",
            fileExists: { _ in false }
        )
        XCTAssertNil(path)
    }

    func testBundledBackendPathReturnsNilWhenAppBundleLacksEmbeddedBackend() {
        // A bundle built before Task 8.2's fix, or missing the plugin for some
        // other reason -- must not fabricate a path that isn't actually there.
        let path = Transcriber.bundledBackendPath(
            bundlePath: "/Applications/Murmur.app",
            fileExists: { _ in false }
        )
        XCTAssertNil(path)
    }

    // MARK: - resolveOutput: exit-code / stdout / stderr success-failure decision
    //
    // whisper-cli's argument parser doesn't fail on an unrecognized flag: it exits 0
    // with empty stdout and an "unknown argument" usage dump on stderr. That must be
    // distinguished from legitimate silence (also empty stdout, but empty stderr too).

    func testResolveOutputReturnsTextOnNormalSuccess() throws {
        let result = try Transcriber.resolveOutput(
            terminationStatus: 0,
            rawStdout: "hello world",
            stderr: ""
        )
        XCTAssertEqual(result, "hello world")
    }

    func testResolveOutputEmptyStdoutAndEmptyStderrIsLegitimateSilence() throws {
        // Real no-speech audio: whisper-cli exits 0, has nothing to say, and prints
        // nothing to stderr either. Must keep succeeding with "".
        let result = try Transcriber.resolveOutput(
            terminationStatus: 0,
            rawStdout: "",
            stderr: ""
        )
        XCTAssertEqual(result, "")
    }

    func testResolveOutputWhitespaceOnlyStdoutAndEmptyStderrIsLegitimateSilence() throws {
        let result = try Transcriber.resolveOutput(
            terminationStatus: 0,
            rawStdout: "   \n  ",
            stderr: ""
        )
        XCTAssertEqual(result, "")
    }

    func testResolveOutputBlankAudioMarkerWithEmptyStderrIsLegitimateSilence() throws {
        // stdout has content, but it's entirely a known hallucination marker that
        // stripWhisperMarkers reduces to "" — still a legitimate non-error result.
        let result = try Transcriber.resolveOutput(
            terminationStatus: 0,
            rawStdout: "[BLANK_AUDIO]",
            stderr: ""
        )
        XCTAssertEqual(result, "")
    }

    func testResolveOutputThrowsOnNonZeroExitStatus() {
        XCTAssertThrowsError(
            try Transcriber.resolveOutput(terminationStatus: 1, rawStdout: "", stderr: "boom")
        ) { error in
            XCTAssertEqual(error as? TranscriberError, .transcriptionFailed)
        }
    }

    func testResolveOutputThrowsWhenExitZeroWithEmptyStdoutButNonEmptyStderr() {
        // The bug this guards against: whisper-cli rejects an unrecognized flag,
        // prints an error + usage dump to stderr, produces empty stdout, and still
        // exits 0. Must be caught as a failure, not returned as "no speech detected".
        XCTAssertThrowsError(
            try Transcriber.resolveOutput(
                terminationStatus: 0,
                rawStdout: "",
                stderr: "error: unknown argument: --suppress-nst\nusage: whisper-cli [options] file0.wav file1.wav ..."
            )
        ) { error in
            XCTAssertEqual(error as? TranscriberError, .transcriptionFailed)
        }
    }

    func testResolveOutputThrowsWhenExitZeroWithWhitespaceOnlyStdoutButNonEmptyStderr() {
        XCTAssertThrowsError(
            try Transcriber.resolveOutput(
                terminationStatus: 0,
                rawStdout: "  \n  ",
                stderr: "error: unknown argument: --bogus-flag"
            )
        ) { error in
            XCTAssertEqual(error as? TranscriberError, .transcriptionFailed)
        }
    }

    func testResolveOutputReturnsTextWhenStderrHasWarningButStdoutHasRealOutput() throws {
        // A non-fatal stderr warning alongside real transcribed text must not be
        // treated as failure — only an EMPTY final output combined with stderr is.
        let result = try Transcriber.resolveOutput(
            terminationStatus: 0,
            rawStdout: "hello world",
            stderr: "warning: some non-fatal whisper-cli warning"
        )
        XCTAssertEqual(result, "hello world")
    }
}
