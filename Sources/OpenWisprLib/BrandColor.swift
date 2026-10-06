import SwiftUI

/// The app's brand colour palette, extracted from `brand-color-system.md`.
///
/// **Usage:** Always prefer the semantic colours (`background`, `text`,
/// `success`, `danger`, `warning`) over the raw palette colours. The semantic
/// colours adapt to light and dark mode automatically via `@Environment(\.colorScheme)`.
///
/// **Contrast audit (Task 6.2, done — see `BrandColorContrastTests`):** white
/// on emerald is 4.50:1 (passes AA for large text and UI). Sage text on light
/// is 2.79:1 — use only for secondary/hint text, never body. The semantic
/// colours below (`success`/`danger`/`warning` and their `Light`/`Dark`
/// variants) all pass against their matching background except
/// `warningLight` on `lightBackground` (4.15:1) and a white label on
/// `warning` or `warningDark` — `warning` has no call site anywhere in the
/// app yet, so those tokens are documented as failing rather than adjusted;
/// fix them when `warning` actually ships. Fix a token, not the test.
struct BrandColor {
    // MARK: - Raw palette

    static let forestGreen = Color(hex: 0x1B4332)
    static let emerald     = Color(hex: 0x2D8659)
    static let darkBackground  = Color(hex: 0x0D1210)
    static let lightBackground = Color(hex: 0xF7F9F7)
    static let darkText   = Color(hex: 0xE8EDE9)
    static let lightText  = Color(hex: 0x14201B)
    static let sageGray   = Color(hex: 0x8A9A92)

    // MARK: - Semantic colours (status / feedback)

    /// Positive outcome: consent granted, upload succeeded, "on" states.
    static let success     = Color(hex: 0x3D8168)
    /// Destructive or critical: revoke, error, failed.
    static let danger      = Color(hex: 0xC0392B)
    /// Caution: rate limit, expiring token, edge case.
    static let warning     = Color(hex: 0xB8860B)

    // Light-mode variants (slightly adjusted for contrast on lightBackground)
    static let successLight = Color(hex: 0x2E6A52)
    static let dangerLight  = Color(hex: 0xA5311F)
    static let warningLight = Color(hex: 0x9A7209)

    // Dark-mode variants (slightly lighter for contrast on darkBackground)
    static let successDark  = Color(hex: 0x4FA07D)
    static let dangerDark   = Color(hex: 0xE05A4D)
    static let warningDark  = Color(hex: 0xD4A017)

    // MARK: - Adaptive helpers

    /// Returns the background colour for the current colour scheme.
    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkBackground : lightBackground
    }

    /// Returns the primary text colour for the current colour scheme.
    static func text(for scheme: ColorScheme) -> Color {
        scheme == .dark ? darkText : lightText
    }

    /// Returns the semantic success colour for the current colour scheme.
    static func success(for scheme: ColorScheme) -> Color {
        scheme == .dark ? successDark : successLight
    }

    /// Returns the semantic danger colour for the current colour scheme.
    static func danger(for scheme: ColorScheme) -> Color {
        scheme == .dark ? dangerDark : dangerLight
    }

    /// Returns the semantic warning colour for the current colour scheme.
    static func warning(for scheme: ColorScheme) -> Color {
        scheme == .dark ? warningDark : warningLight
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
