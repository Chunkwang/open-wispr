import Foundation

/// Local-only debug timing for one dictation attempt, from hotkey press to
/// pasted text. Lines are printed with `print`, the same mechanism
/// `AppDelegate` and `Transcriber` already use for debug output — nothing
/// here opens a socket, writes a file, or leaves the device. This is a
/// console aid for measuring the pipeline, not the backend's request log.
///
/// Every stage of one dictation attempt shares a `token` so the lines can be
/// matched up afterward in the console (e.g. `grep token=ab12cd34`). The
/// token is a random short string, not a hash of anything the user said.
///
/// Hard stop: this logs stage names and elapsed time only. It must never be
/// given the dictated text, an instruction, or any other content string —
/// see CLAUDE.md's "no secrets in... logs" / never log keystroke or dictated
/// text content.
enum DictationTiming {
    /// One correlation id per dictation attempt (key-down to paste, or
    /// whatever the attempt actually reaches before it stops).
    typealias Token = String

    /// Stages in pipeline order. `frameGrab` only fires for Context/Ask mode
    /// (not yet wired — see AskCoordinator.swift's screen-capture call site).
    enum Stage: String {
        case keyDown = "key_down"
        case frameGrab = "frame_grab"
        case asrStart = "asr_start"
        case asrDone = "asr_done"
        case cleanupDone = "cleanup_done"
        case pasteDone = "paste_done"
    }

    /// A fresh, non-empty correlation id. Short enough to scan by eye in the
    /// console; not a secret and not persisted anywhere.
    static func newToken() -> Token {
        String(UUID().uuidString.prefix(8))
    }

    /// Prints one timestamped line for `stage`, correlated by `token`.
    /// `detail` is a short, fixed status word only (e.g. "ok", "error") —
    /// never free text, and never the dictated content.
    ///
    /// `token` is optional only so a call site with nothing to correlate yet
    /// (shouldn't happen in practice, but cheaper than crashing) still
    /// produces a line instead of being silently skipped; it prints as
    /// `token=-`.
    ///
    /// `now` is injectable so a test can fix the clock; production always
    /// uses `CFAbsoluteTimeGetCurrent()`.
    static func mark(
        _ token: Token?,
        _ stage: Stage,
        detail: String? = nil,
        now: () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent
    ) {
        let t = now()
        let tokenPart = (token?.isEmpty == false) ? token! : "-"
        var line = "[timing] token=\(tokenPart) stage=\(stage.rawValue) t=\(String(format: "%.3f", t))"
        if let detail, !detail.isEmpty {
            line += " detail=\(detail)"
        }
        print(line)
    }
}
