import XCTest
@testable import OpenWisprLib

/// QA note: added during the Day 3 hardening pass because `AccessibilityContextReader.swift`
/// and `ExcludedApps.swift` (the code that decides whether a secure field or an
/// excluded app's contents may be read) shipped with zero test coverage. This
/// exercises `DefaultAccessibilityContextReader.capture` against a fake `AXProvider`,
/// so no real Accessibility permission or screen is needed.
private final class FakeElement: AXElementRef {
    let id: Int
    init(_ id: Int) { self.id = id }
}

private final class FakeAXProvider: AXProvider, @unchecked Sendable {
    var trusted = true
    var secureEventInput = false
    var app: FrontmostApp? = FrontmostApp(name: "Notes", bundleID: "com.apple.Notes", pid: 100)
    var focused: AXRead<AXElementRef> = .value(FakeElement(1))
    var window: AXRead<AXElementRef> = .value(FakeElement(2))
    var strings: [String: AXRead<String>] = [:]
    var sameElement = true
    private(set) var focusedElementCalls = 0
    private(set) var stringCalls: [AXTextAttribute] = []

    func key(_ a: AXTextAttribute) -> String {
        switch a {
        case .role: return "role"
        case .subrole: return "subrole"
        case .roleDescription: return "roleDescription"
        case .title: return "title"
        case .selectedText: return "selectedText"
        }
    }

    func isProcessTrusted() -> Bool { trusted }
    func isSecureEventInputEnabled() -> Bool { secureEventInput }
    func frontmostApplication() -> FrontmostApp? { app }
    func focusedElement(pid: Int32) -> AXRead<AXElementRef> { focusedElementCalls += 1; return focused }
    func focusedWindow(pid: Int32) -> AXRead<AXElementRef> { window }
    func string(_ attribute: AXTextAttribute, of element: AXElementRef) -> AXRead<String> {
        stringCalls.append(attribute)
        return strings[key(attribute)] ?? .absent
    }
    func isSameElement(_ a: AXElementRef, _ b: AXElementRef) -> Bool { sameElement }
}

final class AccessibilityContextReaderTests: XCTestCase {
    private func provider(role: String = "AXTextField", roleDescription: String? = nil, title: String = "Untitled", selection: String = "hello") -> FakeAXProvider {
        let p = FakeAXProvider()
        p.strings["role"] = .value(role)
        if let roleDescription { p.strings["roleDescription"] = .value(roleDescription) }
        p.strings["title"] = .value(title)
        p.strings["selectedText"] = .value(selection)
        return p
    }

    // MARK: - secure fields

    func testSecureRoleReadsNoTitleOrSelection() {
        let p = provider(role: ContextSnapshot.secureRole)
        let snap = DefaultAccessibilityContextReader.capture(provider: p, exclusions: ExcludedApps())
        XCTAssertTrue(snap.isSecureField)
        XCTAssertNil(snap.windowTitle)
        XCTAssertNil(snap.selectedText)
    }

    /// Web and Electron password fields sometimes expose the ordinary
    /// "AXTextField" role and only say "secure" or "password" in the role
    /// description (the comment on `isSecure` calls this out by name). This is
    /// the one path `ContextSnapshot`'s own redaction does not backstop, because
    /// its secure check only compares role/subrole to `secureRole`, not the role
    /// description. If this regresses, the field's contents leak into the
    /// snapshot with no second line of defense.
    func testRoleDescriptionSecureFieldReadsNoTitleOrSelection() {
        let p = provider(role: "AXTextField", roleDescription: "secure text field")
        let snap = DefaultAccessibilityContextReader.capture(provider: p, exclusions: ExcludedApps())
        XCTAssertTrue(snap.isSecureField, "a role description saying 'secure' must be treated as a password field")
        XCTAssertNil(snap.windowTitle)
        XCTAssertNil(snap.selectedText)
    }

    func testRoleDescriptionSayingPasswordAlsoCounts() {
        let p = provider(role: "AXTextField", roleDescription: "password field")
        let snap = DefaultAccessibilityContextReader.capture(provider: p, exclusions: ExcludedApps())
        XCTAssertTrue(snap.isSecureField)
    }

    // MARK: - excluded apps

    func testExcludedAppNeverCallsAccessibility() {
        let p = provider()
        p.app = FrontmostApp(name: "1Password", bundleID: "com.1password.1password", pid: 5)
        let snap = DefaultAccessibilityContextReader.capture(provider: p, exclusions: ExcludedApps())
        XCTAssertEqual(snap.status, .excludedApp)
        XCTAssertEqual(snap.excluded, .defaultList)
        XCTAssertEqual(p.focusedElementCalls, 0, "an excluded app must never receive an Accessibility call")
        XCTAssertTrue(p.stringCalls.isEmpty)
    }

