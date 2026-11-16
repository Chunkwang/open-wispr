import XCTest
@testable import OpenWisprLib

final class RewriteGateTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RewriteGateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Writes the stored value directly, so these tests do not depend on
    /// `recordAcceptance()` (which exists only in DEBUG builds).
    private func store(_ value: Any?) {
        if let value = value {
            defaults.set(value, forKey: RewriteConsent.defaultsKey)
        } else {
            defaults.removeObject(forKey: RewriteConsent.defaultsKey)
        }
    }

    private func consent(storing value: Any?) -> RewriteConsent {
        store(value)
        return RewriteConsent(defaults: defaults)
    }

    private var current: Int { RewriteConsent.currentDisclosureVersion }

    // MARK: - consent record

    func testCurrentDisclosureVersionIsOne() {
        XCTAssertEqual(RewriteConsent.currentDisclosureVersion, 1)
    }

    func testNoStoredValueMeansNoConsent() {
        XCTAssertFalse(consent(storing: nil).hasConsent)
    }

    func testCurrentVersionMeansConsent() {
        XCTAssertTrue(consent(storing: current).hasConsent)
    }

    func testOlderVersionIsNotConsent() {
        XCTAssertFalse(consent(storing: current - 1).hasConsent)
        XCTAssertFalse(consent(storing: 0).hasConsent)
    }

    func testNewerVersionIsNotConsent() {
        XCTAssertFalse(consent(storing: current + 1).hasConsent)
    }

    func testNegativeVersionIsNotConsent() {
        XCTAssertFalse(consent(storing: -1).hasConsent)
    }

    func testNonsenseStoredValuesAreNotConsent() {
        XCTAssertFalse(consent(storing: "1").hasConsent)
        XCTAssertFalse(consent(storing: "yes").hasConsent)
        XCTAssertFalse(consent(storing: true).hasConsent)
        XCTAssertFalse(consent(storing: 1.0).hasConsent)
        XCTAssertFalse(consent(storing: 1.5).hasConsent)
        XCTAssertFalse(consent(storing: [1]).hasConsent)
        XCTAssertFalse(consent(storing: ["version": 1]).hasConsent)
        XCTAssertFalse(consent(storing: Data([1])).hasConsent)
    }

    func testRevokeRemovesConsent() {
        let c = consent(storing: current)
        XCTAssertTrue(c.hasConsent)
        c.revoke()
        XCTAssertFalse(c.hasConsent)
    }

    func testConsentIsNotReadFromConfigJSON() throws {
        // A config.json that claims consent must change nothing: the record is
        // read from UserDefaults only.
        let json = "{\"modelSize\": \"small.en\", \"language\": \"en\", \"rewriteMode\": \"auto\", \"rewriteConsent\": true, \"rewriteDisclosureVersionAccepted\": 1}"
        let config = try Config.decode(from: Data(json.utf8))
        XCTAssertEqual(config.rewriteMode, .auto)
        XCTAssertFalse(RewriteGate.shouldRewrite(mode: config.rewriteMode, consent: consent(storing: nil), hasToken: true))
    }

    // MARK: - the gate: every combination

    func testGateTruthTableOverModeConsentAndToken() {
        let modes: [RewriteMode] = [.off, .auto]
        for mode in modes {
            for hasConsent in [false, true] {
                for hasToken in [false, true] {
                    let c = consent(storing: hasConsent ? current : nil)
                    let expected = mode == .auto && hasConsent && hasToken
                    XCTAssertEqual(
                        RewriteGate.shouldRewrite(mode: mode, consent: c, hasToken: hasToken),
                        expected,
                        "mode=\(mode) consent=\(hasConsent) token=\(hasToken)"
                    )
                }
            }
        }
    }

    func testGateOnlyOpensWithAllThree() {
        XCTAssertTrue(RewriteGate.shouldRewrite(mode: .auto, consent: consent(storing: current), hasToken: true))
    }

    func testGateClosedWhenConsentVersionMismatches() {
        let variants: [Any?] = [nil, current - 1, current + 1, "1", true]
        for stored in variants {
            XCTAssertFalse(
                RewriteGate.shouldRewrite(mode: .auto, consent: consent(storing: stored), hasToken: true),
                "stored=\(String(describing: stored))"
            )
        }
    }

    func testGateDoesNotReadTheTokenWhenModeIsOffOrConsentMissing() {
        var reads = 0
        let token: () -> Bool = { reads += 1; return true }
        XCTAssertFalse(RewriteGate.shouldRewrite(mode: .off, consent: consent(storing: current), hasToken: token()))
        XCTAssertFalse(RewriteGate.shouldRewrite(mode: .auto, consent: consent(storing: nil), hasToken: token()))
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(RewriteGate.shouldRewrite(mode: .auto, consent: consent(storing: current), hasToken: token()))
        XCTAssertEqual(reads, 1)
    }

    // MARK: - onDeviceAIEnabled bypass (Foundation Models Phase 1)
    //
    // Mirrors the localLLMEnabled bypass this gate already has: a flag alone must
    // never be enough, only the flag AND the on-device model actually being
    // usable right now. `FoundationModelsPipeline.isAvailable` reflects real
    // device/OS state, so these tests stay deterministic across environments by
    // checking mode/consent short-circuiting (which never depends on it) and by
    // asserting the bypass result always mirrors real availability rather than
    // hard-coding true or false.

    func testOnDeviceAIBypassStillRequiresModeAutoAndConsent() {
        var cfg = Config.defaultConfig
        cfg.onDeviceAIEnabled = FlexBool(true)
        XCTAssertFalse(RewriteGate.shouldRewrite(mode: .off, consent: consent(storing: current), hasToken: false, config: cfg))
        XCTAssertFalse(RewriteGate.shouldRewrite(mode: .auto, consent: consent(storing: nil), hasToken: false, config: cfg))
    }

    func testOnDeviceAIDisabledNeverBypassesTheToken() {
        var cfg = Config.defaultConfig
        cfg.onDeviceAIEnabled = FlexBool(false)
        XCTAssertFalse(RewriteGate.shouldRewrite(mode: .auto, consent: consent(storing: current), hasToken: false, config: cfg))
        cfg.onDeviceAIEnabled = nil
        XCTAssertFalse(RewriteGate.shouldRewrite(mode: .auto, consent: consent(storing: current), hasToken: false, config: cfg))
    }

    func testOnDeviceAIBypassMirrorsRealAvailabilityNotJustTheFlag() {
        var cfg = Config.defaultConfig
        cfg.onDeviceAIEnabled = FlexBool(true)
        let opened = RewriteGate.shouldRewrite(mode: .auto, consent: consent(storing: current), hasToken: false, config: cfg)
        // The flag is on and the token is absent, so the gate can only be open
        // here because the on-device model is genuinely usable right now.
        XCTAssertEqual(opened, FoundationModelsPipeline.isAvailable)
    }

    func testOnDeviceAIPreferredOverTheOllamaBypassWhenBothAreConfigured() {
        // Both bypasses configured, on-device flag on: whether the gate opens
        // without a token must still mirror on-device availability, because
        // on-device is checked first (RewriteGate.shouldRewrite) — the Ollama
        // bypass would also open it, so this only proves the on-device check
        // does not somehow narrow what the Ollama-only bypass already allowed.
        var cfg = Config.defaultConfig
        cfg.onDeviceAIEnabled = FlexBool(true)
        cfg.localLLMEnabled = FlexBool(true)
        cfg.localLLMURL = "http://127.0.0.1:11434"
        XCTAssertTrue(RewriteGate.shouldRewrite(mode: .auto, consent: consent(storing: current), hasToken: false, config: cfg))
    }

    // MARK: - menu status line
    // `statusLine` exists only in DEBUG builds (the Rewrite menu is DEBUG-only
    // until Task 5.1), so these bodies compile to nothing elsewhere.

    func testStatusLineWording() {
        #if DEBUG
        XCTAssertEqual(RewriteGate.statusLine(mode: .off, consent: consent(storing: current), hasToken: true), "Rewrite: off")
        XCTAssertEqual(RewriteGate.statusLine(mode: .auto, consent: consent(storing: current), hasToken: false), "Rewrite: needs sign-in")
        XCTAssertEqual(RewriteGate.statusLine(mode: .auto, consent: consent(storing: nil), hasToken: true), "Rewrite: needs your consent")
        XCTAssertEqual(RewriteGate.statusLine(mode: .auto, consent: consent(storing: current), hasToken: true), "Rewrite: on")
        #endif
    }

    func testStatusLineSaysOnExactlyWhenTheGateIsOpen() {
        #if DEBUG
        for mode in [RewriteMode.off, .auto] {
            for hasConsent in [false, true] {
                for hasToken in [false, true] {
                    let c = consent(storing: hasConsent ? current : nil)
                    let line = RewriteGate.statusLine(mode: mode, consent: c, hasToken: hasToken)
                    XCTAssertEqual(
                        line == "Rewrite: on",
                        RewriteGate.shouldRewrite(mode: mode, consent: c, hasToken: hasToken),
                        "mode=\(mode) consent=\(hasConsent) token=\(hasToken)"
                    )
                }
            }
        }
        #endif
    }

    func testStatusLinesFollowTheVoiceGuide() {
        #if DEBUG
        for mode in [RewriteMode.off, .auto] {
            for hasConsent in [false, true] {
                for hasToken in [false, true] {
                    let line = RewriteGate.statusLine(mode: mode, consent: consent(storing: hasConsent ? current : nil), hasToken: hasToken)
                    XCTAssertFalse(line.contains("!"))
                }
            }
        }
        #endif
    }

    // MARK: - no release path can set consent

    /// Lines that mention `recordAcceptance` outside comments and outside any
    /// `#if DEBUG` region. Any `#if` other than exactly `#if DEBUG`, and any
    /// `#else`, counts as not-DEBUG, so the check errs on the side of flagging.
    static func unguardedAcceptanceReferences(in source: String) -> [Int] {
        var stack: [Bool] = []
        var found: [Int] = []
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                stack.append(trimmed == "#if DEBUG")
            } else if trimmed.hasPrefix("#else") || trimmed.hasPrefix("#elseif") {
                if !stack.isEmpty { stack[stack.count - 1] = false }
            } else if trimmed.hasPrefix("#endif") {
                _ = stack.popLast()
            } else if trimmed.hasPrefix("//") {
                continue
            } else if line.contains("recordAcceptance"), !stack.contains(true) {
                found.append(index + 1)
            }
        }
        return found
    }

    func testScannerFlagsAnUnguardedCall() {
        XCTAssertEqual(RewriteGateTests.unguardedAcceptanceReferences(in: "consent.recordAcceptance()"), [1])
        XCTAssertEqual(RewriteGateTests.unguardedAcceptanceReferences(in: "#if DEBUG\n#else\nx.recordAcceptance()\n#endif"), [3])
        XCTAssertEqual(RewriteGateTests.unguardedAcceptanceReferences(in: "#if !DEBUG\nx.recordAcceptance()\n#endif"), [2])
        XCTAssertEqual(RewriteGateTests.unguardedAcceptanceReferences(in: "#if DEBUG\n#endif\nx.recordAcceptance()"), [3])
    }

    func testScannerAcceptsGuardedAndCommentedReferences() {
        XCTAssertEqual(RewriteGateTests.unguardedAcceptanceReferences(in: "#if DEBUG\nx.recordAcceptance()\n#endif"), [])
        XCTAssertEqual(RewriteGateTests.unguardedAcceptanceReferences(in: "#if DEBUG\n#if os(macOS)\nx.recordAcceptance()\n#endif\n#endif"), [])
        XCTAssertEqual(RewriteGateTests.unguardedAcceptanceReferences(in: "/// mentions recordAcceptance() in prose"), [])
    }

    func testNoSourceFileReferencesRecordAcceptanceOutsideDebug() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            if file.lastPathComponent == "RewriteGate.swift" || file.lastPathComponent == "RewriteDisclosureSheet.swift" {
                continue
            }
            let text = try String(contentsOf: file, encoding: .utf8)
            scanned += 1
            for line in RewriteGateTests.unguardedAcceptanceReferences(in: text) {
                offenders.append("\(file.lastPathComponent):\(line)")
            }
        }
        XCTAssertTrue(scanned > 10, "expected to scan the Sources tree, scanned \(scanned) files")
        XCTAssertEqual(offenders, [])
    }

    // recordAcceptance() exists only in DEBUG builds, so these bodies compile to
    // nothing elsewhere (and pass vacuously). `swift test` builds DEBUG.

    func testRecordAcceptanceStoresTheCurrentVersion() {
        #if DEBUG
        let c = RewriteConsent(defaults: defaults)
        XCTAssertFalse(c.hasConsent)
        c.recordAcceptance()
        XCTAssertTrue(c.hasConsent)
        XCTAssertEqual(defaults.integer(forKey: RewriteConsent.defaultsKey), RewriteConsent.currentDisclosureVersion)
        #endif
    }

    func testRecordAcceptanceOverwritesAnOlderVersion() {
        #if DEBUG
        let c = consent(storing: current - 1)
        XCTAssertFalse(c.hasConsent)
        c.recordAcceptance()
        XCTAssertTrue(c.hasConsent)
        #endif
    }

    func testRecordedAcceptanceOpensTheGate() {
        #if DEBUG
        let c = RewriteConsent(defaults: defaults)
        c.recordAcceptance()
        XCTAssertTrue(RewriteGate.shouldRewrite(mode: .auto, consent: c, hasToken: true))
        #endif
    }
}
