import Foundation

/// What the Level-1 context reader saw in the frontmost app at one moment: which
/// app, the focused window's title, the kind of field the cursor is in and the
/// text selected there (Stage C, tasks C1 and C2).
///
/// The type is built to fail closed. Every path that creates a value, including
/// decoding, goes through the one initialiser, which cleans and caps each field
/// and then applies the redaction rules, so a value that breaks them cannot
/// exist:
///
/// - A secure text field (by role, subrole or the `isSecureField` flag) never has
///   selected text or a window title. Only the app identity and the field kind
///   remain. The same holds when secure keyboard input was on (`.secureEventInput`).
/// - An excluded app keeps nothing but its bundle identifier.
/// - Any status other than `.ok` carries no selected text and no window title,
///   and the statuses that mean "could not tell" carry no app identity either.
/// - Text is stripped of control, bidi and invisible characters and cut to the
///   caps below; a cut is reported in `flags`, never silent, because a caller
///   that replaces the selection must know it did not see all of it.
///
/// `description`, `debugDescription` and the reflection mirror are redacted, so
/// string interpolation, `print` and `dump` cannot leak the text. The Codable
/// output does contain the text on purpose: that is the form that would be sent,
/// after consent, and only a deliberate encode produces it.
struct ContextSnapshot: Codable, Equatable, Sendable {
    // MARK: - hard caps

    /// Selected text, counted in Unicode scalars ("code points").
    static let maxSelectedTextScalars = 8_000
    static let maxWindowTitleScalars = 200
    static let maxAppNameScalars = 100
    static let maxBundleIDScalars = 255
    static let maxRoleScalars = 64

    /// The value AX uses for both role and subrole of a password field.
    static let secureRole = "AXSecureTextField"

    /// Why a snapshot holds less than everything, or why it holds nothing.
    enum Status: String, Codable, Sendable {
        case ok
        /// Accessibility permission is not granted.
        case notTrusted
        /// Secure keyboard input is on (a password field somewhere has focus).
        case secureEventInput
        /// The overall deadline passed before the read finished.
        case timedOut
        /// Earlier reads were still stuck, so no new one was started.
        case readerBusy
        case noFrontmostApp
        /// The frontmost app has no usable bundle identifier.
        case appUnidentified
        case excludedApp
        case secureField
        /// The focused element could not be read (error, timeout or none).
        case focusUnavailable
        /// The focused element's role could not be read.
        case roleUnavailable
        /// The role is not one we read text from.
        case roleNotAllowed
        /// Focus or secure input changed while reading; what was read is dropped.
        case focusChanged
        case unavailable

        /// Statuses that mean "we could not tell what is on screen": no app
        /// identity is kept, so nothing partial is passed on.
        fileprivate var keepsNothing: Bool {
            switch self {
            case .notTrusted, .timedOut, .readerBusy, .noFrontmostApp, .appUnidentified: return true
            default: return false
            }
        }

        /// Statuses that keep the app identity but no field or text.
        fileprivate var keepsIdentityOnly: Bool {
            switch self {
            case .focusUnavailable, .roleUnavailable, .roleNotAllowed, .focusChanged, .unavailable: return true
            default: return false
            }
        }
    }

    enum ExclusionReason: String, Codable, Sendable {
        /// On the built-in list (`DefaultExcludedApps`).
        case defaultList
        /// On the user's list (a config key that does not exist yet).
        case userList
        /// This app itself.
        case appItself
        /// Excluded, reason not recorded (only from decoding old or odd data).
        case unspecified
    }

    /// Source-quality notes about what is in the snapshot.
    enum Flag: String, Codable, Sendable, Comparable {
        case selectedTextTruncated
        case windowTitleTruncated
        /// Some scalars were removed from the selected text as unsafe or invisible.
        case selectedTextCleaned
        /// The window title could not be read.
        case windowTitleUnavailable
        /// The selected text could not be read (attribute missing or a read error).
        /// No selection at all is `selectedText == nil` without this flag.
        case selectionUnavailable

        static func < (lhs: Flag, rhs: Flag) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let status: Status
    let appName: String?
    let bundleID: String?
    let windowTitle: String?
    let focusedRole: String?
    let focusedSubrole: String?
    let selectedText: String?
    let isSecureField: Bool
    let excluded: ExclusionReason?
    /// Sorted, without duplicates.
    let flags: [Flag]

