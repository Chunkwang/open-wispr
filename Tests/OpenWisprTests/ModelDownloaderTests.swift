import XCTest
@testable import OpenWisprLib

// Regression coverage for a real bug found in the bug-hunt this test was
// written during: ModelDownloader.download(modelSize:) treated ANY existing
// file at the destination path as proof the model was already downloaded,
// with no validation. A corrupt leftover (e.g. the process killed in the
// narrow window after moveItem placed the file but before the magic-byte
// check ran) would then never be re-downloaded or healed -- confirmed on a
// real machine: a hand-planted garbage ggml-tiny.bin was reported as
// "already exists" and download-model silently did nothing, leaving a model
// file that fails to load (whisper-cli: "invalid model data (bad magic)").
//
// `canReuseExisting` is the pure decision `download(modelSize:)` now
// delegates to; tested here with injected fakes so it needs neither a real
// file nor a network call.
final class ModelDownloaderTests: XCTestCase {

    func testCanReuseExistingIsFalseWhenFileIsMissing() {
        let result = ModelDownloader.canReuseExisting(
            at: "/does/not/matter",
            fileExists: { _ in false },
            isValid: { _ in XCTFail("isValid should not be consulted when the file doesn't exist"); return false }
        )
        XCTAssertFalse(result)
    }

    func testCanReuseExistingIsFalseWhenFileExistsButIsCorrupt() {
        let result = ModelDownloader.canReuseExisting(
            at: "/some/ggml-tiny.bin",
            fileExists: { _ in true },
            isValid: { _ in false }
        )
        XCTAssertFalse(result, "a corrupt leftover must never be treated as an already-downloaded model")
    }

    func testCanReuseExistingIsTrueWhenFileExistsAndIsValid() {
        let result = ModelDownloader.canReuseExisting(
            at: "/some/ggml-base.en.bin",
            fileExists: { _ in true },
            isValid: { _ in true }
        )
        XCTAssertTrue(result)
    }

    // MARK: - isValidGGMLFile (real file I/O, no network)

    func testIsValidGGMLFileAcceptsRealMagicBytes() throws {
        let url = try Self.write(bytes: [0x6c, 0x6d, 0x67, 0x67] /* little-endian bytes for GGML magic 0x67676d6c */)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ModelDownloader.isValidGGMLFile(at: url))
    }

    func testIsValidGGMLFileRejectsGarbage() throws {
        let url = try Self.write(string: "THIS IS NOT A REAL GGML MODEL FILE - GARBAGE")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(ModelDownloader.isValidGGMLFile(at: url))
    }

    func testIsValidGGMLFileRejectsTruncatedFile() throws {
        // Fewer than 4 bytes: a download interrupted after only a couple of
        // bytes landed, if it ever reached destPath at all.
        let url = try Self.write(bytes: [0x6c, 0x67])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(ModelDownloader.isValidGGMLFile(at: url))
    }

    func testIsValidGGMLFileRejectsMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/this-file-does-not-exist-\(UUID().uuidString).bin")
        XCTAssertFalse(ModelDownloader.isValidGGMLFile(at: url))
    }

    private static func write(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-downloader-test-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private static func write(string: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-downloader-test-\(UUID().uuidString).bin")
        try string.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
