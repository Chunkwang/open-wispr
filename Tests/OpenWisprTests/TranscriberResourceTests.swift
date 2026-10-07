import XCTest
@testable import OpenWisprLib

// Regression test for a real fd leak found by running Transcriber.transcribe
// in a tight loop (50+ iterations) and watching the process's own open file
// descriptor count: each call spawns a fresh whisper-cli Process (there is no
// warm server, see Transcriber.swift's header comment), and
// `readDataToEndOfFile()` reads a pipe's data to EOF without ever closing the
// descriptor itself. Before the fix, every single call leaked exactly 2 fds
// (the stdout and stderr pipes' read ends); over a full day of real dictation
// that slow, linear leak eventually exhausts the process's fd table. Follows
// OfflineDictationTests' pattern: a real integration test against the real
// whisper-cli binary, skipped (not failed) when either isn't installed, so it
// still runs for real wherever the full suite already does.
final class TranscriberResourceTests: XCTestCase {

    func testRepeatedTranscribeDoesNotLeakFileDescriptors() throws {
        guard Transcriber.findWhisperBinary() != nil else {
            throw XCTSkip("whisper-cli not installed; install with: brew install whisper-cpp")
        }
        guard let modelSize = Self.firstAvailableModelSize() else {
            throw XCTSkip("no whisper model found in any standard location; run the app once to download one")
        }

        let audioURL = try Self.writeSilentWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcriber = Transcriber(modelSize: modelSize)

        func openFileDescriptorCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
        }

        // One untimed warm-up call so any one-time setup (e.g. the model's
        // first mmap) doesn't show up as "leaked" fd noise in the measured
        // range below.
        _ = try transcriber.transcribe(audioURL: audioURL)

        let before = openFileDescriptorCount()
        let iterations = 30
        for _ in 0..<iterations {
            _ = try transcriber.transcribe(audioURL: audioURL)
        }
        let after = openFileDescriptorCount()

        // A per-call leak of N fds would show up as growth of roughly
        // N * iterations here (confirmed: exactly 2 * iterations before the
        // fix). Allow a small constant margin for incidental fds (e.g. the
        // stderr-reading Thread's own bookkeeping) that don't scale with
        // iteration count.
        XCTAssertLessThan(
            after - before, 5,
            "fd count grew by \(after - before) over \(iterations) transcribe() calls (before=\(before), after=\(after)) -- likely a per-call descriptor leak"
        )
    }

    private static func firstAvailableModelSize() -> String? {
        for size in ["tiny.en", "base.en", "base"] {
            if Transcriber.modelExists(modelSize: size) {
                return size
            }
        }
        return nil
    }

    // Same hand-built silent-WAV approach as OfflineDictationTests, duplicated
    // rather than shared so this file has no dependency on that one's private
    // helper, and can run standalone with --filter.
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
        func appendASCII(_ s: String) {
            data.append(contentsOf: s.utf8)
        }

        appendASCII("RIFF")
        appendLE(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(channels)
        appendLE(sampleRate)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        appendLE(byteRate)
        let blockAlign = channels * (bitsPerSample / 8)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        appendASCII("data")
        appendLE(dataSize)
        data.append(Data(count: Int(dataSize)))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-resource-test-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }
}
