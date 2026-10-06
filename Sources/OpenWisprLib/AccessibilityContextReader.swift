import Foundation

// Level-1 context reader (Stage C, task C2). All decisions live here and are
// tested against a fake `AXProvider`; the only code that touches the real
// Accessibility API is `SystemAXProvider`.
//
// Rules, in the order they are applied (docs/context-reader-notes.md):
//  1. Accessibility not granted: nothing (`.notTrusted`).
//  2. No frontmost app, or no usable bundle id: nothing.
//  3. Excluded app: its bundle id only, and NO Accessibility call is made.
//  4. Secure keyboard input on: app identity only (`.secureEventInput`).
//  5. Focused element or its role unreadable: app identity only.
//  6. Secure field (role, subrole or role description): identity and field kind
//     only; the title and the text are never asked for.
//  7. Role not on the allow-list: identity only.
//  8. Read the window title and the selected text.
//  9. Read secure input, the frontmost app and the focused element again. If any
//     changed, everything read is dropped (`.focusChanged` / `.secureEventInput`).
// The whole thing has one overall deadline; on expiry the result is an empty
// `.timedOut` snapshot, and a read that overruns is abandoned, never delivered.

/// An opaque handle to one UI element. The real one wraps an `AXUIElement`.
protocol AXElementRef: AnyObject, Sendable {}

enum AXFailure: Error, Equatable, Sendable {
    /// Accessibility permission is off.
    case apiDisabled
    /// The call timed out or the app could not answer (AX reports both this way).
    case cannotComplete
    case invalidElement
    case other
}

/// One attribute read: a value, no value (missing or unsupported), or a failure.
enum AXRead<Value: Sendable>: Sendable {
    case value(Value)
    case absent
    case failure(AXFailure)
}

enum AXTextAttribute: Sendable {
    case role, subrole, roleDescription, title, selectedText
}

struct FrontmostApp: Equatable, Sendable {
    let name: String?
    let bundleID: String?
    let pid: Int32
}

/// Answer to "would a synthetic paste or keystroke at the focused context be
/// safe": secure keyboard input is on system-wide (a Terminal `sudo` prompt, a
/// system password dialog), the focused element itself is a secure field (see
/// `DefaultAccessibilityContextReader.isSecure`), or neither. Separate from
/// `ContextSnapshot.Status` because a caller that only needs this answer (the
/// plain-dictation hotkey, below) must never trigger the fuller read that
/// `ContextSnapshot` is built for.
enum SecureInputCheck: Equatable, Sendable {
    case notSecure
    case secureEventInput
    case secureField
}

/// The few Accessibility and system calls the reader needs. Each call may block
/// (that is why the reader runs off the main thread with a deadline) and must
/// bound itself with a short per-call timeout.
protocol AXProvider: Sendable {
    /// `AXIsProcessTrusted()`.
    func isProcessTrusted() -> Bool
    /// `IsSecureEventInputEnabled()`.
    func isSecureEventInputEnabled() -> Bool
    /// NSWorkspace's frontmost application; no Accessibility call.
    func frontmostApplication() -> FrontmostApp?
    func focusedElement(pid: Int32) -> AXRead<AXElementRef>
    func focusedWindow(pid: Int32) -> AXRead<AXElementRef>
    func string(_ attribute: AXTextAttribute, of element: AXElementRef) -> AXRead<String>
    /// Identity, not equality of attributes: the same UI element.
    func isSameElement(_ a: AXElementRef, _ b: AXElementRef) -> Bool
}

protocol AccessibilityContextReader: Sendable {
    /// Never throws and never returns partial secure content. Runs the reads off
    /// the calling thread and returns within about the reader's deadline.
    func readSnapshot() async -> ContextSnapshot
}

final class DefaultAccessibilityContextReader: AccessibilityContextReader, @unchecked Sendable {
    /// Overall deadline for one snapshot.
    static let defaultDeadline: TimeInterval = 0.5
    /// Reads allowed to be running at once. A hung app can leave a read blocked
    /// past its deadline; a second stuck read is tolerated, a third is refused so
    /// threads cannot pile up behind one unresponsive app.
    static let defaultMaxInFlight = 2

