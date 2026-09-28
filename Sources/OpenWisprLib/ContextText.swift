import Foundation

/// Cleans and caps text that was read from another app before it goes into a
/// `ContextSnapshot`. The source is untrusted: a page or document can hide
/// instructions in characters that render as nothing, or use bidirectional
/// controls to make text read differently from how it is stored. The character
/// rules follow `RewriteSanitizer` (controls, bidi controls, format characters,
/// fillers and unassigned scalars are removed) with two differences on purpose:
///
/// - There is no "shorter than the input means truncated" rule; a cap here is a
///   plain cap and the result says whether it was applied.
/// - The zero-width joiner and non-joiner cannot be kept "because the transcript
///   had one" (the source is the attacker's, not the user's speech). They are kept
///   only between two visible characters, where emoji sequences and Persian
///   spelling need them, and never in runs. Variation selectors other than
///   U+FE0E and U+FE0F are removed: they can carry hidden data.
enum ContextText {
    struct Cleaned: Equatable {
        /// nil when nothing printable is left.
        let text: String?
        /// The input was longer than the cap and was cut.
        let truncated: Bool
        /// At least one scalar was removed as unsafe or invisible.
        let removedUnsafe: Bool
    }

    /// `multiline` keeps line feeds and tabs (selected text). Otherwise every line
    /// break and tab becomes a space, runs of spaces collapse and the ends are
    /// trimmed (window titles, app names).
    static func clean(_ input: String, maxScalars: Int, multiline: Bool) -> Cleaned {
        guard maxScalars > 0 else { return Cleaned(text: nil, truncated: !input.isEmpty, removedUnsafe: false) }

        // Bound the work on hostile input: a huge run of removable scalars must
        // not make the scan unbounded.
        let scanLimit = maxScalars * 4 + 64
        var output = String.UnicodeScalarView()
        var outputCount = 0
        var scanned = 0
        var truncated = false
        var removed = false
        var previousInput: Unicode.Scalar?
        var pendingJoiner: Unicode.Scalar?
        var lastKeptWasVisible = false

        func emit(_ scalar: Unicode.Scalar) -> Bool {
            if outputCount >= maxScalars { truncated = true; return false }
            output.append(scalar)
            outputCount += 1
            return true
        }

        scan: for scalar in input.unicodeScalars {
            scanned += 1
            if scanned > scanLimit { truncated = true; break scan }
            defer { previousInput = scalar }

            if scalar == "\n" && previousInput == "\r" { continue }   // CRLF is one break

            // A held joiner survives only if this scalar is visible.
            if let joiner = pendingJoiner {
                pendingJoiner = nil
                if isVisible(scalar) {
                    if !emit(joiner) { break scan }
                } else {
                    removed = true
                }
            }

            if scalar == "\u{200D}" || scalar == "\u{200C}" {
                if lastKeptWasVisible { pendingJoiner = scalar } else { removed = true }
                continue
            }

            if isLineBreak(scalar) {
                lastKeptWasVisible = false
                if multiline { if !emit("\n") { break scan } } else if !emit(" ") { break scan }
                continue
            }
            if scalar == "\t" {
                lastKeptWasVisible = false
                if !emit(multiline ? "\t" : " ") { break scan }
                continue
            }
            guard isAllowed(scalar) else { removed = true; continue }
            lastKeptWasVisible = isVisible(scalar)
            if !emit(scalar) { break scan }
        }
        if pendingJoiner != nil { removed = true }   // a joiner at the very end joins nothing

        var result = String(output)
        if !multiline { result = collapseSpaces(result) }
        // Whitespace-only text counts as nothing. Multi-line text keeps its exact
        // spacing otherwise: trimming it would change what a later replace covers.
        let isBlank = result.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        if isBlank { return Cleaned(text: nil, truncated: truncated, removedUnsafe: removed) }
        return Cleaned(text: result, truncated: truncated, removedUnsafe: removed)
    }

    /// Characters that are only ever identifiers (bundle ids, AX roles): ASCII
    /// letters, digits and `._-`, at most `maxScalars`. Anything else gives nil.
    static func identifier(_ input: String, maxScalars: Int) -> String? {
        guard !input.isEmpty, input.unicodeScalars.count <= maxScalars else { return nil }
        for s in input.unicodeScalars {
            switch s.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2E, 0x5F, 0x2D: continue
            default: return nil
            }
        }
        return input
    }

    // MARK: - character classes

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// Not blank space and not a joiner: something the reader can see.
    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\u{200D}" || scalar == "\u{200C}" { return false }
        if isLineBreak(scalar) || scalar == "\t" { return false }
        guard isAllowed(scalar) else { return false }
        return !scalar.properties.isWhitespace
    }

    /// Same classes as `RewriteSanitizer.isAllowed` with no transcript context:
    /// C0/DEL/C1 controls, bidi controls, base and ideographic variation selectors,
    /// invisible fillers, and format, unassigned and private-use scalars are out.
    /// U+FE0E and U+FE0F (text and emoji presentation) stay.
    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v < 0x20 || v == 0x7F { return false }
        if v >= 0x80 && v <= 0x9F { return false }
        if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) { return false }
        switch v {
        case 0xFE0E, 0xFE0F: return true
        case 0xFE00...0xFE0D, 0xE0100...0xE01EF: return false
        case 0x034F, 0x115F, 0x1160, 0x3164, 0x2800, 0x17B4, 0x17B5, 0xFFFC: return false
        default: break
        }
        switch scalar.properties.generalCategory {
        case .format, .unassigned, .privateUse, .control: return false
        default: return true
        }
    }

    private static func collapseSpaces(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = true   // drops leading spaces
        for s in text.unicodeScalars {
            if s.properties.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(s)
                lastWasSpace = false
            }
        }
        var result = String(out)
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}
