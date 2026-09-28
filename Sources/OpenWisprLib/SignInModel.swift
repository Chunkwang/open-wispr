import Foundation

/// The numbers the sign-in flow runs on (docs/design/sign-in.md, top table).
enum SignInTimings {
    /// How long a code is treated as valid. The client stamps the request time and
    /// shows the "expired" copy after this without calling the server. The copy
    /// (`SignInCopy.codeSentTo`) is derived from it, so they cannot drift.
    /// The server's own OTP expiry is set to match on Day 16.
    static let codeLifetimeSeconds = 600
    /// Used after a successful send. A 429 to a send uses its own `Retry-After`.
    static let resendCooldownDefault: TimeInterval = 60
    static let maxWrongTries = 5
    static let lockoutSeconds: TimeInterval = 30
    static let minCodeDigits = 6
    static let maxCodeDigits = 10
    static let maxEmailLength = 254
    /// The longest wait the UI will show or count down. A hostile or broken
    /// `Retry-After` cannot lock the window for days.
    static let maxWaitSeconds = 24 * 60 * 60
}

/// Which request a mapped error came from (docs/design/sign-in.md, 10.5).
enum SignInPhase: Equatable {
    case send
    case verify
}

/// A message in the window's status row. Never holds a code, an email address or
/// any server text.
enum SignInStatus: Equatable {
    case invalidEmail
    case codeRejected
    case codeExpiredLocal
    case tooManyAttempts(until: Date)
    /// Shown as a note (muted, clock icon), not an error.
    case resendCooldown(until: Date)
    case offline
    case timedOut
    case serviceDown

    /// `AuthError` to status, one switch with no `default`, so a new `AuthError`
    /// case does not compile until it is placed. Nil means show nothing (the
    /// caller cancelled). `codeRejected` on verify is always `.codeRejected` here;
    /// the model swaps in `.codeExpiredLocal` when its own timer has run out.
    init?(_ error: AuthError, phase: SignInPhase, now: Date) {
        switch error {
        case .cancelled:
            return nil
        case .invalidEmail:
            self = phase == .send ? .invalidEmail : .serviceDown
        case .codeRejected:
            self = phase == .verify ? .codeRejected : .serviceDown
        case .tooManyAttempts(let retryAfter):
            let until = now.addingTimeInterval(TimeInterval(SignInModel.waitSeconds(retryAfter)))
            self = phase == .verify ? .tooManyAttempts(until: until) : .resendCooldown(until: until)
        case .sendRateLimited(let retryAfter):
            let until = now.addingTimeInterval(TimeInterval(SignInModel.waitSeconds(retryAfter)))
            self = phase == .send ? .resendCooldown(until: until) : .serviceDown
        case .offline:
            self = .offline
        case .timedOut:
            self = .timedOut
        case .unreachable, .unavailable, .invalidResponse:
            self = .serviceDown
        case .storageFailed, .sessionRevoked:
            // Not raised by a send or a verify (a save failure has its own screen).
            self = .serviceDown
        }
    }

    var isCooldownNote: Bool {
        if case .resendCooldown = self { return true }
        return false
    }
}

enum SignInState: Equatable {
    case emailEntry
    case sendingCode(SignInSendOrigin)
    case codeEntry
    case verifying
    /// Writing the verified session to the Keychain (synchronous; a state so the
    /// tests can see it).
    case saving
    case saveFailed
    case signedIn
    case closed
}

enum SignInSendOrigin: Equatable {
    /// From the email step.
    case email
    /// "Send a new code" from the code step.
    case resend
}

enum SignInEvent {
    case emailEdited(String)
    case submitEmail
    case sendSucceeded(generation: Int)
    case sendFailed(AuthError, generation: Int)
    case codeEdited(String)
    case submitCode
    case verifySucceeded(AuthSession, generation: Int)
    case verifyFailed(AuthError, generation: Int)
    case resendTapped
    case changeEmailTapped
    case haveCodeTapped
    case saveSucceeded
    case saveFailed
    case retrySaveTapped
    case tick
    /// Esc, Cmd-W, the close button, Done.
    case closeRequested
}

enum SignInFocus: Equatable {
    case email(selectAll: Bool)
    case code(selectAll: Bool)
    case done
    case retry
}

enum SignInAnnouncementPriority: Equatable {
    case high
    case medium
}

