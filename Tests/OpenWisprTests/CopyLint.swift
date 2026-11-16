import Foundation

/// The brand-voice rules shared by every copy lint test (`RewriteNoticeTests`,
/// `SignInCopyTests`), in one place so the two cannot drift apart.
enum CopyLint {
    /// Words the voice guide bans. A substring match, so "adjust" and "justify"
    /// are caught by "just" too, which is fine.
    static let banned = ["smart", "seamless", "powerful", "magic", "simply", "oops", "just", "sorry", "apolog", "unfortunately"]

    /// Counts `.` and `?` that end a sentence: followed by a space or the end of
    /// the text. A dot inside "example.com" does not count.
    static func sentenceCount(_ text: String) -> Int {
        var count = 0
        let chars = Array(text)
        for (i, c) in chars.enumerated() where c == "." || c == "?" {
            if i + 1 == chars.count || chars[i + 1] == " " { count += 1 }
        }
        return count
    }
}
