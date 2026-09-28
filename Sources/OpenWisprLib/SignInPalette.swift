import SwiftUI

/// Accessible variants the sign-in window needs (docs/design/sign-in.md, section 3).
/// Additions only: no existing `BrandColor` value changes. Each value was chosen
/// because the palette's own colour fails contrast for the role, and
/// `ContrastTests` computes the WCAG ratio of every pair the window uses.
///
/// `brand-color-system.md` still has to learn about these (founder decision).
extension BrandColor {
    /// Muted text on the light background. `sageGray` is 2.79:1 there (fails);
    /// this is 5.90:1. Sage stays the muted colour on dark.
    static let sageOnLight = Color(hex: 0x55645C)
    /// Error text and icon on the dark background. The palette's danger red is
    /// 3.48:1 there (fails); this is 6.80:1.
    static let dangerOnDark = Color(hex: 0xF0776A)
    /// The palette's danger red, for error text on the light background (5.14:1).
    static let dangerOnLight = Color(hex: 0xC0392B)
    static let fieldFillDark = Color(hex: 0x151C18)
    static let fieldFillLight = Color(hex: 0xFFFFFF)
    static let fieldStrokeDark = Color(hex: 0x6B7B73)
    static let fieldStrokeLight = Color(hex: 0x66766E)
    /// Emerald darkened for the pressed primary button.
    static let emeraldPressed = Color(hex: 0x26724C)
    static let disabledFillDark = Color(hex: 0x1E2823)
    static let disabledFillLight = Color(hex: 0xDDE4DF)
    /// Check mark on the signed-in screen: a graphic with text beside it.
    static let successGlyph = Color(hex: 0x3D8168)
    /// Label on the emerald primary button.
    static let onEmerald = Color(hex: 0xFFFFFF)
}

/// The colours of the sign-in window for one appearance. Views read colours only
/// from here, so the contrast table below covers every pair on screen.
struct SignInPalette {
    let isDark: Bool

    init(_ scheme: ColorScheme) { isDark = scheme == .dark }

    var background: Color { isDark ? BrandColor.darkBackground : BrandColor.lightBackground }
    var text: Color { isDark ? BrandColor.darkText : BrandColor.lightText }
    var mutedText: Color { isDark ? BrandColor.sageGray : BrandColor.sageOnLight }
    var fieldFill: Color { isDark ? BrandColor.fieldFillDark : BrandColor.fieldFillLight }
    var fieldStroke: Color { isDark ? BrandColor.fieldStrokeDark : BrandColor.fieldStrokeLight }
    var errorText: Color { isDark ? BrandColor.dangerOnDark : BrandColor.dangerOnLight }
    var buttonFill: Color { BrandColor.emerald }
    var buttonFillPressed: Color { BrandColor.emeraldPressed }
    var buttonLabel: Color { BrandColor.onEmerald }
    var disabledFill: Color { isDark ? BrandColor.disabledFillDark : BrandColor.disabledFillLight }
    var disabledLabel: Color { mutedText }
    var successGlyph: Color { BrandColor.successGlyph }
    /// The keyboard focus ring and the focused field's stroke.
    var focusStroke: Color { BrandColor.emerald }

    /// One foreground/background pair on the window and the ratio it must reach:
    /// 4.5 for text, 3 for parts of the interface (borders, focus ring, glyphs).
    struct Pair {
        let name: String
        let foreground: (SignInPalette) -> Color
        let background: (SignInPalette) -> Color
        let minimumRatio: Double
    }

    static let text = 4.5
    static let graphic = 3.0

    /// Every pair section 8.1 lists. The views use no colour that is not in a pair.
    static let pairs: [Pair] = [
        Pair(name: "body text on window", foreground: { $0.text }, background: { $0.background }, minimumRatio: text),
        Pair(name: "muted text on window", foreground: { $0.mutedText }, background: { $0.background }, minimumRatio: text),
        Pair(name: "typed text on field", foreground: { $0.text }, background: { $0.fieldFill }, minimumRatio: text),
        Pair(name: "placeholder on field", foreground: { $0.mutedText }, background: { $0.fieldFill }, minimumRatio: text),
        Pair(name: "error text on window", foreground: { $0.errorText }, background: { $0.background }, minimumRatio: text),
        Pair(name: "primary label", foreground: { $0.buttonLabel }, background: { $0.buttonFill }, minimumRatio: text),
        Pair(name: "primary label pressed", foreground: { $0.buttonLabel }, background: { $0.buttonFillPressed }, minimumRatio: text),
        Pair(name: "secondary label on window", foreground: { $0.text }, background: { $0.background }, minimumRatio: text),
        Pair(name: "disabled primary label", foreground: { $0.disabledLabel }, background: { $0.disabledFill }, minimumRatio: text),
        Pair(name: "disabled secondary label on window", foreground: { $0.mutedText }, background: { $0.background }, minimumRatio: text),
        Pair(name: "field border on window", foreground: { $0.fieldStroke }, background: { $0.background }, minimumRatio: graphic),
        Pair(name: "field border on field", foreground: { $0.fieldStroke }, background: { $0.fieldFill }, minimumRatio: graphic),
        Pair(name: "secondary border on window", foreground: { $0.fieldStroke }, background: { $0.background }, minimumRatio: graphic),
        Pair(name: "focus stroke on field", foreground: { $0.focusStroke }, background: { $0.fieldFill }, minimumRatio: graphic),
        Pair(name: "focus stroke on window", foreground: { $0.focusStroke }, background: { $0.background }, minimumRatio: graphic),
        Pair(name: "primary fill on window", foreground: { $0.buttonFill }, background: { $0.background }, minimumRatio: graphic),
        Pair(name: "success glyph on window", foreground: { $0.successGlyph }, background: { $0.background }, minimumRatio: graphic),
    ]
}
