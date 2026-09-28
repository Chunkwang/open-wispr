import Foundation

/// Every user-visible string of the sign-in window, its DEBUG menu items and the
/// sign-out notice, in one place. Wording is `docs/design/sign-in-copy.md`,
/// verbatim, and follows `brand-voice-tone-guide.md`: calm, specific, no
/// apology, no exclamation mark, two sentences at most. Nothing here reveals
/// whether an address already has an account.
///
/// `SignInCopyTests` lints every string and checks the set of keys against the
/// copy doc. The keys are the names used in the doc and in
/// `docs/auth-design.md` section 6.
enum SignInCopy {
    // MARK: - Messages

    static let emailPrompt = "Enter your email address. We'll send you a code to sign in."
    static let sendingCode = "Sending code…"
    static func codeSentTo(_ email: String) -> String {
        "Code sent to \(email). It expires in \(SignInTimings.codeLifetimeSeconds / 60) minutes."
    }
    static let codePrompt = "Enter the code from the email."
    static let signedIn = "You're signed in."
    static let signedOut = "You're signed out."
    static let signOutSignedOutNotice = "Signed out. Dictation still works; sign in to use rewrite."
    static let invalidEmail = "That email address doesn't look valid. Check it and try again."
    /// ONE string for a wrong and an expired code: the server cannot tell them
    /// apart, so the client must not guess.
    static let codeRejected = "That code is wrong or has expired. Check the latest email or send a new code."
    static let codeExpiredLocal = "This code has expired. Send a new code."
    static func tooManyAttempts(waitSeconds: Int) -> String {
        "Too many attempts. Try again in \(secondsPhrase(waitSeconds)), or send a new code."
    }
    static func resendCooldown(waitSeconds: Int) -> String {
        "You can request a new code in \(secondsPhrase(waitSeconds))."
    }
    static let offline = "You're offline, and sign-in needs a connection. Try again once you're back online."
    static let timedOut = "The sign-in service didn't answer in time. Try again."
    static let serviceDown = "The sign-in service isn't working as expected. Try again in a few minutes."
    static let storageFailed = "Your code was accepted, but this Mac wouldn't let the app save the sign-in. Try saving again."
    static let signOutFailed = "Couldn't remove your sign-in from this Mac. You're still signed in."
    /// Day 5: shown when a refresh fails for good. Not used by the Day 4 window.
    static let sessionRevoked = "You're signed out. Sign in to keep using rewrite."

    // MARK: - Window text that is not a message

    static let windowTitle = "Sign in"
    static let emailPrivacyNote = "Your email address goes to our sign-in service and its email provider to deliver the code."
    static func signedInAs(_ email: String) -> String { "Signed in as \(email)." }
    static let lockoutEnded = "You can try the code again."
    static let resendReady = "You can request a new code now."
    static let verifyingCode = "Checking code…"
    static let savingSession = "Saving sign-in…"

    // MARK: - Field labels and placeholders

    static let emailFieldLabel = "Email address"
    static let emailPlaceholder = "you@example.com"
    static let codeFieldLabel = "Sign-in code"
    static let codePlaceholder = "6-digit code"

    // MARK: - Buttons

    static let sendCodeButton = "Send code"
    static let signInButton = "Sign in"
    static let resendCodeButton = "Send a new code"
    static let changeEmailButton = "Use a different email"
    static let haveCodeButton = "I already have a code"
    static let doneButton = "Done"
    static let retrySaveButton = "Try saving again"

    // MARK: - Menu items

    static let menuSignIn = "Sign in…"
    /// The menu line shows at most 40 characters of the address, cut in the
    /// middle; the item's tooltip carries the full address.
    static func menuSignedInAs(_ email: String) -> String {
        "Signed in as \(truncatedMiddle(email, limit: menuEmailLimit))"
    }
    static let menuSignOut = "Sign out"
    static let menuSignInUnavailable = "Sign-in status unavailable"
    static let menuEmailLimit = 40

    // MARK: - VoiceOver

    static let voEmailFieldHint = "Type the address to send the code to."
    static let voSendCodeHint = "Sends a sign-in code to this address."
    static let voCodeFieldHint = "Type the code from the email. Digits only."
    static let voSignInHint = "Checks the code and signs you in."
    static let voResendHint = "Sends a new code. The old code stops working."
    static let voChangeEmailHint = "Goes back to enter another address."
    static let voHaveCodeHint = "Skips sending and goes to code entry."
    static let voDoneHint = "Closes this window."
    static let voRetrySaveHint = "Tries again to save your sign-in on this Mac."
    static let voErrorPrefix = "Error"
    static let voStatusPrefix = "Note"

    // MARK: - Helpers

    /// "1 second", "2 to 120 seconds", then whole minutes rounded up (Supabase
    /// can rate-limit for an hour, and "3600 seconds" is not readable). Below 1
    /// counts as 1.
    static func secondsPhrase(_ waitSeconds: Int) -> String {
        let wait = max(1, waitSeconds)
        if wait == 1 { return "1 second" }
        if wait <= 120 { return "\(wait) seconds" }
        return "\((wait + 59) / 60) minutes"
    }

    /// Keeps the start and end of `text` and puts "…" in the middle when it is
    /// longer than `limit` characters. The result is at most `limit` long.
    static func truncatedMiddle(_ text: String, limit: Int) -> String {
        let chars = Array(text)
        guard limit >= 3, chars.count > limit else { return text }
        let keep = limit - 1
        let head = (keep + 1) / 2
        let tail = keep / 2
        return String(chars.prefix(head)) + "…" + String(chars.suffix(tail))
    }

    /// The whole seconds left until `date`, at least 1 while it is in the future.
    static func remainingSeconds(until date: Date, now: Date) -> Int {
        max(1, Int(date.timeIntervalSince(now).rounded(.up)))
    }

    // MARK: - Status and error mapping

    /// The text of a status-row message. `now` turns the end of a lockout or
    /// cooldown into the number of seconds left.
    static func text(for status: SignInStatus, now: Date) -> String {
        switch status {
        case .invalidEmail: return invalidEmail
        case .codeRejected: return codeRejected
        case .codeExpiredLocal: return codeExpiredLocal
        case .tooManyAttempts(let until): return tooManyAttempts(waitSeconds: remainingSeconds(until: until, now: now))
        case .resendCooldown(let until): return resendCooldown(waitSeconds: remainingSeconds(until: until, now: now))
        case .offline: return offline
        case .timedOut: return timedOut
        case .serviceDown: return serviceDown
        }
    }

    /// The message an `AuthError` produces in the sign-in flow, or nil when it
    /// deserves no message (a cancelled request is not a failure). One switch,
    /// no `default`, so a new `AuthError` case does not compile until someone
    /// chooses its wording (the model has the matching status mapping).
    static func message(for error: AuthError, phase: SignInPhase, now: Date) -> String? {
        switch error {
        case .cancelled:
            return nil
        case .storageFailed:
            return storageFailed
        case .sessionRevoked:
            return sessionRevoked
        case .invalidEmail, .codeRejected, .tooManyAttempts, .sendRateLimited,
             .offline, .timedOut, .unreachable, .unavailable, .invalidResponse:
            guard let status = SignInStatus(error, phase: phase, now: now) else { return nil }
            return text(for: status, now: now)
        }
    }
}
