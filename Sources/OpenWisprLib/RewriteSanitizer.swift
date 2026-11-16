import Foundation

/// Checks the text a rewrite service returns before it can be pasted. The proxy is
/// the only source, but its reply crosses a network and lands in whatever app has
/// focus, possibly a terminal, so it is treated as untrusted: anything that could
/// act as input rather than text is removed, and a reply that does not look like
/// a rewrite of what was dictated is rejected. A rejection means the caller
/// inserts the raw transcript instead.
enum RewriteSanitizer {
    enum Rejection: Error, Equatable {
        /// Much longer than a rewrite of the transcript can be.
        case tooLong
        /// Far shorter than the transcript: the reply was cut off or is not a rewrite.
        case truncated
        /// Nothing usable is left after cleaning.
        case empty
    }

    /// Upper bound on the result, however long the transcript was.
    static let absoluteMaxLength = 20_000
    /// A long transcript that comes back shorter than this many tenths of its
    /// length (3 = 30%) is treated as truncated. Short transcripts are exempt: a
    /// cleanup of "um yes" is legitimately a fraction of its length.
    static let minimumTenthsOfLongTranscript = 3
    static let longTranscriptThreshold = 200

    static func maximumLength(forRawLength rawLength: Int) -> Int {
        min(absoluteMaxLength, 3 * rawLength + 200)
    }

    static func sanitize(_ text: String, raw: String) -> Result<String, Rejection> {
        // Length first, on the untrusted input and before any cleaning, so padding
        // cannot slip past the cap. It is counted in Unicode scalars, not
        // Characters: a base letter followed by millions of combining marks,
        // variation selectors or joiners is ONE Character but millions of scalars.
        // The utf8 count is a constant-time cut-off for the absurd cases.
        let limit = maximumLength(forRawLength: raw.count)
        guard text.utf8.count <= 4 * limit, text.unicodeScalars.count <= limit else {
            return .failure(.tooLong)
        }

        let rawScalars = raw.unicodeScalars
        let rawHasNewline = rawScalars.contains { isLineBreak($0) }
        let context = KeepContext(raw: rawScalars)

        var cleaned = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            defer { previous = scalar }
            // CRLF is one line break, not two.
            if scalar == "\n" && previous == "\r" { continue }
            if isLineBreak(scalar) {
                cleaned.append("\n")
            } else if isAllowed(scalar, context: context) {
                cleaned.append(scalar)
            }
        }
        var result = String(cleaned)

        if !rawHasNewline {
            result = collapseNewlines(result)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !result.isEmpty else { return .failure(.empty) }
        if raw.count > longTranscriptThreshold,
           result.count * 10 < minimumTenthsOfLongTranscript * raw.count {
            return .failure(.truncated)
        }
        return .success(result)
    }

    // MARK: - character classes

    /// Line breaks of every kind: LF, a lone CR, NEL, line and paragraph
    /// separators. They become "\n" and are then kept or collapsed to a space
    /// depending on the transcript, so words never run together.
    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// What the transcript itself contained, which decides the characters that
    /// legitimate text needs only sometimes.
    private struct KeepContext {
        var keepZWJ = false
        var keepZWNJ = false
        var keepBaseVariationSelectors = false
        var keepIdeographicVariationSelectors = false

        init(raw: String.UnicodeScalarView) {
            for s in raw {
                switch s.value {
                case 0x200D: keepZWJ = true
                case 0x200C: keepZWNJ = true
                case 0xFE00...0xFE0D: keepBaseVariationSelectors = true
                case 0xE0100...0xE01EF: keepIdeographicVariationSelectors = true
                case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                    // Arabic script: ZWNJ is part of correct Persian and Arabic.
                    if s.properties.isAlphabetic { keepZWNJ = true }
                default: break
                }
            }
        }
    }

    /// Keeps printable text, and tab. Removes C0 controls (including ESC, which
    /// starts terminal escape sequences), DEL, C1 controls, bidirectional
    /// controls, unassigned and private-use scalars, and invisible characters that
    /// render as nothing or as blank space: format characters (zero-width spaces,
    /// BOM, soft hyphen, tag characters), the combining grapheme joiner, Hangul
    /// and Khmer fillers, the blank braille pattern and the object replacement
    /// character. Some are kept when the transcript itself shows they belong:
    /// zero-width joiner (emoji sequences), zero-width non-joiner (also for any
    /// Arabic-script transcript), and variation selectors. U+FE0E and U+FE0F
    /// (text and emoji presentation) are always kept.
    private static func isAllowed(_ scalar: Unicode.Scalar, context: KeepContext) -> Bool {
        let v = scalar.value
        if v == 0x09 { return true }
        if v < 0x20 || v == 0x7F { return false }
        if v >= 0x80 && v <= 0x9F { return false }
        if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) { return false }

        switch v {
        case 0xFE0E, 0xFE0F: return true
        case 0xFE00...0xFE0D: return context.keepBaseVariationSelectors
        case 0xE0100...0xE01EF: return context.keepIdeographicVariationSelectors
        case 0x200D: return context.keepZWJ
        case 0x200C: return context.keepZWNJ
        case 0x034F, 0x115F, 0x1160, 0x3164, 0x2800, 0x17B4, 0x17B5, 0xFFFC: return false
        default: break
        }

        switch scalar.properties.generalCategory {
        case .format, .unassigned, .privateUse: return false
        default: return true
        }
    }

    /// Runs of newlines, with any spaces or tabs around them, become one space.
    private static func collapseNewlines(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