    /// Roles whose title and selected text are read. Anything else (a button, a
    /// table, an unknown role) gives identity only.
    static let textBearingRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXWebArea", "AXStaticText", "AXGroup", "AXScrollArea",
    ]

    private let provider: AXProvider
    private let exclusions: ExcludedApps
    private let deadline: TimeInterval
    private let maxInFlight: Int
    private let workQueue = DispatchQueue(
        label: "context-reader.work", qos: .userInitiated, attributes: .concurrent
    )
    private let timerQueue = DispatchQueue(label: "context-reader.timer", qos: .userInitiated)
    private let lock = NSLock()
    private var inFlight = 0

    init(
        provider: AXProvider,
        exclusions: ExcludedApps = ExcludedApps(),
        deadline: TimeInterval = DefaultAccessibilityContextReader.defaultDeadline,
        maxInFlight: Int = DefaultAccessibilityContextReader.defaultMaxInFlight
    ) {
        self.provider = provider
        self.exclusions = exclusions
        self.deadline = deadline
        self.maxInFlight = maxInFlight
    }

    /// A reader over the real Accessibility API.
    static func system() -> DefaultAccessibilityContextReader {
        DefaultAccessibilityContextReader(provider: SystemAXProvider())
    }

    func readSnapshot() async -> ContextSnapshot {
        await withCheckedContinuation { continuation in
            read { continuation.resume(returning: $0) }
        }
    }

    /// Calls `completion` exactly once, on a background queue: with the snapshot,
    /// or with an empty `.timedOut` (or `.readerBusy`) snapshot at the deadline.
    func read(completion: @escaping @Sendable (ContextSnapshot) -> Void) {
        let once = Once(completion)
        guard acquire() else {
            once.fire(.limited(.readerBusy))
            return
        }
        let provider = provider, exclusions = exclusions
        let timeout = DispatchWorkItem { once.fire(.limited(.timedOut)) }
        workQueue.async { [self] in
            let snapshot = Self.capture(
                provider: provider, exclusions: exclusions, isAbandoned: { once.isDone }
            )
            timeout.cancel()
            once.fire(snapshot)
            release()
        }
        timerQueue.asyncAfter(deadline: .now() + deadline, execute: timeout)
    }

    /// Cheapest possible answer to "is dictated text about to land somewhere a
    /// synthetic paste should never be attempted" — secure keyboard input is on
    /// system-wide, or the focused element is a secure field. Unlike `read`,
    /// this never reads a window title or selected text, not even for an
    /// ordinary field, so there is nothing content-bearing to fetch and discard.
    /// For a caller with no other reason to read Accessibility: the
    /// plain-dictation hotkey, unlike Ask/Edit, has none.
    ///
    /// Calls `completion` exactly once, on a background queue, within about
    /// this reader's deadline. Answers `.notSecure` on timeout, the same
    /// fail-open behaviour `capture` already has for an unreadable role: an
    /// inconclusive read is not a known secure field, so dictation proceeds as
    /// it always has rather than blocking indefinitely on a hung app. Does not
    /// share `read`'s in-flight limit — this is a much cheaper, independent
    /// operation, and must not be refused just because two full snapshots are
    /// already in flight.
    func checkSecureInput(completion: @escaping @Sendable (SecureInputCheck) -> Void) {
        let once = Once(completion)
        let provider = provider
        let timeout = DispatchWorkItem { once.fire(.notSecure) }
        workQueue.async {
            let result = Self.captureSecureInputStatus(provider: provider)
            timeout.cancel()
            once.fire(result)
        }
        timerQueue.asyncAfter(deadline: .now() + deadline, execute: timeout)
    }

    private func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard inFlight < maxInFlight else { return false }
        inFlight += 1
        return true
    }

    private func release() {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
    }

    // MARK: - the decisions

    /// One synchronous read. `isAbandoned` is polled between steps so a read that
    /// has already timed out stops asking the app questions.
    static func capture(
        provider: AXProvider,
        exclusions: ExcludedApps,
        isAbandoned: () -> Bool = { false }
    ) -> ContextSnapshot {
        guard provider.isProcessTrusted() else { return .limited(.notTrusted) }

        guard let app = provider.frontmostApplication() else { return .limited(.noFrontmostApp) }
        guard let rawBundle = app.bundleID,
              let bundleID = ContextText.identifier(rawBundle, maxScalars: ContextSnapshot.maxBundleIDScalars)
        else { return .limited(.appUnidentified) }

        if let reason = exclusions.reason(forBundleID: bundleID) {
            return ContextSnapshot(bundleID: bundleID, excluded: reason)
        }

        func identityOnly(_ status: ContextSnapshot.Status) -> ContextSnapshot {
            ContextSnapshot(status: status, appName: app.name, bundleID: bundleID)
        }
        func abandoned() -> ContextSnapshot { .limited(.timedOut) }

        if provider.isSecureEventInputEnabled() { return identityOnly(.secureEventInput) }
        if isAbandoned() { return abandoned() }

        // The one element every later read uses, so a focus change between reads
        // cannot mix a safe role with another field's text.
        let element: AXElementRef
        switch provider.focusedElement(pid: app.pid) {
        case .value(let e): element = e
        case .absent: return identityOnly(.focusUnavailable)
        case .failure(.apiDisabled): return .limited(.notTrusted)
        case .failure: return identityOnly(.focusUnavailable)
        }
        if isAbandoned() { return abandoned() }

        guard case .value(let role) = provider.string(.role, of: element) else {
            return identityOnly(.roleUnavailable)
        }
        var subrole: String?
        switch provider.string(.subrole, of: element) {
        case .value(let s): subrole = s
        case .absent: subrole = nil
        case .failure: return identityOnly(.roleUnavailable)
        }
        var roleDescription: String?
        switch provider.string(.roleDescription, of: element) {
        case .value(let s): roleDescription = s
        case .absent: roleDescription = nil
        case .failure: return identityOnly(.roleUnavailable)
        }

        if isSecure(role: role, subrole: subrole, roleDescription: roleDescription) {
            return ContextSnapshot(
                status: .secureField, appName: app.name, bundleID: bundleID,
                focusedRole: role, focusedSubrole: subrole, isSecureField: true
            )
        }
        guard textBearingRoles.contains(role) else { return identityOnly(.roleNotAllowed) }
        if isAbandoned() { return abandoned() }

        var flags: [ContextSnapshot.Flag] = []
        var title: String?
        if case .value(let window) = provider.focusedWindow(pid: app.pid),
           case .value(let t) = provider.string(.title, of: window) {
            title = t
        } else {
            // An untitled window and an unreadable one look the same from here.
            flags.append(.windowTitleUnavailable)
        }
        if isAbandoned() { return abandoned() }

        var selection: String?
        if case .value(let text) = provider.string(.selectedText, of: element) {
            selection = text
        } else {
            flags.append(.selectionUnavailable)
        }
        if isAbandoned() { return abandoned() }

        // Nothing read above may be used if the ground moved while reading.
        if provider.isSecureEventInputEnabled() { return identityOnly(.secureEventInput) }
        guard let after = provider.frontmostApplication(), after.pid == app.pid,
              case .value(let again) = provider.focusedElement(pid: app.pid),
              provider.isSameElement(element, again)
        else { return identityOnly(.focusChanged) }

        return ContextSnapshot(
            status: .ok, appName: app.name, bundleID: bundleID, windowTitle: title,
            focusedRole: role, focusedSubrole: subrole, selectedText: selection, flags: flags
        )
    }

    /// Role or subrole `AXSecureTextField`, or a role description that says
    /// "secure" or "password" (web and Electron fields sometimes only say so
    /// there).
    static func isSecure(role: String, subrole: String?, roleDescription: String?) -> Bool {
        if role == ContextSnapshot.secureRole || subrole == ContextSnapshot.secureRole { return true }
        if let d = roleDescription?.lowercased(), d.contains("secure") || d.contains("password") { return true }
        return false
    }

    /// The pure decision `checkSecureInput` wraps, tested directly against a
    /// fake `AXProvider`. `isSecureEventInputEnabled` is checked first and
    /// unconditionally: it needs no Accessibility permission at all, so it
    /// still catches a system password prompt even before the user has granted
    /// Accessibility to this app. Everything after it needs the focused
    /// element, and stops at role, subrole and role description — never a
    /// title, never selected text, matching `isSecure`'s own privacy
    /// discipline: this only ever asks "is it secure", never "what does it say".
    static func captureSecureInputStatus(provider: AXProvider) -> SecureInputCheck {
        if provider.isSecureEventInputEnabled() { return .secureEventInput }
        guard provider.isProcessTrusted() else { return .notSecure }
        guard let app = provider.frontmostApplication() else { return .notSecure }
        guard case .value(let element) = provider.focusedElement(pid: app.pid) else { return .notSecure }
        guard case .value(let role) = provider.string(.role, of: element) else { return .notSecure }
        var subrole: String?
        if case .value(let s) = provider.string(.subrole, of: element) { subrole = s }
        var roleDescription: String?
        if case .value(let s) = provider.string(.roleDescription, of: element) { roleDescription = s }
        return isSecure(role: role, subrole: subrole, roleDescription: roleDescription) ? .secureField : .notSecure
    }
}

/// Delivers a value at most once, from whichever of two racing paths gets there
/// first. The handler is dropped after use.
private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Value) -> Void)?

    init(_ handler: @escaping @Sendable (Value) -> Void) { self.handler = handler }

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return handler == nil
    }

    func fire(_ value: Value) {
        lock.lock()
        let h = handler
        handler = nil
        lock.unlock()
        h?(value)
    }
}
