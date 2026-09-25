import XCTest
@testable import OpenWisprLib

/// scripts/bundle-app.sh generates the Info.plist and can't import Swift, so
/// these tests fail if its values drift from ProductInfo.
final class ProductInfoTests: XCTestCase {
    /// Collapses whitespace runs so reformatting bundle-app.sh (indent, blank
    /// lines) doesn't fail these tests; only a changed value does.
    private func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func bundleScript() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenWisprTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        return collapsed(try String(contentsOf: repoRoot.appendingPathComponent("scripts/bundle-app.sh"), encoding: .utf8))
    }

    func testBundleIdentifierMatchesBundleScript() throws {
        let script = try bundleScript()
        XCTAssertTrue(script.contains("<string>\(ProductInfo.bundleIdentifier)</string>"))
        XCTAssertTrue(script.contains("--identifier \(ProductInfo.bundleIdentifier)"))
    }

    func testBundleNameMatchesBundleScript() throws {
        let script = try bundleScript()
        XCTAssertTrue(script.contains("\(ProductInfo.bundleName).app"))
        XCTAssertTrue(script.contains("<string>\(ProductInfo.bundleName)</string>"))
    }

    func testMinimumMacOSVersionMatchesBundleScript() throws {
        let script = try bundleScript()
        XCTAssertTrue(script.contains("<key>LSMinimumSystemVersion</key> <string>\(ProductInfo.minimumMacOSVersion)</string>"))
    }

    func testMinimumMacOSVersionMatchesPackageManifest() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(".macOS(\"\(ProductInfo.minimumMacOSVersion)\")"))
    }

    func testDisplayNameMatchesBundleScript() throws {
        let script = try bundleScript()
        XCTAssertTrue(script.contains("<key>CFBundleDisplayName</key> <string>\(ProductInfo.displayName)</string>"))
    }

    func testKeychainServiceIsPinned() {
        // Stored tokens live under this exact service name. Renaming the bundle ID
        // changes it and orphans them, which is free before sign-in exists (Day 4)
        // and a migration afterwards. This test makes that a deliberate step.
        XCTAssertEqual(Keychain.service, "com.goprimy.dictation-wip.auth")
    }
}
