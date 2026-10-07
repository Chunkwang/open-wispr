import AppKit
import SwiftUI
import XCTest
@testable import OpenWisprLib

/// WCAG 2.x contrast of every colour pair the sign-in window uses, in both
/// appearances (docs/design/sign-in.md, section 8). The colours come from the same
/// tokens the views read (`SignInPalette`); fix a token, not this test.
final class ContrastTests: XCTestCase {
    /// 8-bit sRGB components of a SwiftUI colour.
    private func rgb(_ color: Color) -> (r: Int, g: Int, b: Int) {
        let ns = NSColor(color).usingColorSpace(.sRGB)!
        return (Int((ns.redComponent * 255).rounded()), Int((ns.greenComponent * 255).rounded()), Int((ns.blueComponent * 255).rounded()))
    }

    private func hex(_ color: Color) -> UInt32 {
        let c = rgb(color)
        return UInt32(c.r << 16 | c.g << 8 | c.b)
    }

    static func relativeLuminance(r: Int, g: Int, b: Int) -> Double {
        func channel(_ value: Int) -> Double {
            let v = Double(value) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    static func contrastRatio(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Double {
        let la = relativeLuminance(r: a.r, g: a.g, b: a.b)
        let lb = relativeLuminance(r: b.r, g: b.g, b: b.b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func ratio(_ fg: Color, _ bg: Color) -> Double {
        ContrastTests.contrastRatio(rgb(fg), rgb(bg))
    }

    func testTheHelperMatchesKnownRatios() {
        XCTAssertEqual(ContrastTests.contrastRatio((0, 0, 0), (255, 255, 255)), 21, accuracy: 0.001)
        XCTAssertEqual(ContrastTests.contrastRatio((255, 255, 255), (255, 255, 255)), 1, accuracy: 0.001)
        // The spec's own figures for the palette values that had to be replaced.
        XCTAssertEqual(ContrastTests.contrastRatio((0x8A, 0x9A, 0x92), (0xF7, 0xF9, 0xF7)), 2.79, accuracy: 0.01)
        XCTAssertEqual(ContrastTests.contrastRatio((0xC0, 0x39, 0x2B), (0x0D, 0x12, 0x10)), 3.48, accuracy: 0.01)
    }

    func testEveryTextPairReachesFourPointFive() {
        for scheme in [ColorScheme.dark, .light] {
            let palette = SignInPalette(scheme)
            for pair in SignInPalette.pairs where pair.minimumRatio == SignInPalette.text {
                let value = ratio(pair.foreground(palette), pair.background(palette))
                XCTAssertGreaterThanOrEqual(value, 4.5, "\(pair.name) in \(scheme): \(value)")
            }
        }
    }

    func testEveryInterfacePartReachesThree() {
        for scheme in [ColorScheme.dark, .light] {
            let palette = SignInPalette(scheme)
            for pair in SignInPalette.pairs where pair.minimumRatio == SignInPalette.graphic {
                let value = ratio(pair.foreground(palette), pair.background(palette))
                XCTAssertGreaterThanOrEqual(value, 3, "\(pair.name) in \(scheme): \(value)")
            }
        }
    }

    func testThePairTableCoversTheSeventeenRowsOfTheSpec() {
        XCTAssertEqual(SignInPalette.pairs.count, 17)
        XCTAssertEqual(SignInPalette.pairs.filter { $0.minimumRatio == 4.5 }.count, 10)
        XCTAssertEqual(SignInPalette.pairs.filter { $0.minimumRatio == 3 }.count, 7)
    }

    func testTheSpecifiedHexValues() {
        let dark = SignInPalette(.dark)
        let light = SignInPalette(.light)
        XCTAssertEqual(hex(dark.background), 0x0D1210)
        XCTAssertEqual(hex(light.background), 0xF7F9F7)
        XCTAssertEqual(hex(dark.text), 0xE8EDE9)
        XCTAssertEqual(hex(light.text), 0x14201B)
        XCTAssertEqual(hex(dark.mutedText), 0x8A9A92)
        XCTAssertEqual(hex(light.mutedText), 0x55645C)
        XCTAssertEqual(hex(dark.errorText), 0xF0776A)
        XCTAssertEqual(hex(light.errorText), 0xC0392B)
        XCTAssertEqual(hex(dark.fieldFill), 0x151C18)
        XCTAssertEqual(hex(light.fieldFill), 0xFFFFFF)
        XCTAssertEqual(hex(dark.fieldStroke), 0x6B7B73)
        XCTAssertEqual(hex(light.fieldStroke), 0x66766E)
        XCTAssertEqual(hex(dark.buttonFill), 0x2D8659)
        XCTAssertEqual(hex(light.buttonFill), 0x2D8659)
        XCTAssertEqual(hex(dark.buttonFillPressed), 0x26724C)
        XCTAssertEqual(hex(dark.disabledFill), 0x1E2823)
        XCTAssertEqual(hex(light.disabledFill), 0xDDE4DF)
        XCTAssertEqual(hex(dark.successGlyph), 0x3D8168)
    }

    /// The palette additions are additions only: the tokens that existed before
    /// keep their values.
    func testTheExistingBrandColoursAreUnchanged() {
        XCTAssertEqual(hex(BrandColor.forestGreen), 0x1B4332)
        XCTAssertEqual(hex(BrandColor.emerald), 0x2D8659)
        XCTAssertEqual(hex(BrandColor.darkBackground), 0x0D1210)
        XCTAssertEqual(hex(BrandColor.lightBackground), 0xF7F9F7)
        XCTAssertEqual(hex(BrandColor.darkText), 0xE8EDE9)
        XCTAssertEqual(hex(BrandColor.lightText), 0x14201B)
        XCTAssertEqual(hex(BrandColor.sageGray), 0x8A9A92)
    }

    /// Emerald is a fill and a stroke only: never the colour of text on the window.
    func testNoTextRoleUsesEmerald() {
        for scheme in [ColorScheme.dark, .light] {
            let palette = SignInPalette(scheme)
            let textColours = [palette.text, palette.mutedText, palette.errorText, palette.disabledLabel]
            for colour in textColours { XCTAssertNotEqual(hex(colour), hex(BrandColor.emerald)) }
        }
    }
}