enum SignInEffect: Equatable {
    case requestCode(email: String, generation: Int)
    case verifyCode(email: String, digits: String, generation: Int)
    case storeSession(AuthSession)
    /// The pasteboard is cleared only if it holds this code (spaces and dashes
    /// aside). Anything else the user copied is left alone.
    case clearPasteboardIfItHoldsTheCode(String)
    case announce(String, SignInAnnouncementPriority)
    case focus(SignInFocus)
    /// Best-effort server logout of a session that was verified but never saved.
    case logoutBestEffort(AuthSession)
    case stopTimers
    case closeWindow
}

/// The sign-in window's state machine (docs/design/sign-in.md, section 10). Pure:
/// no UI, no network, no clock of its own. `handle(_:now:)` takes the current
/// time from the caller, so a test advances 600 s without waiting.
///
/// The countdowns (lockout, cooldown, code expiry) are `Date`s, never decrementing
/// counters, so sleep, wake and a throttled timer still give the right remaining
/// time.
///
/// The model holds the entered email and code and, on the save-failure screen,
/// the verified session. None of it is logged or persisted; it is dropped when
/// the window closes.
struct SignInModel {
    // MARK: - State and context

    private(set) var state: SignInState = .emailEntry
    private(set) var email = ""
    private(set) var digits = ""
    /// The stored message. The status row shown on screen is `statusRow(now:)`,
    /// which also derives the lockout, expiry and cooldown from the dates below.
    private(set) var status: SignInStatus?
    private(set) var attempts = 0
    private(set) var codeSentAt: Date?
    private(set) var resendAvailableAt: Date?
    private(set) var resendEmail: String?
    private(set) var lockedUntil: Date?
    /// The verified session while on the save-failure screen (and while saving),
    /// else nil. Never persisted.
    private(set) var pendingSession: AuthSession?
    /// The address to show on the signed-in screen: the one the server reports.
    private(set) var signedInEmail = ""
    private(set) var generation = 0

    private var requestedAt = Date.distantPast
    private var resendReadyAnnounced = true
    private var isRetryingSave = false

    init() {}

    // MARK: - Derived state (what the view reads)

    var isBusy: Bool {
        switch state {
        case .sendingCode, .verifying, .saving: return true
        default: return false
        }
    }

    var isClosed: Bool { state == .closed }

    func isCodeExpired(now: Date) -> Bool {
        guard let sent = codeSentAt else { return false }
        return now >= sent.addingTimeInterval(TimeInterval(SignInTimings.codeLifetimeSeconds))
    }

    func isLockedOut(now: Date) -> Bool {
        guard let until = lockedUntil else { return false }
        return now < until
    }

    /// The end of the send cooldown, when it applies to the address in the field
    /// (compared without regard to case) and has not passed.
    func cooldownUntil(now: Date) -> Date? {
        guard let until = resendAvailableAt, until > now else { return nil }
        return until
    }

    private func cooldownAppliesToEmailField(now: Date) -> Bool {
        guard cooldownUntil(now: now) != nil, let sentTo = resendEmail else { return false }
        return sentTo.caseInsensitiveCompare(email) == .orderedSame
    }

    /// Email step: shows the cooldown note and "I already have a code".
    func emailStepCooldownUntil(now: Date) -> Date? {
        guard state == .emailEntry || state == .sendingCode(.email), cooldownAppliesToEmailField(now: now) else { return nil }
        return resendAvailableAt
    }

    /// Code step: the caption under the buttons.
    func captionCooldownUntil(now: Date) -> Date? {
        state == .codeEntry || state == .sendingCode(.resend) || state == .verifying ? cooldownUntil(now: now) : nil
    }

    /// "I already have a code": only while a send is rate-limited for this address.
    func canOfferHaveCode(now: Date) -> Bool {
        state == .emailEntry && cooldownAppliesToEmailField(now: now)
    }

    func canSendCode(now: Date) -> Bool {
        state == .emailEntry && !email.isEmpty && !cooldownAppliesToEmailField(now: now)
    }

    func canSubmitCode(now: Date) -> Bool {
        state == .codeEntry && digits.count >= SignInTimings.minCodeDigits
            && !isLockedOut(now: now) && !isCodeExpired(now: now)
    }

    func canResend(now: Date) -> Bool {
        state == .codeEntry && cooldownUntil(now: now) == nil
    }

