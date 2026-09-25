import Foundation

/// The one place a rewrite failure becomes user-facing text. Wording follows
/// `brand-voice-tone-guide.md`: say what happened and what happened to the user's
/// text, two sentences at most, no exclamation marks, no apology. Every failure
/// path inserts the raw transcript, and every notice says so.
///
/// The switch has no `default`, so a new `RewriteError` case does not compile
/// until someone chooses its wording. `RewriteNoticeTests` lints the output.
extension RewriteError {
    /// `nil` means show nothing: the caller cancelled, which is not a failure.
    public var userNotice: String? {
        switch self {
        case .cancelled:
            return nil
        case .unreachable, .unavailable, .timedOut:
            return "Couldn't reach the rewrite service. Your raw transcript was inserted instead — nothing was lost."
        case .invalidResponse, .unexpectedStatus:
            // The service answered, so "couldn't reach" would be untrue.
            return "The rewrite service sent back something unusable. Your raw transcript was inserted instead."
        case .offline:
            return "You're offline, and rewrite needs a connection. Your raw transcript was inserted instead."
        case .unauthorized, .notAuthenticated:
            return "You're signed out. Sign in to keep using rewrite — your raw transcript was inserted instead."
        case .requiresPro:
            return "Rewrite is part of Pro. Your raw transcript was inserted instead."
        case .rateLimited:
            return "You've reached your rewrite limit. Your raw transcript was inserted instead."
        case .tooLong:
            return "That dictation is too long to rewrite. Your raw transcript was inserted instead."
        }
    }
}

/// Notices that come from the insertion step rather than from a rewrite error.
/// Same rules as `RewriteError.userNotice`, and linted by `RewriteNoticeTests`.
enum DictationNotice {
    /// The frontmost app changed while the text was being prepared, so nothing
    /// was pasted (pasting would have put it into the wrong app).
    static let switchedApps = "You switched apps before the dictation finished. The text is on your clipboard."

    /// The recording stayed active so long that the text could not be pasted
    /// without waiting indefinitely, so it was put on the clipboard instead.
    static let stillRecording = "You were still recording, so the dictation wasn't pasted. The text is on your clipboard."
}
