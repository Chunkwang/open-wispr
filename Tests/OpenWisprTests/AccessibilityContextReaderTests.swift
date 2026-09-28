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
}
