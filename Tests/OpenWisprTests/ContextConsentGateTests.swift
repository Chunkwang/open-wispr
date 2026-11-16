import XCTest
@testable import OpenWisprLib

/// `EditGate`/`AskGate` had zero test coverage before this pass (QA's finding,
/// matching the security review's finding 5: nothing enforced that the v2 agent
/// layer ships off by default). These tests cover the gate truth table,
/// including the new `agentLayerEnabled` flag (finding 5) and the local-LLM
/// bypass now requiring a validated loopback URL (finding 7).
final class ContextConsentGateTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ContextConsentGateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Sets or clears both records explicitly (a truth-table loop reuses the same
    /// `defaults` suite across iterations, so a value left over from an earlier
    /// `true` would otherwise leak into a later `false`).
    private func consent(text: Bool, image: Bool) -> ContextConsent {
        let c = ContextConsent(defaults: defaults)
        if text {
            defaults.set(ContextConsent.currentTextDisclosureVersion, forKey: ContextConsent.textDefaultsKey)
        } else {
            defaults.removeObject(forKey: ContextConsent.textDefaultsKey)
        }
        if image {
            defaults.set(ContextConsent.currentImageDisclosureVersion, forKey: ContextConsent.imageDefaultsKey)
        } else {
            defaults.removeObject(forKey: ContextConsent.imageDefaultsKey)
        }
        return c
    }

    private func config(agentLayer: Bool?) -> Config {
        var c = Config.defaultConfig
        if let agentLayer { c.agentLayerEnabled = FlexBool(agentLayer) }
        return c
    }

    // MARK: - finding 5: the flag gates everything else

    func testEditGateIsClosedWhenConfigIsNil() {
        // Nothing wired the config in yet: must fail closed, not fail open.
        XCTAssertFalse(EditGate.shouldEdit(mode: .auto, consent: consent(text: true, image: true), hasToken: true, config: nil))
    }

    func testAskGateIsClosedWhenConfigIsNil() {
        XCTAssertFalse(AskGate.shouldAsk(mode: .auto, consent: consent(text: true, image: true), hasToken: true, config: nil))
    }

    func testEditGateIsClosedWhenFlagIsOffRegardlessOfConsentOrToken() {
        for hasConsent in [false, true] {
            for hasToken in [false, true] {
                let c = consent(text: hasConsent, image: hasConsent)
                XCTAssertFalse(
                    EditGate.shouldEdit(mode: .auto, consent: c, hasToken: hasToken, config: config(agentLayer: false)),
                    "consent=\(hasConsent) token=\(hasToken)"
                )
                XCTAssertFalse(
                    EditGate.shouldEdit(mode: .auto, consent: c, hasToken: hasToken, config: config(agentLayer: nil)),
                    "consent=\(hasConsent) token=\(hasToken) (absent flag)"
                )
            }
        }
    }

    func testAskGateIsClosedWhenFlagIsOffRegardlessOfConsentOrToken() {
        for hasConsent in [false, true] {
            for hasToken in [false, true] {
                let c = consent(text: hasConsent, image: hasConsent)
                XCTAssertFalse(
                    AskGate.shouldAsk(mode: .auto, consent: c, hasToken: hasToken, config: config(agentLayer: false)),
                    "consent=\(hasConsent) token=\(hasToken)"
                )
            }
        }
    }

    func testEditGateOpensOnlyWithFlagConsentAndToken() {
        XCTAssertTrue(EditGate.shouldEdit(
            mode: .auto, consent: consent(text: true, image: false), hasToken: true, config: config(agentLayer: true)
        ))
    }

    func testAskGateOpensOnlyWithFlagConsentAndToken() {
        XCTAssertTrue(AskGate.shouldAsk(
            mode: .auto, consent: consent(text: false, image: true), hasToken: true, config: config(agentLayer: true)
        ))
    }

    func testEditGateTruthTableOverFlagModeConsentAndToken() {
        for flag in [false, true] {
            for mode: RewriteMode in [.off, .auto] {
                for hasConsent in [false, true] {
                    for hasToken in [false, true] {
                        let expected = flag && mode == .auto && hasConsent && hasToken
                        let result = EditGate.shouldEdit(
                            mode: mode,
                            consent: consent(text: hasConsent, image: false),
                            hasToken: hasToken,
                            config: config(agentLayer: flag)
                        )
                        XCTAssertEqual(result, expected, "flag=\(flag) mode=\(mode) consent=\(hasConsent) token=\(hasToken)")
                    }
                }
            }
        }
    }

    func testAskGateTruthTableOverFlagModeConsentAndToken() {
        for flag in [false, true] {
            for mode: RewriteMode in [.off, .auto] {
                for hasConsent in [false, true] {
                    for hasToken in [false, true] {
                        let expected = flag && mode == .auto && hasConsent && hasToken
                        let result = AskGate.shouldAsk(
                            mode: mode,
                            consent: consent(text: false, image: hasConsent),
                            hasToken: hasToken,
                            config: config(agentLayer: flag)
                        )
                        XCTAssertEqual(result, expected, "flag=\(flag) mode=\(mode) consent=\(hasConsent) token=\(hasToken)")
                    }
                }
            }
        }
    }

    func testGateDoesNotReadTheTokenWhenFlagIsOff() {
        var reads = 0
        let token: () -> Bool = { reads += 1; return true }
        _ = EditGate.shouldEdit(mode: .auto, consent: consent(text: true, image: true), hasToken: token(), config: config(agentLayer: false))
        XCTAssertEqual(reads, 0)
    }

    // MARK: - finding 7: local-LLM bypass requires a validated loopback URL

    func testLocalLLMBypassRequiresValidatedURL() {
        var cfg = config(agentLayer: true)
        cfg.localLLMEnabled = FlexBool(true)
        cfg.localLLMURL = "http://evil.example.com:11434"
        // localLLMEnabled is true but the URL is not loopback, so it must NOT
        // bypass hasToken(): with no token, the gate must stay closed.
        XCTAssertFalse(EditGate.shouldEdit(mode: .auto, consent: consent(text: true, image: false), hasToken: false, config: cfg))
        XCTAssertFalse(AskGate.shouldAsk(mode: .auto, consent: consent(text: false, image: true), hasToken: false, config: cfg))
    }

    func testLocalLLMBypassWorksWithAValidatedLoopbackURL() {
        var cfg = config(agentLayer: true)
        cfg.localLLMEnabled = FlexBool(true)
        cfg.localLLMURL = "http://127.0.0.1:11434"
        XCTAssertTrue(EditGate.shouldEdit(mode: .auto, consent: consent(text: true, image: false), hasToken: false, config: cfg))
        XCTAssertTrue(AskGate.shouldAsk(mode: .auto, consent: consent(text: false, image: true), hasToken: false, config: cfg))
    }

    // MARK: - AgentLayerEnabled DEBUG-only environment override never persists

    func testAgentLayerEnvironmentOverrideIsNotOnByDefaultInTests() {
        // Sanity: nothing in the test environment sets OPENWISPR_AGENT_LAYER, so
        // an absent config field must read as off.
        XCTAssertFalse(Config.defaultConfig.isAgentLayerEnabled)
    }

    // MARK: - the DEBUG-only env override never reaches a release binary
    //
    // Same scanning approach as `RewriteGateTests.unguardedAcceptanceReferences`:
    // a reference to `OPENWISPR_AGENT_LAYER` outside a `#if DEBUG` region is a
    // hole this whole finding exists to close (a way to flip the flag on that a
    // release build would also see). Only `Config.swift`'s own `#if DEBUG` read
    // exists today, and `swift build -c release` compiles it out entirely, so a
    // release binary contains no code path — and therefore no such string —
    // that can read this variable at all.
    private static func unguardedEnvOverrideReferences(in source: String) -> [Int] {
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
            } else if line.contains("OPENWISPR_AGENT_LAYER"), !stack.contains(true) {
                found.append(index + 1)
            }
        }
        return found
    }

    func testNoSourceFileReferencesTheAgentLayerEnvOverrideOutsideDebug() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            scanned += 1
            for line in Self.unguardedEnvOverrideReferences(in: text) {
                offenders.append("\(file.lastPathComponent):\(line)")
            }
        }
        XCTAssertTrue(scanned > 10, "expected to scan the Sources tree, scanned \(scanned) files")
        XCTAssertEqual(offenders, [])
    }

    // MARK: - Edit/Ask consent calls never reach a release build unguarded
    //
    // `recordTextAcceptance()`/`recordImageAcceptance()` are the v2 equivalents
    // of `RewriteConsent.recordAcceptance()`. Unlike that one (now legitimately
    // called from a real, shipped disclosure sheet per Task 5.1), these two are
    // still dev-only hooks: `ContextConsentSheet.swift`'s call to
    // `recordTextAcceptance()` is `#if DEBUG`-wrapped, and `recordImageAcceptance()`
    // has no call site at all. `nm` on the release binary is not a reliable
    // signal here (Swift keeps the symbol regardless of the `#if DEBUG` at the
    // call site), so this scans source the same way
    // `unguardedEnvOverrideReferences` above does, generalized to two symbols.
    private static func unguardedContextAcceptanceReferences(in source: String) -> [Int] {
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
            } else if (line.contains("recordTextAcceptance(") || line.contains("recordImageAcceptance(")), !stack.contains(true) {
                found.append(index + 1)
            }
        }
        return found
    }

    func testScannerFlagsUnguardedContextAcceptanceCalls() {
        XCTAssertEqual(Self.unguardedContextAcceptanceReferences(in: "consent.recordTextAcceptance()"), [1])
        XCTAssertEqual(Self.unguardedContextAcceptanceReferences(in: "consent.recordImageAcceptance()"), [1])
        XCTAssertEqual(Self.unguardedContextAcceptanceReferences(in: "#if DEBUG\n#else\nx.recordTextAcceptance()\n#endif"), [3])
    }

    func testScannerAcceptsGuardedContextAcceptanceCalls() {
        XCTAssertEqual(Self.unguardedContextAcceptanceReferences(in: "#if DEBUG\nx.recordTextAcceptance()\n#endif"), [])
        XCTAssertEqual(Self.unguardedContextAcceptanceReferences(in: "#if DEBUG\nx.recordImageAcceptance()\n#endif"), [])
    }

    func testNoSourceFileCallsContextAcceptanceOutsideDebug() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            // ContextConsent.swift defines recordTextAcceptance()/recordImageAcceptance()
            // themselves, unguarded (as RewriteGate.swift does for recordAcceptance()) —
            // the definition existing is fine; only an unguarded *call site* is the hole.
            if file.lastPathComponent == "ContextConsent.swift" { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            scanned += 1
            for line in Self.unguardedContextAcceptanceReferences(in: text) {
                offenders.append("\(file.lastPathComponent):\(line)")
            }
        }
        XCTAssertTrue(scanned > 10, "expected to scan the Sources tree, scanned \(scanned) files")
        XCTAssertEqual(offenders, [])
    }
}
