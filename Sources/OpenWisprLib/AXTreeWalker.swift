import Foundation
import AppKit
import ApplicationServices

public struct AXElementNode: Codable, Sendable {
    public let id: Int
    public let role: String
    public let title: String?
    public let frame: CGRect
    
    public var stringRepresentation: String {
        var str = "<element id=\"\(id)\" role=\"\(role)\""
        if let title = title, !title.isEmpty {
            let escapedTitle = title.replacingOccurrences(of: "\"", with: "&quot;")
            str += " title=\"\(escapedTitle)\""
        }
        str += " frame=\"\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))\" />"
        return str
    }
}

/// The frontmost app identity `AXTreeWalker` checks itself, in a form that does
/// not require a live `NSRunningApplication` — so `isPermittedToWalk` can be
/// exercised from a test with a fabricated pid and bundle id.
struct FrontmostAppInfo: Equatable {
    let pid: Int32
    let bundleID: String?
    let localizedName: String?

    init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier
        localizedName = app.localizedName
    }

    init(pid: Int32, bundleID: String? = nil, localizedName: String? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.localizedName = localizedName
    }
}

public final class AXTreeWalker {

    /// Cap on a node's title or value, same field the rest of the context
    /// pipeline uses for a single-line label (`ContextSnapshot.maxWindowTitleScalars`).
    static let maxNodeTextScalars = ContextSnapshot.maxWindowTitleScalars

    /// The frontmost window's own on-screen frame (position and size), in
    /// Accessibility/Quartz screen coordinates: origin at the top-left of the
    /// primary display, Y increasing downward. This is the same convention
    /// `AXElementNode.frame` already uses and the one `SCWindow.frame`
    /// (ScreenCaptureKit) reports, so a caller matching this frame against
    /// `SCShareableContent.current.windows` compares like with like, with no
    /// conversion needed. A caller placing something back on screen with
    /// AppKit (an `NSPanel`, `NSScreen.frame`) must convert with
    /// `axRectToScreenRect` first — see its doc comment.
    ///
    /// Applies the same permission check `walkFrontmostWindow` does
    /// (`isPermittedToWalk`): `nil` for the wrong app, an excluded app, no
    /// focused window, or no readable frame. Does not walk the tree or read
    /// any element's title or value.
    public static func frontmostWindowFrame(expectedPID: Int32) -> CGRect? {
        frontmostWindowFrame(expectedPID: expectedPID, exclusions: ExcludedApps())
    }