    init(
        status: Status = .ok,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil,
        focusedRole: String? = nil,
        focusedSubrole: String? = nil,
        selectedText: String? = nil,
        isSecureField: Bool = false,
        excluded: ExclusionReason? = nil,
        flags: [Flag] = []
    ) {
        let bundle = bundleID.flatMap { ContextText.identifier($0, maxScalars: Self.maxBundleIDScalars) }

        // Excluded apps: nothing but the identifier.
        if excluded != nil || status == .excludedApp {
            self.init(only: bundle, status: .excludedApp, excluded: excluded ?? .unspecified)
            return
        }

        let name = appName.flatMap { Self.singleLine($0, max: Self.maxAppNameScalars).text }
        let role = focusedRole.flatMap { ContextText.identifier($0, maxScalars: Self.maxRoleScalars) }
        let subrole = focusedSubrole.flatMap { ContextText.identifier($0, maxScalars: Self.maxRoleScalars) }
        let secure = isSecureField || status == .secureField
            || role == Self.secureRole || subrole == Self.secureRole

        if status.keepsNothing {
            self.init(only: nil, status: status, excluded: nil)
            return
        }
        if secure {
            self.init(
                verified: .secureField, appName: name, bundleID: bundle, windowTitle: nil,
                focusedRole: role, focusedSubrole: subrole, selectedText: nil,
                isSecureField: true, excluded: nil, flags: []
            )
            return
        }
        if status == .secureEventInput {
            self.init(
                verified: .secureEventInput, appName: name, bundleID: bundle, windowTitle: nil,
                focusedRole: nil, focusedSubrole: nil, selectedText: nil,
                isSecureField: false, excluded: nil, flags: []
            )
            return
        }
        if status.keepsIdentityOnly {
            self.init(
                verified: status, appName: name, bundleID: bundle, windowTitle: nil,
                focusedRole: nil, focusedSubrole: nil, selectedText: nil,
                isSecureField: false, excluded: nil, flags: []
            )
            return
        }

        // status == .ok: keep the fields, cleaned and capped.
        var noted = Set(flags)
        // Cap and cleaning flags are recomputed from the text; stale ones go.
        noted.subtract([.selectedTextTruncated, .windowTitleTruncated, .selectedTextCleaned])

        var cleanedTitle: String?
        if let windowTitle {
            let c = Self.singleLine(windowTitle, max: Self.maxWindowTitleScalars)
            cleanedTitle = c.text
            if c.truncated { noted.insert(.windowTitleTruncated) }
        }
        var cleanedSelection: String?
        if let selectedText {
            let c = ContextText.clean(selectedText, maxScalars: Self.maxSelectedTextScalars, multiline: true)
            cleanedSelection = c.text
            if c.truncated { noted.insert(.selectedTextTruncated) }
            if c.removedUnsafe { noted.insert(.selectedTextCleaned) }
        }
        // A selection that was read successfully (or is empty) is not "unavailable".
        if cleanedSelection != nil { noted.remove(.selectionUnavailable) }
        if cleanedTitle != nil { noted.remove(.windowTitleUnavailable) }

        self.init(
            verified: .ok, appName: name, bundleID: bundle, windowTitle: cleanedTitle,
            focusedRole: role, focusedSubrole: subrole, selectedText: cleanedSelection,
            isSecureField: false, excluded: nil, flags: noted.sorted()
        )
    }

    /// Memberwise, for values the initialiser has already normalised.
    private init(
        verified status: Status, appName: String?, bundleID: String?, windowTitle: String?,
        focusedRole: String?, focusedSubrole: String?, selectedText: String?,
        isSecureField: Bool, excluded: ExclusionReason?, flags: [Flag]
    ) {
        self.status = status
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.focusedRole = focusedRole
        self.focusedSubrole = focusedSubrole
        self.selectedText = selectedText
        self.isSecureField = isSecureField
        self.excluded = excluded
        self.flags = flags
    }

    private init(only bundleID: String?, status: Status, excluded: ExclusionReason?) {
        self.init(
            verified: status, appName: nil, bundleID: bundleID, windowTitle: nil,
            focusedRole: nil, focusedSubrole: nil, selectedText: nil,
            isSecureField: false, excluded: excluded, flags: []
        )
    }