    func testOwnAppIsExcluded() {
        let p = provider()
        p.app = FrontmostApp(name: "Dictation", bundleID: "com.example.dictation", pid: 5)
        let snap = DefaultAccessibilityContextReader.capture(
            provider: p, exclusions: ExcludedApps(ownBundleIdentifier: "com.example.dictation")
        )
        XCTAssertEqual(snap.excluded, .appItself)
        XCTAssertEqual(p.focusedElementCalls, 0)
    }

    func testUserExcludedAppIsExcluded() {
        let p = provider()
        p.app = FrontmostApp(name: "Custom", bundleID: "com.example.custom", pid: 5)
        let snap = DefaultAccessibilityContextReader.capture(
            provider: p, exclusions: ExcludedApps(userIdentifiers: ["com.example.custom"])
        )
        XCTAssertEqual(snap.excluded, .userList)
    }

    // MARK: - permission and identity gates

    func testUntrustedGivesNoFrontmostAppCall() {
        let p = provider()
        p.trusted = false
        let snap = DefaultAccessibilityContextReader.capture(provider: p, exclusions: ExcludedApps())
        XCTAssertEqual(snap.status, .notTrusted)
        XCTAssertNil(snap.bundleID)
    }

    func testSecureEventInputKeepsIdentityOnly() {
        let p = provider()
        p.secureEventInput = true
        let snap = DefaultAccessibilityContextReader.capture(provider: p, exclusions: ExcludedApps())
        XCTAssertEqual(snap.status, .secureEventInput)
        XCTAssertNotNil(snap.bundleID)
        XCTAssertNil(snap.windowTitle)
        XCTAssertNil(snap.selectedText)
    }

    func testRoleNotOnAllowListKeepsIdentityOnly() {
        let p = provider(role: "AXButton")
        let snap = DefaultAccessibilityContextReader.capture(provider: p, exclusions: ExcludedApps())
        XCTAssertEqual(snap.status, .roleNotAllowed)
        XCTAssertNil(snap.windowTitle)
        XCTAssertNil(snap.selectedText)
    }

    func testFocusChangeBetweenReadsDropsWhatWasRead() {
        let p = provider()
        p.sameElement = false
        let snap = DefaultAccessibilityContextReader.capture(provider: p, exclusions: ExcludedApps())
        XCTAssertEqual(snap.status, .focusChanged)
        XCTAssertNil(snap.windowTitle)
        XCTAssertNil(snap.selectedText)
    }