    /// Test-facing overload, matching `walkFrontmostWindow`'s pair: `ExcludedApps`
    /// is internal, so it cannot appear in the public signature above.
    static func frontmostWindowFrame(expectedPID: Int32, exclusions: ExcludedApps) -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard isPermittedToWalk(app: FrontmostAppInfo(app), expectedPID: expectedPID, exclusions: exclusions) else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var frontWindow: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &frontWindow)
        guard error == .success, let window = frontWindow else { return nil }
        let axWindow = window as! AXUIElement

        return getFrame(element: axWindow)
    }

    /// Converts a frame in Accessibility/Quartz screen coordinates (origin
    /// top-left of the primary display, Y increasing downward — what
    /// `frontmostWindowFrame` and `AXElementNode.frame` return) to AppKit/
    /// `NSScreen` coordinates (origin bottom-left, Y increasing upward), the
    /// convention `NormalizedBox.rect(in:)` and `NSScreen.frame` itself use.
    /// Same flip `PointerOverlayController` already applies to an element
    /// frame, pulled out here so both call sites share one piece of math.
    /// Assumes the primary display's origin coincides with AX's global origin
    /// (true for the common case; a window on a secondary display above or
    /// left of the primary one is the known limit, same as the existing
    /// pointer overlay).
    public static func axRectToScreenRect(_ axRect: CGRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return axRect }
        let screenHeight = primaryScreen.frame.height
        let y = screenHeight - axRect.minY - axRect.height
        return CGRect(x: axRect.minX, y: y, width: axRect.width, height: axRect.height)
    }

    /// Walks the accessibility tree of the frontmost window up to the given limits.
    ///
    /// This is a second, independent line of defense on top of whatever the
    /// caller already checked from a `ContextSnapshot` (`AskCoordinator`'s check
    /// happens before a screen capture and a reachability wait, both real
    /// latency, so the frontmost app by the time this runs may not be the one
    /// that was checked): the app is re-identified here from scratch, checked
    /// against `expectedPID` and against `exclusions`, and every title or value
    /// read is cleaned through `ContextText.clean` (the same rules and caps
    /// `ContextSnapshot` applies) and then `InjectionDetector` before it can end
    /// up in the returned tree. A secure field (`AXSecureTextField` role or
    /// subrole) is skipped entirely: neither its title, its value, nor its
    /// children are read.
    ///
    /// - Parameter expectedPID: the frontmost app's pid at the moment the caller
    ///   decided it was safe to proceed. If the real frontmost app is not this
    ///   one, the walk is refused (empty result) rather than reading whatever is
    ///   frontmost now.
    public static func walkFrontmostWindow(
        expectedPID: Int32,
        maxDepth: Int = 10,
        maxElements: Int = 200,
        timeLimit: TimeInterval = 1.0
    ) -> [AXElementNode] {
        walkFrontmostWindow(
            expectedPID: expectedPID, exclusions: ExcludedApps(),
            maxDepth: maxDepth, maxElements: maxElements, timeLimit: timeLimit
        )
    }

    /// Test-facing overload: `ExcludedApps` is internal, so it cannot appear in
    /// the public signature above, but `AccessibilityContextReaderTests`-style
    /// tests in this module still need to inject a fake exclusion list.
    static func walkFrontmostWindow(
        expectedPID: Int32,
        exclusions: ExcludedApps,
        maxDepth: Int = 10,
        maxElements: Int = 200,
        timeLimit: TimeInterval = 1.0
    ) -> [AXElementNode] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        guard isPermittedToWalk(app: FrontmostAppInfo(app), expectedPID: expectedPID, exclusions: exclusions) else { return [] }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var frontWindow: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &frontWindow)
        guard error == .success, let window = frontWindow else { return [] }

        let axWindow = window as! AXUIElement

        var nodes: [AXElementNode] = []
        var nextId = 1

        let startTime = Date()

        func traverse(element: AXUIElement, depth: Int) {
            guard depth <= maxDepth else { return }
            guard nodes.count < maxElements else { return }
            guard Date().timeIntervalSince(startTime) < timeLimit else { return }

            let role = getAttribute(element: element, attribute: kAXRoleAttribute) as? String
            let subrole = getAttribute(element: element, attribute: kAXSubroleAttribute) as? String
            // A secure field's title, value and children are never read, exactly
            // as the Level-1 context reader treats one: identity only, nothing else.
            if isSecureElement(role: role, subrole: subrole) { return }

            if let role, let frame = getFrame(element: element) {

                // Only include interactive or text elements to save tokens
                let isInteresting = [
                    kAXButtonRole, kAXTextFieldRole, kAXStaticTextRole,
                    kAXCheckBoxRole, kAXRadioButtonRole, kAXMenuItemRole,
                    kAXPopUpButtonRole, "AXLink", "AXTabButton", "AXComboBox",
                    kAXSliderRole, kAXOutlineRole, kAXTableRole
                ].contains(role)

                if isInteresting {
                    let rawTitle = getAttribute(element: element, attribute: kAXTitleAttribute) as? String
                    let rawValue = getAttribute(element: element, attribute: kAXValueAttribute) as? String

                    let chosenRaw = (rawTitle?.isEmpty == false) ? rawTitle : (rawValue?.isEmpty == false ? rawValue : nil)
                    let nodeTitle = cleanedNodeText(chosenRaw)

                    if nodeTitle != nil || [kAXButtonRole, kAXCheckBoxRole, "AXTabButton"].contains(role) {
                        nodes.append(AXElementNode(id: nextId, role: role, title: nodeTitle, frame: frame))
                        nextId += 1
                    }
                }
            }

            // Traverse children
            if let children = getAttribute(element: element, attribute: kAXChildrenAttribute) as? [AXUIElement] {
                for child in children {
                    traverse(element: child, depth: depth + 1)
                }
            }
        }

        traverse(element: axWindow, depth: 0)

        return nodes
    }

    /// Same rule `DefaultAccessibilityContextReader.isSecure` uses for role and
    /// subrole (role description is not available cheaply for every node here,
    /// so it is not checked, matching this walker's best-effort role in
    /// defense-in-depth rather than duplicating the Level-1 reader). Internal,
    /// not private, so it can be exercised directly by tests without a live AX tree.
    static func isSecureElement(role: String?, subrole: String?) -> Bool {
        role == ContextSnapshot.secureRole || subrole == ContextSnapshot.secureRole
    }

    /// Whether `app` may be walked at all: it must be the app the caller told us
    /// to walk (`expectedPID`, item 2's TOCTOU fix), and it must not be on the
    /// exclusion list (item 1's own check, independent of whatever the caller
    /// already checked). Pure and side-effect free so a test can call it with a
    /// fabricated `FrontmostAppInfo` instead of a live `NSRunningApplication`.
    static func isPermittedToWalk(app: FrontmostAppInfo, expectedPID: Int32, exclusions: ExcludedApps) -> Bool {
        guard app.pid == expectedPID else { return false }
        if let bundleID = app.bundleID,
           let cleaned = ContextText.identifier(bundleID, maxScalars: ContextSnapshot.maxBundleIDScalars),
           exclusions.reason(forBundleID: cleaned) != nil {
            return false
        }
        if let name = app.localizedName, DefaultExcludedApps.matchesByName(name) { return false }
        return true
    }

    /// Cleans a raw title or value the same way `ContextSnapshot` cleans a
    /// window title (control/bidi/invisible scalars stripped, capped at
    /// `maxNodeTextScalars`), then drops it entirely if `InjectionDetector`
    /// flags it (best-effort only; see that type's documentation). `nil` or
    /// empty in, or nothing printable left after cleaning, gives `nil`.
    static func cleanedNodeText(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let cleaned = ContextText.clean(raw, maxScalars: maxNodeTextScalars, multiline: false).text else { return nil }
        if InjectionDetector.containsInjection(text: cleaned) { return nil }
        return cleaned
    }

    private static func getAttribute(element: AXUIElement, attribute: String) -> Any? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }
    
    private static func getFrame(element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success {
            
            var point = CGPoint.zero
            var size = CGSize.zero
            
            // Note: swiftlint might complain if we force cast, but it's safe if it succeeded
            if let pValue = positionValue, AXValueGetValue(pValue as! AXValue, .cgPoint, &point),
               let sValue = sizeValue, AXValueGetValue(sValue as! AXValue, .cgSize, &size) {
                return CGRect(origin: point, size: size)
            }
        }
        return nil
    }
}