    /// An empty snapshot that only says why nothing was read. Statuses that keep
    /// an app identity (`.secureEventInput` and the `keepsIdentityOnly` ones) are
    /// better made with the full initialiser.
    static func limited(_ status: Status) -> ContextSnapshot {
        ContextSnapshot(status: status)
    }

    private static func singleLine(_ text: String, max: Int) -> ContextText.Cleaned {
        ContextText.clean(text, maxScalars: max, multiline: false)
    }

    // MARK: - use

    /// The snapshot with every rule applied again. Values are already normalised,
    /// so this returns an equal value; callers that hold one from somewhere else
    /// (a decoded copy, a test double) call it before using or sending anything.
    func redacted() -> ContextSnapshot {
        ContextSnapshot(
            status: status, appName: appName, bundleID: bundleID, windowTitle: windowTitle,
            focusedRole: focusedRole, focusedSubrole: focusedSubrole, selectedText: selectedText,
            isSecureField: isSecureField, excluded: excluded, flags: flags
        )
    }

    /// True when the snapshot may be used as context: fully read and not protected.
    var isUsable: Bool { status == .ok }

    /// True when the selected text was cut, so a replace of "the selection" would
    /// cover text the reader never saw.
    var selectionIsIncomplete: Bool { flags.contains(.selectedTextTruncated) }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case status, appName, bundleID, windowTitle, focusedRole, focusedSubrole
        case selectedText, isSecureField, excluded, flags
    }

    /// Decoding goes through the normalising initialiser, so JSON that claims
    /// text for a secure field, or a 10 MB selection, cannot produce such a value.
    /// An unknown status or flag is a decode failure, not a guess.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            status: try c.decodeIfPresent(Status.self, forKey: .status) ?? .unavailable,
            appName: try c.decodeIfPresent(String.self, forKey: .appName),
            bundleID: try c.decodeIfPresent(String.self, forKey: .bundleID),
            windowTitle: try c.decodeIfPresent(String.self, forKey: .windowTitle),
            focusedRole: try c.decodeIfPresent(String.self, forKey: .focusedRole),
            focusedSubrole: try c.decodeIfPresent(String.self, forKey: .focusedSubrole),
            selectedText: try c.decodeIfPresent(String.self, forKey: .selectedText),
            isSecureField: try c.decodeIfPresent(Bool.self, forKey: .isSecureField) ?? false,
            excluded: try c.decodeIfPresent(ExclusionReason.self, forKey: .excluded),
            flags: try c.decodeIfPresent([Flag].self, forKey: .flags) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(appName, forKey: .appName)
        try c.encodeIfPresent(bundleID, forKey: .bundleID)
        try c.encodeIfPresent(windowTitle, forKey: .windowTitle)
        try c.encodeIfPresent(focusedRole, forKey: .focusedRole)
        try c.encodeIfPresent(focusedSubrole, forKey: .focusedSubrole)
        try c.encodeIfPresent(selectedText, forKey: .selectedText)
        try c.encode(isSecureField, forKey: .isSecureField)
        try c.encodeIfPresent(excluded, forKey: .excluded)
        try c.encode(flags, forKey: .flags)
    }
}

// MARK: - redacted descriptions

extension ContextSnapshot: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Never includes the app name, the window title or the selected text: only
    /// the status, the field kind, flags and lengths.
    var description: String {
        var parts = ["status: \(status.rawValue)"]
        if let focusedRole { parts.append("role: \(focusedRole)") }
        if isSecureField { parts.append("secure") }
        if let excluded { parts.append("excluded: \(excluded.rawValue)") }
        if let selectedText { parts.append("selectedText: <redacted, \(selectedText.unicodeScalars.count) scalars>") }
        if windowTitle != nil { parts.append("windowTitle: <redacted>") }
        if !flags.isEmpty { parts.append("flags: \(flags.map(\.rawValue).joined(separator: ","))") }
        return "ContextSnapshot(\(parts.joined(separator: ", ")))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [
            "status": status.rawValue,
            "hasSelectedText": selectedText != nil,
            "hasWindowTitle": windowTitle != nil,
            "isSecureField": isSecureField,
        ], displayStyle: .struct)
    }
}
