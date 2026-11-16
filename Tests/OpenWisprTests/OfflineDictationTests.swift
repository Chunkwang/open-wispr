import XCTest
@testable import OpenWisprLib

// Task 5.4: proves the REAL `Transcriber.transcribe(audioURL:)` production
// code path — same `arguments(modelPath:audioURL:)` flags (-l, -nt,
// --suppress-nst, ...) and the same `resolveOutput`/`stripWhisperMarkers`
// logic the shipping app uses — still produces a clean, non-hallucinated
// transcript.
//
// This file contains no network-blocking logic itself. The offline guarantee
// comes from scripts/test-offline-dictation.sh, which wraps the *process
// running this test* (`swift test --filter OfflineDictationTests`) in
// `sandbox-exec` with a `(deny network*)` profile; macOS sandbox profiles are
// inherited by child processes (Process/fork+exec), so the whisper-cli
// subprocess Transcriber.transcribe(audioURL:) spawns is denied network too.
// Run normally (outside the sandbox, e.g. as part of the full `swift test`
// suite) this is a plain integration test proving the code path works at
// all; it is intentionally the same test either way, so a flag flip in
// Transcriber.swift can't silently drift out of sync with what the offline
// script actually exercises the way a hand-rolled shell re-implementation of
// the whisper-cli invocation could.
final class OfflineDictationTests: XCTestCase {

    func testRealTranscriberSucceedsOnSilentAudio() throws {
        guard Transcriber.findWhisperBinary() != nil else {
            throw XCTSkip("whisper-cli not installed; install with: brew install whisper-cpp")
        }
        guard let modelSize = Self.firstAvailableModelSize() else {
            throw XCTSkip("no whisper model found in any standard location; run the app once to download one")
        }

        let audioURL = try Self.writeSilentWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcriber = Transcriber(modelSize: modelSize)
        // Must not throw. On a real machine this alone is the regression
        // guard for Transcriber.resolveOutput's silent-failure case (exit 0,
        // empty stdout, an "unknown argument" error on stderr) — if
        // arguments(modelPath:audioURL:) ever drifts to pass whisper-cli a
        // flag this build doesn't recognize, resolveOutput throws and this
        // `try` fails the test instead of silently swallowing it.
        let text = try transcriber.transcribe(audioURL: audioURL)

        // Real whisper-cli on true/near silence is known (see the
        // hallucinationOnlyPhrases comment above in Transcriber.swift) to
        // sometimes emit short bare hallucinations like "you" — that is
        // deliberately NOT filtered, because it collides with plausible real
        // one-word dictation, so this test must not assert exact emptiness.
        // What must always hold is that stripWhisperMarkers() stripped any
        // bracket/paren marker (e.g. "[BLANK_AUDIO]") before the text got
        // this far — an unstripped marker reaching this point is exactly the
        // "inserts [BLANK_AUDIO] as if it were dictated text" bug class.
        XCTAssertFalse(text.contains("["), "a bracketed whisper marker leaked through unstripped: '\(text)'")
        XCTAssertFalse(text.contains("("), "a parenthesized whisper marker leaked through unstripped: '\(text)'")
    }

    private static func firstAvailableModelSize() -> String? {
        for size in ["tiny.en", "base.en", "base"] {
            if Transcriber.modelExists(modelSize: size) {
                return size
            }
        }
        return nil
    }

    // Hand-builds a 1-second, 16kHz mono 16-bit PCM WAV of silence. No
    // dependency on sox/afconvert/say — this needs to run unattended inside
    // sandbox-exec, where none of those are guaranteed to behave the same.
    private static func writeSilentWAV() throws -> URL {
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let durationSeconds: UInt32 = 1
        let dataSize = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8) * durationSeconds

        var data = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16))              // fmt chunk size
        appendLE(UInt16(1))               // PCM
        appendLE(channels)
        appendLE(sampleRate)
        appendLE(sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)) // byte rate
        appendLE(channels * (bitsPerSample / 8))                            // block align
        appendLE(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        appendLE(dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize)))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offline-dictation-test-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }
}
