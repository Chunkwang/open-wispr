import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// The real `AXProvider`: raw `AXUIElement` calls, nothing else. This is the only
/// file that talks to the Accessibility API for context reading, and it holds no
/// decisions (the reader has them all), so it is compile-checked and exercised
/// only by a live run (docs/context-reader-notes.md). It never logs, and it
/// touches neither the pasteboard nor the screen.
struct SystemAXProvider: AXProvider {
    /// Per-call limit for every Accessibility request, in seconds. The system
    /// default is far longer; an unresponsive app must not hold a read up.
    let messagingTimeout: Float

    init(messagingTimeout: Float = 0.3) {
        self.messagingTimeout = messagingTimeout
    }

    func isProcessTrusted() -> Bool { AXIsProcessTrusted() }

    func isSecureEventInputEnabled() -> Bool { IsSecureEventInputEnabled() }

    func frontmostApplication() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApp(name: app.localizedName, bundleID: app.bundleIdentifier, pid: app.processIdentifier)
    }

    func focusedElement(pid: Int32) -> AXRead<AXElementRef> {
        elementAttribute(kAXFocusedUIElementAttribute, of: applicationElement(pid: pid))
    }

    func focusedWindow(pid: Int32) -> AXRead<AXElementRef> {
        elementAttribute(kAXFocusedWindowAttribute, of: applicationElement(pid: pid))
    }

    func string(_ attribute: AXTextAttribute, of element: AXElementRef) -> AXRead<String> {
        guard let element = element as? SystemAXElement else { return .failure(.invalidElement) }
        let name: String
        switch attribute {
        case .role: name = kAXRoleAttribute
        case .subrole: name = kAXSubroleAttribute
        case .roleDescription: name = kAXRoleDescriptionAttribute
        case .title: name = kAXTitleAttribute
        case .selectedText: name = kAXSelectedTextAttribute
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element.element, name as CFString, &value)
        if let failure: AXRead<String> = Self.read(error) { return failure }
        guard let value, CFGetTypeID(value) == CFStringGetTypeID(), let text = value as? String else {
            return .absent
        }
        return .value(text)
    }

    func isSameElement(_ a: AXElementRef, _ b: AXElementRef) -> Bool {
        guard let a = a as? SystemAXElement, let b = b as? SystemAXElement else { return false }
        return CFEqual(a.element, b.element)
    }

    // MARK: - helpers

    private func applicationElement(pid: Int32) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private func elementAttribute(_ name: String, of parent: AXUIElement) -> AXRead<AXElementRef> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(parent, name as CFString, &value)
        if let failure: AXRead<AXElementRef> = Self.read(error) { return failure }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .absent }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return .value(SystemAXElement(element))
    }

    /// nil for success; otherwise the read result that the error means.
    private static func read<T>(_ error: AXError) -> AXRead<T>? {
        switch error {
        case .success: return nil
        case .noValue, .attributeUnsupported: return .absent
        case .apiDisabled: return .failure(.apiDisabled)
        case .cannotComplete: return .failure(.cannotComplete)
        case .invalidUIElement: return .failure(.invalidElement)
        default: return .failure(.other)
        }
    }
}

/// `AXUIElement` is a reference-counted CF object that is safe to pass between
/// threads; it is wrapped so it can travel as an `AXElementRef`.
final class SystemAXElement: AXElementRef, @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}