    func testOrdinaryFieldReadsNormally() {
        let p = provider(title: "My Note", selection: "some text")
        let snap = DefaultAccessibilityContextReader.capture(provider: p, exclusions: ExcludedApps())
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.windowTitle, "My Note")
        XCTAssertEqual(snap.selectedText, "some text")
    }

    // MARK: - captureSecureInputStatus (the plain-dictation path's narrow check)
    //
    // Added alongside the Day 3 hardening pass above: plain dictation (unlike
    // Ask/Edit, which already read a full `ContextSnapshot`) had zero secure-field
    // awareness. This never reads a window title or selected text, for any
    // field, secure or not — asserted below by checking `stringCalls` directly.

    func testSecureEventInputIsReportedEvenWhenNotTrusted() {
        let p = provider()
        p.trusted = false
        p.secureEventInput = true
        XCTAssertEqual(DefaultAccessibilityContextReader.captureSecureInputStatus(provider: p), .secureEventInput)
        XCTAssertEqual(p.focusedElementCalls, 0, "secure keyboard input needs no Accessibility call at all")
    }

    /// Day 3 hardening pass, finding 2 (security-engineer): this used to
    /// return `.notSecure`, which fails open -- if Accessibility is off, or
    /// was revoked mid-session, there is no way to tell whether the focused
    /// field is secure, and "we don't know" must not be treated the same as
    /// "we checked and it isn't." `secureEventInput` is checked first and
    /// unconditionally (needs no Accessibility trust at all, so a system
    /// password prompt is still caught even here); everything past that
    /// needs trust, and its absence now yields `.cannotDetermine`.
    func testNotTrustedWithNoSecureEventInputCannotDetermine() {
        let p = provider()
        p.trusted = false
        XCTAssertEqual(DefaultAccessibilityContextReader.captureSecureInputStatus(provider: p), .cannotDetermine)
    }

    func testSecureRoleIsReportedAsSecureField() {
        let p = provider(role: ContextSnapshot.secureRole)
        XCTAssertEqual(DefaultAccessibilityContextReader.captureSecureInputStatus(provider: p), .secureField)
        XCTAssertFalse(p.stringCalls.contains(.title))
        XCTAssertFalse(p.stringCalls.contains(.selectedText))
    }

    func testRoleDescriptionSayingPasswordIsReportedAsSecureField() {
        let p = provider(role: "AXTextField", roleDescription: "password field")
        XCTAssertEqual(DefaultAccessibilityContextReader.captureSecureInputStatus(provider: p), .secureField)
    }

    func testOrdinaryFieldIsNotSecureAndNeverReadsTitleOrSelection() {
        let p = provider(role: "AXTextField", title: "My Note", selection: "some text")
        XCTAssertEqual(DefaultAccessibilityContextReader.captureSecureInputStatus(provider: p), .notSecure)
        XCTAssertFalse(p.stringCalls.contains(.title), "the narrow check must never ask for the title")
        XCTAssertFalse(p.stringCalls.contains(.selectedText), "the narrow check must never ask for the selection")
    }

    func testUnreadableFocusedElementIsNotSecureNotAFailure() {
        let p = provider()
        p.focused = .failure(.cannotComplete)
        XCTAssertEqual(DefaultAccessibilityContextReader.captureSecureInputStatus(provider: p), .notSecure)
    }

    func testNoFrontmostAppIsNotSecure() {
        let p = provider()
        p.app = nil
        XCTAssertEqual(DefaultAccessibilityContextReader.captureSecureInputStatus(provider: p), .notSecure)
    }

    // MARK: - checkSecureInput (the async wrapper, end to end)

    func testCheckSecureInputDeliversTheSameAnswerAsTheStaticCheck() {
        let p = provider(role: ContextSnapshot.secureRole)
        let reader = DefaultAccessibilityContextReader(provider: p)
        let expectation = expectation(description: "checkSecureInput completes")
        reader.checkSecureInput { status in
            XCTAssertEqual(status, .secureField)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testCheckSecureInputOnAnOrdinaryFieldIsNotSecure() {
        let p = provider(role: "AXTextField")
        let reader = DefaultAccessibilityContextReader(provider: p)
        let expectation = expectation(description: "checkSecureInput completes")
        reader.checkSecureInput { status in
            XCTAssertEqual(status, .notSecure)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    // MARK: - QA acceptance pass (Day 3 secure-field fix), angle 4: plain
    // dictation must never block indefinitely on this check. `FakeAXProvider`'s
    // calls are all synchronous and instantaneous, so none of the tests above
    // can tell whether `checkSecureInput` actually fails open on a hung app —
    // only that it answers correctly when the app answers instantly. This
    // provider blocks past the reader's deadline to prove the fail-open path
    // for real, not just by reading the source.

    private final class HangingAXProvider: AXProvider, @unchecked Sendable {
        let hang: TimeInterval
        init(hang: TimeInterval) { self.hang = hang }
        func isProcessTrusted() -> Bool { Thread.sleep(forTimeInterval: hang); return true }
        func isSecureEventInputEnabled() -> Bool { false }
        func frontmostApplication() -> FrontmostApp? { FrontmostApp(name: "Notes", bundleID: "com.apple.Notes", pid: 1) }
        func focusedElement(pid: Int32) -> AXRead<AXElementRef> { .value(FakeElement(1)) }
        func focusedWindow(pid: Int32) -> AXRead<AXElementRef> { .value(FakeElement(2)) }
        func string(_ attribute: AXTextAttribute, of element: AXElementRef) -> AXRead<String> { .value("AXTextField") }
        func isSameElement(_ a: AXElementRef, _ b: AXElementRef) -> Bool { true }
    }

    func testCheckSecureInputFailsOpenToNotSecureWhenTheAppHangsPastTheDeadline() {
        // isProcessTrusted() alone blocks for 10x the reader's deadline, well
        // past it, simulating an unresponsive app. If this ever blocked the
        // completion on the real call returning instead of firing at the
        // deadline, this test would time out at `wait`'s own 1 s limit instead
        // of completing near `deadline`.
        let deadline: TimeInterval = 0.05
        let p = HangingAXProvider(hang: deadline * 10)
        let reader = DefaultAccessibilityContextReader(provider: p, deadline: deadline)
        let expectation = expectation(description: "checkSecureInput fails open at the deadline")
        let start = Date()
        var elapsed: TimeInterval = -1
        reader.checkSecureInput { status in
            elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(status, .notSecure, "an inconclusive read on a hung app must never be treated as secure")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertLessThan(elapsed, 0.5, "the completion must fire at about the reader's deadline (\(deadline)s), not wait for the hung call")
    }
}