    var canChangeEmail: Bool { state == .codeEntry }

    /// The one message for the status row. On the code step: locked out, then
    /// expired, then the stored message. On the email step: the stored message,
    /// or the send cooldown note.
    func statusRow(now: Date) -> SignInStatus? {
        switch state {
        case .codeEntry, .sendingCode(.resend), .verifying:
            if isLockedOut(now: now), let until = lockedUntil { return .tooManyAttempts(until: until) }
            if isCodeExpired(now: now) { return .codeExpiredLocal }
            return status
        case .emailEntry, .sendingCode(.email):
            if let status = status { return status }
            if let until = emailStepCooldownUntil(now: now) { return .resendCooldown(until: until) }
            return nil
        case .saving, .saveFailed, .signedIn, .closed:
            return nil
        }
    }

    // MARK: - Pure helpers

    /// ASCII digits 0 to 9 only, first 10. Spaces, hyphens of every kind,
    /// non-breaking spaces, letters and full-width digits are all dropped.
    static func filterDigits(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar.value >= 0x30 && scalar.value <= 0x39 {
            out.append(scalar)
            if out.count == SignInTimings.maxCodeDigits { break }
        }
        return String(out)
    }

    /// Leading and trailing whitespace and newlines removed, cut at 254 characters.
    static func normalizedEmailInput(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(SignInTimings.maxEmailLength))
    }

    /// The loose local check of docs/auth-design.md section 6: one `@`, text on
    /// both sides, no whitespace or control characters, at most 254 characters.
    /// The server is the authority; this only catches what cannot be an address.
    static func isPlausibleEmail(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= SignInTimings.maxEmailLength else { return false }
        let bad = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard text.unicodeScalars.allSatisfy({ !bad.contains($0) }) else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    /// `max(1, ceil(retryAfter))`, capped, with an unusable value replaced by the
    /// default.
    static func waitSeconds(_ retryAfter: TimeInterval) -> Int {
        guard retryAfter.isFinite else { return Int(AuthError.defaultRetryAfter) }
        return Int(min(max(retryAfter.rounded(.up), 1), TimeInterval(SignInTimings.maxWaitSeconds)))
    }

    /// True when clipboard text is the entered code, ignoring spaces, newlines and
    /// dashes the user may have copied along with it.
    static func pasteboardText(_ text: String, holdsCode code: String) -> Bool {
        guard !code.isEmpty else { return false }
        let dashes = CharacterSet(charactersIn: "-\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2212}")
        let strip = CharacterSet.whitespacesAndNewlines.union(dashes)
        let stripped = String(String.UnicodeScalarView(text.unicodeScalars.filter { !strip.contains($0) }))
        return stripped == code
    }

    // MARK: - Transitions

    /// Applies one event and returns what the driver must do. Rules for every row:
    /// a result event whose generation is not the current one is dropped; every
    /// event in `closed` is ignored; `closeRequested` from any state closes.
    mutating func handle(_ event: SignInEvent, now: Date) -> [SignInEffect] {
        if state == .closed { return [] }
        if case .closeRequested = event { return close() }

        switch event {
        case .emailEdited(let text): return emailEdited(text)
        case .submitEmail: return submitEmail(now: now)
        case .sendSucceeded(let gen): return sendSucceeded(generation: gen, now: now)
        case .sendFailed(let error, let gen): return sendFailed(error, generation: gen, now: now)
        case .haveCodeTapped: return haveCodeTapped(now: now)
        case .codeEdited(let text): return codeEdited(text)
        case .submitCode: return submitCode(now: now)
        case .verifySucceeded(let session, let gen): return verifySucceeded(session, generation: gen)
        case .verifyFailed(let error, let gen): return verifyFailed(error, generation: gen, now: now)
        case .resendTapped: return resendTapped(now: now)
        case .changeEmailTapped: return changeEmailTapped()
        case .saveSucceeded: return saveSucceeded()
        case .saveFailed: return saveFailed()
        case .retrySaveTapped: return retrySaveTapped()
        case .tick: return tick(now: now)
        case .closeRequested: return close()
        }
    }

    // Rows 1 to 5

    private mutating func emailEdited(_ text: String) -> [SignInEffect] {
        guard state == .emailEntry else { return [] }
        email = SignInModel.normalizedEmailInput(text)
        // The cooldown note is derived from the address, so a stored message is
        // only ever an error, and any edit clears it.
        status = nil
        return []
    }

    private mutating func submitEmail(now: Date) -> [SignInEffect] {
        guard state == .emailEntry, !email.isEmpty else { return [] }
        guard SignInModel.isPlausibleEmail(email) else {
            status = .invalidEmail
            return [announceError(.invalidEmail, now: now)]
        }
        if cooldownAppliesToEmailField(now: now) { return [] }
        state = .sendingCode(.email)
        status = nil
        return [startSend(now: now)]
    }

    private mutating func startSend(now: Date) -> SignInEffect {
        generation += 1
        requestedAt = now
        return .requestCode(email: email, generation: generation)
    }

    // Rows 6, 7, 8, 24, 25, 26

    private mutating func sendSucceeded(generation gen: Int, now: Date) -> [SignInEffect] {
        guard case .sendingCode = state, gen == generation else { return [] }
        state = .codeEntry
        codeSentAt = requestedAt
        resendAvailableAt = now.addingTimeInterval(SignInTimings.resendCooldownDefault)
        resendEmail = email
        resendReadyAnnounced = false
        attempts = 0
        lockedUntil = nil
        digits = ""
        status = nil
        return [.focus(.code(selectAll: false)), .announce(SignInCopy.codeSentTo(email), .high)]
    }

    private mutating func sendFailed(_ error: AuthError, generation gen: Int, now: Date) -> [SignInEffect] {
        guard case .sendingCode(let origin) = state, gen == generation else { return [] }
        let idle: SignInState = origin == .email ? .emailEntry : .codeEntry
        state = idle
        guard let mapped = SignInStatus(error, phase: .send, now: now) else { return [] }

        if case .resendCooldown(let until) = mapped {
            // A code went to this address moments ago. The note is derived from
            // these two fields; nothing is stored in `status`.
            resendAvailableAt = until
            resendEmail = email
            resendReadyAnnounced = false
            status = nil
            return [.announce("\(SignInCopy.voStatusPrefix): \(SignInCopy.text(for: mapped, now: now))", .medium)]
        }
        // A failed send starts no cooldown and leaves the old code and timer alone.
        status = mapped
        var effects = [announceError(mapped, now: now)]
        if origin == .email { effects.append(.focus(.email(selectAll: false))) }
        return effects
    }

    // Row 9

    private mutating func haveCodeTapped(now: Date) -> [SignInEffect] {
        guard state == .emailEntry, cooldownAppliesToEmailField(now: now) else { return [] }
        state = .codeEntry
        // The send time is unknown, so the server stays the authority for expiry:
        // counting from now can only expire later than the server does.
        codeSentAt = now
        attempts = 0
        lockedUntil = nil
        digits = ""
        status = nil
        return [.focus(.code(selectAll: false))]
    }

    // Rows 10 to 13

    private mutating func codeEdited(_ text: String) -> [SignInEffect] {
        guard state == .codeEntry else { return [] }
        digits = SignInModel.filterDigits(text)
        if let current = status, current != .codeExpiredLocal, !isTooManyAttempts(current) { status = nil }
        return []
    }

    private func isTooManyAttempts(_ status: SignInStatus) -> Bool {
        if case .tooManyAttempts = status { return true }
        return false
    }

    private mutating func submitCode(now: Date) -> [SignInEffect] {
        guard state == .codeEntry, digits.count >= SignInTimings.minCodeDigits, !isLockedOut(now: now) else { return [] }
        if isCodeExpired(now: now) {
            status = .codeExpiredLocal
            return [announceError(.codeExpiredLocal, now: now)]
        }
        state = .verifying
        status = nil
        generation += 1
        return [.verifyCode(email: email, digits: digits, generation: generation)]
    }

    // Rows 14 to 16, 33, 34

    private mutating func verifySucceeded(_ session: AuthSession, generation gen: Int) -> [SignInEffect] {
        guard state == .verifying, gen == generation else { return [] }
        state = .saving
        pendingSession = session
        isRetryingSave = false
        return [.storeSession(session)]
    }

    private mutating func saveSucceeded() -> [SignInEffect] {
        guard state == .saving, let session = pendingSession else { return [] }
        let code = digits
        state = .signedIn
        signedInEmail = session.email.isEmpty ? email : session.email
        pendingSession = nil
        isRetryingSave = false
        digits = ""
        status = nil
        return [
            .clearPasteboardIfItHoldsTheCode(code),
            .stopTimers,
            .focus(.done),
            .announce(SignInCopy.signedIn, .high),
        ]
    }

    private mutating func saveFailed() -> [SignInEffect] {
        guard state == .saving else { return [] }
        state = .saveFailed
        if isRetryingSave { return [] }
        return [.announce(SignInCopy.storageFailed, .high), .focus(.retry)]
    }

    private mutating func retrySaveTapped() -> [SignInEffect] {
        guard state == .saveFailed, let session = pendingSession else { return [] }
        state = .saving
        isRetryingSave = true
        return [.storeSession(session)]
    }

    // Rows 17 to 21

    private mutating func verifyFailed(_ error: AuthError, generation gen: Int, now: Date) -> [SignInEffect] {
        guard state == .verifying, gen == generation else { return [] }
        state = .codeEntry

        switch error {
        case .codeRejected:
            if isCodeExpired(now: now) {
                status = .codeExpiredLocal
                return [announceError(.codeExpiredLocal, now: now)]
            }
            attempts += 1
            if attempts >= SignInTimings.maxWrongTries {
                let until = now.addingTimeInterval(SignInTimings.lockoutSeconds)
                lockedUntil = until
                status = .tooManyAttempts(until: until)
                return [announceError(.tooManyAttempts(until: until), now: now)]
            }
            status = .codeRejected
            return [announceError(.codeRejected, now: now), .focus(.code(selectAll: true))]
        default:
            guard let mapped = SignInStatus(error, phase: .verify, now: now) else { return [] }
            if case .tooManyAttempts(let until) = mapped { lockedUntil = until }
            status = mapped
            return [announceError(mapped, now: now)]
        }
    }

    // Rows 22, 23, 27

    private mutating func resendTapped(now: Date) -> [SignInEffect] {
        guard state == .codeEntry, cooldownUntil(now: now) == nil else { return [] }
        state = .sendingCode(.resend)
        // A lockout message stays; anything else belongs to the old attempt.
        if let current = status, !isTooManyAttempts(current) { status = nil }
        return [startSend(now: now)]
    }

    private mutating func changeEmailTapped() -> [SignInEffect] {
        guard state == .codeEntry else { return [] }
        state = .emailEntry
        digits = ""
        attempts = 0
        lockedUntil = nil
        codeSentAt = nil
        status = nil
        // The cooldown (resendAvailableAt, resendEmail) is kept: sending to the
        // same address inside it shows the note, not a second email.
        return [.focus(.email(selectAll: true))]
    }

    // Rows 28 to 32

    private mutating func tick(now: Date) -> [SignInEffect] {
        guard state == .codeEntry else { return [] }
        var effects: [SignInEffect] = []

        if let until = lockedUntil, now >= until {
            lockedUntil = nil
            attempts = 0
            if let current = status, isTooManyAttempts(current) { status = nil }
            effects.append(.announce(SignInCopy.lockoutEnded, .medium))
        }
        if status != .codeExpiredLocal, isCodeExpired(now: now), !isLockedOut(now: now) {
            status = .codeExpiredLocal
            effects.append(announceError(.codeExpiredLocal, now: now))
        }
        if !resendReadyAnnounced, let until = resendAvailableAt, now >= until {
            resendReadyAnnounced = true
            effects.append(.announce(SignInCopy.resendReady, .medium))
        }
        return effects
    }

    // Rows 35 to 37

    private mutating func close() -> [SignInEffect] {
        var effects: [SignInEffect] = []
        if let session = pendingSession {
            // Verified but never saved: do not leave the server session orphaned.
            effects.append(.logoutBestEffort(session))
        }
        state = .closed
        generation += 1
        email = ""
        digits = ""
        status = nil
        attempts = 0
        codeSentAt = nil
        resendAvailableAt = nil
        resendEmail = nil
        lockedUntil = nil
        pendingSession = nil
        signedInEmail = ""
        effects.append(contentsOf: [.stopTimers, .closeWindow])
        return effects
    }

    // MARK: - Announcements

    private func announceError(_ status: SignInStatus, now: Date) -> SignInEffect {
        .announce("\(SignInCopy.voErrorPrefix): \(SignInCopy.text(for: status, now: now))", .high)
    }
}
