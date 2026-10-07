import XCTest
@testable import OpenWisprLib

/// Permanent regression coverage for whisper-cli's REAL hallucination behavior on
/// silence and background noise.
///
/// This is deliberately different from `TranscriberTests.swift`: that file only
/// exercises `stripWhisperMarkers` / `isHallucinationOnly` / `resolveOutput` as pure
/// functions with hand-fed strings, which can never catch a change in whisper-cli's
/// actual decoder (a `brew upgrade whisper-cpp`, a removed `--suppress-nst`, a model
/// swap). This file shells out through the real `Transcriber.transcribe(audioURL:)`
/// path to the real installed whisper-cli binary and a real model.
///
/// Why this exists: the original hallucination fix (commit f2ebd24, "Fix whisper
/// hallucination on silence/noise...") was measured once, by hand, against
/// synthetic `say`-generated audio, with the numbers reported in chat and never
/// checked in. An outside technical reviewer correctly pointed out that
/// whisper-family models regress on this constantly as flags, model versions, and
/// VAD settings change — this file makes that measurement permanent and automatic
/// instead of a one-off nobody re-runs.
///
/// Fixtures are generated at test-run time and are NOT checked into the repo. That
/// matches this codebase's existing convention: `scripts/test-transcription.sh`
/// (the only other place that exercises real whisper-cli) generates its audio the
/// same way, via macOS `say` + `afconvert`, and no binary audio fixtures exist
/// anywhere under Tests/ today. True-silence and noise fixtures don't need `say` at
/// all, so they're written directly as tiny synthetic 16kHz mono PCM WAVs (a couple
/// of KB each) instead of shelling out.
///
/// Skips cleanly (does not fail the suite) on a machine without whisper-cli or
/// without the model downloaded — the same convention `Transcriber.findWhisperBinary()`
/// / `modelExists(modelSize:)` already encode, and the same `XCTSkip` pattern
/// `FoundationModelsPipelineTests.swift` uses for its own live-hardware-only tests.
final class HallucinationRegressionTests: XCTestCase {

    // The shipped default (decision D6) — not a quantized variant. If this ever
    // needs to change, change it here with a comparison, per the project's "don't
    // silently diverge from upstream's tested default" rule.
    private static let modelSize = "base.en"

