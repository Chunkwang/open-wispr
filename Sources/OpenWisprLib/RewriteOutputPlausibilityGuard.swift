import Foundation

/// Output-side guard for `FoundationModelsPipeline`: catches the case where the
/// on-device model, despite the prompt-side hardening in `promptText` and
/// `instructionsText` (the random-suffix delimiter tag and the repeated
/// before/after reminders), still complies with an instruction embedded in the
/// transcript and returns an unrelated reply instead of a cleanup of the
/// transcript. Two rounds of prompt hardening did not close this gap (see
/// `FoundationModelsPipelineTests`'s injection test); this is the second line
/// of defense, checked after the model responds and before its text is
/// trusted.
///
/// Mirrors `RewriteSanitizer`'s SHAPE — a focused check on untrusted model
/// output, with its own tests, feeding the same "reject and fall back to the
/// raw transcript" path — but not its specific rule: `RewriteSanitizer`'s
/// 30%-of-length truncation rule assumes a same-length rewrite and only
/// applies past 200 characters, so it does not catch a short reply (see
/// `testLiveRewriteResistsAnInjectionStyleTranscript`, which is shorter than
/// that threshold). This checks CONTENT resemblance instead: a genuine
/// cleanup keeps nearly all of the transcript's significant words (it only
/// fixes casing/punctuation and drops filler); an injected reply, whatever
/// word or sentence it contains, was never derived from the transcript's
/// words in the first place, so it shares almost none of them — regardless of
/// how short or how long the transcript is.
///
/// HONESTY, same framing as `InjectionDetector`: this is a best-effort,
/// defense-in-depth heuristic, not a guarantee.
/// - What it catches: a blatant non-cleanup reply — a bare attacker-requested
///   word or sentence that shares almost none of the transcript's content
///   words, in any language (the check is word-based, not English-specific).
/// - What it does NOT catch: a subtler injected output built to superficially
///   resemble a cleaned transcript while still being wrong — for example one
///   that keeps most of the original words but changes a key fact, name, or
///   number, or one padded with enough of the transcript's own words to clear
///   the overlap floor while still slipping in extra content. That class of
///   attack is semantic, and a word-overlap count cannot see it.
/// - Structured, schema-constrained output (`FoundationModels.Generable` /
///   `@Guide`) was investigated as a possible additional layer and does NOT
///   help here: tested live on this machine, a `@Generable` struct with a
///   `@Guide`-described field asking for "the cleaned-up transcript... never a
///   reply, answer, or action requested by them" still came back with the
///   model's literal "HACKED" as that field's value. A schema constrains the
///   SHAPE of the response, not its truthfulness, so it is not used here —
///   this file's output check is the actual mitigation.
enum RewriteOutputPlausibilityGuard {
    /// Below this fraction of the transcript's significant words surviving
    /// into the output, the output is treated as not a cleanup of it. Genuine
    /// cleanups (fix casing/punctuation, drop filler) keep close to all of
    /// them; a replacement reply typically keeps close to none. 0.5 sits with
    /// margin on both sides of that gap without being so strict that a
    /// legitimately reworded phrase (contractions expanded, a word
    /// re-ordered) gets rejected.
    static let minimumOverlapRatio = 0.5

    /// Filler words `instructionsText` explicitly tells the model it may
    /// drop. Excluded from "must survive into the output" so a real cleanup
    /// that removes them, exactly as asked, is never penalized for doing its
    /// job.
    private static let explicitlyDroppableFillers: Set<String> = ["um", "umm", "uh", "uhh", "like"]

    /// True if `output` plausibly is a cleaned-up version of `raw` — not
    /// proof, see the type's documentation.
    static func looksLikeACleanup(of raw: String, output: String) -> Bool {
        let significant = significantWords(in: raw)
        // Nothing meaningful to check the output against (for example the raw
        // transcript was itself only filler); nothing to reject on either.
        guard !significant.isEmpty else { return true }
        let outputLowercased = output.lowercased()
        let matched = significant.filter { outputLowercased.contains($0) }
        return Double(matched.count) / Double(significant.count) >= minimumOverlapRatio
    }

    /// Lowercased, deduplicated words of at least 3 characters, minus the
    /// explicitly droppable fillers above. The 3-character floor drops short
    /// function words ("a", "to", "is", "ok") that carry little content and
    /// that a light cleanup routinely reflows or drops anyway, without a hand
    /// -maintained stopword list beyond the fillers the model is explicitly
    /// told it may remove. Word-based, not English-specific: this is a plain
    /// Unicode alphanumeric scan, so it applies the same way to transcripts in
    /// any language or script.
    private static func significantWords(in text: String) -> Set<String> {
        var words: Set<String> = []
        var current = ""
        func flush() {
            defer { current = "" }
            guard current.count >= 3, !explicitlyDroppableFillers.contains(current) else { return }
            words.insert(current)
        }
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return words
    }
}
