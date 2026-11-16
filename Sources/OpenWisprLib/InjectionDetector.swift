import Foundation

/// A best-effort, defense-in-depth heuristic: a short blocklist of English
/// phrases that commonly appear in prompt-injection attempts, checked against
/// text this app read from elsewhere (a screenshot, a selection, a window
/// title, an accessibility label) before that text is sent anywhere.
///
/// This is NOT the app's protection against prompt injection and must never be
/// described as such. A blocklist of a handful of English phrases is trivially
/// bypassed (paraphrasing, another language, Unicode tricks, splitting a phrase
/// across characters) and proves nothing when it finds no match. The durable
/// protection is server-side: `/v1/edit`'s prompt (`backend/proxy/src/editPrompt.ts`)
/// wraps the selection and window context in a random, per-request delimiter
/// that content cannot predict or close early, and instructs the model to treat
/// both blocks as data only, regardless of what they say. This client-side check
/// exists only to catch the crudest, most obvious attempts before they leave the
/// device, and to give the user a plain notice instead of silently sending them;
/// every caller must still assume the server-side isolation is what actually
/// protects it.
public enum InjectionDetector {

    // A basic allow-list/block-list of common prompt-injection phrases. A match
    // does not prove an attack, and no match does not prove the text is safe.
    private static let blockedPhrases = [
        "ignore all previous instructions",
        "ignore previous instructions",
        "forget all previous instructions",
        "forget your instructions",
        "new instructions:",
        "system prompt:"
    ]

    /// Returns true if the provided text contains one of the blocked phrases.
    /// A false result is not a safety guarantee (see the type's documentation).
    public static func containsInjection(text: String) -> Bool {
        let lowercased = text.lowercased()
        for phrase in blockedPhrases {
            if lowercased.contains(phrase) {
                return true
            }
        }
        return false
    }
}