    private var fixtureDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallucination-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureDir {
            try? FileManager.default.removeItem(at: fixtureDir)
        }
        try super.tearDownWithError()
    }

    private func skipIfWhisperUnavailable() throws {
        guard Transcriber.findWhisperBinary() != nil else {
            throw XCTSkip("whisper-cli not installed on this machine (brew install whisper-cpp)")
        }
        guard Transcriber.modelExists(modelSize: Self.modelSize) else {
            throw XCTSkip("ggml-\(Self.modelSize).bin not found; download it before running this test")
        }
    }

    private func transcribe(_ url: URL) throws -> String {
        let transcriber = Transcriber(modelSize: Self.modelSize, language: "en")
        return try transcriber.transcribe(audioURL: url)
    }

    // MARK: - tiny deterministic PRNG (no dependency on Swift's RandomNumberGenerator
    // protocol machinery) so the noise fixtures are byte-identical on every run and
    // on every machine, which keeps this test reproducible.

    private struct DeterministicPRNG {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 1 : seed }
        mutating func nextUInt64() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func nextUniform() -> Double {
            // Open (0, 1) interval — avoids log(0) in nextGaussian's Box-Muller.
            Double(nextUInt64() % 1_000_000_000) / 1_000_000_000.0 + 1e-12
        }
        mutating func nextGaussian(sigma: Double) -> Double {
            let u1 = nextUniform()
            let u2 = nextUniform()
            return sigma * sqrt(-2 * Foundation.log(u1)) * cos(2 * Double.pi * u2)
        }
    }

    // MARK: - WAV writing: 16kHz mono 16-bit PCM, the format whisper.cpp wants.

    private func writeWav(samples: [Int16], to url: URL, sampleRate: Int32 = 16000) throws {
        var data = Data()
        let byteRate = sampleRate * 2
        let dataSize = Int32(samples.count * 2)

        func appendASCII(_ s: String) { data.append(s.data(using: .ascii)!) }
        func appendLE(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendLE(_ v: Int16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        appendASCII("RIFF"); appendLE(Int32(36) + dataSize); appendASCII("WAVE")
        appendASCII("fmt "); appendLE(Int32(16))
        appendLE(Int16(1))          // PCM
        appendLE(Int16(1))          // mono
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(Int16(2))          // block align (bytes per frame)
        appendLE(Int16(16))         // bits per sample
        appendASCII("data"); appendLE(dataSize)
        for s in samples { appendLE(s) }

        try data.write(to: url)
    }

    // MARK: - non-speech fixtures: true silence + a couple of distinct low-amplitude
    // noise shapes, matching what the original one-off measurement this session used.

    private func silenceFixture() throws -> URL {
        let url = fixtureDir.appendingPathComponent("silence.wav")
        try writeWav(samples: [Int16](repeating: 0, count: 16000 * 2), to: url)
        return url
    }

    private func hum60HzFixture() throws -> URL {
        // 60Hz AC mains hum at low amplitude (~1% of full scale) — the classic
        // cheap-mic/power-supply noise floor.
        let url = fixtureDir.appendingPathComponent("hum60hz.wav")
        let sampleRate = 16000.0
        let amplitude = 300.0
        let count = Int(sampleRate * 2)
        let samples = (0..<count).map { i -> Int16 in
            Int16(amplitude * sin(2 * Double.pi * 60 * Double(i) / sampleRate))
        }
        try writeWav(samples: samples, to: url)
        return url
    }

    private func gaussianNoiseFixture() throws -> URL {
        // Low-amplitude Gaussian noise (sigma ~80 of 32767 full scale, ~0.25%).
        let url = fixtureDir.appendingPathComponent("gaussian_noise.wav")
        var prng = DeterministicPRNG(seed: 42)
        let count = 16000 * 2
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let v = prng.nextGaussian(sigma: 80).rounded()
            samples[i] = Int16(max(-32768, min(32767, v)))
        }
        try writeWav(samples: samples, to: url)
        return url
    }

    private func roomToneFixture() throws -> URL {
        // A second, differently-shaped low-amplitude noise variant: a bounded random
        // walk, which has more low-frequency energy than the white Gaussian noise
        // above (closer to a quiet room's broadband "tone" than hiss).
        let url = fixtureDir.appendingPathComponent("roomtone.wav")
        var prng = DeterministicPRNG(seed: 7)
        let count = 16000 * 2
        var samples = [Int16](repeating: 0, count: count)
        var value = 0.0
        for i in 0..<count {
            let step = (prng.nextUniform() - 0.5) * 40 // roughly [-20, 20]
            value = max(-400, min(400, value + step))
            samples[i] = Int16(value.rounded())
        }
        try writeWav(samples: samples, to: url)
        return url
    }

    // MARK: - real-speech fixtures: macOS `say` -> aiff -> `afconvert` -> 16kHz mono
    // WAV, the exact pattern scripts/test-transcription.sh already uses for this.

    private func speechFixture(text: String, name: String) throws -> URL {
        let aiffURL = fixtureDir.appendingPathComponent("\(name).aiff")
        let wavURL = fixtureDir.appendingPathComponent("\(name).wav")

        guard FileManager.default.fileExists(atPath: "/usr/bin/say"),
              FileManager.default.fileExists(atPath: "/usr/bin/afconvert") else {
            throw XCTSkip("macOS `say`/`afconvert` not found at the expected path; skipping speech fixture generation")
        }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiffURL.path, text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0, FileManager.default.fileExists(atPath: aiffURL.path) else {
            throw XCTSkip("macOS `say` failed to generate speech audio; skipping")
        }

        let afconvert = Process()
        afconvert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        afconvert.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiffURL.path, wavURL.path]
        try afconvert.run()
        afconvert.waitUntilExit()
        guard afconvert.terminationStatus == 0, FileManager.default.fileExists(atPath: wavURL.path) else {
            throw XCTSkip("afconvert failed to produce a 16kHz mono WAV; skipping")
        }
        return wavURL
    }

    // MARK: - silence / noise must never produce inserted text
    //
    // Each of these calls the REAL Transcriber -> REAL whisper-cli -> REAL model.
    // A hallucinated phrase (bracketed like "(machinery whirring)" or bare like
    // "you"/"thank you for watching") here is exactly the regression this file
    // exists to catch — see this test's run log in the report for what this
    // actually measured on this machine.

    // NOTE: the four tests below are wrapped in `XCTExpectFailure` because they
    // currently DO fail against the real whisper-cli base.en model: silence and
    // quiet background noise deterministically produce the bare word "you"
    // instead of empty output. This is a confirmed, real bug (tracked in
    // murmur-implementation-plan.md's known-gaps table) that tech-lead has
    // deferred — the real fix is a dependency-free RMS/energy pre-gate on the
    // raw audio, which needs real quiet-speech measurement before a safe
    // threshold can be trusted, and that's its own task. `--suppress-nst` only
    // ever suppressed the bracketed/parenthetical hallucination class (e.g.
    // "(machinery whirring)"), never this bare-word class. `XCTExpectFailure`
    // keeps the suite green without hiding the regression: it still reports the
    // underlying assertion failing internally (visible in verbose test output as
    // an "expected failure"), it just doesn't fail the overall test run. If one
    // of these ever starts PASSING (i.e. the gate above lands and silence/noise
    // stop hallucinating), XCTExpectFailure will itself fail the test as a signal
    // to remove the wrapper — don't delete these wrappers without re-measuring.

    func testTrueSilenceProducesNoText() throws {
        try skipIfWhisperUnavailable()
        let url = try silenceFixture()
        let output = try transcribe(url)
        XCTExpectFailure("tracked in murmur-implementation-plan.md's known-gaps table — whisper.cpp base.en hallucinates bare 'you' on silence/background noise; --suppress-nst only ever suppressed the bracketed-marker hallucination class, not this one") {
            XCTAssertTrue(output.isEmpty, "True digital silence must not insert text; got: \"\(output)\"")
        }
    }

    func testLowAmplitude60HzHumProducesNoText() throws {
        try skipIfWhisperUnavailable()
        let url = try hum60HzFixture()
        let output = try transcribe(url)
        XCTExpectFailure("tracked in murmur-implementation-plan.md's known-gaps table — whisper.cpp base.en hallucinates bare 'you' on silence/background noise; --suppress-nst only ever suppressed the bracketed-marker hallucination class, not this one") {
            XCTAssertTrue(output.isEmpty, "Quiet 60Hz AC hum must not insert text; got: \"\(output)\"")
        }
    }

    func testLowAmplitudeGaussianNoiseProducesNoText() throws {
        try skipIfWhisperUnavailable()
        let url = try gaussianNoiseFixture()
        let output = try transcribe(url)
        XCTExpectFailure("tracked in murmur-implementation-plan.md's known-gaps table — whisper.cpp base.en hallucinates bare 'you' on silence/background noise; --suppress-nst only ever suppressed the bracketed-marker hallucination class, not this one") {
            XCTAssertTrue(output.isEmpty, "Quiet Gaussian noise must not insert text; got: \"\(output)\"")
        }
    }

    func testLowAmplitudeRoomToneProducesNoText() throws {
        try skipIfWhisperUnavailable()
        let url = try roomToneFixture()
        let output = try transcribe(url)
        XCTExpectFailure("tracked in murmur-implementation-plan.md's known-gaps table — whisper.cpp base.en hallucinates bare 'you' on silence/background noise; --suppress-nst only ever suppressed the bracketed-marker hallucination class, not this one") {
            XCTAssertTrue(output.isEmpty, "Quiet room-tone noise must not insert text; got: \"\(output)\"")
        }
    }

    // MARK: - real speech must still come through
    //
    // Guards against the opposite regression: a suppression filter tuned so
    // aggressively against hallucination that it starts eating real words. This is
    // the exact failure mode a real acceptance pass found and fixed for bare
    // "bye"/"thanks"/"you" in commit f2ebd24 — loose keyword checks, not exact
    // match, since whisper's output isn't perfectly deterministic across machines
    // or whisper-cpp versions.

    func testRealSpeechIsStillRecognized() throws {
        try skipIfWhisperUnavailable()
        let url = try speechFixture(text: "Hello world, please send the report by Friday", name: "hello")
        let output = try transcribe(url).lowercased()
        XCTAssertTrue(output.contains("hello"), "Expected 'hello' in real-speech output, got: \"\(output)\"")
    }

    func testRealSpeechNumbersAreStillRecognized() throws {
        try skipIfWhisperUnavailable()
        let url = try speechFixture(text: "One two three four five", name: "numbers")
        let output = try transcribe(url).lowercased()
        let hasNumberWord = ["one", "two", "three", "four", "five", "1", "2", "3", "4", "5"]
            .contains { output.contains($0) }
        XCTAssertTrue(hasNumberWord, "Expected a number word in real-speech output, got: \"\(output)\"")
    }

    func testRealShortOneWordDictationIsNotSwallowed() throws {
        // The exact regression f2ebd24 fixed: a short, legitimate one-word reply
        // must survive, not be treated as a hallucination because it happens to
        // match a stock silence phrase.
        try skipIfWhisperUnavailable()
        let url = try speechFixture(text: "Yes", name: "yes")
        let output = try transcribe(url)
        XCTAssertFalse(output.isEmpty, "A real one-word dictation must not be swallowed as a hallucination")
    }
}
